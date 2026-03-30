import Metal
import MetalKit
import UIKit

class MetalRenderCoordinator: NSObject, MTKViewDelegate {
    let engine: RadarEngine
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    weak var appState: AppState?

    // For blitting compute output to screen
    private var pipelineState: MTLRenderPipelineState?
    private var outputTexture: MTLTexture?
    private var outputTextureSize: (Int, Int) = (0, 0)
    private var engineInitialized = false

    var isRendering = true
    private var lastSyncTime: CFTimeInterval = 0

    init(engine: RadarEngine, device: MTLDevice, appState: AppState) {
        self.engine = engine
        self.device = device
        self.appState = appState
        self.commandQueue = device.makeCommandQueue()!
        super.init()
        buildPipeline()
    }

    private func buildPipeline() {
        let shaderSrc = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut blit_vertex(uint vid [[vertex_id]]) {
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

        do {
            let library = try device.makeLibrary(source: shaderSrc, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "blit_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "blit_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("MetalRenderCoordinator: Failed to build blit pipeline: \(error)")
        }
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

    private func initEngineIfNeeded(width: Int, height: Int) {
        guard !engineInitialized && width > 0 && height > 0 else { return }
        print("MetalRenderCoordinator: Initializing engine \(width)x\(height) on thread \(Thread.isMainThread ? "MAIN" : "BG")")
        appState?.initialize(width: width, height: height)
        engineInitialized = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let w = Int(size.width)
        let h = Int(size.height)
        if w > 0 && h > 0 {
            if !engineInitialized {
                initEngineIfNeeded(width: w, height: h)
            } else {
                engine.resizeWidth(Int32(w), height: Int32(h))
            }
        }
    }

    func draw(in view: MTKView) {
        guard isRendering else { return }

        // Try to init if we haven't yet
        if !engineInitialized {
            let size = view.drawableSize
            if size.width > 0 && size.height > 0 {
                initEngineIfNeeded(width: Int(size.width), height: Int(size.height))
            }
            return
        }

        guard let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor else { return }

        let w = engine.viewportWidth()
        let h = engine.viewportHeight()
        if w <= 0 || h <= 0 { return }

        // 1. Copy PREVIOUS frame's output to texture (already complete from last frame's GPU work)
        if let outputBuf = engine.outputBuffer() {
            ensureOutputTexture(width: Int(w), height: Int(h))
            if let tex = outputTexture {
                let region = MTLRegionMake2D(0, 0, Int(w), Int(h))
                tex.replace(region: region, mipmapLevel: 0,
                            withBytes: outputBuf.contents(),
                            bytesPerRow: Int(w) * 4)
            }
        }

        // 2. Blit texture to drawable (uses previous frame's data — 1 frame latency, invisible)
        if let tex = outputTexture,
           let commandBuffer = commandQueue.makeCommandBuffer(),
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc),
           let pipeline = pipelineState {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // 3. Kick off THIS frame's compute (async, no wait — GPU works while we return)
        engine.update(withDeltaTime: Float(1.0 / Double(max(view.preferredFramesPerSecond, 1))))
        engine.render()

        // Sync UI state periodically (throttled, on main thread)
        let now = CACurrentMediaTime()
        if now - lastSyncTime > 0.3 {
            lastSyncTime = now
            DispatchQueue.main.async { [weak self] in
                self?.appState?.syncFromEngine()
            }
        }
    }
}
