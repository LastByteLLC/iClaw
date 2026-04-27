import SwiftUI
import AppKit
import iClawCore

/// Defines how the application appears in the macOS environment.
enum LaunchMode: String, CaseIterable, Identifiable {
    case dock
    case menuBar
    
    var id: String { self.rawValue }
    
    var localizedName: String {
        switch self {
        case .dock: return "Dock & Menu Bar"
        case .menuBar: return "Menu Bar Only"
        }
    }
}

/// Manages the application's launch mode and activation policy.
@MainActor
@Observable
final class LaunchModeManager {
    static let shared = LaunchModeManager()

    var launchMode: LaunchMode {
        get {
            LaunchMode(rawValue: UserDefaults.standard.string(forKey: "appLaunchMode") ?? LaunchMode.dock.rawValue) ?? .dock
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appLaunchMode")
        }
    }
    
    private init() {}

    /// Configures the application's activation policy based on the current launch mode.
    /// Note: The status bar icon is managed by AppDelegate.setupStatusItem() — no dummy item needed here.
    func configureAppActivationPolicy() {
        switch launchMode {
        case .dock:
            NSApp.setActivationPolicy(.regular)
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
