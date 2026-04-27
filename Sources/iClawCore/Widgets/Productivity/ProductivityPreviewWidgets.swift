import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Reminder Confirmation

/// Data for the reminder confirmation/fallback widget.
public struct ReminderConfirmationData: Sendable {
    public let title: String
    public let isConfirmed: Bool

    public init(title: String, isConfirmed: Bool) {
        self.title = title
        self.isConfirmed = isConfirmed
    }
}

struct ReminderConfirmationWidgetView: View {
    let data: ReminderConfirmationData

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: data.isConfirmed ? "checkmark.circle.fill" : "checklist")
                .font(.title2)
                .foregroundStyle(data.isConfirmed ? .green : .orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(data.title)
                    .font(.headline)
                    .lineLimit(2)

                if data.isConfirmed {
                    Text("Added to Reminders", bundle: .iClawCore)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            #if canImport(AppKit)
                            if let url = URL(string: "x-apple-reminderkit://") {
                                NSWorkspace.shared.open(url)
                            }
                            #endif
                        } label: {
                            Label(String(localized: "Open Reminders", bundle: .iClawCore), systemImage: "checklist")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)

                        Button {
                            ClipboardHelper.copy(data.title)
                        } label: {
                            Label(String(localized: "Copy", bundle: .iClawCore), systemImage: "doc.on.doc")
                                .font(.caption.weight(.medium))
                        }
                        .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassContainer(hasShadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reminder: \(data.title)")
    }
}

// MARK: - Note Confirmation

/// Data for the note creation confirmation/fallback widget.
public struct NoteConfirmationData: Sendable {
    public let title: String
    public let body: String
    public let isConfirmed: Bool

    public init(title: String, body: String, isConfirmed: Bool) {
        self.title = title
        self.body = body
        self.isConfirmed = isConfirmed
    }
}

struct NoteConfirmationWidgetView: View {
    let data: NoteConfirmationData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: data.isConfirmed ? "checkmark.circle.fill" : "note.text")
                    .font(.title3)
                    .foregroundStyle(data.isConfirmed ? .green : .yellow)

                Text(data.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            if !data.body.isEmpty {
                Text(data.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            if data.isConfirmed {
                Text("Saved to Notes", bundle: .iClawCore)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 8) {
                    Button {
                        // Copy content then open Notes for manual paste
                        let text = data.body.isEmpty ? data.title : "\(data.title)\n\n\(data.body)"
                        ClipboardHelper.copy(text)
                        #if canImport(AppKit)
                        if let url = URL(string: "mobilenotes://") {
                            NSWorkspace.shared.open(url)
                        }
                        #endif
                    } label: {
                        Label(String(localized: "Copy & Open Notes", bundle: .iClawCore), systemImage: "note.text.badge.plus")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.yellow)

                    Button {
                        let text = data.body.isEmpty ? data.title : "\(data.title)\n\n\(data.body)"
                        ClipboardHelper.copy(text)
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
        .accessibilityLabel("Note: \(data.title)")
    }
}

// MARK: - Contact Preview

/// Data for the contact creation preview/fallback widget.
public struct ContactPreviewData: Sendable {
    public let name: String
    public let phone: String?
    public let email: String?
    /// If non-nil, a .vcf file the user can open to import the contact.
    public let vcfFileURL: URL?
    public let isConfirmed: Bool

    public init(name: String, phone: String? = nil, email: String? = nil, vcfFileURL: URL? = nil, isConfirmed: Bool = false) {
        self.name = name
        self.phone = phone
        self.email = email
        self.vcfFileURL = vcfFileURL
        self.isConfirmed = isConfirmed
    }
}

struct ContactPreviewWidgetView: View {
    let data: ContactPreviewData

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 44, height: 44)
                Text(String(data.name.prefix(1)).uppercased())
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(data.name)
                    .font(.headline)

                if let phone = data.phone, !phone.isEmpty {
                    Label(phone, systemImage: "phone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let email = data.email, !email.isEmpty {
                    Label(email, systemImage: "envelope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if data.isConfirmed {
                    Text("Added to Contacts", bundle: .iClawCore)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.top, 2)
                } else {
                    HStack(spacing: 8) {
                        if let url = data.vcfFileURL {
                            Button {
                                #if canImport(AppKit)
                                NSWorkspace.shared.open(url)
                                #endif
                            } label: {
                                Label(String(localized: "Add to Contacts", bundle: .iClawCore), systemImage: "person.badge.plus")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.blue)
                        }

                        Button {
                            var text = data.name
                            if let p = data.phone { text += "\n\(p)" }
                            if let e = data.email { text += "\n\(e)" }
                            ClipboardHelper.copy(text)
                        } label: {
                            Label(String(localized: "Copy", bundle: .iClawCore), systemImage: "doc.on.doc")
                                .font(.caption.weight(.medium))
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassContainer(hasShadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Contact: \(data.name)")
    }
}
