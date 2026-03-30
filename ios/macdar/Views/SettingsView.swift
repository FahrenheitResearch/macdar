import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var multiRadar = false
    @State private var maxStations: Double = 1
    @State private var dbzThreshold: Float = 5.0

    var body: some View {
        NavigationStack {
            Form {
                Section("Radar Mode") {
                    Toggle("Multi-Radar Mosaic", isOn: $multiRadar)
                        .onChange(of: multiRadar) { _, val in
                            appState.mosaicMode = val
                            appState.engine.mosaicMode = val
                        }

                    if multiRadar {
                        VStack(alignment: .leading) {
                            Text("Max Active Stations: \(Int(maxStations))")
                                .font(.subheadline)
                            Slider(value: $maxStations, in: 2...10, step: 1)
                                .onChange(of: maxStations) { _, val in
                                    appState.maxActiveStations = Int(val)
                                    appState.engine.maxActiveStations = Int32(val)
                                }
                        }
                    }
                }

                Section("Display") {
                    VStack(alignment: .leading) {
                        Text("Min dBZ Threshold: \(Int(dbzThreshold))")
                            .font(.subheadline)
                        Slider(value: $dbzThreshold, in: -30...50, step: 1)
                            .onChange(of: dbzThreshold) { _, val in
                                appState.engine.dbzThreshold = val
                            }
                    }
                }

                Section("Storm-Relative Velocity") {
                    Toggle("SRV Mode", isOn: Binding(
                        get: { appState.engine.srvMode },
                        set: { appState.engine.srvMode = $0 }
                    ))
                }

                Section("Data") {
                    Button("Refresh All Stations") {
                        appState.engine.refreshData()
                    }

                    HStack {
                        Text("Stations Loaded")
                        Spacer()
                        Text("\(appState.stationsLoaded) / \(appState.engine.stationsTotal)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("macdar")
                        Spacer()
                        Text("v1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("Metal-native NEXRAD radar for iOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                multiRadar = appState.mosaicMode
                maxStations = Double(appState.maxActiveStations)
                dbzThreshold = appState.engine.dbzThreshold
            }
        }
    }
}
