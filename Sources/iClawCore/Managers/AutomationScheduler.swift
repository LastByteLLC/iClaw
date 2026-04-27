import Foundation
import os
#if os(iOS)
import BackgroundTasks
#endif

/// Platform-conditional scheduler for automation execution.
/// - macOS: HeartbeatManager calls `executeDueAutomations()` directly via Timer.
/// - iOS: BGTaskScheduler fires a registered handler that calls the same method.
public actor AutomationScheduler {
    public static let shared = AutomationScheduler()

    private let logger = Logger(subsystem: "com.geticlaw.iClaw", category: "AutomationScheduler")

    /// BGTask identifier — must match Info-iOS.plist BGTaskSchedulerPermittedIdentifiers.
    public static let taskIdentifier = "com.geticlaw.iClaw.automation.refresh"

    #if os(iOS)
    /// Registers the background task handler. Call once from app init.
    public func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Task {
                await self.handleBackgroundRefresh(refreshTask)
            }
        }
        logger.info("Registered BGTask: \(Self.taskIdentifier)")
    }

    /// Schedules the next background refresh based on the soonest due automation.
    public func scheduleNextRefresh() async {
        do {
            let active = try await ScheduledQueryStore.shared.fetchActive()
            guard !active.isEmpty else { return }

            // Schedule for the soonest nextRunDate
            let soonest = active.min(by: { $0.nextRunDate < $1.nextRunDate })
            let earliestDate = soonest?.nextRunDate ?? Date(timeIntervalSinceNow: 900)

            let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
            request.earliestBeginDate = earliestDate
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled next BGTask refresh for \(earliestDate)")
        } catch {
            logger.error("Failed to schedule BGTask: \(error)")
        }
    }

    /// Handles a background refresh task from BGTaskScheduler.
    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) async {
        // Set expiration handler
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        // Execute due automations (reuses HeartbeatManager logic)
        await HeartbeatManager.shared.runHeartbeat()

        // Schedule the next refresh
        await scheduleNextRefresh()

        task.setTaskCompleted(success: true)
    }
    #endif

    /// Cross-platform: called after any automation is created/modified to ensure
    /// the scheduling system is aware. On macOS this is a no-op (Timer handles it).
    public func automationsDidChange() async {
        #if os(iOS)
        await scheduleNextRefresh()
        #endif
    }
}
