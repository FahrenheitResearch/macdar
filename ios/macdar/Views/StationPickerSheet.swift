import SwiftUI

struct StationPickerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""

    var stations: [RadarStationInfo] {
        let all = appState.engine.stationList() as? [RadarStationInfo] ?? []
        if searchText.isEmpty { return all }
        return all.filter {
            $0.icao.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(stations, id: \.index) { station in
                Button(action: {
                    appState.engine.selectStation(station.index, centerView: true)
                    appState.syncFromEngine()
                    NotificationCenter.default.post(name: .radarStationChanged, object: nil)
                    dismiss()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.icao)
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                            Text(String(format: "%.2f, %.2f", station.lat, station.lon))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if station.loaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else if station.downloading {
                            ProgressView()
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search stations...")
            .navigationTitle("Stations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
