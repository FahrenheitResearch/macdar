#pragma once

#include "metal_common.h"

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include <cstdint>
#include <cstddef>

// ── GPU-accelerated data pipeline (Metal) ─────────────────
// Metal equivalent of the CUDA gpu_pipeline.
// Kernels for parsing, transposing, and processing radar data
// entirely on the GPU after raw bytes are uploaded.

namespace gpu_pipeline {

// ── Full GPU ingest result ─────────────────────────────────
// All device pointers are Metal buffers.

struct GpuIngestResult {
    id<MTLBuffer> d_azimuths = nil;
    id<MTLBuffer> d_gates[NUM_PRODUCTS] = {};
    int           num_radials = 0;
    int           num_gates[NUM_PRODUCTS] = {};
    float         first_gate_km[NUM_PRODUCTS] = {};
    float         gate_spacing_km[NUM_PRODUCTS] = {};
    float         scale[NUM_PRODUCTS] = {};
    float         offset[NUM_PRODUCTS] = {};
    bool          has_product[NUM_PRODUCTS] = {};
    float         elevation_angle = 0.0f;
    float         station_lat = 0.0f;
    float         station_lon = 0.0f;
};

// ── Parse raw Level 2 data on GPU ──────────────────────────
// Input:  raw decompressed bytes on host (h_raw_data, raw_size)
// Output: GpuParsedRadial array in a Metal buffer
// Returns: number of radials found
//
// Internally dispatches find_message_offsets, find_variable_offsets,
// and parse_msg31 kernels.
int parseOnGpu(const uint8_t* d_raw_data, size_t raw_size,
               id<MTLBuffer> d_radials_out, int max_radials,
               id<MTLCommandQueue> queue);

// ── GPU Transpose ──────────────────────────────────────────
// Transpose gate data from radial-major to gate-major layout.
// Also extracts sorted azimuths.
void transposeGatesGpu(
    id<MTLBuffer> d_raw_data,
    id<MTLBuffer> d_radials,
    int num_radials,
    int product,
    id<MTLBuffer> d_output,       // output: gate-major [num_gates][num_radials]
    int out_num_gates,
    id<MTLBuffer> d_azimuths_out, // output: sorted azimuth array
    id<MTLCommandQueue> queue);

// ── Full GPU ingest pipeline ───────────────────────────────
// Upload raw bytes -> parse -> transpose -> ready for rendering.
// All on GPU, returns Metal buffers ready for the render kernel.
GpuIngestResult ingestSweepGpu(const uint8_t* h_raw_data, size_t raw_size,
                                id<MTLCommandQueue> queue);

// ── Cleanup ────────────────────────────────────────────────
// Release Metal buffers held by the ingest result.
void freeIngestResult(GpuIngestResult& result);

} // namespace gpu_pipeline
