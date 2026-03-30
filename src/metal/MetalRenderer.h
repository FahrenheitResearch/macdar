#pragma once
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "metal_common.h"

// ── Kernel Parameter Structs ───────────────────────────────────
// Passed via setBytes to compute shaders.

struct SingleStationParams {
    GpuViewport  vp;
    GpuStationInfo info;
    int          product;
    float        dbz_min;
    float        srv_speed;
    float        srv_dir_rad;
};

struct NativeRenderParams {
    GpuViewport  vp;
    int          num_stations;
    int          product;
    float        dbz_min;
};

struct ForwardRenderParams {
    GpuViewport    vp;
    GpuStationInfo info;
    int            product;
    float          dbz_min;
    float          srv_speed;
    float          srv_dir_rad;
};

struct ForwardResolveParams {
    int width;
    int height;
};

struct ClearParams {
    int      width;
    int      height;
    uint32_t color;
};

struct BuildGridParams {
    int num_stations;
};

struct BuildVolumeParams {
    int product;
    int num_sweeps;
};

struct SmoothVolumeParams {
    int product;
};

struct RayMarchParams {
    float cam_x, cam_y, cam_z;
    float fwd_x, fwd_y, fwd_z;
    float right_x, right_y, right_z;
    float up_x, up_y, up_z;
    float fov_scale;
    int   width;
    int   height;
    int   product;
    float dbz_min;
};

struct CrossSectionParams {
    float start_x_km;
    float start_y_km;
    float dir_x;
    float dir_y;
    float total_dist_km;
    int   width;
    int   height;
    int   product;
    float dbz_min;
};

// ── MetalRenderer ──────────────────────────────────────────────

class MetalRenderer {
public:
    MetalRenderer();
    ~MetalRenderer();

    // Initialize Metal device, command queue, pipeline states
    bool init();
    bool init(id<MTLDevice> externalDevice);  // use provided device (iOS)
    void shutdown();

    // Color tables
    void setColorTable(int product, const uint32_t* rgba256);
    void resetColorTable(int product);
    void resetAllColorTables();

    // Station management
    void allocateStation(int station_idx, const GpuStationInfo& info);
    void freeStation(int station_idx);
    void uploadStationData(int station_idx, const GpuStationInfo& info,
                           const float* azimuths,
                           const uint16_t* gate_data[NUM_PRODUCTS]);

    // Rendering
    void renderNative(const GpuViewport& vp,
                      const GpuStationInfo* stations, int num_stations,
                      const SpatialGrid& grid,
                      int product, float dbz_min,
                      id<MTLBuffer> output);

    void renderSingleStation(const GpuViewport& vp, int station_idx,
                              int product, float dbz_min,
                              id<MTLBuffer> output,
                              float srv_speed = 0.0f, float srv_dir = 0.0f);

    void forwardRenderStation(const GpuViewport& vp, int station_idx,
                               int product, float dbz_min,
                               id<MTLBuffer> output,
                               float srv_speed = 0.0f, float srv_dir = 0.0f);

    // Volume rendering
    void initVolume();
    void freeVolume();
    void buildVolume(int station_idx, int product,
                     const GpuStationInfo* sweep_infos, int num_sweeps,
                     id<MTLBuffer> __unsafe_unretained * azimuths_per_sweep,
                     id<MTLBuffer> __unsafe_unretained * gates_per_sweep);
    void renderVolume(const Camera3D& cam, int width, int height,
                      int product, float dbz_min,
                      id<MTLBuffer> output);
    void renderCrossSection(int station_idx, int product, float dbz_min,
                            float start_lat, float start_lon,
                            float end_lat, float end_lon,
                            float station_lat, float station_lon,
                            int width, int height,
                            id<MTLBuffer> output);

    // Spatial grid
    void buildSpatialGridGpu(const GpuStationInfo* stations, int num_stations,
                              SpatialGrid* grid_out);

    // Sync
    void syncStation(int station_idx);

    // Swap pointers for instant tilt switching
    void swapStationPointers(int station_idx, const GpuStationInfo& info,
                              id<MTLBuffer> azimuths, id<MTLBuffer> __unsafe_unretained gates[NUM_PRODUCTS]);

    // Get output buffer for display
    id<MTLBuffer> createOutputBuffer(int width, int height);

    // Access device
    id<MTLDevice> getDevice() const { return _device; }
    id<MTLCommandQueue> getQueue() const { return _commandQueue; }

    // Access station buffers (for volume building)
    id<MTLBuffer> getStationAzimuths(int station_idx) const {
        if (station_idx < 0 || station_idx >= MAX_STATIONS) return nil;
        return _stations[station_idx].azimuths;
    }
    id<MTLBuffer> getStationGates(int station_idx, int product) const {
        if (station_idx < 0 || station_idx >= MAX_STATIONS || product < 0 || product >= NUM_PRODUCTS) return nil;
        return _stations[station_idx].gates[product];
    }

private:
    bool initCommon();  // shared init logic after device is set
    void loadShaders();
    void buildColorTexture(int product, const uint32_t* table);
    void buildDefaultColorTables();
    void uploadAllColorTextures();
    void clearOutputBuffer(const GpuViewport& vp, id<MTLBuffer> output);
    bool shouldUseInverseFallback(const GpuViewport& vp, const GpuStationInfo& info, int product);
    void ensureForwardAccumCapacity(size_t pixel_count);
    void initializeSpatialGrid(SpatialGrid* grid);

    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _library;

    // Compute pipeline states for each kernel
    id<MTLComputePipelineState> _nativeRenderPSO;
    id<MTLComputePipelineState> _singleStationPSO;
    id<MTLComputePipelineState> _clearPSO;
    id<MTLComputePipelineState> _forwardRenderPSO;
    id<MTLComputePipelineState> _forwardResolvePSO;
    id<MTLComputePipelineState> _buildGridPSO;
    id<MTLComputePipelineState> _buildVolumePSO;
    id<MTLComputePipelineState> _smoothVolumePSO;
    id<MTLComputePipelineState> _rayMarchPSO;
    id<MTLComputePipelineState> _crossSectionPSO;

    // Color textures (1D, one per product for HW interpolation)
    id<MTLTexture> _colorTextures[NUM_PRODUCTS];
    id<MTLSamplerState> _colorSampler;

    // Per-station buffers
    struct StationBuffers {
        id<MTLBuffer> azimuths;
        id<MTLBuffer> gates[NUM_PRODUCTS];
        GpuStationInfo info;
        bool allocated = false;
    };
    StationBuffers _stations[MAX_STATIONS];
    int _numStations = 0;

    // Color tables (host-side)
    uint32_t _defaultColorTables[NUM_PRODUCTS][256];
    uint32_t _runtimeColorTables[NUM_PRODUCTS][256];
    id<MTLBuffer> _colorTableBuffer;  // GPU copy of color tables [NUM_PRODUCTS * 256]

    // Spatial grid
    id<MTLBuffer> _spatialGridBuffer;

    // Native render persistent buffers
    id<MTLBuffer> _stationInfoBuffer;
    int _stationInfoBufferCapacity = 0;

    // Forward render accumulation (32-bit depth + 32-bit color)
    id<MTLBuffer> _forwardAccumBuffer;   // depth buffer (atomic_uint)
    id<MTLBuffer> _forwardColorBuffer;   // color buffer (uint)
    size_t _forwardAccumCapacity = 0;

    // Volume rendering
    id<MTLBuffer> _volumeRawBuffer;
    id<MTLBuffer> _volumeScratchBuffer;
    id<MTLTexture> _volumeTexture;  // 3D texture
    id<MTLSamplerState> _volumeSampler;
    id<MTLBuffer> _sweepDescBuffer;
    bool _volumeReady = false;
};
