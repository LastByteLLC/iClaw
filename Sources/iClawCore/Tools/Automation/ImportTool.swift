#if os(macOS)
import Foundation
import Contacts
import EventKit

/// Data for the import preview widget.
public enum ImportPreviewWidgetData: Sendable {
    case event(CalendarImportData)
    case contact(ContactImportData)
}

public struct CalendarImportData: Sendable {
    public let title: String
    public let startDate: Date?
    public let endDate: Date?
    public let location: String?
    public let description: String?
    public let fileURL: URL
}

public struct ContactImportData: Sendable {
    public let name: String
    public let phones: [String]
    public let emails: [String]
    public let organization: String?
    public let fileURL: URL
}

/// CoreTool that parses .ics and .vcf files and returns a preview widget.
/// DMG builds import directly; MAS builds open native system sheets.
public struct ImportTool: CoreTool, Sendable {
    public let name = "Import"
    public let schema = "import calendar event contact vcard ics vcf add"
    public let isInternal = true
    public let category = CategoryEnum.offline
    public var consentPolicy: ActionConsentPolicy {
        .requiresConsent(description: "Import to Calendar or Contacts")
    }

    // MARK: - Cached Date Formatters

    private static let mediumDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// ICS "yyyyMMdd'T'HHmmss'Z'" (UTC timestamp).
    private static let icsUTCFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// ICS "yyyyMMdd'T'HHmmss" (local timestamp).
    private static let icsLocalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()

    /// ICS "yyyyMMdd" (all-day event).
    private static let icsDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    public init() {}

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await timed {
            // Extract file path from input (first line)
            let lines = input.components(separatedBy: "\n")
            guard let firstLine = lines.first?.trimmingCharacters(in: .whitespaces),
                  (firstLine.hasPrefix("/") || firstLine.hasPrefix("~")) else {
                return ToolIO(text: "No file path found.", status: .error)
            }

            let url = URL(fileURLWithPath: firstLine)
            let ext = url.pathExtension.lowercased()

            switch ext {
            case "ics":
                return try parseICS(url: url)
            case "vcf", "vcard":
                return try parseVCard(url: url)
            default:
                return ToolIO(text: "Unsupported file type: .\(ext)", status: .error)
            }
        }
    }

    // MARK: - iCal Parsing

    private func parseICS(url: URL) throws -> ToolIO {
        let content = try String(contentsOf: url, encoding: .utf8)

        guard content.contains("BEGIN:VEVENT") else {
            return ToolIO(text: "No calendar event found in .ics file.", status: .error)
        }

        let summary = extractICSField(content, field: "SUMMARY")
        let location = extractICSField(content, field: "LOCATION")
        let description = extractICSField(content, field: "DESCRIPTION")
        let dtStart = parseICSDate(extractICSField(content, field: "DTSTART"))
        let dtEnd = parseICSDate(extractICSField(content, field: "DTEND"))

        let title = summary ?? "Untitled Event"
        let data = CalendarImportData(
            title: title,
            startDate: dtStart,
            endDate: dtEnd,
            location: location,
            description: description,
            fileURL: url
        )

        var textParts = ["Event: \(title)"]
        if let start = dtStart {
            textParts.append("Start: \(Self.mediumDateTimeFormatter.string(from: start))")
        }
        if let end = dtEnd {
            textParts.append("End: \(Self.mediumDateTimeFormatter.string(from: end))")
        }
        if let loc = location { textParts.append("Location: \(loc)") }

        return ToolIO(
            text: textParts.joined(separator: "\n"),
            status: .ok,
            outputWidget: "ImportPreviewWidget",
            widgetData: ImportPreviewWidgetData.event(data)
        )
    }

    private func extractICSField(_ content: String, field: String) -> String? {
        // Handle both "FIELD:value" and "FIELD;params:value" formats
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(field):") || trimmed.hasPrefix("\(field);") {
                if let colonIndex = trimmed.firstIndex(of: ":") {
                    let value = String(trimmed[trimmed.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : value
                }
            }
        }
        return nil
    }

    private func parseICSDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespaces)

        if let date = Self.icsUTCFormatter.date(from: cleaned) { return date }
        if let date = Self.icsLocalFormatter.date(from: cleaned) { return date }
        if let date = Self.icsDateOnlyFormatter.date(from: cleaned) { return date }

        return nil
    }

    // MARK: - vCard Parsing

    private func parseVCard(url: URL) throws -> ToolIO {
        let data = try Data(contentsOf: url)
        let contacts = try CNContactVCardSerialization.contacts(with: data)

        guard let contact = contacts.first else {
            return ToolIO(text: "No contact found in .vcf file.", status: .error)
        }

        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Unknown"
        let phones = contact.phoneNumbers.map { $0.value.stringValue }
        let emails = contact.emailAddresses.map { $0.value as String }
        let org = contact.organizationName.isEmpty ? nil : contact.organizationName

        let contactData = ContactImportData(
            name: name,
            phones: phones,
            emails: emails,
            organization: org,
            fileURL: url
        )

        var textParts = ["Contact: \(name)"]
        if let org { textParts.append("Organization: \(org)") }
        if !phones.isEmpty { textParts.append("Phone: \(phones.joined(separator: ", "))") }
        if !emails.isEmpty { textParts.append("Email: \(emails.joined(separator: ", "))") }

        return ToolIO(
            text: textParts.joined(separator: "\n"),
            status: .ok,
            outputWidget: "ImportPreviewWidget",
            widgetData: ImportPreviewWidgetData.contact(contactData)
        )
    }
}
#endif
