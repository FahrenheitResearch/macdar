#pragma once

// ── Metal Common Header ────────────────────────────────────────
// Shared definitions for Metal shaders and C++ host code.
// Metal equivalent of cuda_common.cuh + renderer.cuh structs.
// ────────────────────────────────────────────────────────────────

#ifdef __METAL_VERSION__
    #include <metal_stdlib>
    using namespace metal;
    #define METAL_CONSTANT constant
#else
    #include <cstdint>
    #define METAL_CONSTANT constexpr
#endif

// ── SIMD / Warp Constants ──────────────────────────────────────

METAL_CONSTANT int SIMD_SIZE = 32;   // Metal SIMD group width (CUDA WARP_SIZE equivalent)

// ── Station / Data Limits ──────────────────────────────────────

METAL_CONSTANT int MAX_STATIONS = 256;
METAL_CONSTANT int MAX_RADIALS  = 720;   // super-res = 720, normal = 360
METAL_CONSTANT int MAX_GATES    = 1840;

// ── Product Definitions ────────────────────────────────────────

METAL_CONSTANT int NUM_PRODUCTS = 7;

METAL_CONSTANT int PROD_REF = 0;
METAL_CONSTANT int PROD_VEL = 1;
METAL_CONSTANT int PROD_SW  = 2;
METAL_CONSTANT int PROD_ZDR = 3;
METAL_CONSTANT int PROD_CC  = 4;
METAL_CONSTANT int PROD_KDP = 5;
METAL_CONSTANT int PROD_PHI = 6;

// ── Rendering Constants ────────────────────────────────────────

METAL_CONSTANT int STATION_TEX_SIZE = 2048;   // per-station render texture size

// ── Gate Sentinel Values ───────────────────────────────────────

#ifdef __METAL_VERSION__
constant uint16_t GATE_BELOW_THRESHOLD = 0;
constant uint16_t GATE_RANGE_FOLDED    = 1;
#else
constexpr uint16_t GATE_BELOW_THRESHOLD = 0;
constexpr uint16_t GATE_RANGE_FOLDED    = 1;
#endif

// ── Spatial Grid Constants ─────────────────────────────────────

METAL_CONSTANT int SPATIAL_GRID_W         = 128;
METAL_CONSTANT int SPATIAL_GRID_H         = 64;
METAL_CONSTANT int MAX_STATIONS_PER_CELL  = 32;

// ── Volume Rendering Constants ─────────────────────────────────

METAL_CONSTANT int   VOL_XY             = 256;
METAL_CONSTANT int   VOL_Z              = 96;
METAL_CONSTANT float VOL_RANGE_KM       = 230.0f;
METAL_CONSTANT float VOL_HEIGHT_KM      = 22.0f;
METAL_CONSTANT float VOL_Z_EXAGGERATION = 10.0f;
METAL_CONSTANT float VOL_DISPLAY_HEIGHT = 22.0f * 10.0f;  // VOL_HEIGHT_KM * VOL_Z_EXAGGERATION

// ════════════════════════════════════════════════════════════════
// Shared Structs
// All structs avoid bool (use uint8_t) for identical layout
// between Metal shaders and C++ host code.
// ════════════════════════════════════════════════════════════════

// ── Per-Station Metadata ───────────────────────────────────────

struct GpuStationInfo {
    float    lat;
    float    lon;
    float    elevation_angle;
    int      num_radials;
    int      num_gates[7];          // NUM_PRODUCTS
    float    first_gate_km[7];
    float    gate_spacing_km[7];
    float    scale[7];
    float    offset[7];
    uint8_t  has_product[7];        // bool replacement for buffer compatibility
    uint8_t  _pad0;                 // pad to 4-byte alignment
    uint8_t  _pad1;
    uint8_t  _pad2;
};

// ── Station Buffer References (Metal) ──────────────────────────
// In CUDA this holds device pointers. In Metal, station data is
// accessed via buffer indices/offsets bound at dispatch time.
// This is a placeholder for the Metal port.

struct GpuStationPtrs {
    uint32_t azimuth_offset;        // byte offset into azimuth buffer
    uint32_t gate_offset[7];        // byte offset into gate buffer per product
};

// ── Viewport ───────────────────────────────────────────────────

struct GpuViewport {
    float center_lat;
    float center_lon;
    float deg_per_pixel_x;
    float deg_per_pixel_y;
    int   width;
    int   height;
};

// ── Spatial Grid ───────────────────────────────────────────────
// Used for fast station lookup during mosaic rendering.
// Large struct -- typically uploaded once to a Metal buffer.

struct SpatialGrid {
    int   cells[64][128][32];       // [SPATIAL_GRID_H][SPATIAL_GRID_W][MAX_STATIONS_PER_CELL]
    int   counts[64][128];          // [SPATIAL_GRID_H][SPATIAL_GRID_W]
    float min_lat;
    float max_lat;
    float min_lon;
    float max_lon;
};

// ── 3D Camera ──────────────────────────────────────────────────

struct Camera3D {
    float orbit_angle;              // horizontal orbit (degrees, 0 = north)
    float tilt_angle;               // vertical tilt (degrees, 0 = horizon, 90 = top-down)
    float distance;                 // distance from center (km)
    float target_z;                 // look-at altitude (km)
};

// ── Sweep Descriptor (Volume Building) ─────────────────────────
// Describes one elevation sweep for volume construction.
// In Metal, azimuths/gates are buffer offsets rather than pointers.

struct SweepDesc {
    float    elevation_deg;
    int      num_radials;
    int      num_gates;
    float    first_gate_km;
    float    gate_spacing_km;
    float    scale;
    float    offset;
    uint32_t azimuth_buffer_offset; // byte offset into shared azimuth buffer
    uint32_t gate_buffer_offset;    // byte offset into shared gate buffer
};

// ── GPU Parsed Radial (Pipeline) ───────────────────────────────
// Output of the GPU-side Level 2 parser.

struct GpuParsedRadial {
    float    azimuth;
    float    elevation;
    uint8_t  radial_status;
    uint8_t  elevation_number;
    uint8_t  data_word_size[7];     // NUM_PRODUCTS: 8 or 16
    uint8_t  _pad0;                 // pad to 4-byte alignment
    int      moment_offsets[7];     // byte offset to gate data, -1 if absent
    int      num_gates[7];
    int      gate_spacing[7];       // meters
    int      first_gate[7];         // meters
    float    scale[7];
    float    offset[7];
};

// ── Transpose Kernel Parameters ────────────────────────────────

struct TransposeParams {
    uint32_t num_radials;
    int      product;
    int      out_num_gates;
};

// ── Cleanup Macro ──────────────────────────────────────────────

#undef METAL_CONSTANT
