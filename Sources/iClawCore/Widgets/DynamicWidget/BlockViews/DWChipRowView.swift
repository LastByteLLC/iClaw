import SwiftUI

struct DWChipRowView: View {
    let block: ChipRowBlock

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(block.chips.enumerated()), id: \.offset) { _, chip in
                    chipButton(chip)
                }
            }
        }
    }

    @ViewBuilder
    private func chipButton(_ chip: Chip) -> some View {
        let label = HStack(spacing: 4) {
            if let icon = chip.icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(chip.label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 12))
        .foregroundStyle(.primary)

        if let urlString = chip.url, let url = URL(string: urlString) {
            Button {
                URLOpener.open(url)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(chip.label))
            .accessibilityHint(Text(String(format: String(localized: "Opens %@", bundle: .iClawCore), urlString)))
        } else {
            label
        }
    }
}
