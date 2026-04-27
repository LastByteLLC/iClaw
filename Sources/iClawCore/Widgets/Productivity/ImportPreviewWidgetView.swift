#if os(macOS)
import SwiftUI
@preconcurrency import EventKit
@preconcurrency import Contacts
import AppKit

struct ImportPreviewWidgetView: View {
    let data: ImportPreviewWidgetData
    @Environment(\.dismissWidget) private var dismissWidget
    @State private var saveError: String?

    var body: some View {
        switch data {
        case .event(let eventData):
            eventPreview(eventData)
        case .contact(let contactData):
            contactPreview(contactData)
        }
    }

    // MARK: - Event Preview

    @ViewBuilder
    private func eventPreview(_ event: CalendarImportData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar.badge.plus")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .font(.title3)
                Text(event.title)
                    .font(.system(.headline, design: .rounded))
                Spacer()
            }

            if let start = event.startDate {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatDateRange(start: start, end: event.endDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let location = event.location {
                HStack(spacing: 6) {
                    Image(systemName: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let desc = event.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await addToCalendar(event) }
                } label: {
                    Label("Add to Calendar", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())

                Button {
                    dismissWidget?()
                } label: {
                    Text("Cancel")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.1))
                .clipShape(Capsule())
            }
        }
        .padding()
        .frame(minWidth: 200)
        .glassContainer(cornerRadius: 20)
    }

    // MARK: - Contact Preview

    @ViewBuilder
    private func contactPreview(_ contact: ContactImportData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.crop.circle.badge.plus")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .font(.title3)
                Text(contact.name)
                    .font(.system(.headline, design: .rounded))
                Spacer()
            }

            if let org = contact.organization {
                HStack(spacing: 6) {
                    Image(systemName: "building.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(org)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !contact.phones.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "phone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(contact.phones.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !contact.emails.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "envelope")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(contact.emails.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button {
                    addToContacts(contact)
                } label: {
                    Label("Add to Contacts", systemImage: "plus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())

                Button {
                    dismissWidget?()
                } label: {
                    Text("Cancel")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.secondary.opacity(0.1))
                .clipShape(Capsule())
            }
        }
        .padding()
        .frame(minWidth: 200)
        .glassContainer(cornerRadius: 20)
    }

    // MARK: - Actions

    private func addToCalendar(_ event: CalendarImportData) async {
        #if MAS_BUILD
        // MAS: Open .ics file with system default handler (Calendar.app)
        NSWorkspace.shared.open(event.fileURL)
        #else
        // DMG: Direct import via EKEventStore
        let store = EKEventStore()
        let granted = try? await store.requestFullAccessToEvents()
        guard granted == true else {
            NSWorkspace.shared.open(event.fileURL)
            return
        }
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.title
        ekEvent.startDate = event.startDate ?? Date()
        ekEvent.endDate = event.endDate ?? (event.startDate ?? Date()).addingTimeInterval(3600)
        ekEvent.location = event.location
        ekEvent.notes = event.description
        ekEvent.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(ekEvent, span: .thisEvent)
        } catch {
            saveError = String(format: String(localized: "Failed to save event: %@", bundle: .iClawCore), error.localizedDescription)
            return
        }
        #endif
        dismissWidget?()
    }

    private func addToContacts(_ contact: ContactImportData) {
        #if MAS_BUILD
        // MAS: Open .vcf file with system default handler (Contacts.app)
        NSWorkspace.shared.open(contact.fileURL)
        #else
        // DMG: Direct import via CNContactStore
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted else {
                DispatchQueue.main.async { NSWorkspace.shared.open(contact.fileURL) }
                return
            }
            guard let data = try? Data(contentsOf: contact.fileURL),
                  let cnContacts = try? CNContactVCardSerialization.contacts(with: data),
                  let cnContact = cnContacts.first else { return }

            guard let mutable = cnContact.mutableCopy() as? CNMutableContact else { return }
            let saveRequest = CNSaveRequest()
            saveRequest.add(mutable, toContainerWithIdentifier: nil)
            do {
                try store.execute(saveRequest)
            } catch {
                DispatchQueue.main.async { saveError = String(format: String(localized: "Failed to save contact: %@", bundle: .iClawCore), error.localizedDescription) }
                return
            }
        }
        #endif
        dismissWidget?()
    }

    // MARK: - Helpers

    private static let mediumDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let shortTimeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private func formatDateRange(start: Date, end: Date?) -> String {
        if let end {
            if Calendar.current.isDate(start, inSameDayAs: end) {
                return "\(Self.mediumDateTimeFormatter.string(from: start)) – \(Self.shortTimeOnlyFormatter.string(from: end))"
            }
            return "\(Self.mediumDateTimeFormatter.string(from: start)) – \(Self.mediumDateTimeFormatter.string(from: end))"
        }
        return Self.mediumDateTimeFormatter.string(from: start)
    }
}
#endif
