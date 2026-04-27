import EventKit

/// Shared EventKit permission request with timeout.
///
/// Both `RemindersTool` and `CalendarEventTool` need to request EventKit access
/// with a timeout guard (headless/CLI mode hangs without one). This helper
/// centralises that pattern.
public enum EventKitPermissionHelper {
    /// Requests access to the specified entity type with a 5-second timeout.
    /// Throws ``EventKitPermissionError`` if permission is denied or times out.
    public static func requestAccess(to entityType: EKEntityType, store: EKEventStore) async throws {
        let status = EKEventStore.authorizationStatus(for: entityType)

        if status == .notDetermined {
            let (toolName, reason, settingsArea): (String, String, String) = switch entityType {
            case .event:
                ("Calendar", "to access your calendar events", "Calendars")
            case .reminder:
                ("Reminders", "to manage your reminders", "Reminders")
            @unknown default:
                ("EventKit", "to access your data", "Privacy")
            }

            let _ = await PermissionManager.requestPermission(
                entityType == .event ? .calendar : .reminders,
                toolName: toolName,
                reason: reason
            )

            let granted: Bool
            do {
                granted = try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        switch entityType {
                        case .event:
                            try await EKEventStore().requestFullAccessToEvents()
                        case .reminder:
                            try await EKEventStore().requestFullAccessToReminders()
                        @unknown default:
                            false
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        throw CancellationError()
                    }
                    let result = try await group.next() ?? false
                    group.cancelAll()
                    return result
                }
            } catch {
                granted = false
            }

            if !granted {
                throw EventKitPermissionError.notGranted(settingsArea: settingsArea)
            }
        } else if status != .fullAccess {
            let settingsArea = entityType == .event ? "Calendars" : "Reminders"
            throw EventKitPermissionError.notAuthorized(settingsArea: settingsArea)
        }
    }
}

/// Errors thrown by ``EventKitPermissionHelper``.
public enum EventKitPermissionError: Error, LocalizedError {
    case notGranted(settingsArea: String)
    case notAuthorized(settingsArea: String)

    public var errorDescription: String? {
        switch self {
        case .notGranted(let area):
            "\(area) access not granted. If running headless, grant permission in System Settings > Privacy & Security > \(area) first."
        case .notAuthorized(let area):
            "\(area) access not authorized. Grant permission in System Settings > Privacy & Security > \(area)."
        }
    }
}
