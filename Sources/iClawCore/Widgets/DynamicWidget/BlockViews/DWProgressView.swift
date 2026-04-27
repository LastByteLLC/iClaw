import SwiftUI

struct DWProgressView: View {
    let block: ProgressBlock
    let tint: WidgetTint?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = block.label {
                HStack {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let total = block.total {
                        Text(total)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            ProgressView(value: min(max(block.value, 0), 1))
                .tint(accentColor)
        }
    }

    private var accentColor: Color {
        guard let tint else { return .accentColor }
        switch tint {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .purple: return .purple
        case .yellow: return .yellow
        case .mint: return .mint
        case .indigo: return .indigo
        case .teal: return .teal
        }
    }
}
