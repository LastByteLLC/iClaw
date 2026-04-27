import SwiftUI

struct DWKeyValueView: View {
    let block: KeyValueBlock
    @State private var expandedIndices: Set<Int> = []

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 0) {
            ForEach(Array(block.pairs.enumerated()), id: \.offset) { index, pair in
                GridRow {
                    Text(pair.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .lineLimit(1)

                    Text(pair.value)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(expandedIndices.contains(index) ? nil : 2)
                        .contentShape(.rect)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if expandedIndices.contains(index) {
                                    expandedIndices.remove(index)
                                } else {
                                    expandedIndices.insert(index)
                                }
                            }
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(expandedIndices.contains(index)
                            ? String(localized: "Double-tap to collapse", bundle: .iClawCore)
                            : String(localized: "Double-tap to expand", bundle: .iClawCore))
                }
                .padding(.vertical, 4)

                if index < block.pairs.count - 1 {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        Divider().opacity(0.08)
                    }
                }
            }
        }
    }
}
