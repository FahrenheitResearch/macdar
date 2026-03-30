import SwiftUI

struct ProductPickerView: View {
    @EnvironmentObject var appState: AppState

    let products = [
        (0, "REF", "Reflectivity"),
        (1, "VEL", "Velocity"),
        (2, "SW", "Spectrum Width"),
        (3, "ZDR", "Diff. Reflectivity"),
        (4, "CC", "Correlation Coeff"),
        (5, "KDP", "Specific Diff Phase"),
        (6, "PHI", "Diff. Phase"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(products, id: \.0) { idx, short, _ in
                    Button(action: { appState.setProduct(idx) }) {
                        Text(short)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(appState.activeProduct == idx ? Color.blue : Color.clear)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                    .foregroundColor(appState.activeProduct == idx ? .white : .primary)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
