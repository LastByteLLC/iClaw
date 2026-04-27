import SwiftUI

// MARK: - About Settings

struct AboutSettingsView: View {
    @Environment(\.checkForUpdatesAction) private var checkForUpdatesAction

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            #if canImport(AppKit)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            #else
            ClawIcon.image
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
            #endif

            Text("iClaw", bundle: .iClawCore)
                .font(.title.bold())

            HStack(spacing: 6) {
                Image(systemName: "apple.intelligence")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Powered by Apple Intelligence", bundle: .iClawCore)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("An on-device AI agent.", bundle: .iClawCore)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            VStack(spacing: 6) {
                LabeledContent(String(localized: "Version", bundle: .iClawCore)) {
                    Text(appVersion)
                        .monospacedDigit()
                }
                LabeledContent(String(localized: "Build", bundle: .iClawCore)) {
                    Text(buildHash)
                        .font(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                }
            }
            .frame(width: 240)

            Divider()
                .frame(width: 200)

            if let checkForUpdates = checkForUpdatesAction {
                Button(String(localized: "Check for Updates…", bundle: .iClawCore)) {
                    checkForUpdates()
                }
            }

            Button(String(localized: "About iClaw", bundle: .iClawCore)) {
                FTUEWindowController.show()
            }

            VStack(spacing: 8) {
                Button(String(localized: "Website", bundle: .iClawCore)) {
                    if let url = URL(string: AppConfig.websiteURL) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(String(localized: "GitHub", bundle: .iClawCore)) {
                    if let url = URL(string: AppConfig.githubURL) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(String(localized: "Contact Support", bundle: .iClawCore)) {
                    if let url = URL(string: AppConfig.supportMailto) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(String(localized: "Privacy Policy", bundle: .iClawCore)) {
                    if let url = URL(string: AppConfig.privacyPolicyURL) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button(String(localized: "Terms of Service", bundle: .iClawCore)) {
                    if let url = URL(string: AppConfig.tosURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .buttonStyle(.link)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String { AppConfig.appVersion }

    private var buildHash: String {
        Bundle.main.infoDictionary?["GitHash"] as? String ?? "dev"
    }
}
