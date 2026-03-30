import SwiftUI
import MetalKit
import MapKit

extension Notification.Name {
    static let radarStationChanged = Notification.Name("radarStationChanged")
}

// Custom annotation for NEXRAD stations
class StationAnnotation: MKPointAnnotation {
    var stationIndex: Int = -1
    var icao: String = ""
    var isLoaded: Bool = false
}

struct RadarMapView: UIViewRepresentable {
    @EnvironmentObject var appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black

        // ── Base map (dark roads/boundaries) ──
        let mapView = MKMapView()
        mapView.overrideUserInterfaceStyle = .dark
        let config = MKStandardMapConfiguration(emphasisStyle: .muted)
        config.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = config
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.delegate = context.coordinator
        mapView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mapView)
        context.coordinator.mapView = mapView

        // Set initial region (CONUS center)
        let initialRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.0, longitude: -98.0),
            span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 70))
        mapView.setRegion(initialRegion, animated: false)

        // ── Radar overlay (transparent Metal view on top) ──
        let mtkView = MTKView()
        mtkView.device = appState.device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isOpaque = false
        mtkView.backgroundColor = .clear
        mtkView.layer.isOpaque = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.isUserInteractionEnabled = false
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mtkView)
        context.coordinator.mtkView = mtkView

        // Render coordinator
        let renderCoord = MetalRenderCoordinator(
            engine: appState.engine,
            device: appState.device,
            appState: appState)
        mtkView.delegate = renderCoord
        context.coordinator.renderCoordinator = renderCoord

        // Layout
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: container.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            mapView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: container.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            mtkView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Load station annotations after a short delay (engine needs to init first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            context.coordinator.loadStationAnnotations()
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.renderCoordinator?.isRendering = appState.isRendering
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        let appState: AppState
        var renderCoordinator: MetalRenderCoordinator?
        var mapView: MKMapView?
        var mtkView: MTKView?
        private var isSyncingFromEngine = false
        private var stationAnnotations: [StationAnnotation] = []
        private var annotationsLoaded = false

        init(appState: AppState) {
            self.appState = appState
            super.init()
            NotificationCenter.default.addObserver(self,
                selector: #selector(handleStationChanged),
                name: .radarStationChanged, object: nil)
        }

        @objc func handleStationChanged() {
            syncMapFromEngine()
            refreshAnnotationViews()
        }

        func loadStationAnnotations() {
            guard let mapView = mapView, !annotationsLoaded else { return }
            let stations = appState.engine.stationList()
            guard !stations.isEmpty else {
                // Retry if stations not loaded yet
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.loadStationAnnotations()
                }
                return
            }

            var annotations: [StationAnnotation] = []
            for st in stations {
                let ann = StationAnnotation()
                ann.coordinate = CLLocationCoordinate2D(latitude: Double(st.lat), longitude: Double(st.lon))
                ann.title = st.icao
                ann.stationIndex = Int(st.index)
                ann.icao = st.icao ?? ""
                annotations.append(ann)
            }

            mapView.addAnnotations(annotations)
            stationAnnotations = annotations
            annotationsLoaded = true
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let station = annotation as? StationAnnotation else { return nil }

            let id = "station"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)

            view.annotation = annotation
            view.canShowCallout = false

            // Small radar icon dot
            let size: CGFloat = 10
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            let isActive = station.stationIndex == Int(appState.engine.activeStationIndex)
            view.image = renderer.image { ctx in
                let color = isActive ? UIColor.white : UIColor(white: 0.6, alpha: 0.8)
                color.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            view.centerOffset = CGPoint(x: 0, y: 0)

            // ICAO label below the dot
            view.subviews.forEach { if $0.tag == 99 { $0.removeFromSuperview() } }
            let label = UILabel()
            label.tag = 99
            label.text = station.icao
            label.font = .monospacedSystemFont(ofSize: isActive ? 10 : 8, weight: isActive ? .bold : .medium)
            label.textColor = isActive ? .white : UIColor(white: 0.65, alpha: 1)
            label.textAlignment = .center
            label.sizeToFit()
            label.center = CGPoint(x: size / 2, y: size + label.bounds.height / 2 + 1)
            view.addSubview(label)
            view.frame = CGRect(x: 0, y: 0, width: max(size, label.bounds.width), height: size + label.bounds.height + 2)

            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let station = annotation as? StationAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)

            // Select this station in the engine
            appState.engine.selectStation(Int32(station.stationIndex), centerView: false)
            appState.syncFromEngine()

            // Refresh annotation views to update active state
            refreshAnnotationViews()
        }

        private func refreshAnnotationViews() {
            guard let mapView = mapView else { return }
            // Remove and re-add to force view refresh
            let anns = stationAnnotations
            mapView.removeAnnotations(anns)
            mapView.addAnnotations(anns)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            guard !isSyncingFromEngine else { return }
            syncEngineFromMap(mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isSyncingFromEngine else { return }
            syncEngineFromMap(mapView)
        }

        private func syncEngineFromMap(_ mapView: MKMapView) {
            let region = mapView.region
            let scale = Double(mapView.traitCollection.displayScale)
            let pixelWidth = Double(mapView.bounds.width) * scale
            let zoom = pixelWidth / region.span.longitudeDelta

            appState.engine.setViewportCenter(region.center.latitude,
                                               lon: region.center.longitude,
                                               zoom: zoom)
        }

        func syncMapFromEngine() {
            guard let mapView = mapView else { return }
            let lat = appState.engine.centerLat
            let lon = appState.engine.centerLon
            let zoom = appState.engine.zoom
            let scale = Double(mapView.traitCollection.displayScale)
            let pixelWidth = Double(mapView.bounds.width) * scale
            let lonSpan = pixelWidth / zoom
            let pixelHeight = Double(mapView.bounds.height) * scale
            let latSpan = pixelHeight / zoom

            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan))

            isSyncingFromEngine = true
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isSyncingFromEngine = false
            }
        }
    }
}
