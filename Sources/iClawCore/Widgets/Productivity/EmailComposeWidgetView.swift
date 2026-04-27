import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Widget Data

/// Data for the email compose preview widget.
public struct EmailComposeWidgetData: Sendable {
    public let recipient: String?
    public let subject: String
    public let body: String
    /// Pre-built mailto URL for the "Open in Mail" button.
    public let mailtoURL: URL?

    public init(recipient: String? = nil, subject: String, body: String, mailtoURL: URL? = nil) {
        self.recipient = recipient
        self.subject = subject
        self.body = body
        self.mailtoURL = mailtoURL
    }
}

// MARK: - Widget View

struct EmailComposeWidgetView: View {
    let data: EmailComposeWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(data.subject)
                        .font(.headline)
                        .lineLimit(2)
                    if let to = data.recipient, !to.isEmpty {
                        Text(String(format: String(localized: "To: %@", bundle: .iClawCore), to))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            // Body preview
            Text(data.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)

            // Actions
            HStack(spacing: 10) {
                if let url = data.mailtoURL {
                    Button {
                        #if canImport(AppKit)
                        NSWorkspace.shared.open(url)
                        #endif
                    } label: {
                        Label(String(localized: "Open in Mail", bundle: .iClawCore), systemImage: "envelope.arrow.triangle.branch")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)
                }

                Button {
                    let text = [
                        data.recipient.map { "To: \($0)" },
                        "Subject: \(data.subject)",
                        "",
                        data.body,
                    ].compactMap { $0 }.joined(separator: "\n")
                    ClipboardHelper.copy(text)
                } label: {
                    Label(String(localized: "Copy", bundle: .iClawCore), systemImage: "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .glassContainer(hasShadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Email draft: \(data.subject)")
    }
}
