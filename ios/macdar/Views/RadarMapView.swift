import SwiftUI
import MetalKit

struct RadarMapView: UIViewRepresentable {
    @EnvironmentObject var appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = appState.device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
        mtkView.preferredFramesPerSecond = 30
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        // Initialize engine with view size
        let size = mtkView.drawableSize
        appState.initialize(width: Int(size.width), height: Int(size.height))

        // Create render coordinator
        let coordinator = context.coordinator
        coordinator.renderCoordinator = MetalRenderCoordinator(
            engine: appState.engine,
            device: appState.device)
        mtkView.delegate = coordinator.renderCoordinator

        // Add gesture recognizers
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        mtkView.addGestureRecognizer(pinch)

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        mtkView.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        mtkView.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        mtkView.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderCoordinator?.isRendering = appState.isRendering
        // Sync state periodically
        appState.syncFromEngine()
    }

    class Coordinator: NSObject {
        let appState: AppState
        var renderCoordinator: MetalRenderCoordinator?
        private var lastPanTranslation = CGPoint.zero
        private var lastScale: CGFloat = 1.0

        init(appState: AppState) {
            self.appState = appState
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                lastScale = 1.0
            case .changed:
                let delta = gesture.scale - lastScale
                lastScale = gesture.scale
                appState.engine.zoom(byMagnification: Double(delta))
                appState.syncFromEngine()
            default: break
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                lastPanTranslation = .zero
            case .changed:
                let dx = translation.x - lastPanTranslation.x
                let dy = translation.y - lastPanTranslation.y
                lastPanTranslation = translation
                appState.engine.pan(byDx: Double(dx), dy: Double(dy))
            default: break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let location = gesture.location(in: gesture.view)
            // Scale for retina
            let scale = gesture.view?.contentScaleFactor ?? 2.0
            appState.engine.tap(atScreenX: Double(location.x * scale),
                               y: Double(location.y * scale))
            appState.syncFromEngine()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            // Double-tap: toggle zoom level
            let zoom = appState.engine.zoom
            if zoom > 80 {
                appState.engine.zoom(byMagnification: -0.7)  // zoom out
            } else {
                appState.engine.zoom(byMagnification: 2.0)  // zoom in
            }
            appState.syncFromEngine()
        }
    }
}
