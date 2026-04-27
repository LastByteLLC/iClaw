import Foundation
import EventKit

// MARK: - Extraction Args

public struct RemindersArgs: ToolArguments {
    public let action: String       // "add", "list", "complete", "edit", "delete"
    public let title: String?
    public let newTitle: String?
}

// MARK: - RemindersTool (CoreTool)

/// Manages reminders via EventKit. Shows confirmation widget for "add",
/// falls back to clipboard + Reminders.app on permission denial.
public struct RemindersTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Reminders"
    public let schema = "Manage reminders remind remember alert notify todo task list follow-up action items mark complete buy milk pick up groceries call mom"
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Modify reminders")
    public let requiredPermission: PermissionManager.PermissionKind? = .reminders

    public init() {}

    public typealias Args = RemindersArgs
    public static let extractionSchema: String = loadExtractionSchema(
        named: "Reminders", fallback: #"{"action":"add|list|complete|edit|delete","title":"string?"}"#
    )

    public func execute(args: RemindersArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        try await executeAction(action: args.action, title: args.title, newTitle: args.newTitle)
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        // Default: treat as "add" with the input as title
        try await executeAction(action: "add", title: input, newTitle: nil)
    }

    private func executeAction(action: String, title: String?, newTitle: String?) async throws -> ToolIO {
        let store = EKEventStore()
        let hasAccess = await requestRemindersAccess(store: store)

        // For "add", if permission denied → show fallback widget
        if action == "add" && !hasAccess {
            let t = title ?? "New Reminder"
            let widgetData = ReminderConfirmationData(title: t, isConfirmed: false)
            return ToolIO(
                text: "Reminders permission not granted. Use the button to open Reminders and add it manually.",
                status: .ok,
                outputWidget: "ReminderConfirmationWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }

        guard hasAccess else {
            return ToolIO(text: "Reminders access not authorized. Grant permission in System Settings > Privacy & Security > Reminders.", status: .error)
        }

        switch action {
        case "add":
            let reminder = EKReminder(eventStore: store)
            reminder.title = title ?? "New Reminder"
            reminder.calendar = store.defaultCalendarForNewReminders()
            try store.save(reminder, commit: true)
            let widgetData = ReminderConfirmationData(title: reminder.title!, isConfirmed: true)
            return ToolIO(
                text: "Reminder '\(reminder.title!)' added.",
                status: .ok,
                outputWidget: "ReminderConfirmationWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )

        case "list":
            let reminders = await fetchIncompleteReminders(store: store)
            if reminders.isEmpty { return ToolIO(text: "No incomplete reminders.", status: .ok, isVerifiedData: true) }
            let lines = reminders.prefix(15).enumerated().map { "\($0.offset + 1). \($0.element.title ?? "Untitled")" }
            return ToolIO(text: "Reminders:\n" + lines.joined(separator: "\n"), status: .ok, isVerifiedData: true)

        case "complete":
            guard let reminder = await findReminder(store: store, title: title) else {
                return ToolIO(text: "No matching reminder found.", status: .error)
            }
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
            return ToolIO(text: "Reminder '\(reminder.title ?? "")' marked complete.", status: .ok, isVerifiedData: true)

        case "edit":
            guard let reminder = await findReminder(store: store, title: title) else {
                return ToolIO(text: "No matching reminder found.", status: .error)
            }
            if let t = newTitle { reminder.title = t }
            try store.save(reminder, commit: true)
            return ToolIO(text: "Reminder updated to '\(reminder.title ?? "")'.", status: .ok, isVerifiedData: true)

        case "delete":
            guard let reminder = await findReminder(store: store, title: title) else {
                return ToolIO(text: "No matching reminder found.", status: .error)
            }
            let t = reminder.title ?? "Untitled"
            try store.remove(reminder, commit: true)
            return ToolIO(text: "Reminder '\(t)' deleted.", status: .ok, isVerifiedData: true)

        default:
            return ToolIO(text: "Unknown action '\(action)'. Use 'add', 'list', 'complete', 'edit', or 'delete'.", status: .error)
        }
    }

    // MARK: - Permission

    private func requestRemindersAccess(store: EKEventStore) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return true }
        if status == .notDetermined {
            let _ = await PermissionManager.requestPermission(.reminders, toolName: "Reminders", reason: "to manage your reminders")
            do {
                return try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask { try await EKEventStore().requestFullAccessToReminders() }
                    group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw CancellationError() }
                    let result = try await group.next() ?? false
                    group.cancelAll()
                    return result
                }
            } catch { return false }
        }
        return false
    }

    // MARK: - Helpers

    private func fetchIncompleteReminders(store: EKEventStore) async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                // EKReminder is not Sendable; the EventKit callback is the only
                // way to hand off the array into async. The continuation is
                // resumed exactly once per call, so there is no shared mutable
                // state to race on.
                nonisolated(unsafe) let result = reminders ?? []
                continuation.resume(returning: result)
            }
        }
    }

    private func findReminder(store: EKEventStore, title: String?) async -> EKReminder? {
        guard let searchTitle = title else { return nil }
        return await fetchIncompleteReminders(store: store).first {
            ($0.title ?? "").localizedCaseInsensitiveContains(searchTitle)
        }
    }
}
