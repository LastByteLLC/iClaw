import SwiftUI
import TipKit
#if canImport(AppKit)
import AppKit
#endif

public struct ChatView: View {
    public init() {}

    @State private var chatState = ChatState()
    @State private var scrollProxy: ScrollViewProxy? = nil
    @FocusState private var isSearchFieldFocused: Bool
    @AppStorage(AppConfig.hasAcceptedTOSKey) private var hasAcceptedTOS = false
    @ObservedObject private var speechManager = SpeechManager.shared
    @ObservedObject private var speechSynthesizer = SpeechSynthesizer.shared

    private var messageBus = MessageBus.shared
    private var feedbackBus = FeedbackActionBus.shared

    let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    let phraseTimer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    @State private var isWindowVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        @Bindable var chatState = chatState
        ZStack {
            VStack(spacing: 0) {
                ChatHeaderView(
                    isSearchActive: $chatState.isSearchActive,
                    isSearchFieldFocused: $isSearchFieldFocused,
                    searchManager: chatState.searchManager,
                    skillModeState: chatState.skillModeState,
                    onExitSkillMode: { chatState.exitSkillMode() }
                )

                ChatMessageListView(
                    chatState: chatState,
                    speechSynthesizer: speechSynthesizer,
                    onScrollProxyAvailable: { proxy in scrollProxy = proxy },
                    onSendMessage: { query in
                        chatState.input = query
                        chatState.sendMessage(speechSynthesizer: speechSynthesizer)
                    },
                    onStartReply: { message in chatState.startReply(to: message) },
                    onStartFeedback: { message in chatState.startFeedback(on: message) },
                    onDeleteMessage: { message in chatState.deleteMessage(message) },
                    onRetryMessage: { message in chatState.retryMessage(message, speechSynthesizer: speechSynthesizer) },
                    onToggleBreadcrumb: {
                        withAnimation(.snappy) { chatState.isBreadcrumbExpanded.toggle() }
                    },
                    onHandleEscape: { chatState.handleEscape() }
                )

                if chatState.podcastPlayer.isActive {
                    PodcastPlayerView(player: chatState.podcastPlayer)
                }

                ChatInputView(
                    chatState: chatState,
                    speechManager: speechManager,
                    messageBus: messageBus,
                    onSendMessage: { chatState.sendMessage(speechSynthesizer: speechSynthesizer) },
                    onToggleSearch: {
                        chatState.toggleSearch()
                        if chatState.isSearchActive {
                            isSearchFieldFocused = true
                        } else {
                            isSearchFieldFocused = false
                        }
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FTUETutorialView()

            if let toast = chatState.toastMessage {
                VStack {
                    Spacer()
                    ToastView(icon: "doc.on.clipboard", message: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 80)
                }
                .animation(.snappy, value: chatState.toastMessage)
            }
        }
        .background { hudBackground }
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .thinkingGlow(isActive: chatState.isThinking, cornerRadius: 32)
        .padding(10)
        .modifier(ChatNotificationHandlers(
            chatState: chatState,
            hasAcceptedTOS: $hasAcceptedTOS,
            phraseTimer: phraseTimer,
            feedbackBus: feedbackBus,
            speechSynthesizer: speechSynthesizer
        ))
        .onReceive(NotificationCenter.default.publisher(for: .iClawHUDDidAppear)) { _ in
            isWindowVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .iClawHUDDidDisappear)) { _ in
            isWindowVisible = false
        }
        .environment(\.isHUDVisible, isWindowVisible)
    }

    // MARK: - Background

    @ViewBuilder
    private var hudBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, cornerRadius: 32)

            if #available(macOS 15.0, *) {
                let points: [SIMD2<Float>] = [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.1 * sin(chatState.t), 0.5 + 0.1 * cos(chatState.t)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1]
                ]
                let colors: [Color] = [
                    .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1),
                    .indigo.opacity(0.1), .clear, .indigo.opacity(0.1),
                    .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1)
                ]
                MeshGradient(width: 3, height: 3, points: points, colors: colors)
                .onReceive(timer) { _ in
                    guard isWindowVisible else { return }
                    // Respect Reduce Motion: freeze the mesh-gradient animation.
                    // The thinking-elapsed counter still needs to advance, so
                    // we keep that branch regardless.
                    if !reduceMotion {
                        chatState.t += Float(1.0 / 30.0) * 3
                    }
                    if let start = chatState.thinkingStartTime {
                        let elapsed = Int(Date().timeIntervalSince(start))
                        if elapsed != chatState.thinkingElapsed { chatState.thinkingElapsed = elapsed }
                    }
                }
            }

            if let tint = chatState.skillModeState.tintColor {
                tint.opacity(0.06)
                    .animation(.easeInOut(duration: 0.3), value: chatState.skillModeState.isActive)
            }
        }
    }

    // MARK: - Helpers

    static func shortToolName(_ name: String) -> String {
        var cleaned = name
        if cleaned.hasSuffix("Tool") && cleaned.count > 4 {
            cleaned = String(cleaned.dropLast(4))
        } else if cleaned.hasSuffix(" Tool") {
            cleaned = String(cleaned.dropLast(5))
        }
        let words = cleaned.split(separator: " ", maxSplits: 2)
        if words.count <= 2 { return cleaned }
        return words.prefix(2).joined(separator: " ")
    }

    static func nonAFMModelName() -> String? {
        let config = BackendConfig.current
        guard config.kind != .appleIntelligence else { return nil }
        if LLMAdapter.isUsingAFMFallback { return nil }
        return "Ollama"
    }

    static func toolNameFromWidgetOrProgress(_ widgetType: String?, progressState: ProgressUpdate?) -> String? {
        if let wt = widgetType {
            return ExecutionEngine.widgetToToolMap[wt.lowercased()]
        }
        return nil
    }

    static func parseSuggestions(from response: String) -> (text: String, suggestions: [String]) {
        let lines = response.components(separatedBy: "\n")
        var textLines: [String] = []
        var suggestions: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">>") {
                let suggestion = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !suggestion.isEmpty {
                    suggestions.append(suggestion)
                }
            } else {
                textLines.append(line)
            }
        }

        while textLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            textLines.removeLast()
        }

        return (textLines.joined(separator: "\n"), suggestions)
    }

    static func buildContextualSuggestions(
        isError: Bool,
        toolName: String?,
        existingSuggestions: [String]?
    ) -> [String]? {
        guard existingSuggestions == nil || existingSuggestions?.isEmpty == true else { return nil }

        if isError {
            guard let name = toolName else { return nil }
            let help = ToolHelpProvider.help(for: name)
            var suggestions: [String] = []
            if let example = help?.examples.first {
                suggestions.append(example)
            }
            suggestions.append(String(localized: "help_suggestion_capabilities", bundle: .iClawCore))
            return suggestions
        } else if let name = toolName {
            let usedTools = Set(UserDefaults.standard.stringArray(forKey: "greetingUsedTools") ?? [])
            for category in ToolCategoryRegistry.categories where category.name != "Help" {
                if category.coreToolNames.contains(name) {
                    let used = category.coreToolNames.filter { usedTools.contains($0) }
                    if used.count <= 1 {
                        return [String(localized: "help_suggestion_explore_category \(category.name)", bundle: .iClawCore)]
                    }
                    break
                }
            }
        }
        return nil
    }
}
