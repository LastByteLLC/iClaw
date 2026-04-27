import SwiftUI
import UserNotifications

// MARK: - Notification Mode

public enum NotificationMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case basic
    case full

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "Off", bundle: .iClawCore)
        case .basic: return String(localized: "Basic", bundle: .iClawCore)
        case .full: return String(localized: "Full", bundle: .iClawCore)
        }
    }

    var description: String {
        switch self {
        case .off: return String(localized: "No badges, dots, or notifications.", bundle: .iClawCore)
        case .basic: return String(localized: "Shows a dot indicator on the menu bar and dock when results arrive in the background.", bundle: .iClawCore)
        case .full: return String(localized: "Shows result count plus system notification banners that navigate to the result.", bundle: .iClawCore)
        }
    }
}

// MARK: - Notifications Settings

struct NotificationsSettingsView: View {
    @AppStorage(AppConfig.notificationModeKey) private var notificationMode: NotificationMode = .basic
    @State private var notificationAuthStatus: UNAuthorizationStatus?

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Notification Style", bundle: .iClawCore), selection: $notificationMode) {
                    ForEach(NotificationMode.allCases) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                            Text(mode.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if notificationMode == .full {
                Section {
                    if let status = notificationAuthStatus, status != .authorized, status != .provisional {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "Notification permission is not granted.", bundle: .iClawCore))
                                    .font(.callout)
                                Text(String(localized: "System banners require notification permission.", bundle: .iClawCore))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(String(localized: "Open Settings", bundle: .iClawCore)) {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    } else if notificationAuthStatus == .authorized || notificationAuthStatus == .provisional {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                            Text(String(localized: "Notification permission granted.", bundle: .iClawCore))
                                .font(.callout)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshAuthStatus()
        }
        .onChange(of: notificationMode) {
            Task { await refreshAuthStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthStatus() }
        }
    }

    private func refreshAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthStatus = settings.authorizationStatus
    }
}
