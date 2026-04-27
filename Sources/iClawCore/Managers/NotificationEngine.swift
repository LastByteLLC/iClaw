import Foundation
import UserNotifications
import os
#if os(macOS)
import AppKit
#endif

/// Delivers automation results and proactive alerts through multiple channels:
/// 1. UNUserNotificationCenter — real notifications with content (Full mode only)
/// 2. Dock badge (macOS) — dot (Basic) or count (Full)
/// 3. Menu bar indicator (macOS) — dot (Basic) or count (Full)
/// 4. HeartbeatManager queue — in-HUD delivery when user opens the app (always)
///
/// Channel gating is controlled by the `notificationMode` user default (off/basic/full).
public actor NotificationEngine {
    public static let shared = NotificationEngine()

    private let logger = Logger(subsystem: "com.geticlaw.iClaw", category: "NotificationEngine")

    /// Category identifier for automation result notifications.
    static let automationCategory = "AUTOMATION_RESULT"

    /// Pending unread count for dock badge.
    private var pendingCount = 0

    // MARK: - Mode

    private func currentMode() -> NotificationMode {
        let raw = UserDefaults.standard.string(forKey: AppConfig.notificationModeKey) ?? "basic"
        return NotificationMode(rawValue: raw) ?? .basic
    }

    // MARK: - Deliver

    /// Delivers a result through channels gated by the user's notification mode.
    /// - Parameters:
    ///   - messageID: The UUID of the chat message, used for click-to-navigate in Full mode.
    public func deliver(title: String, body: String, source: String, sourceId: Int64? = nil, messageID: UUID? = nil) async {
        let mode = currentMode()

        // In-HUD queue always fires regardless of mode
        await HeartbeatManager.shared.queueProactiveResult(
            HeartbeatManager.ProactiveResult(
                text: body,
                widgetType: nil,
                widgetData: nil,
                source: source
            )
        )

        guard mode != .off else {
            logger.debug("Notifications off — skipped external delivery")
            return
        }

        // Increment badge + menu bar indicator (Basic and Full)
        pendingCount += 1
        await updateBadge(mode: mode)
        await postMenuBarNotification(mode: mode)

        // System notification banners (Full only)
        if mode == .full {
            await sendNotification(title: title, body: body, source: source, sourceId: sourceId, messageID: messageID)
        }

        logger.debug("Delivered notification: \(title) [\(source)] mode=\(mode.rawValue)")
    }

    /// Clears the badge count and menu bar indicator. Call when user opens the HUD.
    public func clearBadge() async {
        pendingCount = 0
        let mode = currentMode()
        await updateBadge(mode: mode)
        await MainActor.run {
            NotificationCenter.default.post(name: .iClawClearBadge, object: nil)
        }
    }

    /// Returns the current pending count.
    public var unreadCount: Int { pendingCount }

    // MARK: - System Notifications

    private func sendNotification(title: String, body: String, source: String, sourceId: Int64?, messageID: UUID?) async {
        // Skip in test environment
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard !bundleID.hasPrefix("com.apple.dt.xctest") else { return }

        let center = UNUserNotificationCenter.current()

        // Request authorization if needed, then re-check status
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            status = granted ? .authorized : .denied
        }
        guard status == .authorized || status == .provisional else {
            logger.debug("Notifications not authorized — skipping")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(256))
        content.sound = .default
        content.categoryIdentifier = Self.automationCategory
        if let sourceId {
            content.threadIdentifier = "automation-\(sourceId)"
            content.userInfo["automationID"] = sourceId
        }
        content.userInfo["source"] = source
        if let messageID {
            content.userInfo["messageID"] = messageID.uuidString
        }

        // Fire immediately (1 second delay required by UNTimeIntervalNotificationTrigger)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            logger.error("Failed to schedule notification: \(error)")
        }
    }

    // MARK: - Badge

    private func updateBadge(mode: NotificationMode) async {
        let count = pendingCount
        await MainActor.run {
            #if os(macOS)
            if let app = NSApplication.shared as NSApplication? {
                switch mode {
                case .off:
                    app.dockTile.badgeLabel = nil
                case .basic:
                    app.dockTile.badgeLabel = count > 0 ? "●" : nil
                case .full:
                    app.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
                }
            }
            #endif
        }
    }

    // MARK: - Menu Bar Indicator

    private func postMenuBarNotification(mode: NotificationMode) async {
        let count = pendingCount
        await MainActor.run {
            NotificationCenter.default.post(
                name: .iClawAutomationResult,
                object: nil,
                userInfo: ["mode": mode.rawValue, "count": count]
            )
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a result is delivered. AppDelegate observes this
    /// to update the menu bar status item with a dot or count indicator.
    public static let iClawAutomationResult = Notification.Name("iClaw.automationResult")

    /// Posted when the badge and menu bar indicator should be cleared (HUD opened).
    public static let iClawClearBadge = Notification.Name("iClaw.clearBadge")

    /// Posted when user taps a notification banner. Carries the message UUID as `object`.
    public static let iClawNavigateToMessage = Notification.Name("iClaw.navigateToMessage")

    /// Posted by `/persist on|off` command. Object is `true` to keep HUD open, `false` to restore auto-dismiss.
    public static let iClawPersistHUD = Notification.Name("iClaw.persistHUD")
}
