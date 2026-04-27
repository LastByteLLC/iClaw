import SwiftUI

struct DWStatRowView: View {
    let block: StatRowBlock

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(block.items.enumerated()), id: \.offset) { index, stat in
                VStack(spacing: 2) {
                    Text(stat.value)
                        .font(.headline)
                        .fontDesign(.rounded)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    if let unit = stat.unit {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    if let label = stat.label {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(statAccessibilityLabel(stat)))

                if index < block.items.count - 1 {
                    Divider()
                        .frame(height: 32)
                        .opacity(0.15)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func statAccessibilityLabel(_ stat: StatBlock) -> String {
        var parts = [stat.value]
        if let unit = stat.unit { parts.append(unit) }
        if let label = stat.label { parts.append(label) }
        return parts.joined(separator: " ")
    }
}
