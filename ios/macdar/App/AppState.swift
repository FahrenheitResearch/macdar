import SwiftUI
import Metal

class AppState: ObservableObject {
    let engine = RadarEngine()
    let device: MTLDevice

    @Published var activeProduct: Int = 0
    @Published var activeTilt: Int = 0
    @Published var maxTilts: Int = 1
    @Published var tiltAngle: Float = 0.5
    @Published var stationsLoaded: Int = 0
    @Published var activeStationName: String = "—"
    @Published var productName: String = "REF"
    @Published var mosaicMode: Bool = false
    @Published var isRendering: Bool = true
    @Published var maxActiveStations: Int = 1

    // Product names
    let productNames = ["REF", "VEL", "SW", "ZDR", "CC", "KDP", "PHI"]

    init() {
        device = MTLCreateSystemDefaultDevice()!
    }

    func initialize(width: Int, height: Int) {
        engine.initialize(with: device, width: Int32(width), height: Int32(height))
    }

    func syncFromEngine() {
        activeProduct = Int(engine.activeProduct)
        activeTilt = Int(engine.activeTilt)
        maxTilts = Int(engine.maxTilts)
        tiltAngle = engine.activeTiltAngle
        stationsLoaded = Int(engine.stationsLoaded)
        activeStationName = engine.activeStationName ?? "—"
        productName = productNames[min(Int(engine.activeProduct), productNames.count - 1)]
        mosaicMode = engine.mosaicMode
    }

    func setProduct(_ p: Int) {
        engine.setProduct(Int32(p))
        syncFromEngine()
    }

    func setTilt(_ t: Int) {
        engine.setTilt(Int32(t))
        syncFromEngine()
    }

    func toggleMosaic() {
        mosaicMode.toggle()
        engine.mosaicMode = mosaicMode
    }

    private var hasLaunched = false

    func suspendRendering() {
        isRendering = false
    }

    func resumeRendering() {
        isRendering = true
        if hasLaunched {
            // Only refresh on actual resume from background, not initial launch
        }
        hasLaunched = true
    }
}
