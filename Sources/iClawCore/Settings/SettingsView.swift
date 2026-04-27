import SwiftUI

// MARK: - Update Checker Environment

/// Environment key for the "Check for Updates" action, injected by the app target for DMG builds.
private struct CheckForUpdatesActionKey: EnvironmentKey {
    static let defaultValue: (@Sendable () -> Void)? = nil
}

public extension EnvironmentValues {
    var checkForUpdatesAction: (@Sendable () -> Void)? {
        get { self[CheckForUpdatesActionKey.self] }
        set { self[CheckForUpdatesActionKey.self] = newValue }
    }
}

// MARK: - Settings Tab Enum

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case models
    case tools
    case notifications
    case automations
    case skills
    case email
    case continuity
    case permissions
    case labs
    case history
    case about

    public var id: String { rawValue }

    /// Tabs visible in the current build configuration.
    /// MAS builds hide Automations (no AppleScript/recurring) and Labs.
    static var visibleCases: [SettingsTab] {
        #if MAS_BUILD
        return allCases.filter { $0 != .automations && $0 != .labs }
        #else
        return Array(allCases)
        #endif
    }

    var title: String {
        switch self {
        case .general: return String(localized: "General", bundle: .iClawCore)
        case .models: return String(localized: "Models", bundle: .iClawCore)
        case .tools: return String(localized: "tools_settings_tab", bundle: .iClawCore)
        case .notifications: return String(localized: "Notifications", bundle: .iClawCore)
        case .automations: return String(localized: "Automations", bundle: .iClawCore)
        case .skills: return String(localized: "Skills", bundle: .iClawCore)
        case .email: return String(localized: "Email", bundle: .iClawCore)
        case .continuity: return String(localized: "Continuity", bundle: .iClawCore)
        case .permissions: return String(localized: "Permissions", bundle: .iClawCore)
        case .labs: return String(localized: "Labs", bundle: .iClawCore)
        case .history: return String(localized: "History", bundle: .iClawCore)
        case .about: return String(localized: "About", bundle: .iClawCore)
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .tools: return "wrench.and.screwdriver"
        case .notifications: return "bell.badge"
        case .automations: return "arrow.clockwise.circle"
        case .skills: return "sparkles"
        case .email: return "envelope"
        case .continuity: return "arrow.triangle.2.circlepath"
        case .permissions: return "lock.shield"
        case .labs: return "flask"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Text Size Preference

/// User-selectable text size for chat messages and widget content.
/// Maps to base point sizes that scale proportionally with Dynamic Type.
public enum TextSizePreference: String, CaseIterable, Identifiable, Sendable {
    case small = "small"
    case `default` = "default"
    case large = "large"
    case extraLarge = "extraLarge"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .small: String(localized: "Small", bundle: .iClawCore)
        case .default: String(localized: "Default", bundle: .iClawCore)
        case .large: String(localized: "Large", bundle: .iClawCore)
        case .extraLarge: String(localized: "X-Large", bundle: .iClawCore)
        }
    }

    /// Base chat font size in points.
    public var chatFontSize: CGFloat {
        switch self {
        case .small: 12
        case .default: 14
        case .large: 17
        case .extraLarge: 20
        }
    }

    /// Scale factor relative to default, for widget font sizes.
    public var scaleFactor: CGFloat {
        chatFontSize / 14.0
    }
}

// MARK: - Temperature Unit

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case system
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "System Default", bundle: .iClawCore)
        case .celsius: return String(localized: "Celsius (\u{00B0}C)", bundle: .iClawCore)
        case .fahrenheit: return String(localized: "Fahrenheit (\u{00B0}F)", bundle: .iClawCore)
        }
    }

    /// Countries that use Fahrenheit as their primary temperature unit.
    private static let fahrenheitRegions: Set<String> = ["US", "BS", "BZ", "KY", "PW", "MH", "FM"]

    var usesFahrenheit: Bool {
        switch self {
        case .system:
            if Locale.current.measurementSystem == .us { return true }
            // Check locale region, then language region (covers en_US users with metric measurement system)
            let region = Locale.current.region?.identifier
                ?? Locale.current.language.region?.identifier
            if let region { return Self.fahrenheitRegions.contains(region) }
            return false
        case .celsius:
            return false
        case .fahrenheit:
            return true
        }
    }
}

// MARK: - Main Settings View

public struct SettingsView: View {
    public init() {}

    @State private var selectedTab: SettingsTab = .general
    private var settingsNav = SettingsNavigation.shared

    public var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.visibleCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 180)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsView()
                case .models:
                    ModelsSettingsView()
                case .tools:
                    ToolSettingsView()
                case .notifications:
                    NotificationsSettingsView()
                case .automations:
                    AutomationsSettingsView()
                case .skills:
                    SkillsSettingsView()
                case .email:
                    EmailSettingsView()
                case .continuity:
                    ContinuitySettingsView()
                case .permissions:
                    PermissionsSettingsView()
                case .labs:
                    LabsSettingsView()
                case .history:
                    HistorySettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 540)
        .onChange(of: settingsNav.requestedTab) { _, tab in
            if let tab {
                selectedTab = tab
                settingsNav.requestedTab = nil
            }
        }
    }
}
