import SwiftUI

// MARK: - Models Settings

struct ModelsSettingsView: View {
    @State private var config = BackendConfig.current
    @State private var isSwitching = false
    @State private var ollamaAvailable = false

    var body: some View {
        Form {
            Section(String(localized: "Model Backend", bundle: .iClawCore)) {
                Picker(String(localized: "Backend", bundle: .iClawCore), selection: $config.kind) {
                    HStack {
                        Label("Ollama", systemImage: "server.rack")
                        if !ollamaAvailable {
                            Text("Not available", bundle: .iClawCore)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(BackendConfig.Kind.ollama)

                    Label(String(localized: "Apple Intelligence", bundle: .iClawCore), systemImage: "apple.intelligence")
                        .tag(BackendConfig.Kind.appleIntelligence)
                }
                .pickerStyle(.radioGroup)
                .disabled(isSwitching)
                .onChange(of: config.kind) { _, newKind in
                    if newKind == .ollama && !ollamaAvailable {
                        // Revert — can't select Ollama when unavailable
                        config.kind = .appleIntelligence
                        return
                    }
                    config.userOverride = true
                    applyConfig()
                }
            }

            Section {
                switch config.kind {
                case .ollama:
                    if !config.ollamaModelName.isEmpty {
                        LabeledContent(String(localized: "Model", bundle: .iClawCore), value: config.ollamaModelName)
                        LabeledContent(String(localized: "Context", bundle: .iClawCore), value: Self.formatTokenCount(config.ollamaContextWindow))
                    } else {
                        Text("Auto-detected on launch. Ollama must be running.", bundle: .iClawCore)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .appleIntelligence:
                    Text("On-device, private, no setup required.", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !ollamaAvailable {
                    Text("Ollama is not installed or not running. Install from ollama.com and start the server to enable it.", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ollama is preferred when available. Your selection is remembered across launches.", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            ollamaAvailable = OllamaStatus.shared.isAvailable
        }
    }

    private func applyConfig() {
        isSwitching = true
        BackendConfig.current = config
        Task {
            await LLMAdapter.shared.autoConfigureBackend()
            config = BackendConfig.current
            isSwitching = false
        }
    }

    /// Formats a token count as a human-readable string (e.g. 131072 → "131k tokens").
    private static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let m = Double(count) / 1_000_000.0
            return count % 1_000_000 == 0 ? "\(count / 1_000_000)m tokens" : String(format: "%.1fm tokens", m)
        } else if count >= 1000 {
            let k = Double(count) / 1000.0
            return count % 1000 == 0 ? "\(count / 1000)k tokens" : String(format: "%.1fk tokens", k)
        }
        return "\(count) tokens"
    }
}
