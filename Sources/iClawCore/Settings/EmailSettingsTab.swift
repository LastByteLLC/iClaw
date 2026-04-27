import SwiftUI

// MARK: - Email Settings

struct EmailSettingsView: View {
    @AppStorage(MailHookManager.enabledKey, store: UserDefaults(suiteName: MailHookManager.suiteName))
    private var mailHookEnabled = false

    @State private var ingestedCount: Int = 0

    var body: some View {
        Form {
            Section(String(localized: "Read Email", bundle: .iClawCore)) {
                Text("iClaw reads your inbox via AppleScript when you ask about email. Grant Automation permission for Mail.app below.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PermissionRow(
                    name: String(localized: "Automation (Mail.app)", bundle: .iClawCore),
                    icon: "applescript",
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("You can disable the Email tool under Tools.", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Open Tools", bundle: .iClawCore)) {
                        SettingsNavigation.shared.openTab(.tools)
                    }
                    .font(.caption)
                    .buttonStyle(.link)
                    .accessibilityLabel(String(localized: "open_tools_settings", bundle: .iClawCore))
                }
            }

            // MARK: - Coming Soon

            ZStack {
                VStack(spacing: 0) {
                    Section(String(localized: "Incoming Email Hook", bundle: .iClawCore)) {
                        Toggle(String(localized: "Enable Email Monitoring", bundle: .iClawCore), isOn: $mailHookEnabled)
                            .onChange(of: mailHookEnabled) { _, enabled in
                                Task {
                                    if enabled {
                                        await MailHookManager.shared.start()
                                    } else {
                                        await MailHookManager.shared.stop()
                                    }
                                }
                            }

                        Text("When enabled, iClaw's Mail extension captures incoming emails for contextual awareness. Emails are stored locally and never leave your device.", bundle: .iClawCore)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if mailHookEnabled {
                            LabeledContent(String(localized: "Emails ingested", bundle: .iClawCore)) {
                                Text("\(ingestedCount)")
                                    .monospacedDigit()
                            }
                        }
                    }

                    Section(String(localized: "Future", bundle: .iClawCore)) {
                        Label(String(localized: "Follow-up reminders", bundle: .iClawCore), systemImage: "bell.badge")
                            .foregroundStyle(.secondary)
                        Label(String(localized: "Smart inbox organization", bundle: .iClawCore), systemImage: "tray.2")
                            .foregroundStyle(.secondary)
                        Text("Coming in a future update.", bundle: .iClawCore)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(true)
                .opacity(0.4)

                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Coming Soon", bundle: .iClawCore)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
