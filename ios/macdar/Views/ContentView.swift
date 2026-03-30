import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showStationPicker = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            // Full-screen radar
            RadarMapView()
                .ignoresSafeArea()

            // Top controls
            VStack {
                HStack(spacing: 12) {
                    // Station name
                    Button(action: { showStationPicker = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(appState.activeStationName)
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }

                    Spacer()

                    // Stations loaded counter
                    Text("\(appState.stationsLoaded) sites")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())

                    // Settings
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Bottom controls
                VStack(spacing: 10) {
                    // Product picker
                    ProductPickerView()

                    // Tilt controls
                    if appState.maxTilts > 1 {
                        TiltControlView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showStationPicker) {
            StationPickerSheet()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}
