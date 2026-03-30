// ── volume3d.metal ──────────────────────────────────────────────
// Metal compute shader port of volume3d.cu
// 3D volume building, smoothing, ray-marching, and cross-section kernels.
// ────────────────────────────────────────────────────────────────

#include "metal_common.h"
#include <metal_stdlib>
using namespace metal;

// ── Constants ──────────────────────────────────────────────────

constant float kMissingValue               = -999.0f;
constant float kRadarEffectiveEarthRadiusKm = 8494.0f;
constant float kRadarBeamWidthRad          = 0.01745329251994329577f;
constant float kHalfRadarBeamWidthRad      = kRadarBeamWidthRad * 0.5f;
constant float kBeamMatchTolerance         = 1.35f;
constant float kCrossSectionMaxHeightKm    = 15.0f;

// ── Metal Sweep Descriptor ────────────────────────────────────
// In Metal we cannot store device pointers inside constant-memory structs.
// Instead, store offsets into combined azimuth/gate buffers.

struct MetalSweepDesc {
    float elevation_deg;
    int   num_radials;
    int   num_gates;
    float first_gate_km;
    float gate_spacing_km;
    float scale;
    float offset;
    int   azimuths_offset;   // element offset into combined azimuths buffer
    int   gates_offset;      // element offset into combined gates buffer
};

// ── Ray-March Parameters ──────────────────────────────────────

struct RayMarchParams {
    float cam_x, cam_y, cam_z;
    float fwd_x, fwd_y, fwd_z;
    float right_x, right_y, right_z;
    float up_x, up_y, up_z;
    float fov_scale;
    int   width, height;
    int   product;
    float dbz_min;
};

// ── Cross-Section Parameters ──────────────────────────────────

struct CrossSectionParams {
    float start_x_km, start_y_km;
    float dir_x, dir_y;
    float total_dist_km;
    int   width, height;
    int   product;
    float dbz_min;
};

// ════════════════════════════════════════════════════════════════
// Helper Functions
// ════════════════════════════════════════════════════════════════

inline uint32_t mkRGBA(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
    return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16) | ((uint32_t)a << 24);
}

inline float clamp01(float v) {
    return min(max(v, 0.0f), 1.0f);
}

inline float lerpFloat(float a, float b, float t) {
    return a + (b - a) * t;
}

inline bool isValidSample(float v) {
    return v > -998.0f;
}

inline void productRange(int product, thread float& min_val, thread float& max_val) {
    switch (product) {
        case PROD_REF: min_val = -30.0f; max_val = 75.0f; break;
        case PROD_VEL: min_val = -64.0f; max_val = 64.0f; break;
        case PROD_SW:  min_val =   0.0f; max_val = 30.0f; break;
        case PROD_ZDR: min_val =  -8.0f; max_val =  8.0f; break;
        case PROD_CC:  min_val =   0.2f; max_val = 1.05f; break;
        case PROD_KDP: min_val = -10.0f; max_val = 15.0f; break;
        default:       min_val =   0.0f; max_val = 360.0f; break;
    }
}

#ifndef PRODUCT_THRESHOLD_DEFINED
#define PRODUCT_THRESHOLD_DEFINED
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
#endif
// and available here when the shader sources are concatenated at runtime.

inline float sampleMagnitude(int product, float value) {
    float min_val = 0.0f, max_val = 1.0f;
    productRange(product, min_val, max_val);
    if (product == PROD_VEL || product == PROD_ZDR || product == PROD_KDP) {
        float max_abs = max(abs(min_val), abs(max_val));
        return (max_abs > 0.0f) ? clamp01(abs(value) / max_abs) : 0.0f;
    }
    return clamp01((value - min_val) / max(max_val - min_val, 1e-6f));
}

inline int colorIndexForValue(int product, float value) {
    float min_val = 0.0f, max_val = 1.0f;
    productRange(product, min_val, max_val);
    float norm = clamp01((value - min_val) / max(max_val - min_val, 1e-6f));
    int idx = (int)(norm * 254.0f) + 1;
    if (idx < 1) idx = 1;
    if (idx > 255) idx = 255;
    return idx;
}

inline float gaussianFalloff(float dist, float sigma) {
    float s = max(sigma, 1e-3f);
    float q = dist / s;
    return exp(-0.5f * q * q);
}

// ── Binary search for azimuth ─────────────────────────────────

inline int bsAz(const device float* azimuths, int n, float target) {
    int lo = 0;
    int hi = n - 1;
    while (lo < hi) {
        int mid = (lo + hi) >> 1;
        if (azimuths[mid] < target) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

// ── Decode raw gate value ─────────────────────────────────────

inline float decodeRaw(const device MetalSweepDesc& sw, uint16_t raw) {
    if (raw <= 1 || sw.scale == 0.0f) return kMissingValue;
    return ((float)raw - sw.offset) / sw.scale;
}

// ── Beam geometry at a given ground range ─────────────────────

inline bool beamGeometryAtRange(const device MetalSweepDesc& sw,
                                float ground_range_km,
                                thread float* slant_range_km,
                                thread float* beam_height_km,
                                thread float* beam_half_width_km) {
    if (sw.num_radials <= 0 || sw.num_gates <= 0 || sw.gate_spacing_km <= 0.0f)
        return false;

    float elev_rad = sw.elevation_deg * M_PI_F / 180.0f;
    float cos_e = cos(elev_rad);
    if (abs(cos_e) < 1e-4f) return false;

    float slant = ground_range_km / cos_e;
    float beam_h = slant * sin(elev_rad) +
                   (ground_range_km * ground_range_km) / (2.0f * kRadarEffectiveEarthRadiusKm);
    float half_width = max(0.25f, slant * kHalfRadarBeamWidthRad);

    *slant_range_km = slant;
    *beam_height_km = beam_h;
    *beam_half_width_km = half_width;
    return true;
}

// ── Weighted 4-point interpolation ────────────────────────────

inline float interpolate4(float v00, float w00,
                          float v01, float w01,
                          float v10, float w10,
                          float v11, float w11) {
    float wsum = w00 + w01 + w10 + w11;
    if (wsum <= 1e-6f) return kMissingValue;
    return (v00 * w00 + v01 * w01 + v10 * w10 + v11 * w11) / wsum;
}

// ── Sample a single sweep ─────────────────────────────────────
// Reads from sweep's azimuth and gate buffers via offsets into
// combined device buffers.

inline float sampleSweepValue(const device MetalSweepDesc& sw,
                              const device float* all_azimuths,
                              const device ushort* all_gates,
                              float azimuth_deg,
                              float slant_range_km) {
    float max_range = sw.first_gate_km + (sw.num_gates - 1) * sw.gate_spacing_km;
    if (slant_range_km < sw.first_gate_km || slant_range_km > max_range)
        return kMissingValue;

    float gate_pos = (slant_range_km - sw.first_gate_km) / sw.gate_spacing_km;
    int gate0 = (int)floor(gate_pos);
    if (gate0 < 0 || gate0 >= sw.num_gates)
        return kMissingValue;
    int gate1 = (gate0 + 1 < sw.num_gates) ? gate0 + 1 : gate0;
    float gate_t = clamp01(gate_pos - gate0);

    const device float* azimuths = all_azimuths + sw.azimuths_offset;
    const device ushort* gates   = all_gates + sw.gates_offset;

    int idx_hi = bsAz(azimuths, sw.num_radials, azimuth_deg);
    if (idx_hi >= sw.num_radials) idx_hi = 0;
    int idx_lo = (idx_hi == 0) ? sw.num_radials - 1 : idx_hi - 1;

    float az_lo = azimuths[idx_lo];
    float az_hi = azimuths[idx_hi];
    float az_span = az_hi - az_lo;
    if (az_span < 0.0f) az_span += 360.0f;
    if (az_span < 0.01f) az_span = 360.0f / max((float)sw.num_radials, 1.0f);
    float az_off = azimuth_deg - az_lo;
    if (az_off < 0.0f) az_off += 360.0f;
    float az_t = clamp01(az_off / az_span);

    float v00 = decodeRaw(sw, gates[gate0 * sw.num_radials + idx_lo]);
    float v01 = decodeRaw(sw, gates[gate0 * sw.num_radials + idx_hi]);
    float v10 = decodeRaw(sw, gates[gate1 * sw.num_radials + idx_lo]);
    float v11 = decodeRaw(sw, gates[gate1 * sw.num_radials + idx_hi]);

    float w00 = isValidSample(v00) ? (1.0f - gate_t) * (1.0f - az_t) : 0.0f;
    float w01 = isValidSample(v01) ? (1.0f - gate_t) * az_t : 0.0f;
    float w10 = isValidSample(v10) ? gate_t * (1.0f - az_t) : 0.0f;
    float w11 = isValidSample(v11) ? gate_t * az_t : 0.0f;
    return interpolate4(v00, w00, v01, w01, v10, w10, v11, w11);
}

// ── Volume density from value/coverage ────────────────────────

inline float sampleVolumeDensity(int product, float value, float coverage, float threshold) {
    if (coverage <= 0.01f || !isValidSample(value) || !passesThreshold(product, value, threshold))
        return 0.0f;

    float mag = sampleMagnitude(product, value);
    if (product == PROD_REF && threshold > kMissingValue) {
        float gate = clamp01((value - threshold) / max(75.0f - threshold, 1.0f));
        return pow(gate, 1.55f) * (0.15f + 0.85f * coverage);
    }
    if (product == PROD_CC) {
        float cc_mag = clamp01((value - 0.3f) / 0.75f);
        return pow(cc_mag, 1.4f) * (0.15f + 0.85f * coverage);
    }
    return pow(mag, 1.35f) * (0.14f + 0.86f * coverage);
}

// ── Volume density from 3D texture ────────────────────────────

inline float sampleVolumeDensityTex(texture3d<float> volTex,
                                    sampler volSampler,
                                    float tx, float ty, float tz,
                                    int product, float threshold) {
    float2 s = volTex.sample(volSampler, float3(tx, ty, tz)).xy;
    return sampleVolumeDensity(product, s.x, s.y, threshold);
}

// ════════════════════════════════════════════════════════════════
// Kernel 1: build_volume
// 3D dispatch -- one thread per voxel [VOL_XY x VOL_XY x VOL_Z]
// ════════════════════════════════════════════════════════════════

kernel void build_volume(
    device float2*                   volume        [[buffer(0)]],
    const device MetalSweepDesc*     sweeps        [[buffer(1)]],
    const device float*              all_azimuths  [[buffer(2)]],
    const device ushort*             all_gates     [[buffer(3)]],
    constant int&                    num_sweeps    [[buffer(4)]],
    constant int&                    product       [[buffer(5)]],
    uint3 gid [[thread_position_in_grid]])
{
    int vx = gid.x;
    int vy = gid.y;
    int vz = gid.z;
    if (vx >= VOL_XY || vy >= VOL_XY || vz >= VOL_Z) return;

    float x_km = (((float)vx + 0.5f) / VOL_XY - 0.5f) * 2.0f * VOL_RANGE_KM;
    float y_km = (((float)vy + 0.5f) / VOL_XY - 0.5f) * 2.0f * VOL_RANGE_KM;
    float z_km = (((float)vz + 0.5f) / VOL_Z) * VOL_HEIGHT_KM;

    float ground_range = sqrt(x_km * x_km + y_km * y_km);
    float azimuth = atan2(x_km, y_km) * (180.0f / M_PI_F);
    if (azimuth < 0.0f) azimuth += 360.0f;

    float weighted_value = 0.0f;
    float weight_sum     = 0.0f;
    float intensity_sum  = 0.0f;
    float footprint_sum  = 0.0f;
    float below_gap      = 1e30f;
    float above_gap      = 1e30f;
    int   contrib_count  = 0;

    for (int s = 0; s < num_sweeps; s++) {
        const device MetalSweepDesc& sw = sweeps[s];

        float slant_range     = 0.0f;
        float beam_height     = 0.0f;
        float beam_half_width = 0.0f;
        if (!beamGeometryAtRange(sw, ground_range, &slant_range, &beam_height, &beam_half_width))
            continue;

        float sample = sampleSweepValue(sw, all_azimuths, all_gates, azimuth, slant_range);
        if (!isValidSample(sample))
            continue;

        float beam_offset     = beam_height - z_km;
        float sigma_z         = max(beam_half_width * 0.85f, 0.40f);
        float vertical_weight = gaussianFalloff(beam_offset, sigma_z);
        if (vertical_weight < 0.025f)
            continue;

        float mag              = sampleMagnitude(product, sample);
        float footprint_weight = 1.0f / (1.0f + beam_half_width * 0.20f);
        float weight           = vertical_weight * footprint_weight;
        if (product == PROD_REF)
            weight *= 0.60f + 0.40f * mag;

        weighted_value += sample * weight;
        weight_sum     += weight;
        intensity_sum  += mag * weight;
        footprint_sum  += beam_half_width * weight;
        if (beam_height <= z_km) below_gap = min(below_gap, z_km - beam_height);
        else                     above_gap = min(above_gap, beam_height - z_km);
        contrib_count++;
    }

    float2 out = float2(0.0f, 0.0f);
    if (weight_sum > 0.02f) {
        float value          = weighted_value / weight_sum;
        float mean_intensity = intensity_sum / weight_sum;
        float mean_footprint = footprint_sum / weight_sum;

        float bracket = 0.35f;
        if (below_gap < 1e20f)
            bracket += 0.25f * gaussianFalloff(below_gap, max(mean_footprint, 0.5f));
        if (above_gap < 1e20f)
            bracket += 0.25f * gaussianFalloff(above_gap, max(mean_footprint, 0.5f));
        if (below_gap < 1e20f && above_gap < 1e20f)
            bracket = max(bracket, 0.95f);

        float support        = clamp01(weight_sum * 0.75f);
        float footprint_conf = 1.0f / (1.0f + max(mean_footprint - 0.75f, 0.0f) * 0.28f);
        float coverage       = (0.20f + mean_intensity * 0.80f) * support * bracket * footprint_conf;
        if (contrib_count == 1)
            coverage *= 0.72f;

        out = float2(value, clamp01(coverage));
    }

    volume[(size_t)vz * VOL_XY * VOL_XY + vy * VOL_XY + vx] = out;
}

// ════════════════════════════════════════════════════════════════
// Kernel 2: smooth_volume
// 3D dispatch -- bilateral 26-neighbor filter
// ════════════════════════════════════════════════════════════════

kernel void smooth_volume(
    const device float2*   src     [[buffer(0)]],
    device float2*         dst     [[buffer(1)]],
    constant int&          product [[buffer(2)]],
    uint3 gid [[thread_position_in_grid]])
{
    int vx = gid.x;
    int vy = gid.y;
    int vz = gid.z;
    if (vx >= VOL_XY || vy >= VOL_XY || vz >= VOL_Z) return;

    size_t idx = (size_t)vz * VOL_XY * VOL_XY + vy * VOL_XY + vx;
    float2 center = src[idx];

    float x_km = (((float)vx + 0.5f) / VOL_XY - 0.5f) * 2.0f * VOL_RANGE_KM;
    float y_km = (((float)vy + 0.5f) / VOL_XY - 0.5f) * 2.0f * VOL_RANGE_KM;
    float range_norm = clamp01(sqrt(x_km * x_km + y_km * y_km) / VOL_RANGE_KM);
    float sigma_xy = 0.85f + range_norm * 1.15f;
    float sigma_z  = 0.70f + range_norm * 0.65f;
    float center_intensity =
        (center.y > 0.01f && isValidSample(center.x)) ? sampleMagnitude(product, center.x) : 0.0f;

    float sum_w   = 0.0f;
    float sum_val = 0.0f;
    float sum_cov = 0.0f;
    float similarity_scale = (product == PROD_REF) ? 0.07f : 0.035f;

    for (int oz = -1; oz <= 1; ++oz) {
        int nz = vz + oz;
        if (nz < 0 || nz >= VOL_Z) continue;
        for (int oy = -1; oy <= 1; ++oy) {
            int ny = vy + oy;
            if (ny < 0 || ny >= VOL_XY) continue;
            for (int ox = -1; ox <= 1; ++ox) {
                int nx = vx + ox;
                if (nx < 0 || nx >= VOL_XY) continue;

                float2 s = src[(size_t)nz * VOL_XY * VOL_XY + ny * VOL_XY + nx];
                if (s.y <= 0.01f || !isValidSample(s.x))
                    continue;

                float spatial =
                    exp(-0.5f * ((ox * ox + oy * oy) / (sigma_xy * sigma_xy) +
                                 (oz * oz) / (sigma_z * sigma_z)));
                float similarity = 1.0f;
                if (center.y > 0.01f && isValidSample(center.x))
                    similarity = exp(-abs(s.x - center.x) * similarity_scale);

                float weight = spatial * (0.12f + 0.88f * s.y) * similarity;
                if (ox == 0 && oy == 0 && oz == 0)
                    weight *= 1.35f;

                sum_w   += weight;
                sum_val += s.x * weight;
                sum_cov += s.y * spatial;
            }
        }
    }

    if (sum_w <= 1e-5f) {
        dst[idx] = float2(0.0f, 0.0f);
        return;
    }

    float filtered_val = sum_val / sum_w;
    float filtered_cov = clamp01(sum_cov * 0.19f);
    float smooth_mix   = clamp01(0.18f + range_norm * 0.55f);
    smooth_mix *= (1.0f - center_intensity * 0.35f);
    if (center.y <= 0.01f || !isValidSample(center.x))
        smooth_mix = 1.0f;

    float out_val = (center.y > 0.01f && isValidSample(center.x))
        ? lerpFloat(center.x, filtered_val, smooth_mix)
        : filtered_val;
    float out_cov = (center.y > 0.01f)
        ? clamp01(max(center.y * 0.85f, center.y * 0.55f + filtered_cov * 0.45f))
        : clamp01(filtered_cov * 0.82f);

    if (out_cov < 0.015f || !isValidSample(out_val)) {
        dst[idx] = float2(0.0f, 0.0f);
        return;
    }

    dst[idx] = float2(out_val, out_cov);
}

// ════════════════════════════════════════════════════════════════
// Kernel 3: ray_march
// 2D dispatch -- one thread per output pixel, volumetric ray-marching
// ════════════════════════════════════════════════════════════════

kernel void ray_march(
    texture3d<float>          volTex      [[texture(0)]],
    sampler                   volSampler  [[sampler(0)]],
    device uint*              output      [[buffer(0)]],
    constant RayMarchParams&  params      [[buffer(1)]],
    constant uint*            colorTable  [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    int px = gid.x;
    int py = gid.y;
    if (px >= params.width || py >= params.height) return;

    int   product = params.product;
    float dbz_min = params.dbz_min;
    int   width   = params.width;
    int   height  = params.height;

    float u = ((float)px / width - 0.5f) * 2.0f * params.fov_scale * ((float)width / height);
    float v = (0.5f - (float)py / height) * 2.0f * params.fov_scale;

    float dx = params.fwd_x + params.right_x * u + params.up_x * v;
    float dy = params.fwd_y + params.right_y * u + params.up_y * v;
    float dz = params.fwd_z + params.right_z * u + params.up_z * v;
    float inv_dir_len = rsqrt(dx * dx + dy * dy + dz * dz);
    dx *= inv_dir_len;
    dy *= inv_dir_len;
    dz *= inv_dir_len;

    // ── AABB ray intersection ──
    float bmin  = -VOL_RANGE_KM;
    float bmax  =  VOL_RANGE_KM;
    float bzmax =  VOL_DISPLAY_HEIGHT;
    float tmin  = -1e9f;
    float tmax  =  1e9f;

    if (abs(dx) > 1e-6f) {
        float t1 = (bmin - params.cam_x) / dx;
        float t2 = (bmax - params.cam_x) / dx;
        if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
        tmin = max(tmin, t1);
        tmax = min(tmax, t2);
    }
    if (abs(dy) > 1e-6f) {
        float t1 = (bmin - params.cam_y) / dy;
        float t2 = (bmax - params.cam_y) / dy;
        if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
        tmin = max(tmin, t1);
        tmax = min(tmax, t2);
    }
    if (abs(dz) > 1e-6f) {
        float t1 = (0.0f - params.cam_z) / dz;
        float t2 = (bzmax - params.cam_z) / dz;
        if (t1 > t2) { float tmp = t1; t1 = t2; t2 = tmp; }
        tmin = max(tmin, t1);
        tmax = min(tmax, t2);
    }

    // ── Sky background ──
    float sky_t = max(0.0f, v * 0.3f + 0.3f);
    float3 bg = float3(0.03f + sky_t * 0.04f,
                        0.03f + sky_t * 0.06f,
                        0.06f + sky_t * 0.10f);

    // ── Ground plane ──
    float ground_t = -1.0f;
    if (abs(dz) > 1e-6f)
        ground_t = -params.cam_z / dz;

    bool hit_ground = false;
    float3 ground_color = bg;
    if (ground_t > 0.0f && (tmin > tmax || ground_t < tmin)) {
        float gx = params.cam_x + dx * ground_t;
        float gy = params.cam_y + dy * ground_t;
        float gmod_x = fmod(abs(gx), 50.0f);
        float gmod_y = fmod(abs(gy), 50.0f);
        float line_x = min(gmod_x, 50.0f - gmod_x);
        float line_y = min(gmod_y, 50.0f - gmod_y);
        float grid_line  = min(line_x, line_y);
        float grid_alpha = max(0.0f, 1.0f - grid_line * 0.8f) * 0.15f;
        float gdist = sqrt(gx * gx + gy * gy);
        float gfade = max(0.0f, 1.0f - gdist / (VOL_RANGE_KM * 1.5f));
        grid_alpha *= gfade;
        ground_color = float3(bg.x + grid_alpha * 0.3f,
                              bg.y + grid_alpha * 0.4f,
                              bg.z + grid_alpha * 0.5f);
        hit_ground = true;
    }

    // ── Early out if no volume hit ──
    if (tmin > tmax || tmax < 0.0f) {
        float3 c = hit_ground ? ground_color : bg;
        output[py * width + px] = mkRGBA((uint8_t)(c.x * 255.0f),
                                          (uint8_t)(c.y * 255.0f),
                                          (uint8_t)(c.z * 255.0f));
        return;
    }

    tmin = max(tmin, 0.001f);

    float base_step = 0.55f;
    int   max_steps = (int)min((tmax - tmin) / base_step, 720.0f);

    // ── Light direction ──
    const float lx  = 0.34f;
    const float ly  = -0.22f;
    const float lz  = 0.91f;
    const float eps = 1.2f / VOL_XY;

    float3 accum     = float3(0.0f, 0.0f, 0.0f);
    float  alpha     = 0.0f;
    float  threshold = productThreshold(product, dbz_min);
    float  t         = tmin;
    int    step      = 0;

    // ── Main ray-march loop ──
    while (t <= tmax && step < max_steps && alpha < 0.995f) {
        step++;

        float sx = params.cam_x + dx * t;
        float sy = params.cam_y + dy * t;
        float sz = params.cam_z + dz * t;
        float tx = sx / VOL_RANGE_KM * 0.5f + 0.5f;
        float ty = sy / VOL_RANGE_KM * 0.5f + 0.5f;
        float tz = (sz / VOL_Z_EXAGGERATION) / VOL_HEIGHT_KM;

        if (tx < 0.002f || tx > 0.998f || ty < 0.002f || ty > 0.998f ||
            tz < 0.002f || tz > 0.998f) {
            t += base_step;
            continue;
        }

        float2 sam = volTex.sample(volSampler, float3(tx, ty, tz)).xy;
        float  val      = sam.x;
        float  coverage = sam.y;
        float  density  = sampleVolumeDensity(product, val, coverage, threshold);
        if (density < 0.01f) {
            t += base_step * 1.25f;
            continue;
        }

        // ── Gradient (central differences) ──
        float gnx = sampleVolumeDensityTex(volTex, volSampler, tx + eps, ty, tz, product, threshold) -
                     sampleVolumeDensityTex(volTex, volSampler, tx - eps, ty, tz, product, threshold);
        float gny = sampleVolumeDensityTex(volTex, volSampler, tx, ty + eps, tz, product, threshold) -
                     sampleVolumeDensityTex(volTex, volSampler, tx, ty - eps, tz, product, threshold);
        float gnz = sampleVolumeDensityTex(volTex, volSampler, tx, ty, tz + eps, product, threshold) -
                     sampleVolumeDensityTex(volTex, volSampler, tx, ty, tz - eps, product, threshold);
        float gl = rsqrt(gnx * gnx + gny * gny + gnz * gnz + 1e-6f);
        float nx = gnx * gl;
        float ny = gny * gl;
        float nz = gnz * gl;

        // ── Diffuse ──
        float ndotl = max(0.0f, nx * lx + ny * ly + nz * lz);
        float ambient = 0.18f;

        // ── Shadow march ──
        float shadow = 1.0f;
        float stx = tx;
        float sty = ty;
        float stz = tz;
        float sl_dx = lx * eps * 4.0f;
        float sl_dy = ly * eps * 4.0f;
        float sl_dz = lz * (1.0f / VOL_Z) * 4.0f;
        for (int si = 0; si < 6; si++) {
            stx += sl_dx;
            sty += sl_dy;
            stz += sl_dz;
            if (stx < 0.0f || stx > 1.0f || sty < 0.0f || sty > 1.0f || stz < 0.0f || stz > 1.0f)
                break;
            float shadow_density = sampleVolumeDensityTex(volTex, volSampler, stx, sty, stz, product, threshold);
            shadow *= exp(-shadow_density * 0.45f);
        }
        shadow = max(shadow, 0.18f);

        // ── Specular (Blinn-Phong) ──
        float hx = lx - dx;
        float hy = ly - dy;
        float hz = lz - dz;
        float hl = rsqrt(hx * hx + hy * hy + hz * hz + 1e-6f);
        float ndoth   = max(0.0f, nx * hx * hl + ny * hy * hl + nz * hz * hl);
        float specular = pow(ndoth, 28.0f) * 0.22f * shadow;

        // ── Rim, powder, combined lighting ──
        float ndotv   = abs(nx * (-dx) + ny * (-dy) + nz * (-dz));
        float rim     = pow(1.0f - ndotv, 2.5f) * (0.08f + 0.22f * density);
        float powder  = 1.0f - exp(-density * 1.8f);
        float lighting = ambient + 0.42f * ndotl * shadow + 0.25f * powder + rim;

        // ── Color from table ──
        uint32_t color = colorTable[product * 256 + colorIndexForValue(product, val)];
        float cr = (float)(color & 0xFF) / 255.0f;
        float cg = (float)((color >> 8) & 0xFF) / 255.0f;
        float cb = (float)((color >> 16) & 0xFF) / 255.0f;

        // ── Saturation adjustment ──
        float luminance  = (cr + cg + cb) / 3.0f;
        float saturation = 0.65f + density * 0.35f;
        cr = lerpFloat(luminance, cr, saturation);
        cg = lerpFloat(luminance, cg, saturation);
        cb = lerpFloat(luminance, cb, saturation);

        // ── Apply lighting ──
        cr = cr * lighting + specular;
        cg = cg * lighting + specular * 0.90f;
        cb = cb * lighting + specular * 0.80f;

        // ── Glow for high reflectivity ──
        if (product == PROD_REF) {
            float glow = max(0.0f, (val - 50.0f) / 20.0f);
            float core = glow * glow;
            cr += core * 0.35f;
            cg += core * 0.10f;
            cb += core * 0.05f;
        }

        // ── Forward scatter ──
        float forward = pow(clamp01(lx * (-dx) + ly * (-dy) + lz * (-dz)), 10.0f) * density * 0.12f;
        cr += forward;
        cg += forward * 0.8f;
        cb += forward * 0.6f;

        // ── Accumulate ──
        float extinction = density * ((product == PROD_REF) ? 1.6f : 1.2f);
        float opacity    = 1.0f - exp(-extinction * base_step);

        accum.x += (1.0f - alpha) * min(cr, 1.5f) * opacity;
        accum.y += (1.0f - alpha) * min(cg, 1.5f) * opacity;
        accum.z += (1.0f - alpha) * min(cb, 1.5f) * opacity;
        alpha   += (1.0f - alpha) * opacity;
        t       += base_step;
    }

    // ── Composite over background ──
    float3 final_bg = hit_ground ? ground_color : bg;
    float fr = min(accum.x + final_bg.x * (1.0f - alpha), 1.0f);
    float fg = min(accum.y + final_bg.y * (1.0f - alpha), 1.0f);
    float fb = min(accum.z + final_bg.z * (1.0f - alpha), 1.0f);

    output[py * width + px] = mkRGBA((uint8_t)(fr * 255.0f),
                                      (uint8_t)(fg * 255.0f),
                                      (uint8_t)(fb * 255.0f));
}

// ════════════════════════════════════════════════════════════════
// Kernel 4: cross_section
// 2D dispatch -- one thread per output pixel
// ════════════════════════════════════════════════════════════════

kernel void cross_section(
    device uint*                     output        [[buffer(0)]],
    constant CrossSectionParams&     params        [[buffer(1)]],
    const device MetalSweepDesc*     sweeps        [[buffer(2)]],
    const device float*              all_azimuths  [[buffer(3)]],
    const device ushort*             all_gates     [[buffer(4)]],
    constant int&                    num_sweeps    [[buffer(5)]],
    constant uint*                   colorTable    [[buffer(6)]],
    uint2 gid [[thread_position_in_grid]])
{
    int px = gid.x;
    int py = gid.y;
    if (px >= params.width || py >= params.height) return;

    int   product = params.product;
    float dbz_min = params.dbz_min;
    int   w       = params.width;
    int   h       = params.height;

    float dist_along = ((float)px / w) * params.total_dist_km;
    float alt_km     = (1.0f - (float)py / h) * kCrossSectionMaxHeightKm;

    float x_km = params.start_x_km + params.dir_x * dist_along;
    float y_km = params.start_y_km + params.dir_y * dist_along;

    float ground_range = sqrt(x_km * x_km + y_km * y_km);
    if (ground_range < 1.0f) ground_range = 1.0f;

    float azimuth = atan2(x_km, y_km) * (180.0f / M_PI_F);
    if (azimuth < 0.0f) azimuth += 360.0f;

    // ── Grid lines ──
    uint32_t bg = mkRGBA(18, 18, 25);
    float hgrid = fmod(dist_along, 25.0f);
    float vgrid = fmod(alt_km, 1.524f);
    if (min(hgrid, 25.0f - hgrid) < 0.3f)
        bg = mkRGBA(25, 25, 35);
    if (min(vgrid, 1.524f - vgrid) < 0.02f)
        bg = mkRGBA(25, 25, 35);

    float best_val   = kMissingValue;
    float best_score = 1e30f;
    float best_dist  = 1e30f;

    for (int s = 0; s < num_sweeps; s++) {
        const device MetalSweepDesc& sw = sweeps[s];

        float slant_range     = 0.0f;
        float beam_height     = 0.0f;
        float beam_half_width = 0.0f;
        if (!beamGeometryAtRange(sw, ground_range, &slant_range, &beam_height, &beam_half_width))
            continue;

        float value = sampleSweepValue(sw, all_azimuths, all_gates, azimuth, slant_range);
        if (!passesThreshold(product, value, dbz_min))
            continue;

        float beam_offset = abs(beam_height - alt_km);
        float score = beam_offset / max(beam_half_width, 0.1f);
        if (score > kBeamMatchTolerance)
            continue;

        if (score < best_score ||
            (abs(score - best_score) < 1e-3f && beam_offset < best_dist) ||
            (abs(score - best_score) < 1e-3f && abs(beam_offset - best_dist) < 1e-3f &&
             abs(value) > abs(best_val))) {
            best_score = score;
            best_dist  = beam_offset;
            best_val   = value;
        }
    }

    if (!passesThreshold(product, best_val, dbz_min)) {
        output[py * w + px] = bg;
        return;
    }

    uint32_t color = colorTable[product * 256 + colorIndexForValue(product, best_val)];
    output[py * w + px] = color | 0xFF000000u;
}
