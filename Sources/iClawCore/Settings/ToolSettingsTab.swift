import SwiftUI

// MARK: - Tool Settings

struct ToolSettingsView: View {
    private var settings = SkillSettingsManager.shared
    @State private var needsRestart = false

    /// All core tool names that can be toggled, grouped by category.
    private var toolsByCategory: [(category: ToolCategory, tools: [ToolInfo])] {
        ToolCategoryRegistry.categories
            .filter { $0.name != "Help" }
            .compactMap { category in
                let tools = category.coreToolNames.compactMap { name -> ToolInfo? in
                    // Skip undisableable tools
                    guard !SkillSettingsManager.undisableableTools.contains(name) else { return nil }
                    let manifest = ToolManifest.entry(for: name)
                    let help = ToolHelpProvider.help(for: name)
                    return ToolInfo(
                        name: name,
                        displayName: manifest?.displayName ?? name,
                        icon: manifest?.icon ?? "questionmark.circle",
                        description: help?.description
                    )
                }
                return tools.isEmpty ? nil : (category: category, tools: tools)
            }
    }

    var body: some View {
        Form {
            ForEach(toolsByCategory, id: \.category.chipName) { group in
                Section {
                    ForEach(group.tools) { tool in
                        toolRow(tool)
                    }
                } header: {
                    Label(group.category.name, systemImage: group.category.icon)
                }
            }

            Section {
                Text("tools_settings_footer", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if needsRestart {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.orange)
                        Text("tools_restart_required", bundle: .iClawCore)
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(String(localized: "tools_restart_button", bundle: .iClawCore)) {
                            restartApp()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toolRow(_ tool: ToolInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: tool.icon)
                .symbolRenderingMode(.monochrome)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName)
                    .font(.body)
                if let desc = tool.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Toggle(tool.displayName, isOn: Binding(
                get: { !settings.disabledToolNames.contains(tool.name) },
                set: { enabled in
                    if enabled {
                        settings.disabledToolNames.remove(tool.name)
                    } else {
                        settings.disabledToolNames.insert(tool.name)
                    }
                    withAnimation(.snappy) { needsRestart = true }
                }
            ))
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(settings.disabledToolNames.contains(tool.name) ? "Off" : "On"))
    }

    private func restartApp() {
        #if canImport(AppKit)
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url.path]
        task.launch()
        NSApp.terminate(nil)
        #endif
    }
}

// MARK: - Tool Info

private struct ToolInfo: Identifiable {
    let name: String
    let displayName: String
    let icon: String
    let description: String?
    var id: String { name }
}
