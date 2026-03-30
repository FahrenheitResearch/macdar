import SwiftUI

struct TiltControlView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            Button(action: { appState.setTilt(appState.activeTilt - 1) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .bold))
            }
            .disabled(appState.activeTilt <= 0)

            Text(String(format: "%.1f°", appState.tiltAngle))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .frame(minWidth: 50)

            Button(action: { appState.setTilt(appState.activeTilt + 1) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 16, weight: .bold))
            }
            .disabled(appState.activeTilt >= appState.maxTilts - 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }
}
