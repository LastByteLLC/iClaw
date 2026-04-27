import AppKit
import iClawCore

/// Manages a user-configurable global keyboard shortcut to toggle the iClaw HUD.
/// Uses `NSEvent.addGlobalMonitorForEvents` (sandbox-safe, no extra entitlements).
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Start monitoring for the configured hotkey (if any).
    func startMonitoring() {
        stopMonitoring()

        guard let keyCode = storedKeyCode, let modifiers = storedModifiers else { return }

        // Global: fires when the app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event, keyCode: keyCode, modifiers: modifiers) == true {
                Task { @MainActor in
                    (NSApp.delegate as? AppDelegate)?.toggleWindow()
                }
            }
        }

        // Local: fires when the app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event, keyCode: keyCode, modifiers: modifiers) == true {
                Task { @MainActor in
                    (NSApp.delegate as? AppDelegate)?.toggleWindow()
                }
                return nil // consume the event
            }
            return event
        }
    }

    func stopMonitoring() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    /// Reload monitors after settings change.
    func reload() {
        startMonitoring()
    }

    // MARK: - Private

    private var storedKeyCode: UInt16? {
        let raw = UserDefaults.standard.integer(forKey: AppConfig.hotkeyKeyCodeKey)
        return raw > 0 ? UInt16(raw) : nil
    }

    private var storedModifiers: NSEvent.ModifierFlags? {
        let raw = UserDefaults.standard.integer(forKey: AppConfig.hotkeyModifierFlagsKey)
        return raw > 0 ? NSEvent.ModifierFlags(rawValue: UInt(raw)) : nil
    }

    private func matches(_ event: NSEvent, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        event.keyCode == keyCode &&
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifiers
    }
}
