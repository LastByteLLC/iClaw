import Foundation
import EventKit

// MARK: - Extraction Args

public struct CalendarEventArgs: ToolArguments {
    public let action: String       // "list", "add", "edit", "delete"
    public let title: String?
    public let days: Int?
    public let newTitle: String?
    public let newStartDate: String?
    public let startDate: String?
    public let eventIdentifier: String?
}

// MARK: - CalendarEventTool (CoreTool)

/// Manages calendar events via EventKit. Returns a confirmation widget for "add"
/// and falls back to .ics file generation if the user denies calendar permission.
public struct CalendarEventTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "CalendarEvent"
    public let schema = "Manage calendar events: 'create a meeting tomorrow at 10am', 'what's on my calendar', 'delete the 3pm meeting'."
    public let isInternal = false
    public let consentPolicy: ActionConsentPolicy = .requiresConsent(description: "Access your calendar")
    public let category = CategoryEnum.offline
    public let requiredPermission: PermissionManager.PermissionKind? = .calendar

    public init() {}

    // MARK: - ExtractableCoreTool

    public typealias Args = CalendarEventArgs
    public static let extractionSchema: String = loadExtractionSchema(
        named: "CalendarEvent",
        fallback: #"{"action":"list|add|edit|delete","title":"string?","days":"int?","startDate":"string?"}"#
    )

    // MARK: - Structured Execute

    public func execute(args: CalendarEventArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        return try await executeAction(
            action: args.action,
            title: args.title,
            days: args.days,
            newTitle: args.newTitle,
            newStartDate: args.newStartDate ?? args.startDate,
            eventIdentifier: args.eventIdentifier,
            rawInput: rawInput
        )
    }

    // MARK: - Raw Execute

    public func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        // Best-effort: treat as "list" for raw input
        return try await executeAction(action: "list", title: nil, days: nil, newTitle: nil, newStartDate: nil, eventIdentifier: nil, rawInput: input)
    }

    // MARK: - Core Logic

    private func executeAction(
        action: String, title: String?, days: Int?, newTitle: String?,
        newStartDate: String?, eventIdentifier: String?, rawInput: String
    ) async throws -> ToolIO {
        let store = EKEventStore()
        let hasAccess = await requestCalendarAccess(store: store)

        // For "add", if permission denied → fall back to .ics file with widget
        if action == "add" && !hasAccess {
            return buildICSFallback(title: title ?? "New Event", startDateStr: newStartDate, rawInput: rawInput)
        }

        guard hasAccess else {
            return ToolIO(text: "Calendar access not authorized. Grant permission in System Settings > Privacy & Security > Calendars.", status: .error)
        }

        switch action {
        case "add":
            return try addEvent(store: store, title: title, startDateStr: newStartDate, rawInput: rawInput)

        case "edit":
            guard let event = findEvent(store: store, identifier: eventIdentifier, title: title, days: days ?? 30) else {
                return ToolIO(text: "No matching event found.", status: .error)
            }
            if let t = newTitle { event.title = t }
            if let s = newStartDate, let date = ISO8601DateFormatter().date(from: s) {
                let duration = event.endDate.timeIntervalSince(event.startDate)
                event.startDate = date
                event.endDate = date.addingTimeInterval(duration)
            }
            try store.save(event, span: .thisEvent)
            return ToolIO(text: "Event updated: '\(event.title ?? "Untitled")'.", status: .ok, isVerifiedData: true)

        case "delete":
            guard let event = findEvent(store: store, identifier: eventIdentifier, title: title, days: days ?? 30) else {
                return ToolIO(text: "No matching event found.", status: .error)
            }
            let t = event.title ?? "Untitled"
            try store.remove(event, span: .thisEvent, commit: true)
            return ToolIO(text: "Event '\(t)' deleted.", status: .ok, isVerifiedData: true)

        default: // "list"
            let d = days ?? 7
            let now = Date()
            let end = Calendar.current.date(byAdding: .day, value: d, to: now)!
            let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
            let allEvents = store.events(matching: predicate)
            // `predicateForEvents` returns events that OVERLAP the range, so a
            // meeting that started before `now` but hasn't ended yet is
            // included. "Next meeting" semantics require events that START
            // after now — the currently in-progress event is surfaced
            // separately as `current`.
            let current = allEvents.first { $0.startDate <= now && $0.endDate > now }
            let upcoming = allEvents.filter { $0.startDate > now }.prefix(10)

            if upcoming.isEmpty && current == nil {
                return ToolIO(text: "No events in the next \(d) days.", status: .ok, isVerifiedData: true)
            }

            var lines: [String] = []
            if let c = current {
                lines.append("[\(c.eventIdentifier ?? "?")] (current) \(c.title ?? "Untitled") — started \(c.startDate.formatted(date: .abbreviated, time: .shortened))")
            }
            for e in upcoming {
                lines.append("[\(e.eventIdentifier ?? "?")] \(e.title ?? "Untitled") — \(e.startDate.formatted(date: .abbreviated, time: .shortened))")
            }

            // Render a widget for the next (or current) event so the HUD shows
            // a calendar card instead of bare text. Reuses the confirmation
            // widget (isConfirmed=true = read-only display).
            let featured = upcoming.first ?? current
            let widget: CalendarEventConfirmationData? = featured.map {
                CalendarEventConfirmationData(
                    title: $0.title ?? "Untitled",
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isConfirmed: true
                )
            }

            return ToolIO(
                text: "Upcoming events:\n" + lines.joined(separator: "\n"),
                status: .ok,
                outputWidget: widget != nil ? "CalendarEventConfirmationWidget" : nil,
                widgetData: widget,
                isVerifiedData: true
            )
        }
    }

    // MARK: - Add Event (with confirmation widget)

    private func addEvent(store: EKEventStore, title: String?, startDateStr: String?, rawInput: String) throws -> ToolIO {
        let eventTitle = title ?? "New Event"
        let startDate: Date
        if let s = startDateStr, let parsed = ISO8601DateFormatter().date(from: s) {
            startDate = parsed
        } else {
            startDate = Date().addingTimeInterval(3600)
        }
        let endDate = startDate.addingTimeInterval(3600)

        let event = EKEvent(eventStore: store)
        event.title = eventTitle
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)

        let widgetData = CalendarEventConfirmationData(
            title: eventTitle, startDate: startDate, endDate: endDate, isConfirmed: true
        )
        return ToolIO(
            text: "Event '\(eventTitle)' created for \(startDate.formatted()).",
            status: .ok,
            outputWidget: "CalendarEventConfirmationWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - ICS Fallback

    private func buildICSFallback(title: String, startDateStr: String?, rawInput: String) -> ToolIO {
        let startDate: Date
        if let s = startDateStr, let parsed = ISO8601DateFormatter().date(from: s) {
            startDate = parsed
        } else {
            startDate = Date().addingTimeInterval(3600)
        }
        let endDate = startDate.addingTimeInterval(3600)

        // Generate .ics file
        let ics = generateICS(title: title, start: startDate, end: endDate)
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = title.replacingOccurrences(of: " ", with: "_") + ".ics"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try ics.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return ToolIO(text: "Failed to create calendar file: \(error.localizedDescription)", status: .error)
        }

        let widgetData = CalendarEventConfirmationData(
            title: title, startDate: startDate, endDate: endDate, icsFileURL: fileURL, isConfirmed: false
        )
        return ToolIO(
            text: "Calendar permission not granted. Tap 'Add to Calendar' to open the event in Calendar.app.",
            status: .ok,
            outputWidget: "CalendarEventConfirmationWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    private func generateICS(title: String, start: Date, end: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let uid = UUID().uuidString

        return """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//iClaw//iClaw//EN
        BEGIN:VEVENT
        UID:\(uid)
        DTSTART:\(fmt.string(from: start))
        DTEND:\(fmt.string(from: end))
        SUMMARY:\(title)
        END:VEVENT
        END:VCALENDAR
        """
    }

    // MARK: - Permission

    private func requestCalendarAccess(store: EKEventStore) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return true }

        if status == .notDetermined {
            let _ = await PermissionManager.requestPermission(.calendar, toolName: "Calendar", reason: "to access your calendar events")
            do {
                return try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask { try await EKEventStore().requestFullAccessToEvents() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        throw CancellationError()
                    }
                    let result = try await group.next() ?? false
                    group.cancelAll()
                    return result
                }
            } catch {
                return false
            }
        }

        return false
    }

    // MARK: - Find Event

    private func findEvent(store: EKEventStore, identifier: String?, title: String?, days: Int) -> EKEvent? {
        if let id = identifier, let event = store.event(withIdentifier: id) {
            return event
        }
        guard let searchTitle = title else { return nil }
        let start = Date().addingTimeInterval(-86400)
        let end = Calendar.current.date(byAdding: .day, value: days, to: Date())!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).first {
            ($0.title ?? "").localizedCaseInsensitiveContains(searchTitle)
        }
    }
}
