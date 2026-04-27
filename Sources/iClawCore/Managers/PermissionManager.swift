import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Centralized permission request helper.
/// Shows an OS-standard dialog before triggering the system permission prompt.
/// Tracks rejected permissions so tools can skip re-asking.
public enum PermissionManager {

    public enum PermissionKind: String, Sendable {
        case location = "Location"
        case contacts = "Contacts"
        case camera = "Camera"
        case calendar = "Calendar"
        case reminders = "Reminders"
        case health = "Health"
        case notifications = "Notifications"
        case microphone = "Microphone"
        case alarms = "Alarms"
    }

    /// Result of a permission request dialog.
    public enum PermissionResponse: Sendable {
        case allowed    // User clicked "Allow" — proceed to OS permission request
        case denied     // User clicked "Not Now" — skip, use fallback
        case rejected   // Previously rejected — don't ask again
    }

    // MARK: - Rejection Tracking

    private static let rejectedKey = "iClaw_rejectedPermissions"

    /// Whether the user has previously rejected this permission kind in iClaw.
    public static func isRejected(_ kind: PermissionKind) -> Bool {
        let rejected = UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []
        return rejected.contains(kind.rawValue)
    }

    /// Record that the user rejected this permission kind.
    public static func reject(_ kind: PermissionKind) {
        var rejected = UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []
        if !rejected.contains(kind.rawValue) {
            rejected.append(kind.rawValue)
            UserDefaults.standard.set(rejected, forKey: rejectedKey)
        }
    }

    /// Clear a previous rejection (e.g. user tapped "Open Settings" and granted).
    public static func clearRejection(_ kind: PermissionKind) {
        var rejected = UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []
        rejected.removeAll { $0 == kind.rawValue }
        UserDefaults.standard.set(rejected, forKey: rejectedKey)
    }

    /// Returns all permission kinds the user has rejected in iClaw.
    public static func allRejected() -> Set<PermissionKind> {
        let rejected = UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []
        return Set(rejected.compactMap { PermissionKind(rawValue: $0) })
    }

    // MARK: - Permission Request (Dialog)

    /// Shows an OS-standard dialog asking the user to allow or deny a permission.
    /// Returns `.allowed` if user consents, `.denied` if they decline, `.rejected` if previously rejected.
    ///
    /// On macOS, this shows an `NSAlert` with informational style.
    /// On iOS, falls back to returning `.allowed` (system handles the prompt).
    @MainActor
    public static func requestPermission(_ kind: PermissionKind, toolName: String, reason: String) async -> PermissionResponse {
        // If previously rejected, don't show dialog again
        if isRejected(kind) { return .rejected }

        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "\(toolName) needs \(kind.rawValue) access"
        alert.informativeText = "iClaw wants to access \(kind.rawValue) \(reason). This data stays on your device."
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: iconName(for: kind), accessibilityDescription: kind.rawValue)
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            clearRejection(kind)
            return .allowed
        } else {
            reject(kind)
            return .denied
        }
        #else
        // iOS: system handles permission prompts natively
        return .allowed
        #endif
    }

    // MARK: - Helpers

    private static func iconName(for kind: PermissionKind) -> String {
        switch kind {
        case .location: return "location.fill"
        case .contacts: return "person.crop.circle.fill"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .health: return "heart.fill"
        case .camera: return "camera.fill"
        case .microphone: return "mic.fill"
        case .notifications: return "bell.fill"
        case .alarms: return "alarm.fill"
        }
    }
}
