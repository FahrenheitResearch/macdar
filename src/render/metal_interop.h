#pragma once
#import <Metal/Metal.h>
#include <cstdint>

// Metal texture manager for ImGui display
// Replaces GlCudaTexture (CUDA-GL interop) with native Metal textures
class MetalTexture {
public:
    MetalTexture() = default;
    ~MetalTexture();

    // Create texture with given dimensions
    bool init(int width, int height, id<MTLDevice> device);

    // Resize (recreate if needed)
    bool resize(int width, int height);

    // Copy from MTLBuffer to texture for display
    void updateFromBuffer(id<MTLBuffer> buffer, int width, int height,
                          id<MTLCommandQueue> queue);

    // Get texture for ImGui::Image (cast to ImTextureID)
    id<MTLTexture> texture() const { return m_texture; }
    void* textureId() const { return (__bridge void*)m_texture; }
    int width() const { return m_width; }
    int height() const { return m_height; }

    void destroy();

private:
    id<MTLTexture> m_texture = nil;
    id<MTLDevice> m_device = nil;
    int m_width = 0;
    int m_height = 0;
};
