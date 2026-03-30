#include "metal_interop.h"
#include <cstdio>

MetalTexture::~MetalTexture() {
    destroy();
}

bool MetalTexture::init(int width, int height, id<MTLDevice> device) {
    m_device = device;
    m_width = width;
    m_height = height;

    MTLTextureDescriptor* desc = [MTLTextureDescriptor new];
    desc.textureType = MTLTextureType2D;
    desc.pixelFormat = MTLPixelFormatRGBA8Unorm;
    desc.width = width;
    desc.height = height;
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;  // CPU+GPU accessible

    m_texture = [device newTextureWithDescriptor:desc];
    if (!m_texture) {
        fprintf(stderr, "Failed to create Metal texture %dx%d\n", width, height);
        return false;
    }

    printf("Metal texture created: %dx%d\n", width, height);
    return true;
}

bool MetalTexture::resize(int width, int height) {
    if (width == m_width && height == m_height && m_texture) return true;
    destroy();
    return init(width, height, m_device);
}

void MetalTexture::updateFromBuffer(id<MTLBuffer> buffer, int width, int height,
                                     id<MTLCommandQueue> queue) {
    if (!m_texture || !buffer) return;

    // For shared storage mode, we can use replaceRegion directly
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [m_texture replaceRegion:region
                 mipmapLevel:0
                   withBytes:buffer.contents
                 bytesPerRow:width * sizeof(uint32_t)];
}

void MetalTexture::destroy() {
    m_texture = nil;
    m_width = 0;
    m_height = 0;
}
