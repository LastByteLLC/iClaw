import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Widget Data

/// Data for the iMessage compose preview widget.
public struct MessageComposeWidgetData: Sendable {
    public let recipient: String
    public let message: String
    /// True if the message was sent successfully via AppleScript.
    public let isSent: Bool
    /// Fallback sms: URL for "Open in Messages" button when AppleScript fails.
    public let smsURL: URL?

    public init(recipient: String, message: String, isSent: Bool, smsURL: URL? = nil) {
        self.recipient = recipient
        self.message = message
        self.isSent = isSent
        self.smsURL = smsURL
    }
}

// MARK: - Widget View

struct MessageComposeWidgetView: View {
    let data: MessageComposeWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "message.fill")
                    .font(.title3)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(data.recipient)
                        .font(.headline)
                    if data.isSent {
                        Label(String(localized: "Sent", bundle: .iClawCore), systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 0)
            }

            // Message bubble
            Text(data.message)
                .font(.callout)
                .padding(10)
                .background(.blue.opacity(0.15))
                .clipShape(.rect(cornerRadius: 14))
                .lineLimit(6)

            // Actions (only when not sent)
            if !data.isSent {
                HStack(spacing: 10) {
                    if let url = data.smsURL {
                        Button {
                            #if canImport(AppKit)
                            NSWorkspace.shared.open(url)
                            #endif
                        } label: {
                            Label(String(localized: "Open in Messages", bundle: .iClawCore), systemImage: "message.badge.waveform")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.green)
                    }

                    Button {
                        ClipboardHelper.copy(data.message)
                    } label: {
                        Label(String(localized: "Copy", bundle: .iClawCore), systemImage: "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .glassContainer(hasShadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Message to \(data.recipient): \(data.message)")
    }
}
