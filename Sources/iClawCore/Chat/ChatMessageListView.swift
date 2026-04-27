import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct ChatMessageListView: View {
    var chatState: ChatState
    @ObservedObject var speechSynthesizer: SpeechSynthesizer

    @AppStorage(AppConfig.textSizePreferenceKey) private var textSizePreference: TextSizePreference = .default

    var onScrollProxyAvailable: (ScrollViewProxy) -> Void
    var onSendMessage: (String) -> Void
    var onStartReply: (Message) -> Void
    var onStartFeedback: (Message) -> Void
    var onDeleteMessage: (Message) -> Void
    var onRetryMessage: (Message) -> Void
    var onToggleBreadcrumb: () -> Void
    var onHandleEscape: () -> Void

    @State private var retryTarget: Message?
    @State private var showRetryConfirmation = false

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    if chatState.isSearchActive {
                        searchResultsList
                    } else {
                        conversationList(containerWidth: geo.size.width)
                    }
                }
                .onAppear { onScrollProxyAvailable(proxy) }
                .onReceive(NotificationCenter.default.publisher(for: .iClawNavigateToMessage)) { notification in
                    if let targetID = notification.object as? UUID {
                        withAnimation {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
                .onChange(of: chatState.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatState.isThinking) { _, thinking in
                    if thinking {
                        scrollToBottom(proxy: proxy)
                    }
                }
            }
        }
    }

    // MARK: - Scroll

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.2)) {
                if chatState.isThinking {
                    proxy.scrollTo("thinking-indicator", anchor: .bottom)
                } else if let lastID = chatState.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Search Results

    private var searchResultsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if chatState.searchManager.searchResults.isEmpty && !chatState.searchManager.isSearching
                && !chatState.searchManager.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 60)
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(String(format: String(localized: "No matches for \"%@\"", bundle: .iClawCore),
                                chatState.searchManager.searchQuery))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "Clear search", bundle: .iClawCore)) {
                        chatState.searchManager.searchQuery = ""
                        chatState.isSearchActive = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ForEach(chatState.searchManager.searchResults) { result in
                    SearchResultView(result: result)
                }

                if chatState.searchManager.hasMoreResults && !chatState.searchManager.searchResults.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .onAppear {
                            chatState.searchManager.loadMore()
                        }
                }
            }
        }
        .padding(24)
    }

    // MARK: - Conversation List

    private func conversationList(containerWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if chatState.hasMoreHistory {
                Button {
                    Task { await loadEarlierMessages() }
                } label: {
                    HStack(spacing: 6) {
                        if chatState.isLoadingHistory {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption2)
                        }
                        Text("Show earlier messages", bundle: .iClawCore)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .disabled(chatState.isLoadingHistory)
            } else if chatState.oldestLoadedMemoryID != nil {
                Text("That's everything.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }

            ForEach(chatState.messages) { message in
                if chatState.dismissedMessageIDs.contains(message.id) {
                    EmptyView()
                } else if message.isModeSummary {
                    if chatState.expandedModeGroup != message.modeGroupId {
                        ModeSummaryBubble(
                            message: message,
                            isExpanded: false,
                            onToggle: {
                                withAnimation(.snappy) {
                                    chatState.expandedModeGroup = message.modeGroupId
                                }
                            },
                            onDelete: {
                                if let gid = message.modeGroupId {
                                    chatState.messages.removeAll { $0.modeGroupId == gid }
                                    chatState.completedModeGroups.remove(gid)
                                    if chatState.expandedModeGroup == gid { chatState.expandedModeGroup = nil }
                                }
                            }
                        )
                    } else {
                        ModeSummaryBubble(
                            message: message,
                            isExpanded: true,
                            onToggle: {
                                withAnimation(.snappy) {
                                    chatState.expandedModeGroup = nil
                                }
                            },
                            onDelete: {
                                if let gid = message.modeGroupId {
                                    chatState.messages.removeAll { $0.modeGroupId == gid }
                                    chatState.completedModeGroups.remove(gid)
                                    chatState.expandedModeGroup = nil
                                }
                            }
                        )
                    }
                } else if let gid = message.modeGroupId, chatState.completedModeGroups.contains(gid) {
                    if chatState.expandedModeGroup == gid {
                        messageRow(message, containerWidth: containerWidth)
                    }
                } else if chatState.expandedModeGroup != nil, message.modeGroupId == nil {
                    EmptyView()
                } else {
                    let isGhosted = chatState.replyContext != nil && (message.id == chatState.replyContext!.userMessage.id || message.id == chatState.replyContext!.agentMessage.id)

                    messageRow(message, containerWidth: containerWidth)
                        .opacity(isGhosted ? 0.35 : 1.0)
                }
            }

            if chatState.isThinking {
                thinkingIndicator
            }
        }
        .padding(24)
    }

    // MARK: - Thinking Indicator

    private var currentStageName: String? {
        guard let state = chatState.progressState else { return nil }
        switch state {
        case .routing: return String(localized: "Routing", bundle: .iClawCore)
        case .executing(let tool, _, _): return ChatView.shortToolName(tool)
        case .retrying: return String(localized: "Retry", bundle: .iClawCore)
        case .processing: return String(localized: "Processing", bundle: .iClawCore)
        case .finalizing: return String(localized: "Finishing", bundle: .iClawCore)
        case .planning: return String(localized: "Planning", bundle: .iClawCore)
        case .planStep(_, _, let tool): return ChatView.shortToolName(tool)
        case .chaining(_, let to): return ChatView.shortToolName(to)
        case .reactIteration: return String(localized: "Checking", bundle: .iClawCore)
        case .performance: return nil
        }
    }

    private var progressText: String {
        guard let state = chatState.progressState else { return chatState.thinkingPhrase }
        switch state {
        case .routing:
            return String(localized: "Thinking...", bundle: .iClawCore)
        case .executing(let toolName, let step, let total):
            return total > 1 ? String(localized: "Running \(toolName)... (\(step)/\(total))", bundle: .iClawCore) : String(localized: "Running \(toolName)...", bundle: .iClawCore)
        case .retrying(let toolName, _):
            return String(localized: "Retrying \(toolName)...", bundle: .iClawCore)
        case .processing(let description):
            return description
        case .finalizing:
            return chatState.thinkingPhrase
        case .reactIteration(let current, let total):
            return String(localized: "Step \(current) of \(total)...", bundle: .iClawCore)
        case .planning:
            return String(localized: "Planning steps...", bundle: .iClawCore)
        case .planStep(let current, let total, let toolName):
            return String(localized: "Step \(current)/\(total): \(toolName)...", bundle: .iClawCore)
        case .chaining(_, let toTool):
            return String(localized: "Chaining to \(toTool)...", bundle: .iClawCore)
        case .performance:
            return chatState.thinkingPhrase
        }
    }

    private var thinkingIndicator: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(.primary.opacity(0.1))
                .frame(width: 32, height: 32)
                .overlay {
                    if BackendConfig.current.kind == .ollama && !LLMAdapter.isUsingAFMFallback {
                        OllamaIcon.image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("iClaw", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        onHandleEscape()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(.white.opacity(0.08))
                            .clipShape(Circle())
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Stop", bundle: .iClawCore))
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ThinkingDotsView(time: chatState.t)

                    HStack {
                        Text(progressText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        Spacer()
                        Text("\(chatState.thinkingElapsed)s")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }

                    if let currentStage = currentStageName {
                        VStack(alignment: .leading, spacing: 2) {
                            if chatState.isBreadcrumbExpanded {
                                BreadcrumbFlowLayout(spacing: 3) {
                                    ForEach(Array(chatState.stageHistory.enumerated()), id: \.offset) { idx, stage in
                                        HStack(spacing: 3) {
                                            if idx > 0 {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 7))
                                                    .foregroundStyle(.quaternary)
                                            }
                                            Text(stage)
                                                .font(.caption2)
                                                .foregroundStyle(stage == currentStage ? .secondary : .tertiary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            } else {
                                Text(currentStage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .transition(.push(from: .trailing))
                            }

                            if chatState.stageHistory.count > 1 {
                                HStack {
                                    Spacer()
                                    Button {
                                        onToggleBreadcrumb()
                                    } label: {
                                        Image(systemName: chatState.isBreadcrumbExpanded ? "chevron.up" : "chevron.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(chatState.isBreadcrumbExpanded ? String(localized: "Collapse stages", bundle: .iClawCore) : String(localized: "Expand stages", bundle: .iClawCore))
                                }
                            }
                        }
                    }
                }
                .padding(12)
                .background(.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .frame(maxWidth: 280)
        }
        .id("thinking-indicator")
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ message: Message, containerWidth: CGFloat) -> some View {
        let isUser = message.role == "user"
        let maxBubbleWidth = containerWidth * 0.8

        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 0) }

            HStack(alignment: .top, spacing: 12) {
                if !isUser {
                    messageAvatar(message)
                }

                VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                    messageHeader(message)
                    replyQuote(for: message)
                    messageBody(message)

                    if let suggestions = message.suggestedQueries, !suggestions.isEmpty {
                        ModeSuggestionPills(
                            suggestions: suggestions,
                            tintColor: message.modeGroupId != nil
                                ? (chatState.skillModeState.tintColor ?? .accentColor)
                                : .accentColor
                        ) { query in
                            onSendMessage(query)
                        }
                    }

                    if message.role == "agent" && !message.isError && !message.isGreeting {
                        Button {
                            onStartReply(message)
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                        .accessibilityLabel(String(localized: "Reply", bundle: .iClawCore))
                        .help(String(localized: "Reply to this message", bundle: .iClawCore))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 0) }
        }
        .contextMenu {
            Button {
                ClipboardHelper.copy(message.content)
            } label: {
                Label(String(localized: "Copy", bundle: .iClawCore), systemImage: "doc.on.doc")
            }

            if !message.isError && !message.isGreeting {
                Button {
                    onStartReply(message)
                } label: {
                    Label(String(localized: "Reply", bundle: .iClawCore), systemImage: "arrowshape.turn.up.left")
                }
            }

            if message.role == "agent" && !message.isError && !message.isGreeting {
                Button {
                    onStartFeedback(message)
                } label: {
                    Label(String(localized: "Feedback", bundle: .iClawCore), systemImage: "exclamationmark.bubble")
                }
            }

            if message.isError, message.originalInput != nil {
                Button {
                    retryTarget = message
                    showRetryConfirmation = true
                } label: {
                    Label(String(localized: "Retry", bundle: .iClawCore), systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button(role: .destructive) {
                onDeleteMessage(message)
            } label: {
                Label(String(localized: "Delete", bundle: .iClawCore), systemImage: "trash")
            }
        }
        .confirmationDialog(String(localized: "Retry this request?", bundle: .iClawCore), isPresented: $showRetryConfirmation) {
            Button(String(localized: "Retry", bundle: .iClawCore)) {
                if let msg = retryTarget { onRetryMessage(msg) }
                retryTarget = nil
            }
            Button(String(localized: "Cancel", bundle: .iClawCore), role: .cancel) { retryTarget = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(message.role == "user" ? "You said" : "iClaw said"): \(message.content)"))
        .accessibilityAction(named: Text("Copy", bundle: .iClawCore)) {
            ClipboardHelper.copy(message.content)
        }
        .accessibilityActions {
            if !message.isError && !message.isGreeting {
                Button(String(localized: "Reply", bundle: .iClawCore)) { onStartReply(message) }
            }
            if message.role == "agent" && !message.isError && !message.isGreeting {
                Button(String(localized: "Feedback", bundle: .iClawCore)) { onStartFeedback(message) }
            }
            if message.isError, message.originalInput != nil {
                Button(String(localized: "Retry", bundle: .iClawCore)) {
                    retryTarget = message
                    showRetryConfirmation = true
                }
            }
            Button(String(localized: "Delete", bundle: .iClawCore), role: .destructive) {
                onDeleteMessage(message)
            }
        }
    }

    // MARK: - Message Parts

    private func messageAvatar(_ message: Message) -> some View {
        let isOllama = message.modelName != nil && message.role != "user"
        let iconName: String = message.isError
            ? "exclamationmark.triangle.fill"
            : (message.source == "imessage" ? "message.fill" : (message.role == "user" ? "person.fill" : "sparkles"))
        let fillColor: Color = message.isError ? .red.opacity(0.2) : (message.source == "imessage" ? .green.opacity(0.2) : .primary.opacity(0.1))
        let iconColor: Color = message.isError ? .red : (message.source == "imessage" ? .green : .primary)

        return Circle()
            .fill(fillColor)
            .frame(width: 32, height: 32)
            .overlay {
                if isOllama {
                    OllamaIcon.image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(iconColor)
                } else {
                    Image(systemName: iconName)
                        .font(.caption2)
                        .foregroundStyle(iconColor)
                }
            }
            .accessibilityHidden(true)
    }

    private func messageHeader(_ message: Message) -> some View {
        let label: String
        let color: Color

        if message.source == "imessage" {
            label = message.role == "user" ? String(localized: "iMessage", bundle: .iClawCore) : String(localized: "iClaw", bundle: .iClawCore)
            color = message.isError ? .red : .green
        } else {
            label = message.role == "user" ? String(localized: "You", bundle: .iClawCore) : String(localized: "iClaw", bundle: .iClawCore)
            color = message.isError ? .red : .secondary
        }

        return HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(color)
            if message.modelName != nil, message.role != "user" {
                Text("Ollama")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func replyQuote(for message: Message) -> some View {
        if let replyID = message.replyToID,
           let original = chatState.messages.first(where: { $0.id == replyID }) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.blue.opacity(0.5))
                    .frame(width: 2.5)

                replyQuoteContent(for: original)
            }
            .frame(maxHeight: 36)
            .clipped()
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(.blue.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private func replyQuoteContent(for original: Message) -> some View {
        let preview: (icon: String, text: String)? = {
            guard let widgetType = original.widgetType, let data = original.widgetData else { return nil }
            switch widgetType {
            case "MathWidget":
                if let d = data as? CalculationWidgetData { return ("function", "\(d.expression) = \(d.result)") }
            case "WeatherWidget":
                return ("cloud.sun", String(original.content.prefix(60)))
            case "StockWidget":
                return ("chart.line.uptrend.xyaxis", String(original.content.prefix(60)))
            case "NewsWidget":
                return ("newspaper", String(original.content.prefix(60)))
            case "MapWidget":
                return ("map", String(original.content.prefix(60)))
            case "TimerWidget":
                return ("timer", String(original.content.prefix(60)))
            case "PodcastEpisodesWidget", "PodcastSearchWidget":
                return ("headphones", String(original.content.prefix(60)))
            default:
                break
            }
            return nil
        }()

        if let preview {
            HStack(spacing: 4) {
                Image(systemName: preview.icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(preview.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text(original.content)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: - Message Body

    @ViewBuilder
    private func messageBody(_ message: Message) -> some View {
        if message.content.contains("PHOTO_CAPTURED:"),
           let capturedPart = message.content.split(separator: "PHOTO_CAPTURED:", maxSplits: 1).last,
           let path = capturedPart.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces),
           let image = PlatformImage(contentsOfFile: String(path)) {
            photoBubble(message: message, path: String(path), image: image)
        } else if let widgetType = message.widgetType, let widgetData = message.widgetData {
            VStack(alignment: .leading, spacing: 4) {
                // DynamicWidget is a structured-layout summary (tint, blocks),
                // not a replacement for the LLM's narrative answer. Render the
                // text alongside so WikipediaSearch / future summary tools don't
                // swallow the response body. Other widgets carry their full data
                // in the widget itself — showing text again would be redundant.
                if Self.widgetShouldKeepText(widgetType),
                   !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textBubble(message: message)
                }
                WidgetRenderer(widgetType: widgetType, data: widgetData, messageContent: message.content)
                    .environment(\.dismissWidget, { [id = message.id] in
                        chatState.dismissedMessageIDs.insert(id)
                    })
                    .environment(\.parentMessageID, message.id)

                let isSpeakingThis = speechSynthesizer.speakingMessageID == message.id
                if (message.content.count >= AppConfig.ttsCharacterThreshold || isSpeakingThis) && !chatState.podcastPlayer.isActive {
                    let icon = isSpeakingThis
                        ? (speechSynthesizer.isPaused ? "play.fill" : "stop.fill")
                        : "speaker.wave.2"
                    Button {
                        if isSpeakingThis {
                            speechSynthesizer.stop()
                        } else {
                            speechSynthesizer.speak(text: message.content, messageID: message.id)
                        }
                    } label: {
                        Image(systemName: icon)
                            .font(.caption2)
                            .foregroundStyle(isSpeakingThis ? .primary : .secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel(isSpeakingThis ? String(localized: "Stop reading", bundle: .iClawCore) : String(localized: "Read aloud", bundle: .iClawCore))
                    .help(isSpeakingThis ? String(localized: "Stop", bundle: .iClawCore) : String(localized: "Read aloud", bundle: .iClawCore))
                }
            }
            .padding(.top, 4)
        } else {
            textBubble(message: message)
        }
    }

    @ViewBuilder
    private func photoBubble(message: Message, path: String, image: PlatformImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.content.starts(with: "PHOTO_CAPTURED:") {
                Text(markdownAttributed(message.content.replacingOccurrences(of: "PHOTO_CAPTURED:\(path)", with: "")))
                    .textSelection(.enabled)
            }

            #if canImport(AppKit)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            #else
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            #endif
        }
        .padding(12)
        .background(message.role == "user" ? .blue.opacity(0.2) : .white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .saveToFile(content: message.content)
    }

    @ViewBuilder
    private func textBubble(message: Message) -> some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                if let fileName = message.attachmentName {
                    if message.attachmentCategory == .image,
                       let url = message.attachmentURL,
                       let image = PlatformImage(contentsOfFile: url.path) {
                        attachmentThumbnail(image: image, url: url)
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: FileAttachment.icon(for: message.attachmentCategory ?? .binary))
                                .font(.system(size: 9))
                                .foregroundStyle(.purple)
                            Text(fileName)
                                .font(.caption2)
                                .foregroundStyle(.purple.opacity(0.8))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.purple.opacity(0.1))
                        .clipShape(Capsule())
                    }
                }

                #if canImport(AppKit)
                if LaTeXDetector.containsLaTeX(message.content) {
                    RichMathText(message.content, fontSize: textSizePreference.chatFontSize)
                } else {
                    Text(markdownAttributed(message.content))
                        .font(.system(size: textSizePreference.chatFontSize))
                        .textSelection(.enabled)
                }
                #else
                Text(markdownAttributed(message.content))
                    .font(.system(size: textSizePreference.chatFontSize))
                    .textSelection(.enabled)
                #endif

                if let action = message.errorAction {
                    Button {
                        if let url = URL(string: action.urlString) {
                            URLOpener.open(url)
                        }
                    } label: {
                        Label(action.label, systemImage: "arrow.up.forward.square")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
            .padding(12)
            .background(message.isError ? .red.opacity(0.1) : (message.role == "user" ? .blue.opacity(0.2) : .white.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .saveToFile(content: message.content)

            let isSpeakingThisText = speechSynthesizer.speakingMessageID == message.id
            if message.role == "agent" && !message.isError && (message.content.count >= AppConfig.ttsCharacterThreshold || isSpeakingThisText) && !chatState.podcastPlayer.isActive {
                let textIcon = isSpeakingThisText
                    ? (speechSynthesizer.isPaused ? "play.fill" : "stop.fill")
                    : "speaker.wave.2"
                Button {
                    if isSpeakingThisText {
                        speechSynthesizer.stop()
                    } else {
                        speechSynthesizer.speak(text: message.content, messageID: message.id)
                    }
                } label: {
                    Image(systemName: textIcon)
                        .font(.caption2)
                        .foregroundStyle(isSpeakingThisText ? .primary : .secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.ultraThinMaterial))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(isSpeakingThisText ? String(localized: "Stop", bundle: .iClawCore) : String(localized: "Read aloud", bundle: .iClawCore))
            }
        }
        .onDisappear {
            if speechSynthesizer.speakingMessageID == message.id {
                speechSynthesizer.stop()
            }
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(image: PlatformImage, url: URL) -> some View {
        #if canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 200, maxHeight: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                chatState.quickLookURL = url
            }
        #else
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 200, maxHeight: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture {
                chatState.quickLookURL = url
            }
        #endif
    }

    // MARK: - Helpers

    /// Widgets whose rendered layout is a visual summary that complements —
    /// not replaces — the LLM's narrative answer. For these, show both the
    /// text bubble and the widget. Other widgets carry the full response in
    /// the widget itself, so duplicating text would be noise.
    ///
    /// Currently only `DynamicWidget` (emitted by `WikipediaCoreTool` and
    /// similar Wiki/summary paths) qualifies — the widget is a compact
    /// block layout, not the full narrative.
    private static func widgetShouldKeepText(_ widgetType: String) -> Bool {
        widgetType == "DynamicWidget"
    }

    private func markdownAttributed(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
    }

    private func loadEarlierMessages() async {
        guard !chatState.isLoadingHistory else { return }
        chatState.isLoadingHistory = true
        defer { chatState.isLoadingHistory = false }

        let chunkSize = 5
        let page = await DatabaseManager.shared.recentConversationPairs(
            limit: chunkSize,
            beforeID: chatState.oldestLoadedMemoryID
        )

        if page.scannedCount == 0 {
            chatState.hasMoreHistory = false
            return
        }

        if let cursor = page.cursorID {
            chatState.oldestLoadedMemoryID = cursor
        }

        var historyMessages: [Message] = []
        for pair in page.pairs {
            var userMsg = Message(role: "user", content: pair.user.content)
            userMsg.memoryID = pair.user.id
            historyMessages.append(userMsg)

            var agentMsg = Message(role: "agent", content: pair.agent.content)
            agentMsg.memoryID = pair.agent.id
            historyMessages.append(agentMsg)
        }

        if !historyMessages.isEmpty {
            withAnimation(.snappy) {
                chatState.messages.insert(contentsOf: historyMessages, at: 0)
            }
        }

        if page.scannedCount < chunkSize {
            chatState.hasMoreHistory = false
        }
    }
}

// MARK: - Breadcrumb Flow Layout

struct BreadcrumbFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
