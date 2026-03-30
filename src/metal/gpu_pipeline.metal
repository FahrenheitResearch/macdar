#include "metal_common.h"

// ── Helper Functions ────────────────────────────────────────

// Byte-swap helpers (big-endian to little-endian)
inline uint16_t d_bswap16(uint16_t v) {
    return (v >> 8) | (v << 8);
}

inline uint32_t d_bswap32(uint32_t v) {
    return ((v >> 24) & 0xFF) | ((v >> 8) & 0xFF00) |
           ((v << 8) & 0xFF0000) | ((v << 24) & 0xFF000000);
}

inline float d_bswapf(float v) {
    uint32_t i = as_type<uint32_t>(v);
    i = d_bswap32(i);
    return as_type<float>(i);
}

// Validate a potential MSG31 position in the raw buffer
inline bool isValidMsg31(const device uint8_t* data, int pos, int size) {
    if (pos + 12 + 16 + 32 > size) return false;
    // CTM at pos, MessageHeader at pos+12
    uint8_t msg_type = data[pos + 12 + 3]; // message_type byte
    if (msg_type != 31) return false;
    // Check message size is sane
    uint16_t msize = ((uint16_t)data[pos + 12] << 8) | data[pos + 12 + 1];
    if (msize < 20 || msize > 30000) return false;
    return true;
}

// Product code matching on GPU
// block[0] = btype, block[1..3] = product code characters
inline int d_productFromCode(const device uint8_t* block) {
    char c0 = (char)block[1];
    char c1 = (char)block[2];
    char c2 = (char)block[3];
    // REF=0, VEL=1, SW=2, ZDR=3, RHO=4, KDP=5, PHI=6
    if (c0 == 'R' && c1 == 'E' && c2 == 'F') return 0;
    if (c0 == 'V' && c1 == 'E' && c2 == 'L') return 1;
    if (c0 == 'S' && c1 == 'W')               return 2;
    if (c0 == 'Z' && c1 == 'D' && c2 == 'R') return 3;
    if (c0 == 'R' && c1 == 'H' && c2 == 'O') return 4;
    if (c0 == 'K' && c1 == 'D' && c2 == 'P') return 5;
    if (c0 == 'P' && c1 == 'H' && c2 == 'I') return 6;
    return -1;
}

// ── Kernel 1: Find Message Offsets at 2432-byte boundaries ──

kernel void find_message_offsets(
    const device uint8_t* raw        [[buffer(0)]],
    device int* offsets_out           [[buffer(1)]],
    device atomic_int* count_out      [[buffer(2)]],
    constant uint& raw_size           [[buffer(3)]],
    constant uint& max_messages       [[buffer(4)]],
    uint tid [[thread_position_in_grid]])
{
    // Each thread checks one potential position at a 2432-byte boundary
    int pos = tid * 2432;
    if (pos + 28 > (int)raw_size) return;

    if (isValidMsg31(raw, pos, (int)raw_size)) {
        int slot = atomic_fetch_add_explicit(count_out, 1, memory_order_relaxed);
        if (slot < (int)max_messages) {
            offsets_out[slot] = pos;
        }
    }
}

// ── Kernel 2: Find Variable-Offset Messages ────────────────

kernel void find_variable_offsets(
    const device uint8_t* raw         [[buffer(0)]],
    const device int* aligned_offsets  [[buffer(1)]],
    device int* offsets_out            [[buffer(2)]],
    device atomic_int* count_out       [[buffer(3)]],
    constant uint& raw_size            [[buffer(4)]],
    constant uint& num_aligned         [[buffer(5)]],
    constant uint& max_messages        [[buffer(6)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid >= num_aligned) return;

    int base = aligned_offsets[tid];
    if (base < 0 || base + 28 > (int)raw_size) return;

    // Read message size and compute next message position
    uint16_t msize = ((uint16_t)raw[base + 12] << 8) | raw[base + 12 + 1];
    if (msize < 20 || msize > 30000) return;

    int next_pos = base + (int)msize * 2 + 12;
    // Check if there's a valid message at a variable-offset position
    // that we wouldn't find at a 2432-byte boundary
    if (next_pos % 2432 != 0 && next_pos + 28 < (int)raw_size) {
        if (isValidMsg31(raw, next_pos, (int)raw_size)) {
            int slot = atomic_fetch_add_explicit(count_out, 1, memory_order_relaxed);
            if (slot < (int)max_messages) {
                offsets_out[slot] = next_pos;
            }
        }
    }
}

// ── Kernel 3: Parse MSG31 Messages ─────────────────────────

kernel void parse_msg31(
    const device uint8_t* raw         [[buffer(0)]],
    const device int* msg_offsets      [[buffer(1)]],
    device GpuParsedRadial* radials    [[buffer(2)]],
    constant uint& raw_size            [[buffer(3)]],
    constant uint& num_messages        [[buffer(4)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid >= num_messages) return;

    int pos = msg_offsets[tid];
    if (pos < 0 || pos + 12 + 16 + 32 > (int)raw_size) return;

    // Skip CTM(12) + MessageHeader(16) -> Msg31Header starts at pos+28
    int msg_base = pos + 12 + 16;
    int msg_remain = (int)raw_size - msg_base;
    if (msg_remain < 32) return;

    device GpuParsedRadial& r = radials[tid];

    // Zero-initialize
    r.azimuth = 0.0f;
    r.elevation = 0.0f;
    r.radial_status = 0;
    r.elevation_number = 0;
    r._pad0 = 0;
    for (int p = 0; p < NUM_PRODUCTS; p++) {
        r.moment_offsets[p] = -1;
        r.num_gates[p] = 0;
        r.gate_spacing[p] = 0;
        r.first_gate[p] = 0;
        r.scale[p] = 0.0f;
        r.offset[p] = 0.0f;
        r.data_word_size[p] = 0;
    }

    const device uint8_t* msg = raw + msg_base;

    // Parse Msg31 header
    // Bytes 12-15: azimuth angle (float32 BE)
    {
        uint32_t az_bits = ((uint32_t)msg[12] << 24) | ((uint32_t)msg[13] << 16) |
                           ((uint32_t)msg[14] << 8)  | (uint32_t)msg[15];
        r.azimuth = as_type<float>(az_bits);
    }
    // Bytes 24-27: elevation angle (float32 BE)
    {
        uint32_t el_bits = ((uint32_t)msg[24] << 24) | ((uint32_t)msg[25] << 16) |
                           ((uint32_t)msg[26] << 8)  | (uint32_t)msg[27];
        r.elevation = as_type<float>(el_bits);
    }

    r.radial_status = msg[21];
    r.elevation_number = msg[22];

    // Validate
    if (r.azimuth < 0.0f || r.azimuth >= 360.0f) { r.azimuth = -1.0f; return; }
    if (r.elevation < -2.0f || r.elevation > 90.0f) { r.azimuth = -1.0f; return; }

    // Data block count at bytes 30-31 (big-endian uint16)
    uint16_t block_count = ((uint16_t)msg[30] << 8) | msg[31];
    if (block_count < 1 || block_count > 20) return;

    // Data block pointers start at byte 32 (big-endian uint32)
    for (int b = 0; b < (int)block_count && b < 10; b++) {
        int ptr_off = 32 + b * 4;
        uint32_t bptr = ((uint32_t)msg[ptr_off] << 24) | ((uint32_t)msg[ptr_off + 1] << 16) |
                        ((uint32_t)msg[ptr_off + 2] << 8) | (uint32_t)msg[ptr_off + 3];
        if (bptr == 0 || (int)bptr >= msg_remain) continue;

        const device uint8_t* block = msg + bptr;
        char btype = (char)block[0];

        if (btype == 'D') {
            int p = d_productFromCode(block);
            if (p < 0 || p >= NUM_PRODUCTS) continue;
            if ((int)bptr + 28 > msg_remain) continue;

            r.num_gates[p] = ((uint16_t)block[8] << 8) | block[9];
            r.first_gate[p] = ((uint16_t)block[10] << 8) | block[11];
            r.gate_spacing[p] = ((uint16_t)block[12] << 8) | block[13];
            r.data_word_size[p] = block[19];

            {
                uint32_t s_bits = ((uint32_t)block[20] << 24) | ((uint32_t)block[21] << 16) |
                                  ((uint32_t)block[22] << 8)  | (uint32_t)block[23];
                r.scale[p] = as_type<float>(s_bits);
            }
            {
                uint32_t o_bits = ((uint32_t)block[24] << 24) | ((uint32_t)block[25] << 16) |
                                  ((uint32_t)block[26] << 8)  | (uint32_t)block[27];
                r.offset[p] = as_type<float>(o_bits);
            }

            // Store the absolute byte offset to gate data within raw buffer
            r.moment_offsets[p] = (int)((msg + bptr + 28) - raw);

            if (r.num_gates[p] == 0 || r.num_gates[p] > 2000) {
                r.moment_offsets[p] = -1;
                r.num_gates[p] = 0;
            }
            if (r.scale[p] == 0.0f) {
                r.moment_offsets[p] = -1;
            }
        }
    }
}

// ── Kernel 4: Transpose Gates ──────────────────────────────
// One thread per (gate, radial) pair. Reads from raw buffer at
// the offset stored in the parsed radial info, writes to
// gate-major output buffer.

kernel void transpose_gates(
    const device uint8_t* raw_data       [[buffer(0)]],
    const device GpuParsedRadial* radials [[buffer(1)]],
    const device int* radial_indices      [[buffer(2)]],
    device ushort* output                 [[buffer(3)]],
    constant TransposeParams& params      [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]])
{
    int gate = (int)gid.x;
    int radial = (int)gid.y;
    if (gate >= params.out_num_gates || radial >= (int)params.num_radials) return;

    int sorted_idx = radial_indices[radial];
    const device GpuParsedRadial& r = radials[sorted_idx];

    ushort value = 0;
    int off = r.moment_offsets[params.product];
    if (off >= 0 && gate < r.num_gates[params.product]) {
        if (r.data_word_size[params.product] == 16) {
            // 16-bit big-endian
            const device uint8_t* p = raw_data + off + gate * 2;
            value = ((ushort)p[0] << 8) | p[1];
        } else {
            // 8-bit
            value = raw_data[off + gate];
        }
    }

    // gate-major layout: output[gate * num_radials + radial]
    output[gate * (int)params.num_radials + radial] = value;
}

// ── Kernel 5: Extract Sorted Azimuths ──────────────────────

kernel void extract_azimuths(
    const device GpuParsedRadial* radials [[buffer(0)]],
    const device int* radial_indices      [[buffer(1)]],
    device float* azimuths_out            [[buffer(2)]],
    constant uint& num_radials            [[buffer(3)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid >= num_radials) return;
    azimuths_out[tid] = radials[radial_indices[tid]].azimuth;
}
