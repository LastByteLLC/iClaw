import SwiftUI

/// Data for the tool discovery tip card shown during greeting Phase 2.
/// When `settingsTab` is set, the action button opens Settings instead of pre-filling a query.
public struct ToolTipCardData: Sendable {
    public let toolName: String
    public let tipText: String
    public let exampleQuery: String
    public let icon: String
    /// If set, the "Try it" button opens this Settings tab instead of pre-filling a query.
    public let settingsTab: SettingsTab?

    public init(toolName: String, tipText: String, exampleQuery: String, icon: String, settingsTab: SettingsTab? = nil) {
        self.toolName = toolName
        self.tipText = tipText
        self.exampleQuery = exampleQuery
        self.icon = icon
        self.settingsTab = settingsTab
    }
}

/// A visually distinct tip card for tool discovery, shown during the greeting sequence.
/// Includes a "Try it" button that pre-fills the input field with an example query.
struct ToolTipCardView: View {
    let data: ToolTipCardData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                Text("Tip", bundle: .iClawCore)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            // Tip text
            Text(data.tipText)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Action button — opens Settings or pre-fills a query
            Button {
                if let tab = data.settingsTab {
                    SettingsNavigation.shared.openTab(tab)
                } else {
                    NotificationCenter.default.post(
                        name: .toolTipTryAction,
                        object: data.exampleQuery
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: data.settingsTab != nil ? "gearshape" : data.icon)
                        .symbolRenderingMode(.monochrome)
                        .font(.caption2)
                    Text(data.settingsTab != nil ? data.exampleQuery : String(localized: "Try: \"\(data.exampleQuery)\"", bundle: .iClawCore))
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: data.settingsTab != nil ? "arrow.up.right" : "arrow.right")
                        .font(.caption2)
                }
                .foregroundStyle(.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.yellow.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.yellow.opacity(0.15), lineWidth: 0.5)
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted by ToolTipCardView when the user taps "Try it". Object is the example query string.
    static let toolTipTryAction = Notification.Name("iClaw.toolTipTryAction")
}
