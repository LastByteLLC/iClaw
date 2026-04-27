import SwiftUI

/// Widget displaying a list of email summaries from Mail.app.
struct EmailListWidgetView: View {
    let data: ReadEmailTool.EmailListWidgetData

    var body: some View {
        if data.emails.isEmpty {
            Text("No emails")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .glassContainer(hasShadow: false)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: "envelope.fill")
                        .font(.caption) // SF Symbol sizing
                        .foregroundStyle(.secondary)
                    Text(headerTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: String(localized: "email_count", bundle: .iClawCore), data.emails.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()
                    .opacity(0.2)
                    .padding(.horizontal, 12)

                // Email list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(data.emails.prefix(10).enumerated()), id: \.offset) { index, email in
                        EmailRow(email: email)

                        if index < min(data.emails.count, 10) - 1 {
                            Divider()
                                .opacity(0.1)
                                .padding(.leading, 38)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .glassContainer(hasShadow: false)
            .frame(minWidth: 280, maxWidth: 380)
        }
    }

    private var headerTitle: String {
        switch data.intentLabel {
        case "Search":
            return String(format: String(localized: "email.header.search", bundle: .iClawCore), data.query ?? "")
        case "From":
            return String(format: String(localized: "email.header.from", bundle: .iClawCore), data.query ?? "")
        default:
            return data.intentLabel
        }
    }
}

// MARK: - Email Row

private struct EmailRow: View {
    let email: ReadEmailTool.EmailSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Unread indicator
            Circle()
                .fill(email.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(email.subject)
                    .font(.caption.weight(email.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(email.sender)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\u{00B7}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)

                    Text(email.date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !email.bodySnippet.isEmpty {
                    Text(email.bodySnippet)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(emailAccessibilityLabel))
    }

    private var emailAccessibilityLabel: String {
        var parts: [String] = []
        if !email.isRead { parts.append(String(localized: "Unread", bundle: .iClawCore)) }
        parts.append(email.subject)
        parts.append(email.sender)
        parts.append(email.date)
        if !email.bodySnippet.isEmpty { parts.append(email.bodySnippet) }
        return parts.joined(separator: ", ")
    }
}

#Preview("Email List Widget") {
    EmailListWidgetView(data: ReadEmailTool.EmailListWidgetData(
        emails: [
            ReadEmailTool.EmailSummary(subject: "Q1 Report Ready", sender: "Sarah Chen", date: "10:30 AM", bodySnippet: "Hi, the Q1 report is ready for your review. Key highlights include...", isRead: false),
            ReadEmailTool.EmailSummary(subject: "Lunch tomorrow?", sender: "Mike Johnson", date: "9:15 AM", bodySnippet: "Hey, are you free for lunch tomorrow? Thinking of trying that new place.", isRead: false),
            ReadEmailTool.EmailSummary(subject: "Re: Project Timeline", sender: "Alex Rivera", date: "Yesterday", bodySnippet: "Sounds good, let's plan for the Friday deadline.", isRead: true),
            ReadEmailTool.EmailSummary(subject: "Your order has shipped", sender: "Amazon", date: "Yesterday", bodySnippet: "Your package is on its way and will arrive by Thursday.", isRead: true),
        ],
        intentLabel: "Inbox"
    ))
    .padding()
    .frame(width: 360)
}
