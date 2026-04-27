import SwiftUI
import TipKit
#if canImport(AppKit)
import AppKit
#endif

/// The input field area including text input, send button, attachment handling,
/// paste suggestions, chip autocomplete, recording UI, and keyboard shortcuts.
struct ChatInputView: View {
    @Bindable var chatState: ChatState

    @ObservedObject var speechManager: SpeechManager
    var messageBus: MessageBus

    @AppStorage(AppConfig.textSizePreferenceKey) private var textSizePreference: TextSizePreference = .default

    var onSendMessage: () -> Void
    var onToggleSearch: () -> Void

    // User-facing tools for chip autocomplete (internal + hidden tools excluded)
    private let availableTools: [any CoreTool] = ToolRegistry.coreTools.filter {
        !$0.isInternal && ToolManifest.showsInUI(for: $0.name)
    }

    /// Category chip suggestions for `#` autocomplete, excluding fully-disabled categories.
    private let availableCategories: [ToolCategory] = {
        let disabled = ToolRegistry.loadDisabledToolNamesPublic()
        if disabled.isEmpty { return ToolCategoryRegistry.categories }
        return ToolCategoryRegistry.categories.filter { cat in
            cat.coreToolNames.contains(where: { !disabled.contains($0) })
        }
    }()

    @State private var suggestedTools: [any CoreTool] = []
    @State private var suggestedCategories: [ToolCategory] = []
    @State private var suggestedTickers: [TickerEntry] = []
    @State private var cachedStarterPrompts: [(label: String, prompt: String)]?
    @State private var selectedToolIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Suggestion tooltips (above divider, matching original layout)
            if !suggestedCategories.isEmpty {
                categorySuggestionTooltip
                    .transition(AnyTransition.move(edge: Edge.bottom).combined(with: AnyTransition.opacity))
                    .padding(.bottom, 8)
            } else if !suggestedTools.isEmpty {
                toolSuggestionTooltip
                    .transition(AnyTransition.move(edge: Edge.bottom).combined(with: AnyTransition.opacity))
                    .padding(.bottom, 8)
            } else if !suggestedTickers.isEmpty {
                tickerSuggestionTooltip
                    .transition(AnyTransition.move(edge: Edge.bottom).combined(with: AnyTransition.opacity))
                    .padding(.bottom, 8)
            } else if !chatState.attachmentSuggestions.isEmpty {
                attachmentSuggestionChips
                    .transition(AnyTransition.move(edge: Edge.bottom).combined(with: AnyTransition.opacity))
                    .padding(.bottom, 8)
            } else if showStarterPrompts {
                starterPromptChips
                    .transition(AnyTransition.move(edge: Edge.bottom).combined(with: AnyTransition.opacity))
                    .padding(.bottom, 8)
            }

            Divider()
                .background(.white.opacity(0.1))

            // Reply preview banner
            if let reply = chatState.replyContext {
                replyBanner(reply)
            }

            // Feedback preview banner
            if chatState.feedbackContext != nil {
                feedbackBanner
            }

            // Attachment preview banner
            if !chatState.attachedFiles.isEmpty {
                attachmentBanner
            }

            // Browser context pill — shows when extension pushed page content
            #if os(macOS)
            if let title = chatState.browserContextTitle {
                browserContextBanner(title)
            }
            #endif

            // Context pill — shows prior tool context for follow-up detection
            if chatState.contextPillState.isVisible {
                HStack {
                    ContextPillView(state: chatState.contextPillState)
                        .popoverTip(ContextPillTip())
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            if speechManager.isRecording {
                recordingView
            } else {
                // iMessage-style floating input bar
                inputBar
            }

            // Hidden Escape key handler
            Button("") { chatState.handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            // Hidden Cmd+V paste handler
            Button("") { handlePaste() }
                .keyboardShortcut("v", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)

            // Hidden Cmd+F search handler
            Button("") { toggleSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // These handlers live outside the if/else so they fire reliably
        // even when SwiftUI tears down the recording view.
        .onChange(of: speechManager.isRecording) { _, recording in
            if !recording {
                chatState.confirmRecording(speechManager: speechManager)
                #if canImport(AppKit)
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [.announcement: String(localized: "Recording stopped", bundle: .iClawCore)]
                )
                #endif
            } else {
                #if canImport(AppKit)
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [.announcement: String(localized: "Recording. Speak now.", bundle: .iClawCore)]
                )
                #endif
            }
        }
        .onChange(of: messageBus.pending.count) { _, _ in
            let newMessages = messageBus.pending
            messageBus.pending.removeAll()
            chatState.messages.append(contentsOf: newMessages)
        }
    }

    // MARK: - Reply Banner

    private func replyBanner(_ reply: ReplyContext) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.blue.opacity(0.6))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to", bundle: .iClawCore)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(reply.agentMessage.content)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
                    .lineLimit(2)
            }

            Spacer()

            Button {
                withAnimation(.quick) {
                    chatState.replyContext = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss reply", bundle: .iClawCore))
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        // Prevent the Shape (RoundedRectangle) from making this banner layout-flexible.
        // Without this, the VStack parent distributes extra height to flexible children,
        // causing the banner to expand far beyond its text content.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.05))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Feedback Banner

    private var feedbackBanner: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.orange.opacity(0.6))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Giving feedback", bundle: .iClawCore)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Type your feedback and send", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.7))
            }

            Spacer()

            Button {
                withAnimation(.quick) {
                    chatState.feedbackContext = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Dismiss feedback", bundle: .iClawCore))
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.05))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Attachment Banner

    private var attachmentBanner: some View {
        VStack(spacing: 0) {
            ForEach(chatState.attachedFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: FileAttachment.icon(for: file.fileCategory))
                        .font(.system(size: 11))
                        .foregroundStyle(.purple)

                    MarqueeText(text: file.fileName, font: .caption)
                        .foregroundStyle(.primary.opacity(0.7))

                    Spacer(minLength: 4)

                    Button {
                        removeAttachment(file)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove \(file.fileName)", bundle: .iClawCore))
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 2)
        .background(.purple.opacity(0.05))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Browser Context Banner

    #if os(macOS)
    private func browserContextBanner(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.blue)

            Text(title)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button {
                Task { await BrowserBridge.shared.clearBrowserContext() }
                withAnimation { chatState.browserContextTitle = nil }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(.blue.opacity(0.05))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Browser context: \(title)", bundle: .iClawCore))
        .accessibilityHint(String(localized: "Activate to remove browser context", bundle: .iClawCore))
    }
    #endif

    // MARK: - Recording View

    private var recordingView: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Text(speechManager.transcription)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
                    .truncationMode(.head)

                if speechManager.transcription.count > 120 {
                    Text("...")
                        .font(.body.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .background(.black.opacity(0.4))
                }
            }

            HStack(spacing: 12) {
                AudioWaveformView(time: chatState.t)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)

                Button {
                    chatState.confirmRecording(speechManager: speechManager)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Stop recording", bundle: .iClawCore))
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.black.opacity(0.2))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            // "+" button (replaces paperclip attachment)
            Button {
                openFilePicker()
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(!chatState.attachedFiles.isEmpty ? .purple : .primary)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Attach file", bundle: .iClawCore))
            .disabled(chatState.isThinking)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

            // Floating input pill
            HStack(spacing: 8) {
                TextField(String(localized: "Message iClaw...", bundle: .iClawCore), text: $chatState.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: textSizePreference.chatFontSize))
                    .lineLimit(1...5)
                    .popoverTip(ChipDiscoveryTip())
                    .onChange(of: chatState.input) { _, newValue in
                        chatState.contextPillState.onInputChanged(newValue)
                        updateAutocompleteSuggestions(newValue)
                    }
                    .onKeyPress(.tab) {
                        if !suggestedCategories.isEmpty {
                            let idx = min(selectedToolIndex, suggestedCategories.count - 1)
                            autocompleteCategory(suggestedCategories[idx])
                            return .handled
                        } else if !suggestedTools.isEmpty {
                            let idx = min(selectedToolIndex, suggestedTools.count - 1)
                            autocompleteTool(suggestedTools[idx])
                            return .handled
                        } else if !suggestedTickers.isEmpty {
                            let idx = min(selectedToolIndex, suggestedTickers.count - 1)
                            autocompleteTicker(suggestedTickers[idx])
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.downArrow) {
                        let count = max(suggestedCategories.count, max(suggestedTools.count, suggestedTickers.count))
                        guard count > 0 else { return .ignored }
                        selectedToolIndex = min(selectedToolIndex + 1, count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        let count = max(suggestedCategories.count, max(suggestedTools.count, suggestedTickers.count))
                        if count > 0 {
                            selectedToolIndex = max(selectedToolIndex - 1, 0)
                            return .handled
                        }
                        if chatState.input.isEmpty && !chatState.previousInput.isEmpty {
                            chatState.input = chatState.previousInput
                            return .handled
                        }
                        return .ignored
                    }
                    .onSubmit {
                        if !suggestedTools.isEmpty {
                            let idx = min(selectedToolIndex, suggestedTools.count - 1)
                            autocompleteTool(suggestedTools[idx])
                        } else if !suggestedTickers.isEmpty {
                            let idx = min(selectedToolIndex, suggestedTickers.count - 1)
                            autocompleteTicker(suggestedTickers[idx])
                        } else {
                            onSendMessage()
                        }
                    }

                // Waveform mic button (inside the pill, right side)
                if speechManager.isSpeechAvailable {
                    Button {
                        speechManager.startRecording()
                        Task { await TipDonations.donateMicUsed() }
                    } label: {
                        Image(systemName: "waveform")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Voice input", bundle: .iClawCore))
                    .disabled(chatState.isThinking)
                    .popoverTip(MicDiscoveryTip())
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Hidden return-key submit
        .background {
            Button("") { onSendMessage() }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    // MARK: - Autocomplete Logic

    private func updateAutocompleteSuggestions(_ newValue: String) {
        let words = newValue.components(separatedBy: .whitespaces)
        if let lastWord = words.last, lastWord.hasPrefix("#") {
            TipDonations.donateChipTyped()
            let prefix = lastWord.dropFirst().lowercased()
            // Suggest categories first (primary chip + aliases)
            suggestedCategories = availableCategories.filter { cat in
                cat.chipName.hasPrefix(prefix)
                || cat.name.lowercased().hasPrefix(prefix)
                || cat.chipAliases.contains(where: { $0.hasPrefix(prefix) })
            }
            // Fall back to individual tools only if no category matched
            if suggestedCategories.isEmpty {
                suggestedTools = availableTools.filter { tool in
                    let chipName = ToolManifest.entry(for: tool.name)?.chipName?.lowercased()
                        ?? tool.name.lowercased().replacingOccurrences(of: " ", with: "_")
                    return chipName.hasPrefix(prefix) || tool.name.lowercased().hasPrefix(prefix)
                }
            } else {
                suggestedTools = []
            }
            suggestedTickers = []
            selectedToolIndex = 0
        } else if let lastWord = words.last, lastWord.hasPrefix("$"), lastWord.count >= 2 {
            let prefix = String(lastWord.dropFirst())
            suggestedTickers = TickerLookup.search(prefix: prefix)
            suggestedTools = []
            selectedToolIndex = 0
        } else {
            suggestedTools = []
            suggestedCategories = []
            suggestedTickers = []
            selectedToolIndex = 0
        }
    }

    // MARK: - Category Suggestions

    private var categorySuggestionTooltip: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestedCategories.enumerated()), id: \.element.chipName) { index, category in
                Button {
                    autocompleteCategory(category)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: category.icon)
                            .font(.caption2)
                            .foregroundStyle(.purple)

                        Text(category.name)
                            .font(.callout)
                            .foregroundStyle(.primary)

                        Text("#\(category.chipName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedToolIndex ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(6)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        .frame(width: 200)
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tool category suggestions", bundle: .iClawCore))
        .accessibilityAddTraits(.isModal)
    }

    private func autocompleteCategory(_ category: ToolCategory) {
        var words = chatState.input.components(separatedBy: .whitespaces)
        guard words.last?.hasPrefix("#") == true else { return }

        words[words.count - 1] = "#" + category.chipName + " "
        chatState.input = words.joined(separator: " ")
        suggestedCategories = []
    }

    // MARK: - Tool Suggestions

    private var toolSuggestionTooltip: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestedTools.enumerated()), id: \.element.name) { index, tool in
                Button {
                    autocompleteTool(tool)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "number")
                            .font(.caption2)
                            .foregroundStyle(.purple)

                        Text((ToolManifest.entry(for: tool.name)?.chipName ?? tool.name).capitalized)
                            .font(.callout)
                            .foregroundStyle(.primary)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedToolIndex ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(6)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        .frame(width: 200)
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tool suggestions", bundle: .iClawCore))
        .accessibilityAddTraits(.isModal)
    }

    private func autocompleteTool(_ tool: any CoreTool) {
        var words = chatState.input.components(separatedBy: .whitespaces)
        guard words.last?.hasPrefix("#") == true else { return }

        let chipName = ToolManifest.entry(for: tool.name)?.chipName?.lowercased()
            ?? tool.name.lowercased().replacingOccurrences(of: " ", with: "_")
        words[words.count - 1] = "#" + chipName + " "
        chatState.input = words.joined(separator: " ")
        suggestedTools = []
    }

    // MARK: - Ticker Suggestions

    private var tickerSuggestionTooltip: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(suggestedTickers.enumerated()), id: \.element.symbol) { index, ticker in
                Button {
                    autocompleteTicker(ticker)
                } label: {
                    HStack(spacing: 8) {
                        Text("$")
                            .font(.caption2.bold())
                            .foregroundStyle(.green)

                        Text(ticker.symbol)
                            .font(.callout.bold())
                            .foregroundStyle(.primary)

                        Text(ticker.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedToolIndex ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(6)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.15), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        .frame(width: 280)
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Ticker suggestions", bundle: .iClawCore))
        .accessibilityAddTraits(.isModal)
    }

    private func autocompleteTicker(_ ticker: TickerEntry) {
        // Replace the $PREFIX with #stocks SYMBOL — auto-selects StockTool
        var words = chatState.input.components(separatedBy: .whitespaces)
        guard words.last?.hasPrefix("$") == true else { return }
        words[words.count - 1] = "#stocks \(ticker.symbol)"
        chatState.input = words.joined(separator: " ")
        suggestedTickers = []
    }

    // MARK: - Attachment Suggestions

    private var attachmentSuggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(chatState.attachmentSuggestions.enumerated()), id: \.element.label) { _, suggestion in
                    Button {
                        chatState.input = suggestion.prompt
                    } label: {
                        Text(suggestion.label)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.purple.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Starter Prompts

    /// Show starter prompts when the conversation has no user messages and input is empty.
    private var showStarterPrompts: Bool {
        chatState.input.isEmpty
        && chatState.messages.filter({ $0.role == "user" }).isEmpty
        && chatState.attachedFiles.isEmpty
    }



    /// Generates starter prompts by drawing from the full ToolHelp.json example pool,
    /// with slot-filling for varied cities/tickers/topics. Computed once and cached.
    private func generateStarterPrompts() -> [(label: String, prompt: String)] {
        let disabledTools = ToolRegistry.loadDisabledToolNamesPublic()

        // Build a large candidate pool from ToolHelp.json examples + slot-filled variants
        var pool: [(label: String, prompt: String, toolName: String)] = []

        // Slot-filling pools
        let cities = ["London", "Tokyo", "Paris", "Berlin", "Sydney", "Seoul", "Toronto", "Rome", "Mumbai", "Cairo"]
        let tickers = ["AAPL", "TSLA", "MSFT", "GOOG", "AMZN", "NFLX", "META", "NVDA"]
        let wikiTopics = ["Alan Turing", "black holes", "photosynthesis", "the Roman Empire", "Marie Curie", "the Silk Road", "DNA", "quantum mechanics"]
        let translatePhrases = [
            ("hello", "Japanese"), ("thank you", "French"), ("good morning", "Spanish"),
            ("goodbye", "Korean"), ("how are you", "Italian"), ("welcome", "German"),
            ("I love you", "Portuguese"), ("cheers", "Mandarin"),
        ]
        let defineWords = ["serendipity", "ephemeral", "ubiquitous", "petrichor", "sonder", "mellifluous", "luminous", "cascade"]
        let newsTopics = ["latest tech news", "AI news today", "science headlines", "space news", "world news"]
        let mathExamples = ["15% tip on $86", "sqrt(144) + 3^2", "72°F to celsius", "sin(45 degrees)", "5 miles to km", "100 USD to EUR"]

        // Weather — slot-fill cities
        if !disabledTools.contains("Weather") {
            let c = cities.randomElement()!
            pool.append(("☀️ " + c, "weather in \(c)", "Weather"))
            pool.append(("🌅 " + String(localized: "starter_sunrise", bundle: .iClawCore), "sunrise today", "Weather"))
        }

        // Time — slot-fill cities
        if !disabledTools.contains("Time") {
            let c = cities.randomElement()!
            pool.append(("🕐 " + c, "time in \(c)", "Time"))
            pool.append(("⏱️ " + String(localized: "starter_timer", bundle: .iClawCore), "set a 5 minute timer", "Time"))
        }

        // Stocks — slot-fill tickers
        if !disabledTools.contains("Stocks") {
            let t = tickers.randomElement()!
            pool.append(("📈 $\(t)", "$\(t)", "Stocks"))
        }

        // Calculator/Convert — slot-fill math
        if !disabledTools.contains("Calculator") || !disabledTools.contains("Convert") {
            let m = mathExamples.randomElement()!
            pool.append(("🧮 " + String(localized: "starter_math_label", bundle: .iClawCore), m, "Calculator"))
        }

        // News — slot-fill topics
        if !disabledTools.contains("News") {
            let n = newsTopics.randomElement()!
            pool.append(("📰 " + String(localized: "starter_news", bundle: .iClawCore), n, "News"))
        }

        // Translate — slot-fill phrase + language
        if !disabledTools.contains("Translate") {
            let (phrase, lang) = translatePhrases.randomElement()!
            pool.append(("🌐 " + String(localized: "starter_translate_label", bundle: .iClawCore), "translate \(phrase) to \(lang)", "Translate"))
        }

        // Dictionary — slot-fill words
        if !disabledTools.contains("Dictionary") {
            let w = defineWords.randomElement()!
            pool.append(("📖 " + String(localized: "starter_define_label", bundle: .iClawCore), "define \(w)", "Dictionary"))
        }

        // Wikipedia — slot-fill topics
        if !disabledTools.contains("WikipediaSearch") {
            let t = wikiTopics.randomElement()!
            pool.append(("📚 " + t, "wiki \(t)", "WikipediaSearch"))
        }

        // Random
        if !disabledTools.contains("Random") {
            let randomExamples = ["flip a coin", "roll 2d6", "random number 1 to 100", "pick a card"]
            pool.append(("🎲 " + String(localized: "starter_random", bundle: .iClawCore), randomExamples.randomElement()!, "Random"))
        }

        // Calendar
        if !disabledTools.contains("Calendar") {
            pool.append(("📅 " + String(localized: "starter_calendar", bundle: .iClawCore), "what's on my calendar?", "Calendar"))
        }

        // Today
        if !disabledTools.contains("Today") {
            pool.append(("📋 " + String(localized: "starter_today", bundle: .iClawCore), "today", "Today"))
        }

        // SystemInfo
        if !disabledTools.contains("SystemInfo") {
            let sysExamples = ["battery status", "how much storage do I have", "what macOS am I running"]
            pool.append(("💻 " + String(localized: "starter_system", bundle: .iClawCore), sysExamples.randomElement()!, "SystemInfo"))
        }

        // Podcast
        if !disabledTools.contains("Podcast") {
            pool.append(("🎙️ " + String(localized: "starter_podcast", bundle: .iClawCore), "find podcasts about technology", "Podcast"))
        }

        guard !pool.isEmpty else { return [] }

        // Shuffle and pick 3, preferring different tools
        pool.shuffle()
        var selected: [(label: String, prompt: String)] = []
        var usedToolNames: Set<String> = []
        for candidate in pool {
            if usedToolNames.contains(candidate.toolName) { continue }
            selected.append((label: candidate.label, prompt: candidate.prompt))
            usedToolNames.insert(candidate.toolName)
            if selected.count >= 3 { break }
        }

        return selected
    }

    private var starterPromptChips: some View {
        let prompts = cachedStarterPrompts ?? []
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(prompts.enumerated()), id: \.element.label) { _, suggestion in
                    Button {
                        chatState.input = suggestion.prompt
                    } label: {
                        Text(suggestion.label)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.tint.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(suggestion.label))
                    .accessibilityHint(Text("starter_hint", bundle: .iClawCore))
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            if cachedStarterPrompts == nil {
                cachedStarterPrompts = generateStarterPrompts()
            }
        }
    }

    // MARK: - File Picker

    private func openFilePicker() {
        #if canImport(AppKit)
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = String(localized: "Choose a file or folder to attach", bundle: .iClawCore)

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                let attachment = FileAttachment(url: url)
                withAnimation(.quick) {
                    self.chatState.attachedFiles.append(attachment)
                    let profile = FileAttachment.analyzeContent(url: attachment.url, category: attachment.fileCategory)
                    self.chatState.attachmentSuggestions = FileAttachment.suggestions(for: attachment.fileCategory, profile: profile)
                }
            }
        }
        #else
        // iOS: use UIDocumentPickerViewController via a sheet (placeholder — not yet wired)
        #endif
    }

    // MARK: - Paste Handling

    private func handlePaste() {
        let result = PasteboardClassifier.classify()
        switch result {
        case .inline(let text):
            chatState.input += text
        case .attachment(let data, let category, let ext):
            let hash = PasteboardClassifier.hashPrefix(data)
            if chatState.pastedHashes.contains(hash) {
                showToast(String(localized: "Already pasted", bundle: .iClawCore))
                return
            }
            chatState.pastedHashes.insert(hash)
            chatState.pasteSequence += 1
            if let attachment = FileAttachment(pastedData: data, category: category, sequence: chatState.pasteSequence, ext: ext, hash: hash) {
                withAnimation(.quick) {
                    chatState.attachedFiles.append(attachment)
                    let profile = FileAttachment.analyzeContent(url: attachment.url, category: attachment.fileCategory)
                    chatState.attachmentSuggestions = FileAttachment.suggestions(for: attachment.fileCategory, profile: profile)
                }
                Task { await TipDonations.donateFilesPasted() }
            }
        case .empty:
            break
        }
    }

    private func removeAttachment(_ file: FileAttachment) {
        withAnimation(.quick) {
            chatState.attachedFiles.removeAll { $0.id == file.id }
            if let hash = file.pasteHash {
                chatState.pastedHashes.remove(hash)
            }
            if chatState.attachedFiles.isEmpty {
                chatState.attachmentSuggestions = []
            } else if let last = chatState.attachedFiles.last {
                let profile = FileAttachment.analyzeContent(url: last.url, category: last.fileCategory)
                chatState.attachmentSuggestions = FileAttachment.suggestions(for: last.fileCategory, profile: profile)
            }
        }
    }

    // MARK: - Helpers

    private func showToast(_ message: String) {
        withAnimation { chatState.toastMessage = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { chatState.toastMessage = nil }
        }
    }

    private func toggleSearch() {
        onToggleSearch()
    }
}
