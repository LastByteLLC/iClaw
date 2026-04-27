import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Manages consent for tool actions that require user confirmation.
///
/// Tools declare their consent policy via `ActionConsentPolicy`. The engine
/// checks consent before execution. Confirmation is shown via NSAlert.
///
/// Flow:
/// 1. Engine calls `requestConsent(action:toolName:)` before executing a consent-required tool
/// 2. ConsentManager checks `testModePolicy` (test/headless override)
/// 3. Then `autoApproveActions` setting
/// 4. Falls back to NSAlert (GUI only — never in headless mode)
@MainActor
@Observable
public class ConsentManager {
    public static let shared = ConsentManager()

    /// The result of a consent request.
    public enum ConsentResult: Sendable {
        case approved
        case denied
    }

    /// Test/headless override policy. Takes precedence over `autoApproveActions`
    /// and disables NSAlert entirely. Set by CLI daemon or test harness.
    public enum TestModePolicy: Sendable {
        case alwaysApprove
        case alwaysDeny
        case byTool([String: ConsentResult])
    }

    /// When set, all consent requests resolve via this policy — no NSAlert,
    /// no `autoApproveActions` fallback. Designed for the headless CLI and
    /// Swift Testing cases so `.destructive` actions can be probed without
    /// deadlocking on `NSAlert.runModal()`.
    public var testModePolicy: TestModePolicy?

    /// Whether non-destructive consent-required actions are auto-approved.
    /// Destructive actions always require explicit confirmation.
    public var autoApproveActions = false

    private init() {
        // Sync with @AppStorage on init
        self.autoApproveActions = UserDefaults.standard.bool(forKey: AppConfig.autoApproveActionsKey)
    }

    /// Requests consent for a tool action. Resolution order:
    /// 1. `.safe` → `.approved` (no consent needed)
    /// 2. `testModePolicy` if set — deterministic bypass for CLI/tests
    /// 3. `autoApproveActions` (non-destructive only)
    /// 4. Headless safety net — if `ToolRegistry.headlessMode` or no key window,
    ///    deny rather than call `NSAlert.runModal()` (which would block the
    ///    main actor indefinitely and cannot be cancelled by Swift Concurrency).
    /// 5. GUI path: sheet-modal alert → user decides.
    public func requestConsent(
        policy: ActionConsentPolicy,
        toolName: String
    ) async -> ConsentResult {
        // (1) Safe actions don't need consent
        guard policy.needsConsent else { return .approved }

        // (2) Test mode override — highest priority
        if let testPolicy = testModePolicy {
            switch testPolicy {
            case .alwaysApprove:
                Log.engine.debug("Test mode: approved \(toolName)")
                return .approved
            case .alwaysDeny:
                Log.engine.debug("Test mode: denied \(toolName)")
                return .denied
            case .byTool(let decisions):
                if let decision = decisions[toolName] {
                    Log.engine.debug("Test mode (byTool): \(decision == .approved ? "approved" : "denied") \(toolName)")
                    return decision
                }
                // Fall through if no per-tool entry set
            }
        }

        // (3) Auto-approve non-destructive actions if setting is enabled
        if autoApproveActions && !policy.isDestructive {
            Log.engine.debug("Auto-approved action for \(toolName)")
            return .approved
        }

        #if canImport(AppKit)
        // (4) Headless safety net — never hit runModal without a GUI.
        // `NSApp` is an implicitly-unwrapped optional and is nil in test/CLI
        // processes that never boot NSApplication — reading it crashes. The
        // short-circuit `||` can't save a `let` computed on the prior line,
        // so check `headlessMode` first and only touch `NSApp` inside the
        // GUI branch via Objective-C nil-tolerant bridging.
        if ToolRegistry.headlessMode {
            Log.engine.warning("Headless mode: denying consent for \(toolName) (set ConsentManager.shared.testModePolicy to override)")
            return .denied
        }
        let keyWindow: NSWindow? = (NSApp as NSApplication?)?.keyWindow
        if keyWindow == nil {
            Log.engine.warning("No key window: denying consent for \(toolName) (set ConsentManager.shared.testModePolicy to override)")
            return .denied
        }

        // (5) GUI path
        let description = policy.actionDescription ?? "Perform action"
        let isDestructive = policy.isDestructive

        let alert = NSAlert()
        alert.messageText = description
        alert.informativeText = isDestructive
            ? String(localized: "This action cannot be undone.", bundle: .iClawCore)
            : String(localized: "iClaw wants to perform this action.", bundle: .iClawCore)
        alert.alertStyle = isDestructive ? .critical : .informational
        alert.icon = NSImage(
            systemSymbolName: isDestructive ? "exclamationmark.triangle.fill" : "lock.shield",
            accessibilityDescription: nil
        )

        let allowTitle = String(localized: "Allow", bundle: .iClawCore)
        let cancelTitle = String(localized: "Cancel", bundle: .iClawCore)

        alert.addButton(withTitle: allowTitle)
        alert.addButton(withTitle: cancelTitle)

        if let window = keyWindow {
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
            return response == .alertFirstButtonReturn ? .approved : .denied
        } else {
            Log.engine.error("ConsentManager reached runModal fallback unexpectedly — denying to avoid deadlock")
            return .denied
        }
        #else
        // Non-macOS: always approve (iOS has its own permission patterns)
        return .approved
        #endif
    }
}
