import Foundation
import NaturalLanguage
import os

/// Context-aware deterministic stubs replacing tools that would otherwise
/// hit EventKit, AppleScript, Mail.app, `NSWorkspace.open()`, or
/// `NSAlert.runModal()`. Fixtures live in `Resources/Config/StubFixtures.json`
/// so no hardcoded English is in Swift code.
///
/// Behavior goals:
///  * Same input → same output (replayable).
///  * Queries that mention a contact name / email / subject surface that
///    record in the response — so an autonomous test harness can verify
///    extraction, routing, and recall accuracy.
///  * Failure modes (contact not found, empty recipient) are signaled so
///    error handling can be exercised.
public enum HeadlessStubs {

    // MARK: - Fixtures

    private struct Fixtures: Decodable {
        let contacts: [ContactRecord]
        let emails: [EmailRecord]
        let notes: [NoteRecord]
        let calendar_events: [CalendarRecord]
    }

    struct ContactRecord: Decodable, Sendable {
        let name: String
        let phone: String
        let email: String
        let relationship: String
    }

    struct EmailRecord: Decodable, Sendable {
        let from: String
        let subject: String
        let date_offset_hours: Int
        let snippet: String
    }

    struct NoteRecord: Decodable, Sendable {
        let title: String
        let body: String
    }

    struct CalendarRecord: Decodable, Sendable {
        let title: String
        let hours_from_now: Int
        let duration_min: Int
        let attendees: [String]
    }

    private static let fixtures: Fixtures = {
        if let f: Fixtures = ConfigLoader.load("StubFixtures", as: Fixtures.self) {
            return f
        }
        return Fixtures(contacts: [], emails: [], notes: [], calendar_events: [])
    }()

    // MARK: - Install

    @MainActor
    public static func install() {
        guard ToolRegistry.headlessMode else { return }

        var stubs: [String: any CoreTool] = [:]

        stubs["Contacts"] = ContactsStub()
        stubs["Messages"] = MessagesStub()
        stubs["Email"]    = EmailStub()
        stubs["Notes"]    = NotesStub()
        stubs["ReadEmail"] = ReadEmailStub()
        stubs["Reminders"] = RemindersStub()
        stubs["CalendarEvent"] = CalendarEventStub()
        stubs["Maps"]     = MapsStub()
        stubs["Automate"] = AutomateStub()
        stubs["Automation"] = AutomationStub()

        ToolRegistry.setStubTools(stubs)
        Log.engine.info("HeadlessStubs installed with \(stubs.count) context-aware stub(s)")
    }

    // MARK: - NER helpers

    /// Extract the first personal-name span from the input via NLTagger.
    /// Empty when no name is found. Language-independent via NLTagger.
    static func extractPersonName(_ input: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = input
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        var found: String?
        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            if tag == .personalName, found == nil {
                found = String(input[range])
            }
            return true
        }
        return found
    }

    /// Match a query against the fixture contacts list by substring (lower-
    /// case, word-boundary tolerant). Returns the first match or nil.
    static func findContact(matching query: String) -> ContactRecord? {
        let q = query.lowercased()
        // Try NER-extracted name first
        if let ner = extractPersonName(query)?.lowercased() {
            if let hit = fixtures.contacts.first(where: { $0.name.lowercased().contains(ner) }) {
                return hit
            }
        }
        // Fall back: any contact whose name or email matches any token
        let tokens = q.components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 3 }
        for contact in fixtures.contacts {
            let nameLower = contact.name.lowercased()
            let emailLower = contact.email.lowercased()
            for t in tokens {
                if nameLower.contains(t) || emailLower.contains(t) {
                    return contact
                }
            }
        }
        return nil
    }

    /// Seeded pick when no match: same input → same contact
    static func deterministicContact(for query: String) -> ContactRecord {
        let hash = query.lowercased().utf8.reduce(UInt64(0xcbf29ce484222325)) { h, b in
            (h ^ UInt64(b)) &* 0x100000001b3
        }
        // UInt64 → Int64 can overflow when the top bit is set. Stay in
        // unsigned arithmetic for the modulo, then narrow-convert. The
        // result is guaranteed to fit since it's < count (≤ Int.max).
        let bucket = UInt64(max(fixtures.contacts.count, 1))
        let idx = Int(hash % bucket)
        return fixtures.contacts[idx]
    }

    // MARK: - Date helper

    static func formatRelative(hoursFromNow: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: Date().addingTimeInterval(TimeInterval(hoursFromNow * 3600)))
    }
}

// MARK: - Individual stubs

struct ContactsStub: CoreTool, Sendable {
    let name = "Contacts"
    let schema = "Look up contact address book phone number email relationship person name information lookup"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .safe
    let requiredPermission: PermissionManager.PermissionKind? = .contacts

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        if let contact = HeadlessStubs.findContact(matching: input) {
            return ToolIO(
                text: "\(contact.name) — \(contact.phone) — \(contact.email) (\(contact.relationship))",
                status: .ok,
                outputWidget: "ContactCardWidget",
                isVerifiedData: true
            )
        }
        return ToolIO(
            text: "No contact found matching your query. (\(HeadlessStubs.stubbedMarker))",
            status: .ok,
            isVerifiedData: true
        )
    }
}

struct MessagesStub: CoreTool, Sendable {
    let name = "Messages"
    let schema = "Send a message to a contact via iMessage or SMS"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .requiresConsent(description: "Send a message")
    let requiredPermission: PermissionManager.PermissionKind? = nil

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let contact = HeadlessStubs.findContact(matching: input)
            ?? HeadlessStubs.deterministicContact(for: input)
        let body = extractMessageBody(input, recipientName: contact.name)
        return ToolIO(
            text: "Message drafted to \(contact.name) (\(contact.phone)): \"\(body)\" \(HeadlessStubs.stubbedMarker)",
            status: .ok,
            outputWidget: "MessageComposeWidget",
            isVerifiedData: true
        )
    }

    /// Strip the recipient name from the input; what remains is the body.
    /// Uses NLTagger to find the name span, then removes it plus common
    /// prepositions/commands adjacent to it, deterministically and language-
    /// agnostically.
    private func extractMessageBody(_ input: String, recipientName: String) -> String {
        var body = input
        // Remove the resolved recipient name (full or first token)
        let first = recipientName.components(separatedBy: " ").first ?? recipientName
        for name in [recipientName, first] {
            if let r = body.range(of: name, options: [.caseInsensitive]) {
                body.removeSubrange(r)
            }
        }
        // Strip leading action verb + prepositions via NLTagger lexical class
        // to keep this language-agnostic. Fallback: trim punctuation.
        body = body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        // Collapse multiple spaces
        body = body.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return body.isEmpty ? "(empty body)" : body
    }
}

struct EmailStub: CoreTool, Sendable {
    let name = "Email"
    let schema = "Compose or send an email"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .requiresConsent(description: "Send an email")
    let requiredPermission: PermissionManager.PermissionKind? = nil

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let contact = HeadlessStubs.findContact(matching: input)
            ?? HeadlessStubs.deterministicContact(for: input)
        return ToolIO(
            text: "Email drafted to \(contact.name) <\(contact.email)>. Subject: \"\(inferSubject(input))\". \(HeadlessStubs.stubbedMarker)",
            status: .ok,
            outputWidget: "EmailComposeWidget",
            isVerifiedData: true
        )
    }

    private func inferSubject(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(60))
    }
}

struct ReadEmailStub: CoreTool, Sendable {
    let name = "ReadEmail"
    let schema = "Read recent emails from inbox"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .safe
    let requiredPermission: PermissionManager.PermissionKind? = nil

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        // If the query mentions a sender name, filter by that
        let filter = HeadlessStubs.findContact(matching: input)?.name
        let emails = HeadlessStubs.fixturesEmails(filterByFrom: filter)
        guard !emails.isEmpty else {
            return ToolIO(
                text: filter.map { "No recent emails from \($0)." } ?? "Inbox is empty.",
                status: .ok, isVerifiedData: true
            )
        }
        var lines = ["Recent emails:"]
        for (i, e) in emails.prefix(5).enumerated() {
            let when = HeadlessStubs.formatRelative(hoursFromNow: e.date_offset_hours)
            lines.append("\(i + 1). \(e.from) — \"\(e.subject)\" (\(when))")
            lines.append("   \(e.snippet)")
        }
        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "EmailListWidget",
            isVerifiedData: true
        )
    }
}

struct NotesStub: CoreTool, Sendable {
    let name = "Notes"
    let schema = "Create search list notes memo journal personal entries jot write down create add append find recall"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .requiresConsent(description: "Modify notes")
    let requiredPermission: PermissionManager.PermissionKind? = nil

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let lower = input.lowercased()
        // Retrieval shapes: "find my note about X", "show notes"
        let notes = HeadlessStubs.fixturesNotes()
        let isListing = lower.contains("list") || lower.contains("show")
            || lower.contains("find") || lower.contains("search")
            || lower.contains("all notes")
        if isListing {
            let tokens = lower.components(separatedBy: .alphanumerics.inverted).filter { $0.count >= 4 }
            let filtered = notes.filter { note in
                let hay = (note.title + " " + note.body).lowercased()
                return tokens.isEmpty || tokens.contains(where: { hay.contains($0) })
            }
            let hits = filtered.isEmpty ? Array(notes.prefix(3)) : filtered
            var lines = ["Notes:"]
            for n in hits.prefix(3) { lines.append("- \(n.title): \(n.body)") }
            return ToolIO(
                text: lines.joined(separator: "\n"),
                status: .ok,
                outputWidget: "NoteListWidget",
                isVerifiedData: true
            )
        }
        // Otherwise treat as a "create" intent
        return ToolIO(
            text: "Note saved: \"\(String(input.prefix(120)))\" \(HeadlessStubs.stubbedMarker)",
            status: .ok,
            outputWidget: "NoteConfirmationWidget",
            isVerifiedData: true
        )
    }
}

struct RemindersStub: CoreTool, Sendable {
    let name = "Reminders"
    let schema = "Create or modify reminders"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .requiresConsent(description: "Modify reminders")
    let requiredPermission: PermissionManager.PermissionKind? = .reminders

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        ToolIO(
            text: "Reminder scheduled: \"\(String(input.prefix(120)))\" \(HeadlessStubs.stubbedMarker)",
            status: .ok,
            outputWidget: "ReminderConfirmationWidget",
            isVerifiedData: true
        )
    }
}

struct CalendarEventStub: CoreTool, Sendable {
    let name = "CalendarEvent"
    let schema = "Manage calendar events — create list edit"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .requiresConsent(description: "Access your calendar")
    let requiredPermission: PermissionManager.PermissionKind? = .calendar

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let lower = input.lowercased()
        let events = HeadlessStubs.fixturesCalendarEvents()
        let isListing = lower.contains("what") || lower.contains("list")
            || lower.contains("show") || lower.contains("any")
            || lower.contains("my calendar") || lower.contains("meetings") || lower.contains("events")
        if isListing {
            var lines = ["Upcoming events:"]
            for e in events.prefix(4) {
                let when = HeadlessStubs.formatRelative(hoursFromNow: e.hours_from_now)
                let who = e.attendees.isEmpty ? "" : " with " + e.attendees.joined(separator: ", ")
                lines.append("- \(e.title)\(who) — \(when) (\(e.duration_min)m)")
            }
            return ToolIO(
                text: lines.joined(separator: "\n"),
                status: .ok,
                outputWidget: "CalendarListWidget",
                isVerifiedData: true
            )
        }
        return ToolIO(
            text: "Event scheduled: \"\(String(input.prefix(120)))\" \(HeadlessStubs.stubbedMarker)",
            status: .ok,
            outputWidget: "CalendarEventConfirmationWidget",
            isVerifiedData: true
        )
    }
}

struct MapsStub: CoreTool, Sendable {
    let name = "Maps"
    let schema = "Directions or nearby places"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .safe
    let requiredPermission: PermissionManager.PermissionKind? = .location

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        // Hash input to a stable distance/time pair
        let hash = input.lowercased().utf8.reduce(0) { $0 &+ Int($1) }
        let distances = [("2.1 mi", "7 min"), ("5.8 mi", "14 min"), ("11.3 mi", "28 min"), ("0.8 mi", "4 min")]
        let (d, t) = distances[hash % distances.count]
        return ToolIO(
            text: "Route: \(d), ~\(t) by car.",
            status: .ok,
            outputWidget: "DirectionsWidget",
            isVerifiedData: true
        )
    }
}

struct AutomateStub: CoreTool, Sendable {
    let name = "Automate"
    let schema = "Run an AppleScript automation"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .destructive(description: "Generate and run AppleScript")
    let requiredPermission: PermissionManager.PermissionKind? = nil

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        ToolIO(
            text: "Automation dry-run prepared. \(HeadlessStubs.stubbedMarker)",
            status: .ok, isVerifiedData: true
        )
    }
}

struct AutomationStub: CoreTool, Sendable {
    let name = "Automation"
    let schema = "Schedule a recurring automation"
    let isInternal = false
    let category = CategoryEnum.offline
    let consentPolicy: ActionConsentPolicy = .requiresConsent(description: "Manage scheduled automations")
    let requiredPermission: PermissionManager.PermissionKind? = nil

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        ToolIO(
            text: "Automation queued. \(HeadlessStubs.stubbedMarker)",
            status: .ok, isVerifiedData: true
        )
    }
}

extension HeadlessStubs {
    /// Suffix used by stubs to signal headless-mode-only execution to test
    /// harnesses. User-visible on purpose so judge passes can detect the
    /// difference between real and stubbed data in telemetry.
    static let stubbedMarker = "[stubbed]"

    static func fixturesEmails(filterByFrom: String?) -> [EmailRecord] {
        let all = fixtures.emails
        guard let filter = filterByFrom else { return all }
        return all.filter { $0.from.lowercased().contains(filter.lowercased()) }
    }

    static func fixturesNotes() -> [NoteRecord] { fixtures.notes }

    static func fixturesCalendarEvents() -> [CalendarRecord] { fixtures.calendar_events }
}
