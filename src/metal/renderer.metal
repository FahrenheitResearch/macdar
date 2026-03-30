#include "metal_common.h"
#include <metal_stdlib>
using namespace metal;

// ── Constants ──────────────────────────────────────────────────

constant uint kBackgroundColor = 0xFF140F0Fu;   // ABGR: dark background
constant ulong kEmptyForwardPixel = ~0ull;

// SPATIAL_GRID_W, SPATIAL_GRID_H, MAX_STATIONS_PER_CELL, MAX_STATIONS
// are defined in metal_common.h

// M_PI_F is provided by <metal_stdlib>

// GpuStationInfo, GpuViewport, and SpatialGrid are defined in metal_common.h

// ── Kernel parameter structs ───────────────────────────────────

struct NativeRenderParams {
    GpuViewport vp;
    int num_stations;
    int product;
    float dbz_min;
};

struct SingleStationParams {
    GpuViewport vp;
    GpuStationInfo info;
    int product;
    float dbz_min;
    float srv_speed;
    float srv_dir_rad;
};

struct ForwardRenderParams {
    GpuViewport vp;
    GpuStationInfo info;
    int product;
    float dbz_min;
    float srv_speed;
    float srv_dir_rad;
};

// ── Helper functions ───────────────────────────────────────────

inline uint makeRGBA(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
    return uint(r) | (uint(g) << 8) | (uint(b) << 16) | (uint(a) << 24);
}

inline float angleDiffDeg(float a, float b) {
    float d = abs(a - b);
    return (d > 180.0f) ? (360.0f - d) : d;
}

inline float positiveAngleDeltaDeg(float from, float to) {
    float d = to - from;
    if (d < 0.0f) d += 360.0f;
    return d;
}

inline float wrapAngleDeg(float angle) {
    while (angle < 0.0f) angle += 360.0f;
    while (angle >= 360.0f) angle -= 360.0f;
    return angle;
}

inline float productThreshold(int product, float dbz_min) {
    if (product == PROD_VEL || product == PROD_ZDR || product == PROD_KDP || product == PROD_PHI)
        return -999.0f;
    if (product == PROD_CC) return 0.3f;
    if (product == PROD_SW) return 0.5f;
    return dbz_min;
}

inline bool passesThreshold(int product, float value, float threshold) {
    if (value <= -998.0f) return false;
    if (product == PROD_VEL)
        return abs(value) >= max(threshold, 0.0f);
    return value >= productThreshold(product, threshold);
}

inline void productColorRange(int product, thread float& min_val, thread float& max_val) {
    switch (product) {
        case PROD_REF: min_val = -30.0f; max_val = 75.0f; break;
        case PROD_VEL: min_val = -64.0f; max_val = 64.0f; break;
        case PROD_SW:  min_val = 0.0f;   max_val = 30.0f; break;
        case PROD_ZDR: min_val = -8.0f;  max_val = 8.0f; break;
        case PROD_CC:  min_val = 0.2f;   max_val = 1.05f; break;
        case PROD_KDP: min_val = -10.0f; max_val = 15.0f; break;
        default:       min_val = 0.0f;   max_val = 360.0f; break;
    }
}

inline float normalizedColorCoord(float value, int product) {
    float min_val, max_val;
    productColorRange(product, min_val, max_val);
    float norm = (value - min_val) / (max_val - min_val);
    norm = min(max(norm, 0.0f), 1.0f);
    return (norm * 254.0f + 1.0f) / 256.0f;
}

// 32-bit depth key: upper 16 bits = depth (quantized range), lower 16 bits = color index
// This avoids 64-bit atomics which have limited Metal support.
inline uint forwardDepthKey32(float range_km, uint rgba) {
    // Quantize range to 16-bit (0-460km at ~7m resolution)
    uint depth16 = uint(min(max(range_km * 142.0f, 0.0f), 65534.0f));
    // Pack: depth in high 16 bits (for min-sorting), color index in low 16 bits
    // Store full RGBA separately — use depth-only atomic, then resolve color
    return (depth16 << 16) | (rgba & 0xFFFFu);
}

// Use two 32-bit atomics: one for packed depth+colorHi, one for colorLo
// Or simpler: just use atomic_min on a 32-bit depth key, store color in a parallel buffer
inline void atomicMinDepth(volatile device atomic_uint* depthBuf,
                           device uint* colorBuf,
                           uint pixelIdx, float range_km, uint rgba) {
    uint depth16 = uint(min(max(range_km * 142.0f, 0.0f), 65534.0f));
    uint old = atomic_load_explicit(depthBuf, memory_order_relaxed);
    while (depth16 < (old >> 16)) {
        uint desired = (depth16 << 16) | (rgba & 0xFFFFu);
        bool success = atomic_compare_exchange_weak_explicit(
            depthBuf, &old, desired,
            memory_order_relaxed, memory_order_relaxed);
        if (success) {
            colorBuf[pixelIdx] = rgba;
            break;
        }
    }
}

// Binary search for nearest azimuth index (sorted ascending).
// Works with device memory pointer.
inline int bsearchAz(const device float* az, int n, float target) {
    int lo = 0, hi = n - 1;
    while (lo < hi) {
        int mid = (lo + hi) >> 1;
        if (az[mid] < target) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

// Overload for threadgroup memory (used by single_station_render).
inline int bsearchAz(threadgroup float* az, int n, float target) {
    int lo = 0, hi = n - 1;
    while (lo < hi) {
        int mid = (lo + hi) >> 1;
        if (az[mid] < target) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

// Sample a station's data given azimuth and range.
// Uses the indirect-buffer approach: all_azimuths and all_gates are large
// concatenated buffers; per-station offsets index into them.
inline float sampleStation(
    const device GpuStationInfo& info,
    const device float* azimuths,
    const device ushort* gates,
    float az, float range_km, int product, float dbz_min)
{
    if (!info.has_product[product]) return -999.0f;

    int ng = info.num_gates[product];
    int nr = info.num_radials;
    float fgkm = info.first_gate_km[product];
    float gskm = info.gate_spacing_km[product];
    if (ng <= 0 || nr <= 0 || gskm <= 0.0f) return -999.0f;

    float max_range = fgkm + ng * gskm;
    if (range_km < fgkm || range_km > max_range) return -999.0f;

    // Nearest radial with fallback (fills beam width)
    int idx_hi = bsearchAz(azimuths, nr, az);
    int idx_lo = (idx_hi == 0) ? nr - 1 : idx_hi - 1;
    if (idx_hi >= nr) idx_hi = 0;

    float d_lo = angleDiffDeg(az, azimuths[idx_lo]);
    float d_hi = angleDiffDeg(az, azimuths[idx_hi]);

    int gi = int((range_km - fgkm) / gskm);
    if (gi < 0 || gi >= ng) return -999.0f;

    int ri_first  = (d_lo <= d_hi) ? idx_lo : idx_hi;
    int ri_second = (d_lo <= d_hi) ? idx_hi : idx_lo;
    ushort raw = gates[gi * nr + ri_first];
    if (raw <= 1) raw = gates[gi * nr + ri_second];
    if (raw <= 1) return -999.0f;

    float sc = info.scale[product], off = info.offset[product];
    float value = (float(raw) - off) / sc;

    if (!passesThreshold(product, value, dbz_min)) return -999.0f;

    return value;
}

// ── Forward-render helper functions ────────────────────────────

inline float2 polarToScreen(float range_km, float az_rad,
                             float slat, float slon,
                             constant GpuViewport& vp) {
    float cos_lat = cos(slat * M_PI_F / 180.0f);
    float east_km  = range_km * sin(az_rad);
    float north_km = range_km * cos(az_rad);
    float lon_off = east_km / (111.0f * cos_lat);
    float lat_off = north_km / 111.0f;
    float px = ((slon + lon_off) - vp.center_lon) / vp.deg_per_pixel_x + vp.width * 0.5f;
    float py = (vp.center_lat - (slat + lat_off)) / vp.deg_per_pixel_y + vp.height * 0.5f;
    return float2(px, py);
}

// Overload for non-constant viewport (used in forward_render where params is constant
// but we extract vp).
inline float2 polarToScreen(float range_km, float az_rad,
                             float slat, float slon,
                             GpuViewport vp) {
    float cos_lat = cos(slat * M_PI_F / 180.0f);
    float east_km  = range_km * sin(az_rad);
    float north_km = range_km * cos(az_rad);
    float lon_off = east_km / (111.0f * cos_lat);
    float lat_off = north_km / 111.0f;
    float px = ((slon + lon_off) - vp.center_lon) / vp.deg_per_pixel_x + vp.width * 0.5f;
    float py = (vp.center_lat - (slat + lat_off)) / vp.deg_per_pixel_y + vp.height * 0.5f;
    return float2(px, py);
}

inline float radialBoundaryStartDeg(const device float* azimuths, int nr, int ri) {
    float curr = azimuths[ri];
    float prev = azimuths[(ri + nr - 1) % nr];
    float nominal = 360.0f / max(float(nr), 1.0f);
    float min_half = max(0.25f * nominal, 0.05f);
    float max_half = max(2.0f * nominal, 1.0f);
    float half_gap = 0.5f * positiveAngleDeltaDeg(prev, curr);
    half_gap = min(max(half_gap, min_half), max_half);
    return wrapAngleDeg(curr - half_gap);
}

inline float radialBoundaryEndDeg(const device float* azimuths, int nr, int ri) {
    float curr = azimuths[ri];
    float next = azimuths[(ri + 1) % nr];
    float nominal = 360.0f / max(float(nr), 1.0f);
    float min_half = max(0.25f * nominal, 0.05f);
    float max_half = max(2.0f * nominal, 1.0f);
    float half_gap = 0.5f * positiveAngleDeltaDeg(curr, next);
    half_gap = min(max(half_gap, min_half), max_half);
    return wrapAngleDeg(curr + half_gap);
}

inline bool pointInConvexQuad(float2 corners[4], float px, float py) {
    bool saw_pos = false;
    bool saw_neg = false;
    for (int e = 0; e < 4; e++) {
        float2 a = corners[e];
        float2 b = corners[(e + 1) & 3];
        float cross_val = (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
        saw_pos |= (cross_val > 0.01f);
        saw_neg |= (cross_val < -0.01f);
        if (saw_pos && saw_neg) return false;
    }
    return true;
}

// ── Kernel 1: native_render (mosaic, one thread per pixel) ─────

kernel void native_render(
    const device GpuStationInfo* stations       [[buffer(0)]],
    const device float*          all_azimuths   [[buffer(1)]],
    const device ushort*         all_gates      [[buffer(2)]],
    const device int*            station_azimuth_offsets [[buffer(3)]],
    const device int*            station_gate_offsets    [[buffer(4)]],
    const device SpatialGrid*    grid           [[buffer(5)]],
    device uint*                 output         [[buffer(6)]],
    constant NativeRenderParams& params         [[buffer(7)]],
    texture1d<float>             colorTex       [[texture(0)]],
    sampler                      colorSampler   [[sampler(0)]],
    uint2                        gid            [[thread_position_in_grid]])
{
    int px = int(gid.x);
    int py = int(gid.y);
    if (px >= params.vp.width || py >= params.vp.height) return;

    float lon = params.vp.center_lon + (px - params.vp.width * 0.5f) * params.vp.deg_per_pixel_x;
    float lat = params.vp.center_lat - (py - params.vp.height * 0.5f) * params.vp.deg_per_pixel_y;

    // Background
    uint result = makeRGBA(15, 15, 20, 255);

    // Spatial grid lookup
    float gfx = (lon - grid->min_lon) / (grid->max_lon - grid->min_lon) * SPATIAL_GRID_W;
    float gfy = (lat - grid->min_lat) / (grid->max_lat - grid->min_lat) * SPATIAL_GRID_H;
    int gx = int(gfx), gy = int(gfy);

    if (gx < 0 || gx >= SPATIAL_GRID_W || gy < 0 || gy >= SPATIAL_GRID_H) {
        output[py * params.vp.width + px] = result;
        return;
    }

    int count = grid->counts[gy][gx];
    if (count > MAX_STATIONS_PER_CELL) count = MAX_STATIONS_PER_CELL;
    float best_value = -999.0f;
    float best_range = 1e9f;

    int product = params.product;

    // Check each station in this cell
    for (int ci = 0; ci < count; ci++) {
        int si = grid->cells[gy][gx][ci];
        if (si < 0 || si >= params.num_stations) continue;

        const device GpuStationInfo& info = stations[si];

        // Distance in km (flat earth approx, good for <500km)
        float dlat_km = (lat - info.lat) * 111.0f;
        float dlon_km = (lon - info.lon) * 111.0f * cos(info.lat * M_PI_F / 180.0f);
        float range_km = sqrt(dlat_km * dlat_km + dlon_km * dlon_km);

        if (range_km > 460.0f) continue;

        float az = atan2(dlon_km, dlat_km) * (180.0f / M_PI_F);
        if (az < 0.0f) az += 360.0f;

        // Get per-station azimuth and gate pointers via offsets
        const device float*  sta_az    = all_azimuths + station_azimuth_offsets[si];
        const device ushort* sta_gates = all_gates + station_gate_offsets[si];

        float val = sampleStation(info, sta_az, sta_gates,
                                  az, range_km, product, params.dbz_min);
        if (val > -998.0f && range_km < best_range) {
            best_value = val;
            best_range = range_km;
        }
    }

    if (best_value <= -998.0f) {
        output[py * params.vp.width + px] = result;
        return;
    }

    // Map value to color via hardware-interpolated texture
    float tex_coord = normalizedColorCoord(best_value, product);
    float4 tc = colorTex.sample(colorSampler, tex_coord);

    if (tc.w < 0.01f) {
        output[py * params.vp.width + px] = result;
        return;
    }

    // Blend over background using texture alpha
    uint8_t br = result & 0xFF;
    uint8_t bg = (result >> 8) & 0xFF;
    uint8_t bb = (result >> 16) & 0xFF;
    result = makeRGBA(
        uint8_t(br * (1.0f - tc.w) + tc.x * 255.0f * tc.w),
        uint8_t(bg * (1.0f - tc.w) + tc.y * 255.0f * tc.w),
        uint8_t(bb * (1.0f - tc.w) + tc.z * 255.0f * tc.w), 255);

    output[py * params.vp.width + px] = result;
}

// ── Kernel 2: single_station_render (shared-memory azimuths) ───

kernel void single_station_render(
    const device float*          azimuths     [[buffer(0)]],
    const device ushort*         gates        [[buffer(1)]],
    device uint*                 output       [[buffer(2)]],
    constant SingleStationParams& params      [[buffer(3)]],
    texture1d<float>             colorTex     [[texture(0)]],
    sampler                      colorSampler [[sampler(0)]],
    uint2                        gid          [[thread_position_in_grid]],
    uint2                        lid          [[thread_position_in_threadgroup]],
    uint2                        tg_size      [[threads_per_threadgroup]])
{
    // Shared memory for azimuths - cooperative load
    threadgroup float s_az[MAX_RADIALS];

    uint tid = lid.y * tg_size.x + lid.x;
    uint block_size = tg_size.x * tg_size.y;
    for (uint i = tid; i < uint(params.info.num_radials); i += block_size)
        s_az[i] = azimuths[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int px = int(gid.x);
    int py = int(gid.y);
    if (px >= params.vp.width || py >= params.vp.height) return;

    float lon = params.vp.center_lon + (px - params.vp.width * 0.5f) * params.vp.deg_per_pixel_x;
    float lat = params.vp.center_lat - (py - params.vp.height * 0.5f) * params.vp.deg_per_pixel_y;

    uint bg = kBackgroundColor;
    int product = params.product;

    int ng = params.info.num_gates[product];
    int nr = params.info.num_radials;
    float fgkm = params.info.first_gate_km[product];
    float gskm = params.info.gate_spacing_km[product];
    if (ng <= 0 || nr <= 0 || gskm <= 0.0f) {
        output[py * params.vp.width + px] = bg;
        return;
    }

    // Distance from station
    float dlat_km = (lat - params.info.lat) * 111.0f;
    float dlon_km = (lon - params.info.lon) * 111.0f * cos(params.info.lat * M_PI_F / 180.0f);
    float range_km = sqrt(dlat_km * dlat_km + dlon_km * dlon_km);

    float max_range = fgkm + ng * gskm;
    if (range_km < fgkm || range_km > max_range) {
        output[py * params.vp.width + px] = bg;
        return;
    }

    // Azimuth
    float az = atan2(dlon_km, dlat_km) * (180.0f / M_PI_F);
    if (az < 0.0f) az += 360.0f;

    // Binary search in shared memory azimuths
    int idx_hi = bsearchAz(s_az, nr, az);
    int idx_lo = (idx_hi == 0) ? nr - 1 : idx_hi - 1;
    if (idx_hi >= nr) idx_hi = 0;

    float d_lo = angleDiffDeg(az, s_az[idx_lo]);
    float d_hi = angleDiffDeg(az, s_az[idx_hi]);

    // Nearest gate
    int gi = int((range_km - fgkm) / gskm);
    if (gi < 0 || gi >= ng) {
        output[py * params.vp.width + px] = bg;
        return;
    }

    // Try nearest radial first, then fallback
    int ri_first  = (d_lo <= d_hi) ? idx_lo : idx_hi;
    int ri_second = (d_lo <= d_hi) ? idx_hi : idx_lo;

    ushort raw = gates[gi * nr + ri_first];
    if (raw <= 1) raw = gates[gi * nr + ri_second];
    if (raw <= 1) {
        output[py * params.vp.width + px] = bg;
        return;
    }

    float sc = params.info.scale[product];
    float off = params.info.offset[product];
    float value = (float(raw) - off) / sc;

    // Storm-Relative Velocity adjustment
    if (params.srv_speed > 0.0f && product == PROD_VEL) {
        float az_rad = s_az[ri_first] * (M_PI_F / 180.0f);
        value -= params.srv_speed * cos(az_rad - params.srv_dir_rad);
    }

    if (!passesThreshold(product, value, params.dbz_min)) {
        output[py * params.vp.width + px] = bg;
        return;
    }

    // Color via hardware texture
    float tc_coord = normalizedColorCoord(value, product);
    float4 tc = colorTex.sample(colorSampler, tc_coord);

    if (tc.w < 0.01f) {
        output[py * params.vp.width + px] = bg;
        return;
    }

    uint8_t br = bg & 0xFF;
    uint8_t bgg = (bg >> 8) & 0xFF;
    uint8_t bb = (bg >> 16) & 0xFF;
    output[py * params.vp.width + px] = makeRGBA(
        uint8_t(br * (1.0f - tc.w) + tc.x * 255.0f * tc.w),
        uint8_t(bgg * (1.0f - tc.w) + tc.y * 255.0f * tc.w),
        uint8_t(bb * (1.0f - tc.w) + tc.z * 255.0f * tc.w), 255);
}

// ── Kernel 3: clear_output ─────────────────────────────────────

kernel void clear_output(
    device uint*      output [[buffer(0)]],
    constant int2&    dims   [[buffer(1)]],
    constant uint&    color  [[buffer(2)]],
    uint2             gid    [[thread_position_in_grid]])
{
    int px = int(gid.x);
    int py = int(gid.y);
    if (px < dims.x && py < dims.y)
        output[py * dims.x + px] = color;
}

// ── Kernel 4: forward_render (one thread per radial/gate pair) ─

kernel void forward_render(
    const device float*          azimuths     [[buffer(0)]],
    const device ushort*         gates        [[buffer(1)]],
    volatile device atomic_uint* depthBuf     [[buffer(2)]],
    device uint*                 colorBuf     [[buffer(3)]],
    constant ForwardRenderParams& params      [[buffer(4)]],
    texture1d<float>             colorTex     [[texture(0)]],
    sampler                      colorSampler [[sampler(0)]],
    uint2                        gid          [[thread_position_in_grid]])
{
    int ri = int(gid.x);
    int gi = int(gid.y);

    int nr = params.info.num_radials;
    int ng = params.info.num_gates[params.product];
    if (ri >= nr || gi >= ng) return;

    int product = params.product;

    // Early exit: empty gate
    ushort raw = gates[gi * nr + ri];
    if (raw <= 1) return;

    float sc = params.info.scale[product];
    float off = params.info.offset[product];
    float value = (float(raw) - off) / sc;

    // SRV: subtract storm motion component from velocity
    if (params.srv_speed > 0.0f && product == PROD_VEL) {
        float az_rad = azimuths[ri] * (M_PI_F / 180.0f);
        value -= params.srv_speed * cos(az_rad - params.srv_dir_rad);
    }

    if (!passesThreshold(product, value, params.dbz_min)) return;

    // Color lookup
    float tc = normalizedColorCoord(value, product);
    float4 col = colorTex.sample(colorSampler, tc);
    if (col.w < 0.01f) return;
    uint rgba = makeRGBA(uint8_t(col.x * 255.0f), uint8_t(col.y * 255.0f),
                          uint8_t(col.z * 255.0f), 255);

    // Compute polar quad screen-space corners
    float az0 = radialBoundaryStartDeg(azimuths, nr, ri) * (M_PI_F / 180.0f);
    float az1 = radialBoundaryEndDeg(azimuths, nr, ri) * (M_PI_F / 180.0f);
    float gskm = params.info.gate_spacing_km[product];
    float r0 = params.info.first_gate_km[product] + gi * gskm;
    float r1 = r0 + gskm;

    GpuViewport vp = params.vp;
    float slat = params.info.lat;
    float slon = params.info.lon;

    float2 c0 = polarToScreen(r0, az0, slat, slon, vp);
    float2 c1 = polarToScreen(r1, az0, slat, slon, vp);
    float2 c2 = polarToScreen(r1, az1, slat, slon, vp);
    float2 c3 = polarToScreen(r0, az1, slat, slon, vp);

    // Bounding box (clipped to viewport)
    int ix0 = max(0, int(floor(min(min(c0.x, c1.x), min(c2.x, c3.x)))));
    int ix1 = min(vp.width - 1, int(ceil(max(max(c0.x, c1.x), max(c2.x, c3.x)))));
    int iy0 = max(0, int(floor(min(min(c0.y, c1.y), min(c2.y, c3.y)))));
    int iy1 = min(vp.height - 1, int(ceil(max(max(c0.y, c1.y), max(c2.y, c3.y)))));

    if (ix0 > ix1 || iy0 > iy1) return;

    float2 corners[4] = {c0, c1, c2, c3};
    float range_mid = r0 + 0.5f * gskm;
    uint depth16 = uint(min(max(range_mid * 142.0f, 0.0f), 65534.0f));

    for (int py = iy0; py <= iy1; py++) {
        for (int ppx = ix0; ppx <= ix1; ppx++) {
            float fx = float(ppx) + 0.5f;
            float fy = float(py) + 0.5f;
            if (pointInConvexQuad(corners, fx, fy)) {
                uint pixelIdx = uint(py * vp.width + ppx);
                uint old = atomic_load_explicit(&depthBuf[pixelIdx], memory_order_relaxed);
                while (depth16 < (old >> 16)) {
                    uint desired = (depth16 << 16) | (rgba & 0xFFFFu);
                    bool ok = atomic_compare_exchange_weak_explicit(
                        &depthBuf[pixelIdx], &old, desired,
                        memory_order_relaxed, memory_order_relaxed);
                    if (ok) {
                        colorBuf[pixelIdx] = rgba;
                        break;
                    }
                }
            }
        }
    }
}

// ── Kernel 5: forward_resolve ──────────────────────────────────

kernel void forward_resolve(
    const device uint* depthBuf [[buffer(0)]],
    const device uint* colorBuf [[buffer(1)]],
    device uint*       output   [[buffer(2)]],
    constant int2&     dims     [[buffer(3)]],
    uint2              gid      [[thread_position_in_grid]])
{
    int px = int(gid.x);
    int py = int(gid.y);
    if (px >= dims.x || py >= dims.y) return;

    uint idx = uint(py * dims.x + px);
    uint depth = depthBuf[idx];
    // 0xFFFFFFFF means no pixel was written (initialized to all 1s)
    output[idx] = (depth == 0xFFFFFFFFu) ? kBackgroundColor : colorBuf[idx];
}

// ── Kernel 6: build_spatial_grid ───────────────────────────────

kernel void build_spatial_grid(
    const device GpuStationInfo* stations [[buffer(0)]],
    const device uint8_t*        active   [[buffer(1)]],
    device SpatialGrid*          grid     [[buffer(2)]],
    constant uint&               num_stations [[buffer(3)]],
    uint                         tid      [[thread_position_in_grid]])
{
    int si = int(tid);
    if (si >= int(num_stations) || !active[si]) return;

    float slat = stations[si].lat;
    float slon = stations[si].lon;
    float lat_range = grid->max_lat - grid->min_lat;
    float lon_range = grid->max_lon - grid->min_lon;
    float max_range_deg = 460.0f / 111.0f;

    int gx_min = int((slon - max_range_deg - grid->min_lon) / lon_range * SPATIAL_GRID_W);
    int gx_max = int((slon + max_range_deg - grid->min_lon) / lon_range * SPATIAL_GRID_W);
    int gy_min = int((slat - max_range_deg - grid->min_lat) / lat_range * SPATIAL_GRID_H);
    int gy_max = int((slat + max_range_deg - grid->min_lat) / lat_range * SPATIAL_GRID_H);

    gx_min = max(0, gx_min); gx_max = min(SPATIAL_GRID_W - 1, gx_max);
    gy_min = max(0, gy_min); gy_max = min(SPATIAL_GRID_H - 1, gy_max);

    for (int gy = gy_min; gy <= gy_max; gy++) {
        for (int gx = gx_min; gx <= gx_max; gx++) {
            // Atomic CAS loop to insert station index into grid cell
            // Cast the count to atomic_int for atomic operations
            device atomic_int* count_ptr =
                (device atomic_int*)&grid->counts[gy][gx];

            int slot = atomic_load_explicit(count_ptr, memory_order_relaxed);
            while (slot < MAX_STATIONS_PER_CELL) {
                bool success = atomic_compare_exchange_weak_explicit(
                    count_ptr, &slot, slot + 1,
                    memory_order_relaxed, memory_order_relaxed);
                if (success) {
                    grid->cells[gy][gx][slot] = si;
                    break;
                }
                // On failure, slot is updated to the current value automatically
            }
        }
    }
}
