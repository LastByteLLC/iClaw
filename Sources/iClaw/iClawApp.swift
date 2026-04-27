import SwiftUI
import AppKit
import iClawCore

@main
struct iClawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    #if !MAS_BUILD
    @State private var updaterManager = UpdaterManager.shared
    #endif

    var body: some Scene {
        Settings {
            SettingsView()
                #if !MAS_BUILD
                .environment(\.checkForUpdatesAction, { @Sendable in
                    Task { @MainActor in
                        UpdaterManager.shared.checkForUpdates()
                    }
                })
                #endif
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button(String(localized: "iClaw Website", bundle: .iClawCore)) {
                    openURL(AppConfig.websiteURL)
                }
                Divider()
                Button(String(localized: "Contact Support…", bundle: .iClawCore)) {
                    openURL(AppConfig.supportMailto)
                }
                Button(String(localized: "Send Feedback…", bundle: .iClawCore)) {
                    openURL(AppConfig.feedbackMailto)
                }
                Divider()
                Button(String(localized: "Privacy Policy", bundle: .iClawCore)) {
                    openURL(AppConfig.privacyPolicyURL)
                }
                Button(String(localized: "Terms of Service", bundle: .iClawCore)) {
                    openURL(AppConfig.tosURL)
                }
            }
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
