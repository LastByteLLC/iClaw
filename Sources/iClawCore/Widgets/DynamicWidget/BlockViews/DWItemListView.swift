import SwiftUI

struct DWItemListView: View {
    let block: ItemListBlock

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                itemRow(item)

                if index < block.items.count - 1 {
                    Divider().opacity(0.08)
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: ListItem) -> some View {
        let combinedLabel = [item.title, item.subtitle, item.trailing]
            .compactMap { $0 }
            .joined(separator: ", ")

        let content = HStack(spacing: 8) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let trailing = item.trailing {
                Text(trailing)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if item.url != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)

        if let urlString = item.url, let url = URL(string: urlString) {
            Button {
                URLOpener.open(url)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(combinedLabel))
            .accessibilityHint(Text(String(format: String(localized: "Opens %@", bundle: .iClawCore), urlString)))
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(combinedLabel))
        }
    }
}
