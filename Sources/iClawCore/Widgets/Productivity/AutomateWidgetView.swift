import SwiftUI

/// Widget for displaying generated AppleScript automations with action buttons.
struct AutomateWidgetView: View {
    let data: AutomateWidgetData

    @State private var runResult: String?
    @State private var isRunning = false
    @State private var saved = false

    var body: some View {
        content(data)
            .glassContainer()
    }

    @ViewBuilder
    private func content(_ ad: AutomateWidgetData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "applescript")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Automation")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)

                Spacer()

                if ad.apps.count > 0 {
                    Text(ad.apps.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            // Description
            Text(ad.description)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(3)
                .padding(.horizontal, 12)

            // Script preview
            ScrollView(.vertical) {
                Text(ad.script)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.7))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(.black.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)

            // Run result
            if let result = runResult {
                HStack(spacing: 6) {
                    Image(systemName: result.hasPrefix("Error:") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(result.hasPrefix("Error:") ? .red : .green)
                        .font(.caption2)
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.horizontal, 12)
            }

            // Action buttons
            HStack(spacing: 10) {
                #if os(macOS)
                // Run button
                Button {
                    runScript(ad.script)
                } label: {
                    if isRunning {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Label("Run", systemImage: "play.fill")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isRunning)

                // Save button
                Button {
                    Task { await saveScript(ad) }
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                // Open in Script Editor
                Button {
                    Task { await AutomateTool.openInScriptEditor(ad.script, name: ad.description) }
                } label: {
                    Label("Script Editor", systemImage: "doc.text")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                #endif

                Spacer()

                // Iteration badge
                if ad.iterations > 1 {
                    Text(String(format: String(localized: "iteration_count", bundle: .iClawCore), ad.iterations))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    #if os(macOS)
    private func runScript(_ source: String) {
        isRunning = true
        runResult = nil
        Task { @MainActor in
            let result = await AutomateTool.runScript(source)
            isRunning = false
            runResult = result.success ? result.output : "Error: \(result.output)"
        }
    }

    private func saveScript(_ ad: AutomateWidgetData) async {
        if await AutomateTool.saveScript(ad.script, name: ad.description) != nil {
            saved = true
        }
    }
    #endif
}
