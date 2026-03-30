#import "MetalRenderer.h"
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstring>
#include <cmath>
#include <cstdint>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ── Color Constants ────────────────────────────────────────────

static constexpr uint32_t kBackgroundColor = 0x00000000u; // transparent
static constexpr uint64_t kEmptyForwardPixel = ~0ull;

// ── Color Table Helpers ────────────────────────────────────────

static uint32_t makeRGBA(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
    return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16) | ((uint32_t)a << 24);
}

static int valToIdx(float val, float min_val, float max_val) {
    int idx = (int)((val - min_val) / (max_val - min_val) * 255.0f);
    return (idx < 0) ? 0 : (idx > 255) ? 255 : idx;
}

static void fillRange(uint32_t* table, float v0, float v1, float vmin, float vmax,
                      uint8_t r, uint8_t g, uint8_t b) {
    int i0 = valToIdx(v0, vmin, vmax);
    int i1 = valToIdx(v1, vmin, vmax);
    for (int i = i0; i < i1 && i < 256; i++)
        table[i] = makeRGBA(r, g, b);
}

static void interpolateColor(uint32_t* table, int i0, int i1,
                              uint8_t r0, uint8_t g0, uint8_t b0,
                              uint8_t r1, uint8_t g1, uint8_t b1) {
    if (i1 <= i0) return;
    for (int i = i0; i <= i1; i++) {
        float t = (float)(i - i0) / (float)(i1 - i0);
        table[i] = makeRGBA((uint8_t)(r0 + t * (r1 - r0)),
                             (uint8_t)(g0 + t * (g1 - g0)),
                             (uint8_t)(b0 + t * (b1 - b0)));
    }
}

// ── AWIPS Standard Reflectivity (exact NWS RGB values) ─────────

static void generateRefColorTable(uint32_t* table) {
    memset(table, 0, 256 * sizeof(uint32_t));
    const float mn = -30, mx = 75;
    fillRange(table,  5, 10, mn, mx,   0, 131, 174);
    fillRange(table, 10, 15, mn, mx,  65,  90, 160);
    fillRange(table, 15, 20, mn, mx,  62, 169, 214);
    fillRange(table, 20, 25, mn, mx,   0, 220, 183);
    fillRange(table, 25, 30, mn, mx,  15, 195,  21);
    fillRange(table, 30, 35, mn, mx,  11, 147,  22);
    fillRange(table, 35, 40, mn, mx,  10,  95,  19);
    fillRange(table, 40, 45, mn, mx, 255, 245,   5);
    fillRange(table, 45, 50, mn, mx, 255, 190,   0);
    fillRange(table, 50, 55, mn, mx, 255,   0,   0);
    fillRange(table, 55, 60, mn, mx, 120,   0,   0);
    fillRange(table, 60, 65, mn, mx, 255, 255, 255);
    fillRange(table, 65, 70, mn, mx, 201, 161, 255);
    fillRange(table, 70, 75, mn, mx, 174,   0, 255);
    fillRange(table, 75, 76, mn, mx,   5, 221, 225);
}

// ── AWIPS Enhanced Base Velocity (exact NWS values) ────────────

static void generateVelColorTable(uint32_t* table) {
    memset(table, 0, 256 * sizeof(uint32_t));
    const float mn = -64, mx = 64;
    fillRange(table, -64, -50, mn, mx,   0,   0, 100);
    fillRange(table, -50, -40, mn, mx, 100, 255, 255);
    fillRange(table, -40, -30, mn, mx,   0, 255,   0);
    fillRange(table, -30, -20, mn, mx,   0, 209,   0);
    fillRange(table, -20, -10, mn, mx,   0, 163,   0);
    fillRange(table, -10,  -5, mn, mx,   0, 116,   0);
    fillRange(table,  -5,   0, mn, mx,   0,  70,   0);
    fillRange(table,   0,   5, mn, mx, 120, 120, 120);
    fillRange(table,   5,  10, mn, mx,  70,   0,   0);
    fillRange(table,  10,  20, mn, mx, 116,   0,   0);
    fillRange(table,  20,  30, mn, mx, 209,   0,   0);
    fillRange(table,  30,  40, mn, mx, 255,   0,   0);
    fillRange(table,  40,  50, mn, mx, 255, 129, 125);
    fillRange(table,  50,  60, mn, mx, 255, 140,  70);
    fillRange(table,  60,  64, mn, mx, 255, 255,   0);
}

// ════════════════════════════════════════════════════════════════
// MetalRenderer Implementation
// ════════════════════════════════════════════════════════════════

MetalRenderer::MetalRenderer()
    : _device(nil)
    , _commandQueue(nil)
    , _library(nil)
    , _nativeRenderPSO(nil)
    , _singleStationPSO(nil)
    , _clearPSO(nil)
    , _forwardRenderPSO(nil)
    , _forwardResolvePSO(nil)
    , _buildGridPSO(nil)
    , _buildVolumePSO(nil)
    , _smoothVolumePSO(nil)
    , _rayMarchPSO(nil)
    , _crossSectionPSO(nil)
    , _colorSampler(nil)
    , _colorTableBuffer(nil)
    , _spatialGridBuffer(nil)
    , _stationInfoBuffer(nil)
    , _forwardAccumBuffer(nil)
    , _volumeRawBuffer(nil)
    , _volumeScratchBuffer(nil)
    , _volumeTexture(nil)
    , _volumeSampler(nil)
    , _sweepDescBuffer(nil)
{
    memset(_defaultColorTables, 0, sizeof(_defaultColorTables));
    memset(_runtimeColorTables, 0, sizeof(_runtimeColorTables));
    for (int i = 0; i < NUM_PRODUCTS; i++)
        _colorTextures[i] = nil;
    for (int i = 0; i < MAX_STATIONS; i++) {
        _stations[i].azimuths = nil;
        for (int p = 0; p < NUM_PRODUCTS; p++)
            _stations[i].gates[p] = nil;
        memset(&_stations[i].info, 0, sizeof(GpuStationInfo));
        _stations[i].allocated = false;
    }
}

MetalRenderer::~MetalRenderer() {
    shutdown();
}

// ── init ───────────────────────────────────────────────────────

bool MetalRenderer::init() {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        NSLog(@"MetalRenderer: No Metal device available");
        return false;
    }
    return initCommon();
}

bool MetalRenderer::init(id<MTLDevice> externalDevice) {
    if (!externalDevice) {
        NSLog(@"MetalRenderer: nil external device");
        return false;
    }
    _device = externalDevice;
    return initCommon();
}

bool MetalRenderer::initCommon() {
    _commandQueue = [_device newCommandQueue];

    NSLog(@"Metal Device: %@ (recommended max working set: %.1f GB)",
          _device.name,
          _device.recommendedMaxWorkingSetSize / (1024.0 * 1024.0 * 1024.0));

    loadShaders();
    buildDefaultColorTables();
    uploadAllColorTextures();

    // Create spatial grid buffer
    _spatialGridBuffer = [_device newBufferWithLength:sizeof(SpatialGrid)
                                             options:MTLResourceStorageModeShared];

    // Create color table buffer (GPU copy of all color tables)
    _colorTableBuffer = [_device newBufferWithLength:sizeof(_runtimeColorTables)
                                            options:MTLResourceStorageModeShared];
    memcpy(_colorTableBuffer.contents, _runtimeColorTables, sizeof(_runtimeColorTables));

    memset(&_stations, 0, sizeof(_stations));
    _numStations = 0;

    // Reinitialize station buffer Obj-C references after memset
    for (int i = 0; i < MAX_STATIONS; i++) {
        _stations[i].azimuths = nil;
        for (int p = 0; p < NUM_PRODUCTS; p++)
            _stations[i].gates[p] = nil;
        _stations[i].allocated = false;
    }

    NSLog(@"Metal renderer initialized (native-res mode).");
    return true;
}

// ── shutdown ───────────────────────────────────────────────────

void MetalRenderer::shutdown() {
    for (int i = 0; i < MAX_STATIONS; i++)
        freeStation(i);

    for (int p = 0; p < NUM_PRODUCTS; p++)
        _colorTextures[p] = nil;

    _colorSampler = nil;
    _colorTableBuffer = nil;
    _spatialGridBuffer = nil;
    _stationInfoBuffer = nil;
    _stationInfoBufferCapacity = 0;
    _forwardAccumBuffer = nil;
    _forwardAccumCapacity = 0;

    _volumeRawBuffer = nil;
    _volumeScratchBuffer = nil;
    _volumeTexture = nil;
    _volumeSampler = nil;
    _sweepDescBuffer = nil;
    _volumeReady = false;

    _nativeRenderPSO = nil;
    _singleStationPSO = nil;
    _clearPSO = nil;
    _forwardRenderPSO = nil;
    _forwardResolvePSO = nil;
    _buildGridPSO = nil;
    _buildVolumePSO = nil;
    _smoothVolumePSO = nil;
    _rayMarchPSO = nil;
    _crossSectionPSO = nil;

    _library = nil;
    _commandQueue = nil;
    _device = nil;
}

// ── loadShaders ────────────────────────────────────────────────

void MetalRenderer::loadShaders() {
    NSError* error = nil;

    // Try 1: default library (embedded in app bundle)
    _library = [_device newDefaultLibrary];

    // Try 2: metallib next to executable
    if (!_library) {
        NSString* execPath = [[NSBundle mainBundle] executablePath];
        NSString* dir = [execPath stringByDeletingLastPathComponent];
        NSString* libPath = [dir stringByAppendingPathComponent:@"default.metallib"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:libPath]) {
            _library = [_device newLibraryWithFile:libPath error:&error];
            if (_library) NSLog(@"Loaded metallib from: %@", libPath);
        }
    }

    // Try 3: compile from source at runtime
    if (!_library) {
        NSLog(@"MetalRenderer: No precompiled metallib found, compiling shaders from source...");
        // Find shader source files relative to executable or in src/metal/
        NSArray* searchPaths = @[
            @"src/metal",
            @"../src/metal",
            @"../../src/metal",
        ];
        // Also try relative to current working dir
        NSString* cwd = [[NSFileManager defaultManager] currentDirectoryPath];

        NSMutableString* combinedSource = [NSMutableString string];
        NSArray* shaderFiles = @[@"gpu_pipeline.metal", @"renderer.metal", @"volume3d.metal"];

        for (NSString* searchPath in searchPaths) {
            NSString* fullBase = [cwd stringByAppendingPathComponent:searchPath];
            NSString* testFile = [fullBase stringByAppendingPathComponent:@"renderer.metal"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:testFile]) {
                // First, inline the common header once at the top
                NSString* headerPath = [fullBase stringByAppendingPathComponent:@"metal_common.h"];
                NSString* headerSrc = [NSString stringWithContentsOfFile:headerPath
                                                                encoding:NSUTF8StringEncoding
                                                                   error:nil];
                if (headerSrc) {
                    // Strip #pragma once from header
                    headerSrc = [headerSrc stringByReplacingOccurrencesOfString:@"#pragma once"
                                                                    withString:@""];
                    [combinedSource appendString:headerSrc];
                    [combinedSource appendString:@"\n"];
                }

                // Then append each shader file, stripping their #include and #pragma once
                for (NSString* file in shaderFiles) {
                    NSString* filePath = [fullBase stringByAppendingPathComponent:file];
                    NSString* source = [NSString stringWithContentsOfFile:filePath
                                                                encoding:NSUTF8StringEncoding
                                                                   error:&error];
                    if (source) {
                        source = [source stringByReplacingOccurrencesOfString:@"#include \"metal_common.h\""
                                                                  withString:@"// (header already included)"];
                        source = [source stringByReplacingOccurrencesOfString:@"#pragma once"
                                                                  withString:@""];
                        [combinedSource appendString:source];
                        [combinedSource appendString:@"\n"];
                    }
                }
                break;
            }
        }

        if (combinedSource.length > 0) {
            MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
            opts.fastMathEnabled = YES;
            opts.languageVersion = MTLLanguageVersion3_1;
            _library = [_device newLibraryWithSource:combinedSource options:opts error:&error];
            if (_library) {
                NSLog(@"MetalRenderer: Compiled shaders from source successfully");
            } else {
                NSLog(@"MetalRenderer: Shader compilation failed: %@", error);
                return;
            }
        } else {
            NSLog(@"MetalRenderer: Could not find shader source files");
            return;
        }
    }

    auto makePSO = [&](NSString* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> fn = [_library newFunctionWithName:name];
        if (!fn) {
            NSLog(@"MetalRenderer: Missing kernel: %@", name);
            return nil;
        }
        NSError* err = nil;
        id<MTLComputePipelineState> pso = [_device newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) {
            NSLog(@"MetalRenderer: PSO error for %@: %@", name, err);
        }
        return pso;
    };

    _nativeRenderPSO   = makePSO(@"native_render");
    _singleStationPSO  = makePSO(@"single_station_render");
    _clearPSO          = makePSO(@"clear_output");
    _forwardRenderPSO  = makePSO(@"forward_render");
    _forwardResolvePSO = makePSO(@"forward_resolve");
    _buildGridPSO      = makePSO(@"build_spatial_grid");
    _buildVolumePSO    = makePSO(@"build_volume");
    _smoothVolumePSO   = makePSO(@"smooth_volume");
    _rayMarchPSO       = makePSO(@"ray_march");
    _crossSectionPSO   = makePSO(@"cross_section");
}

// ── Color Table Generation ─────────────────────────────────────

void MetalRenderer::buildDefaultColorTables() {
    generateRefColorTable(_defaultColorTables[PROD_REF]);
    generateVelColorTable(_defaultColorTables[PROD_VEL]);

    // Spectrum Width
    memset(_defaultColorTables[PROD_SW], 0, 256 * 4);
    {
        const float mn = 0, mx = 30;
        fillRange(_defaultColorTables[PROD_SW],  0,  3, mn, mx,  45,  45,  45);
        fillRange(_defaultColorTables[PROD_SW],  3,  5, mn, mx, 117, 117, 117);
        fillRange(_defaultColorTables[PROD_SW],  5,  7, mn, mx, 200, 200, 200);
        fillRange(_defaultColorTables[PROD_SW],  7,  9, mn, mx, 255, 230,   0);
        fillRange(_defaultColorTables[PROD_SW],  9, 12, mn, mx, 255, 195,   0);
        fillRange(_defaultColorTables[PROD_SW], 12, 15, mn, mx, 255, 110,   0);
        fillRange(_defaultColorTables[PROD_SW], 15, 18, mn, mx, 255,  10,   0);
        fillRange(_defaultColorTables[PROD_SW], 18, 22, mn, mx, 255,   5, 100);
        fillRange(_defaultColorTables[PROD_SW], 22, 26, mn, mx, 255,   0, 200);
        fillRange(_defaultColorTables[PROD_SW], 26, 30, mn, mx, 255, 159, 234);
    }

    // Differential Reflectivity (ZDR)
    memset(_defaultColorTables[PROD_ZDR], 0, 256 * 4);
    {
        const float mn = -8, mx = 8;
        fillRange(_defaultColorTables[PROD_ZDR], -8, -3, mn, mx,  55,  55,  55);
        fillRange(_defaultColorTables[PROD_ZDR], -3, -1, mn, mx, 138, 138, 138);
        fillRange(_defaultColorTables[PROD_ZDR], -1,  0, mn, mx, 148, 132, 177);
        fillRange(_defaultColorTables[PROD_ZDR],  0,  0.5f, mn, mx,  29,  89, 174);
        fillRange(_defaultColorTables[PROD_ZDR],  0.5f, 1, mn, mx,  49, 169, 193);
        fillRange(_defaultColorTables[PROD_ZDR],  1, 1.5f, mn, mx,  68, 248, 212);
        fillRange(_defaultColorTables[PROD_ZDR],  1.5f, 2, mn, mx,  90, 221,  98);
        fillRange(_defaultColorTables[PROD_ZDR],  2, 2.5f, mn, mx, 255, 255, 100);
        fillRange(_defaultColorTables[PROD_ZDR],  2.5f, 3, mn, mx, 238, 133,  53);
        fillRange(_defaultColorTables[PROD_ZDR],  3, 4, mn, mx, 220,  10,   5);
        fillRange(_defaultColorTables[PROD_ZDR],  4, 5, mn, mx, 208,  60,  90);
        fillRange(_defaultColorTables[PROD_ZDR],  5, 6, mn, mx, 240, 120, 180);
        fillRange(_defaultColorTables[PROD_ZDR],  6, 7, mn, mx, 255, 255, 255);
        fillRange(_defaultColorTables[PROD_ZDR],  7, 8, mn, mx, 200, 150, 203);
    }

    // Correlation Coefficient (CC/RhoHV)
    memset(_defaultColorTables[PROD_CC], 0, 256 * 4);
    {
        const float mn = 0.2f, mx = 1.05f;
        fillRange(_defaultColorTables[PROD_CC], 0.20f, 0.45f, mn, mx,  20,   0,  50);
        fillRange(_defaultColorTables[PROD_CC], 0.45f, 0.60f, mn, mx,   0,   0, 110);
        fillRange(_defaultColorTables[PROD_CC], 0.60f, 0.70f, mn, mx,   0,   0, 150);
        fillRange(_defaultColorTables[PROD_CC], 0.70f, 0.75f, mn, mx,   0,   0, 170);
        fillRange(_defaultColorTables[PROD_CC], 0.75f, 0.80f, mn, mx,   0,   0, 255);
        fillRange(_defaultColorTables[PROD_CC], 0.80f, 0.85f, mn, mx, 125, 125, 255);
        fillRange(_defaultColorTables[PROD_CC], 0.85f, 0.90f, mn, mx,  85, 255,  85);
        fillRange(_defaultColorTables[PROD_CC], 0.90f, 0.92f, mn, mx, 255, 255,   0);
        fillRange(_defaultColorTables[PROD_CC], 0.92f, 0.95f, mn, mx, 255, 110,   0);
        fillRange(_defaultColorTables[PROD_CC], 0.95f, 0.97f, mn, mx, 255,  55,   0);
        fillRange(_defaultColorTables[PROD_CC], 0.97f, 1.00f, mn, mx, 255,   0,   0);
        fillRange(_defaultColorTables[PROD_CC], 1.00f, 1.05f, mn, mx, 145,   0, 135);
    }

    // Specific Differential Phase (KDP)
    memset(_defaultColorTables[PROD_KDP], 0, 256 * 4);
    {
        const float mn = -10, mx = 15;
        fillRange(_defaultColorTables[PROD_KDP], -10, -1, mn, mx, 101, 101, 101);
        fillRange(_defaultColorTables[PROD_KDP],  -1,  0, mn, mx, 166,  10,  50);
        fillRange(_defaultColorTables[PROD_KDP],   0,  1, mn, mx, 228, 105, 161);
        fillRange(_defaultColorTables[PROD_KDP],   1,  2, mn, mx, 166, 125, 185);
        fillRange(_defaultColorTables[PROD_KDP],   2,  3, mn, mx,  90, 255, 255);
        fillRange(_defaultColorTables[PROD_KDP],   3,  4, mn, mx,  20, 246,  20);
        fillRange(_defaultColorTables[PROD_KDP],   4,  5, mn, mx, 255, 251,   3);
        fillRange(_defaultColorTables[PROD_KDP],   5,  6, mn, mx, 255, 129,  21);
        fillRange(_defaultColorTables[PROD_KDP],   6,  8, mn, mx, 255, 162,  75);
        fillRange(_defaultColorTables[PROD_KDP],   8, 15, mn, mx, 145,  37, 125);
    }

    // Differential Phase (PHI)
    memset(_defaultColorTables[PROD_PHI], 0, 256 * 4);
    interpolateColor(_defaultColorTables[PROD_PHI],   1,  64,   0,   0, 200,   0, 200, 255);
    interpolateColor(_defaultColorTables[PROD_PHI],  64, 128,   0, 200, 255,   0, 255,   0);
    interpolateColor(_defaultColorTables[PROD_PHI], 128, 192,   0, 255,   0, 255, 255,   0);
    interpolateColor(_defaultColorTables[PROD_PHI], 192, 255, 255, 255,   0, 255,   0,   0);

    // Copy defaults into runtime tables
    memcpy(_runtimeColorTables, _defaultColorTables, sizeof(_runtimeColorTables));
}

// ── Color Texture (1D with HW interpolation) ──────────────────

void MetalRenderer::buildColorTexture(int product, const uint32_t* table) {
    if (product < 0 || product >= NUM_PRODUCTS || !table) return;

    // Convert RGBA8 -> RGBA32F for linear interpolation
    float texData[256 * 4];
    for (int i = 0; i < 256; i++) {
        uint32_t c = table[i];
        texData[i * 4 + 0] = (float)(c & 0xFF) / 255.0f;
        texData[i * 4 + 1] = (float)((c >> 8) & 0xFF) / 255.0f;
        texData[i * 4 + 2] = (float)((c >> 16) & 0xFF) / 255.0f;
        texData[i * 4 + 3] = (float)((c >> 24) & 0xFF) / 255.0f;
    }

    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.textureType = MTLTextureType1D;
    desc.pixelFormat = MTLPixelFormatRGBA32Float;
    desc.width = 256;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    _colorTextures[product] = [_device newTextureWithDescriptor:desc];
    [_colorTextures[product] replaceRegion:MTLRegionMake1D(0, 256)
                               mipmapLevel:0
                                 withBytes:texData
                               bytesPerRow:256 * 4 * sizeof(float)];

    if (!_colorSampler) {
        MTLSamplerDescriptor* samplerDesc = [MTLSamplerDescriptor new];
        samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        _colorSampler = [_device newSamplerStateWithDescriptor:samplerDesc];
    }
}

void MetalRenderer::uploadAllColorTextures() {
    for (int p = 0; p < NUM_PRODUCTS; p++)
        buildColorTexture(p, _runtimeColorTables[p]);

    // Also upload the flat buffer copy for kernels that use buffer-based lookup
    if (_colorTableBuffer) {
        memcpy(_colorTableBuffer.contents, _runtimeColorTables, sizeof(_runtimeColorTables));
    }
}

// ── Color Table API ────────────────────────────────────────────

void MetalRenderer::setColorTable(int product, const uint32_t* rgba256) {
    if (product < 0 || product >= NUM_PRODUCTS || !rgba256) return;
    memcpy(_runtimeColorTables[product], rgba256, 256 * sizeof(uint32_t));
    buildColorTexture(product, _runtimeColorTables[product]);
    if (_colorTableBuffer) {
        memcpy(_colorTableBuffer.contents, _runtimeColorTables, sizeof(_runtimeColorTables));
    }
}

void MetalRenderer::resetColorTable(int product) {
    if (product < 0 || product >= NUM_PRODUCTS) return;
    setColorTable(product, _defaultColorTables[product]);
}

void MetalRenderer::resetAllColorTables() {
    memcpy(_runtimeColorTables, _defaultColorTables, sizeof(_runtimeColorTables));
    uploadAllColorTextures();
}

// ── Station Management ─────────────────────────────────────────

void MetalRenderer::allocateStation(int idx, const GpuStationInfo& info) {
    if (idx < 0 || idx >= MAX_STATIONS) return;
    auto& station = _stations[idx];
    station.info = info;
    station.allocated = true;

    if (idx >= _numStations)
        _numStations = idx + 1;
}

void MetalRenderer::freeStation(int idx) {
    if (idx < 0 || idx >= MAX_STATIONS) return;
    auto& station = _stations[idx];
    if (!station.allocated) return;

    station.azimuths = nil;
    for (int p = 0; p < NUM_PRODUCTS; p++)
        station.gates[p] = nil;
    memset(&station.info, 0, sizeof(GpuStationInfo));
    station.allocated = false;
}

void MetalRenderer::uploadStationData(int idx, const GpuStationInfo& info,
                                       const float* azimuths,
                                       const uint16_t* gate_data[NUM_PRODUCTS]) {
    if (idx < 0 || idx >= MAX_STATIONS) return;
    auto& station = _stations[idx];
    station.info = info;
    station.allocated = true;

    if (idx >= _numStations)
        _numStations = idx + 1;

    // Azimuths buffer
    size_t az_size = (size_t)info.num_radials * sizeof(float);
    if (az_size > 0) {
        if (!station.azimuths || station.azimuths.length < az_size) {
            station.azimuths = [_device newBufferWithLength:az_size
                                                   options:MTLResourceStorageModeShared];
        }
        memcpy(station.azimuths.contents, azimuths, az_size);
    }

    // Gate buffers per product
    for (int p = 0; p < NUM_PRODUCTS; p++) {
        if (info.has_product[p] && gate_data[p]) {
            size_t sz = (size_t)info.num_gates[p] * (size_t)info.num_radials * sizeof(uint16_t);
            if (sz > 0) {
                if (!station.gates[p] || station.gates[p].length < sz) {
                    station.gates[p] = [_device newBufferWithLength:sz
                                                           options:MTLResourceStorageModeShared];
                }
                memcpy(station.gates[p].contents, gate_data[p], sz);
            }
        }
    }
}

void MetalRenderer::waitForGpu() {
    // Submit an empty command buffer and wait for it to complete.
    // This guarantees all previously committed work is finished.
    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];
}

void MetalRenderer::syncStation(int idx) {
    // In Metal with StorageModeShared, CPU writes are immediately visible.
    // For completeness, we could wait on a command buffer if one is in flight.
    // Currently a no-op since we use synchronous commit patterns.
    (void)idx;
}

void MetalRenderer::swapStationPointers(int idx, const GpuStationInfo& info,
                                         id<MTLBuffer> azimuths,
                                         id<MTLBuffer> __unsafe_unretained gates[NUM_PRODUCTS]) {
    if (idx < 0 || idx >= MAX_STATIONS) return;
    auto& station = _stations[idx];
    station.info = info;
    station.azimuths = azimuths;
    for (int p = 0; p < NUM_PRODUCTS; p++)
        station.gates[p] = gates[p];
    if (!station.allocated)
        station.allocated = true;
}

// ── Helper: Clear Output Buffer ────────────────────────────────

void MetalRenderer::clearOutputBuffer(const GpuViewport& vp, id<MTLBuffer> output) {
    // CPU clear — fast for shared-mode buffers, avoids kernel binding complexity
    size_t pixel_count = (size_t)vp.width * (size_t)vp.height;
    uint32_t* ptr = (uint32_t*)output.contents;
    for (size_t i = 0; i < pixel_count; i++)
        ptr[i] = kBackgroundColor;
    return;

    // GPU clear (disabled — binding mismatch to fix later)
    ClearParams params;
    params.width = vp.width;
    params.height = vp.height;
    params.color = kBackgroundColor;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

    [enc setComputePipelineState:_clearPSO];
    [enc setBuffer:output offset:0 atIndex:0];
    [enc setBytes:&params length:sizeof(params) atIndex:1];

    MTLSize threadsPerGroup = MTLSizeMake(32, 8, 1);
    MTLSize threadgroupCount = MTLSizeMake(
        ((NSUInteger)vp.width + 31) / 32,
        ((NSUInteger)vp.height + 7) / 8, 1);

    [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [enc endEncoding];
    [cmdBuf commit];
    // Note: GPU clear path disabled — CPU clear above returns before reaching here
    // If re-enabled, no waitUntilCompleted needed (async is fine for clear)
}

// ── Helper: shouldUseInverseFallback ───────────────────────────

bool MetalRenderer::shouldUseInverseFallback(const GpuViewport& vp,
                                              const GpuStationInfo& info,
                                              int product) {
    if (product < 0 || product >= NUM_PRODUCTS || info.num_radials <= 0)
        return true;

    float gskm = info.gate_spacing_km[product];
    if (gskm <= 0.0f) return true;

    float cos_lat = cosf(info.lat * (float)M_PI / 180.0f);
    cos_lat = fmaxf(cos_lat, 0.1f);

    float km_per_px_x = fabsf(vp.deg_per_pixel_x) * 111.0f * cos_lat;
    float km_per_px_y = fabsf(vp.deg_per_pixel_y) * 111.0f;
    if (km_per_px_x <= 0.0f || km_per_px_y <= 0.0f) return false;

    float px_per_km = 1.0f / fminf(km_per_px_x, km_per_px_y);
    float gate_depth_px = gskm * px_per_km;
    float nominal_span_rad = (2.0f * (float)M_PI) / fmaxf((float)info.num_radials, 1.0f);
    float sample_range_km = fmaxf(info.first_gate_km[product] + 8.0f * gskm, 20.0f);
    float beam_width_px = sample_range_km * nominal_span_rad * px_per_km;

    return gate_depth_px > 48.0f ||
           beam_width_px > 48.0f ||
           (gate_depth_px * fmaxf(beam_width_px, 1.0f)) > 2048.0f;
}

// ── Helper: ensureForwardAccumCapacity ─────────────────────────

void MetalRenderer::ensureForwardAccumCapacity(size_t pixel_count) {
    if (pixel_count <= _forwardAccumCapacity && _forwardAccumBuffer) return;
    _forwardAccumBuffer = [_device newBufferWithLength:pixel_count * sizeof(uint32_t)
                                              options:MTLResourceStorageModeShared];
    _forwardColorBuffer = [_device newBufferWithLength:pixel_count * sizeof(uint32_t)
                                               options:MTLResourceStorageModeShared];
    _forwardAccumCapacity = pixel_count;
}

// ── Helper: initializeSpatialGrid ──────────────────────────────

void MetalRenderer::initializeSpatialGrid(SpatialGrid* grid) {
    if (!grid) return;
    memset(grid, 0, sizeof(SpatialGrid));
    grid->min_lat = 15.0f;
    grid->max_lat = 72.0f;
    grid->min_lon = -180.0f;
    grid->max_lon = -60.0f;
    for (int gy = 0; gy < SPATIAL_GRID_H; gy++)
        for (int gx = 0; gx < SPATIAL_GRID_W; gx++)
            for (int s = 0; s < MAX_STATIONS_PER_CELL; s++)
                grid->cells[gy][gx][s] = -1;
}

// ── createOutputBuffer ─────────────────────────────────────────

id<MTLBuffer> MetalRenderer::createOutputBuffer(int width, int height) {
    size_t size = (size_t)width * (size_t)height * sizeof(uint32_t);
    return [_device newBufferWithLength:size options:MTLResourceStorageModeShared];
}

// ════════════════════════════════════════════════════════════════
// Rendering
// ════════════════════════════════════════════════════════════════

// ── renderNative (mosaic: all stations) ────────────────────────

void MetalRenderer::renderNative(const GpuViewport& vp,
                                  const GpuStationInfo* stations, int num_stations,
                                  const SpatialGrid& grid,
                                  int product, float dbz_min,
                                  id<MTLBuffer> output) {
    // Mosaic mode: multi-station composite using forward render with shared
    // depth buffer. Metal limits buffer bindings to 31, so we can't bind all
    // 256 stations at once like CUDA. Instead, forward-render each visible
    // station into a shared depth+color accumulation buffer, then resolve once.

    if (!_forwardRenderPSO || !_forwardResolvePSO) {
        clearOutputBuffer(vp, output);
        return;
    }

    size_t pixel_count = (size_t)vp.width * (size_t)vp.height;
    ensureForwardAccumCapacity(pixel_count);

    // Clear depth buffer to max (empty), color to 0
    memset(_forwardAccumBuffer.contents, 0xFF, pixel_count * sizeof(uint32_t));
    memset(_forwardColorBuffer.contents, 0, pixel_count * sizeof(uint32_t));

    // Single command buffer for ALL station forward renders + resolve
    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];

    // Forward-render each visible station into the shared accum buffers
    for (int i = 0; i < num_stations && i < MAX_STATIONS; i++) {
        auto& st = _stations[i];
        if (!st.allocated || !st.info.has_product[product] || !st.gates[product])
            continue;
        if (st.info.num_radials <= 0) continue;

        // Frustum cull: skip stations far outside viewport
        float dlat = fabsf(st.info.lat - vp.center_lat);
        float dlon = fabsf(st.info.lon - vp.center_lon);
        float halfH = (float)vp.height * 0.5f * vp.deg_per_pixel_y;
        float halfW = (float)vp.width * 0.5f * vp.deg_per_pixel_x;
        if (dlat > halfH + 5.0f || dlon > halfW + 5.0f)
            continue;

        ForwardRenderParams fwdParams;
        fwdParams.vp = vp;
        fwdParams.info = st.info;
        fwdParams.product = product;
        fwdParams.dbz_min = dbz_min;
        fwdParams.srv_speed = 0.0f;
        fwdParams.srv_dir_rad = 0.0f;

        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:_forwardRenderPSO];
        [enc setBuffer:st.azimuths offset:0 atIndex:0];
        [enc setBuffer:st.gates[product] offset:0 atIndex:1];
        [enc setBuffer:_forwardAccumBuffer offset:0 atIndex:2];
        [enc setBuffer:_forwardColorBuffer offset:0 atIndex:3];
        [enc setBytes:&fwdParams length:sizeof(fwdParams) atIndex:4];
        [enc setTexture:_colorTextures[product] atIndex:0];
        [enc setSamplerState:_colorSampler atIndex:0];

        int nr = st.info.num_radials;
        int ng = st.info.num_gates[product];
        MTLSize threadsPerGroup = MTLSizeMake(32, 8, 1);
        MTLSize threadgroupCount = MTLSizeMake(
            ((NSUInteger)nr + 31) / 32,
            ((NSUInteger)ng + 7) / 8, 1);

        [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
        [enc endEncoding];
    }

    // Resolve: depth+color -> final RGBA output (same command buffer, no wait between)
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:_forwardResolvePSO];
        [enc setBuffer:_forwardAccumBuffer offset:0 atIndex:0];
        [enc setBuffer:_forwardColorBuffer offset:0 atIndex:1];
        [enc setBuffer:output offset:0 atIndex:2];

        ForwardResolveParams resolveParams;
        resolveParams.width = vp.width;
        resolveParams.height = vp.height;
        [enc setBytes:&resolveParams length:sizeof(resolveParams) atIndex:3];

        MTLSize threadsPerGroup = MTLSizeMake(32, 8, 1);
        MTLSize threadgroupCount = MTLSizeMake(
            ((NSUInteger)vp.width + 31) / 32,
            ((NSUInteger)vp.height + 7) / 8, 1);

        [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
        [enc endEncoding];
    }

    [cmdBuf commit];
    // NO waitUntilCompleted — all station renders + resolve are batched in one command buffer.
    // GPU executes them in order. Coordinator reads the output buffer next frame.
}

// ── renderSingleStation ────────────────────────────────────────

void MetalRenderer::renderSingleStation(const GpuViewport& vp, int station_idx,
                                         int product, float dbz_min,
                                         id<MTLBuffer> output,
                                         float srv_speed, float srv_dir) {
    if (station_idx < 0 || station_idx >= MAX_STATIONS) {
        clearOutputBuffer(vp, output);
        return;
    }
    auto& station = _stations[station_idx];
    if (!station.allocated || !station.info.has_product[product] || !station.gates[product]) {
        clearOutputBuffer(vp, output);
        return;
    }

    if (!_singleStationPSO) {
        clearOutputBuffer(vp, output);
        return;
    }

    SingleStationParams params;
    params.vp = vp;
    params.info = station.info;
    params.product = product;
    params.dbz_min = dbz_min;
    params.srv_speed = srv_speed;
    params.srv_dir_rad = srv_dir * (float)M_PI / 180.0f;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

    [enc setComputePipelineState:_singleStationPSO];
    [enc setBuffer:station.azimuths offset:0 atIndex:0];
    [enc setBuffer:station.gates[product] offset:0 atIndex:1];
    [enc setBuffer:output offset:0 atIndex:2];
    [enc setBytes:&params length:sizeof(params) atIndex:3];
    [enc setTexture:_colorTextures[product] atIndex:0];
    [enc setSamplerState:_colorSampler atIndex:0];

    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadgroupCount = MTLSizeMake(
        ((NSUInteger)vp.width + 15) / 16,
        ((NSUInteger)vp.height + 15) / 16, 1);

    // Shared memory for azimuths (cap at 32KB for Metal)
    NSUInteger sharedMemSize = (NSUInteger)station.info.num_radials * sizeof(float);
    if (sharedMemSize > 32768) sharedMemSize = 32768;
    [enc setThreadgroupMemoryLength:sharedMemSize atIndex:0];

    [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [enc endEncoding];
    [cmdBuf commit];
    // NO waitUntilCompleted — let GPU work complete asynchronously.
    // The coordinator reads the output buffer next frame (1-frame latency, invisible to user).
}

// ── forwardRenderStation ───────────────────────────────────────

void MetalRenderer::forwardRenderStation(const GpuViewport& vp, int station_idx,
                                          int product, float dbz_min,
                                          id<MTLBuffer> output,
                                          float srv_speed, float srv_dir) {
    if (station_idx < 0 || station_idx >= MAX_STATIONS) {
        clearOutputBuffer(vp, output);
        return;
    }
    auto& station = _stations[station_idx];
    if (!station.allocated || !station.info.has_product[product] || !station.gates[product]) {
        clearOutputBuffer(vp, output);
        return;
    }

    // Fall back to inverse mapping when zoomed in far enough that
    // forward rasterization would be less accurate
    if (shouldUseInverseFallback(vp, station.info, product)) {
        renderSingleStation(vp, station_idx, product, dbz_min, output, srv_speed, srv_dir);
        return;
    }

    if (!_forwardRenderPSO || !_forwardResolvePSO) {
        renderSingleStation(vp, station_idx, product, dbz_min, output, srv_speed, srv_dir);
        return;
    }

    size_t pixel_count = (size_t)vp.width * (size_t)vp.height;
    ensureForwardAccumCapacity(pixel_count);

    // Fill depth buffer with sentinel (0xFF = max depth = empty)
    memset(_forwardAccumBuffer.contents, 0xFF, pixel_count * sizeof(uint32_t));
    memset(_forwardColorBuffer.contents, 0, pixel_count * sizeof(uint32_t));

    ForwardRenderParams fwdParams;
    fwdParams.vp = vp;
    fwdParams.info = station.info;
    fwdParams.product = product;
    fwdParams.dbz_min = dbz_min;
    fwdParams.srv_speed = srv_speed;
    fwdParams.srv_dir_rad = srv_dir * (float)M_PI / 180.0f;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];

    // Pass 1: Forward render (one thread per radial/gate pair)
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:_forwardRenderPSO];
        [enc setBuffer:station.azimuths offset:0 atIndex:0];
        [enc setBuffer:station.gates[product] offset:0 atIndex:1];
        [enc setBuffer:_forwardAccumBuffer offset:0 atIndex:2];  // depth buffer (atomic_uint)
        [enc setBuffer:_forwardColorBuffer offset:0 atIndex:3];  // color buffer
        [enc setBytes:&fwdParams length:sizeof(fwdParams) atIndex:4];
        [enc setTexture:_colorTextures[product] atIndex:0];
        [enc setSamplerState:_colorSampler atIndex:0];

        int nr = station.info.num_radials;
        int ng = station.info.num_gates[product];
        MTLSize threadsPerGroup = MTLSizeMake(32, 8, 1);
        MTLSize threadgroupCount = MTLSizeMake(
            ((NSUInteger)nr + 31) / 32,
            ((NSUInteger)ng + 7) / 8, 1);

        [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
        [enc endEncoding];
    }

    // Pass 2: Resolve accumulation buffer to RGBA output
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:_forwardResolvePSO];
        [enc setBuffer:_forwardAccumBuffer offset:0 atIndex:0];  // depth buffer
        [enc setBuffer:_forwardColorBuffer offset:0 atIndex:1];  // color buffer
        [enc setBuffer:output offset:0 atIndex:2];

        ForwardResolveParams resolveParams;
        resolveParams.width = vp.width;
        resolveParams.height = vp.height;
        [enc setBytes:&resolveParams length:sizeof(resolveParams) atIndex:3];

        MTLSize threadsPerGroup = MTLSizeMake(32, 8, 1);
        MTLSize threadgroupCount = MTLSizeMake(
            ((NSUInteger)vp.width + 31) / 32,
            ((NSUInteger)vp.height + 7) / 8, 1);

        [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
        [enc endEncoding];
    }

    [cmdBuf commit];
    // NO waitUntilCompleted — let GPU work complete asynchronously.
    // Both forward render + resolve are in the same command buffer for correct ordering.
    // The coordinator reads the output buffer next frame (1-frame latency, invisible to user).
}

// ════════════════════════════════════════════════════════════════
// Spatial Grid
// ════════════════════════════════════════════════════════════════

void MetalRenderer::buildSpatialGridGpu(const GpuStationInfo* h_stations, int num_stations,
                                         SpatialGrid* h_grid_out) {
    if (!h_grid_out) return;
    if (num_stations <= 0 || !h_stations) {
        initializeSpatialGrid(h_grid_out);
        return;
    }

    if (!_buildGridPSO) {
        // CPU fallback: build the grid on CPU
        initializeSpatialGrid(h_grid_out);
        float lat_range = h_grid_out->max_lat - h_grid_out->min_lat;
        float lon_range = h_grid_out->max_lon - h_grid_out->min_lon;
        float max_range_deg = 460.0f / 111.0f;

        for (int si = 0; si < num_stations; si++) {
            if (h_stations[si].num_radials <= 0) continue;
            float slat = h_stations[si].lat;
            float slon = h_stations[si].lon;

            int gx_min = (int)((slon - max_range_deg - h_grid_out->min_lon) / lon_range * SPATIAL_GRID_W);
            int gx_max = (int)((slon + max_range_deg - h_grid_out->min_lon) / lon_range * SPATIAL_GRID_W);
            int gy_min = (int)((slat - max_range_deg - h_grid_out->min_lat) / lat_range * SPATIAL_GRID_H);
            int gy_max = (int)((slat + max_range_deg - h_grid_out->min_lat) / lat_range * SPATIAL_GRID_H);

            if (gx_min < 0) gx_min = 0;
            if (gx_max >= SPATIAL_GRID_W) gx_max = SPATIAL_GRID_W - 1;
            if (gy_min < 0) gy_min = 0;
            if (gy_max >= SPATIAL_GRID_H) gy_max = SPATIAL_GRID_H - 1;

            for (int gy = gy_min; gy <= gy_max; gy++) {
                for (int gx = gx_min; gx <= gx_max; gx++) {
                    int& count = h_grid_out->counts[gy][gx];
                    if (count < MAX_STATIONS_PER_CELL) {
                        h_grid_out->cells[gy][gx][count] = si;
                        count++;
                    }
                }
            }
        }
        return;
    }

    // GPU path: upload station data, dispatch kernel, read back
    size_t info_size = (size_t)num_stations * sizeof(GpuStationInfo);
    id<MTLBuffer> stationBuf = [_device newBufferWithLength:info_size
                                                   options:MTLResourceStorageModeShared];
    memcpy(stationBuf.contents, h_stations, info_size);

    // Build active flags
    size_t active_size = (size_t)num_stations * sizeof(uint8_t);
    id<MTLBuffer> activeBuf = [_device newBufferWithLength:active_size
                                                  options:MTLResourceStorageModeShared];
    uint8_t* active_ptr = (uint8_t*)activeBuf.contents;
    for (int i = 0; i < num_stations; i++)
        active_ptr[i] = (h_stations[i].num_radials > 0) ? 1 : 0;

    // Initialize grid on CPU, upload (heap-allocated — SpatialGrid is ~1MB)
    auto init_grid_ptr = std::make_unique<SpatialGrid>();
    initializeSpatialGrid(init_grid_ptr.get());
    SpatialGrid& init_grid = *init_grid_ptr;

    id<MTLBuffer> gridBuf = [_device newBufferWithLength:sizeof(SpatialGrid)
                                                options:MTLResourceStorageModeShared];
    memcpy(gridBuf.contents, &init_grid, sizeof(SpatialGrid));

    BuildGridParams params;
    params.num_stations = num_stations;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

    [enc setComputePipelineState:_buildGridPSO];
    [enc setBuffer:stationBuf offset:0 atIndex:0];
    [enc setBuffer:activeBuf offset:0 atIndex:1];
    [enc setBuffer:gridBuf offset:0 atIndex:2];
    [enc setBytes:&params length:sizeof(params) atIndex:3];

    NSUInteger threadCount = (NSUInteger)num_stations;
    MTLSize threadsPerGroup = MTLSizeMake(256, 1, 1);
    MTLSize threadgroupCount = MTLSizeMake((threadCount + 255) / 256, 1, 1);

    [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [enc endEncoding];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    // Read back
    memcpy(h_grid_out, gridBuf.contents, sizeof(SpatialGrid));
}

// ════════════════════════════════════════════════════════════════
// Volume Rendering
// ════════════════════════════════════════════════════════════════

void MetalRenderer::initVolume() {
    freeVolume();

    size_t vol_size = (size_t)VOL_XY * VOL_XY * VOL_Z * sizeof(float) * 2;  // float2 = 8 bytes
    _volumeRawBuffer = [_device newBufferWithLength:vol_size
                                           options:MTLResourceStorageModeShared];
    _volumeScratchBuffer = [_device newBufferWithLength:vol_size
                                               options:MTLResourceStorageModeShared];

    // 3D texture for trilinear interpolation during ray marching
    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.textureType = MTLTextureType3D;
    desc.pixelFormat = MTLPixelFormatRG32Float;  // float2 (value, coverage)
    desc.width = VOL_XY;
    desc.height = VOL_XY;
    desc.depth = VOL_Z;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    _volumeTexture = [_device newTextureWithDescriptor:desc];

    if (!_volumeSampler) {
        MTLSamplerDescriptor* samplerDesc = [MTLSamplerDescriptor new];
        samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        samplerDesc.rAddressMode = MTLSamplerAddressModeClampToEdge;
        _volumeSampler = [_device newSamplerStateWithDescriptor:samplerDesc];
    }

    NSLog(@"3D volume: %dx%dx%d, HW trilinear texture, %.1f MB",
          VOL_XY, VOL_XY, VOL_Z, vol_size / (1024.0f * 1024.0f));
}

void MetalRenderer::freeVolume() {
    _volumeRawBuffer = nil;
    _volumeScratchBuffer = nil;
    _volumeTexture = nil;
    _volumeSampler = nil;
    _sweepDescBuffer = nil;
    _volumeReady = false;
}

void MetalRenderer::buildVolume(int station_idx, int product,
                                 const GpuStationInfo* sweep_infos, int num_sweeps,
                                 id<MTLBuffer> __unsafe_unretained * azimuths_per_sweep,
                                 id<MTLBuffer> __unsafe_unretained * gates_per_sweep) {
    (void)station_idx;
    _volumeReady = false;
    if (num_sweeps <= 0 || !_volumeRawBuffer || !_volumeScratchBuffer) return;
    if (!_buildVolumePSO || !_smoothVolumePSO) return;

    // Build sweep descriptors
    std::vector<SweepDesc> h_sweeps;
    h_sweeps.reserve(num_sweeps < 32 ? num_sweeps : 32);

    for (int s = 0; s < num_sweeps && (int)h_sweeps.size() < 32; s++) {
        const GpuStationInfo& info = sweep_infos[s];
        if (!info.has_product[product] ||
            info.num_radials <= 0 ||
            info.num_gates[product] <= 0 ||
            info.gate_spacing_km[product] <= 0.0f ||
            !azimuths_per_sweep[s] ||
            !gates_per_sweep[s]) {
            continue;
        }

        SweepDesc sw;
        memset(&sw, 0, sizeof(sw));
        sw.elevation_deg = info.elevation_angle;
        sw.num_radials = info.num_radials;
        sw.num_gates = info.num_gates[product];
        sw.first_gate_km = info.first_gate_km[product];
        sw.gate_spacing_km = info.gate_spacing_km[product];
        sw.scale = info.scale[product];
        sw.offset = info.offset[product];
        // Buffer offsets will be resolved by binding individual buffers
        sw.azimuth_buffer_offset = 0;
        sw.gate_buffer_offset = 0;
        h_sweeps.push_back(sw);
    }

    int count = (int)h_sweeps.size();
    if (count <= 0) return;

    // Upload sweep descriptors
    size_t sweep_buf_size = (size_t)count * sizeof(SweepDesc);
    if (!_sweepDescBuffer || _sweepDescBuffer.length < sweep_buf_size) {
        _sweepDescBuffer = [_device newBufferWithLength:sweep_buf_size
                                               options:MTLResourceStorageModeShared];
    }
    memcpy(_sweepDescBuffer.contents, h_sweeps.data(), sweep_buf_size);

    BuildVolumeParams buildParams;
    buildParams.product = product;
    buildParams.num_sweeps = count;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];

    // Pass 1: Build volume from sweep data
    {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:_buildVolumePSO];
        [enc setBuffer:_volumeRawBuffer offset:0 atIndex:0];
        [enc setBuffer:_sweepDescBuffer offset:0 atIndex:1];
        [enc setBytes:&buildParams length:sizeof(buildParams) atIndex:2];

        // Bind per-sweep azimuth and gate buffers
        for (int s = 0; s < count; s++) {
            // Find the original sweep index for this filtered sweep
            int orig_idx = 0;
            int found = 0;
            for (int si = 0; si < num_sweeps && found <= s; si++) {
                const GpuStationInfo& info = sweep_infos[si];
                if (info.has_product[product] &&
                    info.num_radials > 0 &&
                    info.num_gates[product] > 0 &&
                    info.gate_spacing_km[product] > 0.0f &&
                    azimuths_per_sweep[si] &&
                    gates_per_sweep[si]) {
                    if (found == s) { orig_idx = si; break; }
                    found++;
                }
            }
            [enc setBuffer:azimuths_per_sweep[orig_idx] offset:0 atIndex:(NSUInteger)(3 + s)];
            [enc setBuffer:gates_per_sweep[orig_idx] offset:0 atIndex:(NSUInteger)(3 + 32 + s)];
        }

        MTLSize threadsPerGroup = MTLSizeMake(8, 8, 1);
        MTLSize threadgroupCount = MTLSizeMake(
            ((NSUInteger)VOL_XY + 7) / 8,
            ((NSUInteger)VOL_XY + 7) / 8,
            (NSUInteger)VOL_Z);

        [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
        [enc endEncoding];
    }

    // Pass 2 & 3: Smooth volume (2 passes)
    static const int kVolumeSmoothPasses = 2;
    for (int pass = 0; pass < kVolumeSmoothPasses; ++pass) {
        id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];
        [enc setComputePipelineState:_smoothVolumePSO];

        id<MTLBuffer> src = (pass & 1) ? _volumeScratchBuffer : _volumeRawBuffer;
        id<MTLBuffer> dst = (pass & 1) ? _volumeRawBuffer : _volumeScratchBuffer;
        [enc setBuffer:src offset:0 atIndex:0];
        [enc setBuffer:dst offset:0 atIndex:1];

        SmoothVolumeParams smoothParams;
        smoothParams.product = product;
        [enc setBytes:&smoothParams length:sizeof(smoothParams) atIndex:2];

        MTLSize threadsPerGroup = MTLSizeMake(8, 8, 1);
        MTLSize threadgroupCount = MTLSizeMake(
            ((NSUInteger)VOL_XY + 7) / 8,
            ((NSUInteger)VOL_XY + 7) / 8,
            (NSUInteger)VOL_Z);

        [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
        [enc endEncoding];
    }

    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    // Copy the final smoothed data into the 3D texture for trilinear sampling
    // After 2 passes (even count), result is in _volumeRawBuffer
    id<MTLBuffer> finalBuf = _volumeRawBuffer;

    MTLRegion region = MTLRegionMake3D(0, 0, 0, VOL_XY, VOL_XY, VOL_Z);
    NSUInteger bytesPerRow = VOL_XY * sizeof(float) * 2;
    NSUInteger bytesPerImage = bytesPerRow * VOL_XY;

    [_volumeTexture replaceRegion:region
                      mipmapLevel:0
                            slice:0
                        withBytes:finalBuf.contents
                      bytesPerRow:bytesPerRow
                    bytesPerImage:bytesPerImage];

    _volumeReady = true;
    NSLog(@"3D volume built: %d sweeps, HW trilinear ready", count);
}

// ── renderVolume ───────────────────────────────────────────────

void MetalRenderer::renderVolume(const Camera3D& cam, int width, int height,
                                  int product, float dbz_min,
                                  id<MTLBuffer> output) {
    if (!_volumeReady || !_rayMarchPSO) return;

    // Compute camera vectors (same math as CUDA version)
    float theta = cam.orbit_angle * (float)M_PI / 180.0f;
    float phi = cam.tilt_angle * (float)M_PI / 180.0f;

    float cx = cam.distance * sinf(theta) * cosf(phi);
    float cy = cam.distance * cosf(theta) * cosf(phi);
    float cz = cam.distance * sinf(phi) + cam.target_z;

    // Forward vector (camera to target)
    float fx = -cx;
    float fy = -cy;
    float fz = cam.target_z - cz;
    float fl = 1.0f / sqrtf(fx * fx + fy * fy + fz * fz + 1e-8f);
    fx *= fl;
    fy *= fl;
    fz *= fl;

    // Right vector (cross forward with world up approximation)
    float rx = fy;
    float ry = -fx;
    float rz = 0.0f;
    float rl = 1.0f / sqrtf(rx * rx + ry * ry + rz * rz + 1e-8f);
    rx *= rl;
    ry *= rl;
    rz *= rl;

    // Up vector (cross right with forward)
    float ux = ry * fz - rz * fy;
    float uy = rz * fx - rx * fz;
    float uz = rx * fy - ry * fx;

    RayMarchParams params;
    params.cam_x = cx;    params.cam_y = cy;    params.cam_z = cz;
    params.fwd_x = fx;    params.fwd_y = fy;    params.fwd_z = fz;
    params.right_x = rx;  params.right_y = ry;  params.right_z = rz;
    params.up_x = ux;     params.up_y = uy;     params.up_z = uz;
    params.fov_scale = 0.62f;
    params.width = width;
    params.height = height;
    params.product = product;
    params.dbz_min = dbz_min;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

    [enc setComputePipelineState:_rayMarchPSO];
    [enc setBuffer:output offset:0 atIndex:0];
    [enc setBytes:&params length:sizeof(params) atIndex:1];
    [enc setBuffer:_colorTableBuffer offset:0 atIndex:2];
    [enc setTexture:_volumeTexture atIndex:0];
    [enc setSamplerState:_volumeSampler atIndex:0];

    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadgroupCount = MTLSizeMake(
        ((NSUInteger)width + 15) / 16,
        ((NSUInteger)height + 15) / 16, 1);

    [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [enc endEncoding];
    [cmdBuf commit];
    // NO waitUntilCompleted — let GPU ray march complete asynchronously.
}

// ── renderCrossSection ─────────────────────────────────────────

void MetalRenderer::renderCrossSection(int station_idx, int product, float dbz_min,
                                        float start_lat, float start_lon,
                                        float end_lat, float end_lon,
                                        float station_lat, float station_lon,
                                        int width, int height,
                                        id<MTLBuffer> output) {
    (void)station_idx;
    if (!_volumeReady || !_crossSectionPSO) return;

    float cos_lat = cosf(station_lat * (float)M_PI / 180.0f);
    float sx_km = (start_lon - station_lon) * 111.0f * cos_lat;
    float sy_km = (start_lat - station_lat) * 111.0f;
    float ex_km = (end_lon - station_lon) * 111.0f * cos_lat;
    float ey_km = (end_lat - station_lat) * 111.0f;

    float ddx = ex_km - sx_km;
    float ddy = ey_km - sy_km;
    float total = sqrtf(ddx * ddx + ddy * ddy);
    if (total < 1.0f) return;

    float nx = ddx / total;
    float ny = ddy / total;

    CrossSectionParams params;
    params.start_x_km = sx_km;
    params.start_y_km = sy_km;
    params.dir_x = nx;
    params.dir_y = ny;
    params.total_dist_km = total;
    params.width = width;
    params.height = height;
    params.product = product;
    params.dbz_min = dbz_min;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmdBuf computeCommandEncoder];

    [enc setComputePipelineState:_crossSectionPSO];
    [enc setBuffer:output offset:0 atIndex:0];
    [enc setBytes:&params length:sizeof(params) atIndex:1];
    [enc setBuffer:_sweepDescBuffer offset:0 atIndex:2];
    [enc setBuffer:_colorTableBuffer offset:0 atIndex:3];
    [enc setTexture:_volumeTexture atIndex:0];
    [enc setSamplerState:_volumeSampler atIndex:0];

    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);
    MTLSize threadgroupCount = MTLSizeMake(
        ((NSUInteger)width + 15) / 16,
        ((NSUInteger)height + 15) / 16, 1);

    [enc dispatchThreadgroups:threadgroupCount threadsPerThreadgroup:threadsPerGroup];
    [enc endEncoding];
    [cmdBuf commit];
    // NO waitUntilCompleted — let GPU cross-section render complete asynchronously.
}
