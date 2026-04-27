import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Settings Navigation

/// Coordinates programmatic navigation to a specific Settings tab.
@MainActor
@Observable
public final class SettingsNavigation {
    public static let shared = SettingsNavigation()
    public var requestedTab: SettingsTab?
    /// URL of a skill file to import when the Skills tab opens.
    public var pendingSkillImport: URL?

    /// Opens the Settings window and navigates to the given tab.
    /// Prefer calling `openSettings()` from SwiftUI views (via `@Environment(\.openSettings)`).
    /// This method is a fallback for non-view contexts (e.g., skill import).
    public func openTab(_ tab: SettingsTab) {
        requestedTab = tab
        #if canImport(AppKit)
        if NSApp.activationPolicy() == .accessory {
            NSApp.setActivationPolicy(.regular)
        }
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async {
            if NSApp.responds(to: Selector(("showSettingsWindow:"))) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        #endif
    }

    /// Opens Settings > Skills and queues a skill file for import.
    public func importSkill(from url: URL) {
        pendingSkillImport = url
        openTab(.skills)
    }
}
