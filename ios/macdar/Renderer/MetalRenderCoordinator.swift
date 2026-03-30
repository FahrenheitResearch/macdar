import Metal
import MetalKit
import UIKit

class MetalRenderCoordinator: NSObject, MTKViewDelegate {
    let engine: RadarEngine
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // For blitting compute output to screen
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var outputTexture: MTLTexture?
    private var outputTextureSize: (Int, Int) = (0, 0)

    var isRendering = true

    init(engine: RadarEngine, device: MTLDevice) {
        self.engine = engine
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        super.init()
        buildPipeline()
    }

    // Build a simple fullscreen textured quad pipeline for displaying the compute output
    private func buildPipeline() {
        // We'll use a simple vertex/fragment shader to blit a texture to screen
        // Embedded as a string to avoid needing a separate .metal file
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut blit_vertex(uint vid [[vertex_id]]) {
            // Fullscreen triangle (3 vertices, no vertex buffer needed)
            float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            float2 texCoords[3] = {float2(0, 1), float2(2, 1), float2(0, -1)};
            VertexOut out;
            out.position = float4(positions[vid], 0, 1);
            out.texCoord = texCoords[vid];
            return out;
        }

        fragment float4 blit_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::nearest);
            return tex.sample(s, in.texCoord);
        }
        """

        let library = try! device.makeLibrary(source: shaderSrc, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "blit_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "blit_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func ensureOutputTexture(width: Int, height: Int) {
        if outputTextureSize == (width, height) && outputTexture != nil { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width, height: height,
            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        outputTexture = device.makeTexture(descriptor: desc)
        outputTextureSize = (width, height)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let w = Int(size.width)
        let h = Int(size.height)
        if w > 0 && h > 0 {
            engine.resize(width: Int32(w), height: Int32(h))
        }
    }

    func draw(in view: MTKView) {
        guard isRendering else { return }
        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor else { return }

        let w = engine.viewportWidth()
        let h = engine.viewportHeight()
        if w <= 0 || h <= 0 { return }

        // Update app state
        engine.update(withDeltaTime: Float(1.0 / Double(view.preferredFramesPerSecond)))

        // Run Metal compute to render radar
        engine.render()

        // Get the output buffer
        guard let outputBuf = engine.outputBuffer() else { return }

        // Copy buffer to texture
        ensureOutputTexture(width: Int(w), height: Int(h))
        guard let tex = outputTexture else { return }

        let region = MTLRegionMake2D(0, 0, Int(w), Int(h))
        tex.replace(region: region, mipmapLevel: 0,
                    withBytes: outputBuf.contents(),
                    bytesPerRow: Int(w) * 4)

        // Blit texture to drawable
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc),
              let pipeline = pipelineState else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(tex, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
