import SwiftUI
import AVFoundation
import SafariServices

// MARK: - Personality Level

enum PersonalityLevel: String, CaseIterable, Identifiable, RawRepresentable {
    case full
    case moderate
    case neutral
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return String(localized: "Full (Terse & Sassy)", bundle: .iClawCore)
        case .moderate: return String(localized: "Moderate", bundle: .iClawCore)
        case .neutral: return String(localized: "Neutral", bundle: .iClawCore)
        case .custom: return String(localized: "Custom", bundle: .iClawCore)
        }
    }

    var description: String {
        switch self {
        case .full: return String(localized: "Default personality: terse, no filler, dry humor.", bundle: .iClawCore)
        case .moderate: return String(localized: "Keeps brevity but tones down the sass.", bundle: .iClawCore)
        case .neutral: return String(localized: "Straightforward assistant responses, no personality flavor.", bundle: .iClawCore)
        case .custom: return ""
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage(AppConfig.textSizePreferenceKey) private var textSizePreference: TextSizePreference = .default
    @AppStorage(AppConfig.heartbeatIntervalKey) private var heartbeatInterval: Int = 0
    @AppStorage(AppConfig.browserBridgeEnabledKey) private var browserBridgeEnabled = false
    @AppStorage(AppConfig.personalityLevelKey) private var personalityLevel: PersonalityLevel = .full
    @AppStorage(AppConfig.customPersonalityKey) private var customPersonality: String = ""
    @AppStorage(AppConfig.autoApproveActionsKey) private var autoApproveActions = false
    @AppStorage(AppConfig.autoSpeakResponsesKey) private var autoSpeakResponses = false
    @AppStorage(AppConfig.ttsVoiceIdentifierKey) private var ttsVoiceIdentifier: String = ""
    @AppStorage(AppConfig.sendAnonymousCrashDataKey) private var sendAnonymousCrashData = false
    @State private var placeholderText: String = ""
    @State private var ttsVoices: [AVSpeechSynthesisVoice] = []
    @State private var bridgeConnected: Bool = false
    private var browserMonitor = BrowserMonitor.shared

    var body: some View {
        Form {

            Section(String(localized: "Appearance", bundle: .iClawCore)) {
                Picker(String(localized: "Text Size", bundle: .iClawCore), selection: $textSizePreference) {
                    ForEach(TextSizePreference.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(String(localized: "Global Shortcut", bundle: .iClawCore)) {
                ShortcutRecorderView()

                Text("Press this shortcut to show or hide iClaw from anywhere. If it conflicts with a system shortcut, it won't activate.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Personality", bundle: .iClawCore)) {
                Picker(String(localized: "Personality", bundle: .iClawCore), selection: $personalityLevel) {
                    ForEach(PersonalityLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)

                if personalityLevel == .custom {
                    ZStack(alignment: .topLeading) {
                        if customPersonality.isEmpty {
                            Text(placeholderText.isEmpty ? String(localized: "e.g. Warm and encouraging, like a patient mentor who celebrates small wins", bundle: .iClawCore) : placeholderText)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $customPersonality)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 60, maxHeight: 80)
                            .onChange(of: customPersonality) { _, newValue in
                                if newValue.count > 280 {
                                    customPersonality = String(newValue.prefix(280))
                                }
                            }
                    }

                    Text("\(customPersonality.count)/280")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text(personalityLevel.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: personalityLevel) { _, newValue in
                if newValue == .custom && customPersonality.isEmpty && placeholderText.isEmpty {
                    Task { await generatePlaceholder() }
                }
            }

            Section(String(localized: "Browser Integration", bundle: .iClawCore)) {
                Toggle(String(localized: "Enable Browser Bridge", bundle: .iClawCore), isOn: $browserBridgeEnabled)
                    .onChange(of: browserBridgeEnabled) { _, enabled in
                        Task {
                            if enabled && browserMonitor.isBrowserRunning {
                                try? await BrowserBridge.shared.start()
                            } else if !enabled {
                                await BrowserBridge.shared.stop()
                            }
                            bridgeConnected = await BrowserBridge.shared.isConnected
                        }
                    }

                #if os(macOS)
                // Browser picker — only Safari is supported today.
                Picker(String(localized: "Browser", bundle: .iClawCore), selection: Binding(
                    get: { browserMonitor.selectedBrowser },
                    set: { browser in
                        if browser.isSupported { browserMonitor.select(browser) }
                    }
                )) {
                    ForEach(browserMonitor.installedBrowsers) { browser in
                        HStack(spacing: 6) {
                            if let icon = browserMonitor.icon(for: browser) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            }
                            Text(browser.displayName)
                            if !browser.isSupported {
                                Text("Coming Soon", bundle: .iClawCore)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(browser)
                        .disabled(!browser.isSupported)
                    }
                }
                .disabled(!browserBridgeEnabled)
                #endif

                if browserBridgeEnabled {
                    HStack {
                        if !browserMonitor.isBrowserRunning {
                            // Browser not running
                            Image(systemName: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("Open \(browserMonitor.selectedBrowser.displayName) to continue.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if bridgeConnected {
                            // Connected
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(String(localized: "Connected to browser extension", bundle: .iClawCore))
                                .font(.caption)
                        } else {
                            // Browser running but extension not connected
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(localized: "Waiting for browser extension", bundle: .iClawCore))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { bridgeConnected = await BrowserBridge.shared.isConnected }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Refresh connection status", bundle: .iClawCore))
                        .accessibilityLabel(Text("Refresh connection status", bundle: .iClawCore))
                    }
                    .task {
                        while !Task.isCancelled {
                            bridgeConnected = await BrowserBridge.shared.isConnected
                            try? await Task.sleep(for: .seconds(5))
                        }
                    }
                    .onChange(of: browserMonitor.isBrowserRunning) { _, _ in
                        // BrowserMonitor handles bridge start/stop; just refresh UI state
                        Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            bridgeConnected = await BrowserBridge.shared.isConnected
                        }
                    }

                    #if os(macOS)
                    if browserMonitor.selectedBrowser == .safari {
                        Button(String(localized: "Open Safari Extension Settings", bundle: .iClawCore)) {
                            Task { @MainActor in
                                await openSafariExtensionSettings()
                            }
                        }
                        .font(.caption)
                    }
                    #endif
                }

                Text("The browser extension lets iClaw read and interact with page content. Enable the extension in \(browserMonitor.selectedBrowser.displayName) → Settings → Extensions.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Action Consent", bundle: .iClawCore)) {
                Toggle(String(localized: "Auto-approve actions", bundle: .iClawCore), isOn: $autoApproveActions)
                    .onChange(of: autoApproveActions) { _, newValue in
                        ConsentManager.shared.autoApproveActions = newValue
                    }
                Text("When enabled, actions like sending emails or creating events run without confirmation. Destructive actions (deleting files, removing contacts) always require confirmation.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Speech", bundle: .iClawCore)) {
                Toggle(String(localized: "Auto-speak responses", bundle: .iClawCore), isOn: $autoSpeakResponses)
                Text("Automatically reads aloud agent responses when they appear.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(String(localized: "Voice", bundle: .iClawCore), selection: $ttsVoiceIdentifier) {
                    Text("System Default", bundle: .iClawCore).tag("")
                    ForEach(ttsVoices, id: \.identifier) { voice in
                        Text(voiceLabel(voice)).tag(voice.identifier)
                    }
                }
                .pickerStyle(.menu)

                Button(String(localized: "Preview Voice", bundle: .iClawCore)) {
                    SpeechSynthesizer.shared.speak(
                        text: String(localized: "This is iClaw, your local AI agent.", bundle: .iClawCore),
                        messageID: UUID()
                    )
                }
                .buttonStyle(.plain)
                .font(.caption)
            }

            Section(String(localized: "Heartbeat", bundle: .iClawCore)) {
                Picker(String(localized: "Heartbeat Interval", bundle: .iClawCore), selection: $heartbeatInterval) {
                    Text("Disabled", bundle: .iClawCore).tag(0)
                    Text("1 minute (debug)", bundle: .iClawCore).tag(1)
                    Text("5 minutes", bundle: .iClawCore).tag(5)
                    Text("15 minutes", bundle: .iClawCore).tag(15)
                    Text("30 minutes", bundle: .iClawCore).tag(30)
                    Text("60 minutes", bundle: .iClawCore).tag(60)
                }
                .pickerStyle(.menu)
                .onChange(of: heartbeatInterval) { _, _ in
                    // Restart heartbeat timer with new interval
                    if let delegate = NSApp.delegate as? NSObject {
                        delegate.perform(NSSelectorFromString("restartHeartbeat"))
                    }
                }

                Text("How often iClaw checks for upcoming events, weather changes, and performs memory maintenance. Disabled stops all background checks.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Privacy", bundle: .iClawCore)) {
                Toggle(String(localized: "Send anonymous crash data", bundle: .iClawCore), isOn: $sendAnonymousCrashData)
                    .onChange(of: sendAnonymousCrashData) { _, enabled in
                        if enabled {
                            MetricsManager.shared.enable()
                        } else {
                            MetricsManager.shared.disable()
                        }
                    }
                Text("Help make iClaw better by sharing anonymous data", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            ttsVoices = SpeechSynthesizer.availableVoices()
            // Reset invalid voice selection to prevent Picker warning
            if !ttsVoiceIdentifier.isEmpty && !ttsVoices.contains(where: { $0.identifier == ttsVoiceIdentifier }) {
                ttsVoiceIdentifier = ""
            }
        }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: String(localized: " (Premium)", bundle: .iClawCore)
        case .enhanced: String(localized: " (Enhanced)", bundle: .iClawCore)
        default: ""
        }
        return "\(voice.name)\(quality)"
    }

    private func generatePlaceholder() async {
        let prompt = """
        Generate a single example personality description for an AI assistant. \
        It should be 10-16 words, vivid and specific. Use a style like: \
        "Warm and encouraging, like a patient mentor who celebrates small wins" or \
        "Laconic and precise, a seasoned expert who values clarity over charm". \
        Be creative and varied — do NOT reuse those examples. Output ONLY the description, no quotes.
        """
        do {
            let result = try await LLMAdapter.shared.generateText(prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty {
                placeholderText = "e.g. \(result)"
            }
        } catch {
            // LLM unavailable — static fallback already in place
        }
    }

    #if os(macOS)
    @MainActor
    private func openSafariExtensionSettings() async {
        let extensionID = "com.geticlaw.iClaw.Extension"
        if let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: safariURL, configuration: config)
            try? await Task.sleep(for: .milliseconds(350))
        }
        do {
            try await SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionID)
        } catch {
            Log.ui.warning("showPreferencesForExtension failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
