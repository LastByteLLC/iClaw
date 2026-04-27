import SwiftUI

// MARK: - Labs Settings

struct LabsSettingsView: View {
    @AppStorage(AppConfig.dynamicWidgetsEnabledKey) private var dynamicWidgetsEnabled = false
    @AppStorage(AppConfig.screenContextEnabledKey) private var screenContextEnabled = false

    var body: some View {
        Form {
            Section {
                Text("Experimental features that are still being refined. They may be unstable or change without notice.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Dynamic Widgets", bundle: .iClawCore)) {
                Toggle(String(localized: "Enable Dynamic Widgets", bundle: .iClawCore), isOn: $dynamicWidgetsEnabled)
                Text("Generates rich visual layouts from tool results using an additional LLM call. May increase response time.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            Section(String(localized: "Screen Context", bundle: .iClawCore)) {
                Toggle(String(localized: "Enable Passive Screen Context", bundle: .iClawCore), isOn: $screenContextEnabled)
                    .onChange(of: screenContextEnabled) { _, enabled in
                        Task {
                            if enabled {
                                await ScreenContextManager.shared.start()
                            } else {
                                await ScreenContextManager.shared.stop()
                            }
                        }
                    }
                Text("Periodically reads the frontmost window to give iClaw awareness of what you're looking at. Requires Screen Recording permission.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
