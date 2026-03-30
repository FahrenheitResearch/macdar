import SwiftUI

@main
struct macdarApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        appState.suspendRendering()
                    case .active:
                        appState.resumeRendering()
                    default: break
                    }
                }
        }
    }
}
