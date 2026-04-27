import SwiftUI

struct DWHeaderView: View {
    let block: HeaderBlock
    let tint: WidgetTint?
    @State private var isSubtitleExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(block.title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if let badge = block.badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(.rect(cornerRadius: 4))
                }
            }

            if let subtitle = block.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(isSubtitleExpanded ? nil : 2)
                    .contentShape(.rect)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSubtitleExpanded.toggle()
                        }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(isSubtitleExpanded
                        ? String(localized: "Double-tap to collapse", bundle: .iClawCore)
                        : String(localized: "Double-tap to expand", bundle: .iClawCore))
            }
        }
    }

    private var tintColor: Color {
        guard let tint else { return .primary }
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
