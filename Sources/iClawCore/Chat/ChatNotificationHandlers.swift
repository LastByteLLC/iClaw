import SwiftUI
import Combine

@MainActor
struct ChatNotificationHandlers: ViewModifier {
    var chatState: ChatState
    @Binding var hasAcceptedTOS: Bool
    let phraseTimer: Publishers.Autoconnect<Timer.TimerPublisher>
    let feedbackBus: FeedbackActionBus
    let speechSynthesizer: SpeechSynthesizer

    func body(content: Content) -> some View {
        content
            .modifier(ChatTimerHandlers(
                chatState: chatState,
                phraseTimer: phraseTimer
            ))
            .modifier(ChatLifecycleHandlers(
                chatState: chatState,
                hasAcceptedTOS: $hasAcceptedTOS
            ))
            .modifier(ChatEventHandlers(
                chatState: chatState,
                feedbackBus: feedbackBus,
                speechSynthesizer: speechSynthesizer
            ))
    }
}

// MARK: - Timer Handlers

@MainActor
private struct ChatTimerHandlers: ViewModifier {
    var chatState: ChatState
    let phraseTimer: Publishers.Autoconnect<Timer.TimerPublisher>

    func body(content: Content) -> some View {
        content
            .onReceive(phraseTimer) { _ in
                if chatState.isThinking {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        chatState.thinkingPhrase = PhraseGenerator.shared.randomPhrase(ofType: .thinking)
                            ?? thinkingPhrases.randomElement() ?? "Thinking\u{2026}"
                    }
                }
            }
    }
}

// MARK: - Lifecycle Handlers

@MainActor
private struct ChatLifecycleHandlers: ViewModifier {
    var chatState: ChatState
    @Binding var hasAcceptedTOS: Bool

    func body(content: Content) -> some View {
        content
            .task {
                if !hasAcceptedTOS {
                    chatState.messages = [Message(role: "agent", content: "", widgetType: "TOSWidget", widgetData: TOSWidgetData())]
                    return
                }
                await chatState.runGreetingSequence()
            }
            .onChange(of: hasAcceptedTOS) { _, accepted in
                if accepted {
                    chatState.messages.removeAll { $0.widgetType == "TOSWidget" }
                    Task { await chatState.runGreetingSequence() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .iClawHUDDidAppear)) { _ in
                Task {
                    guard !Calendar.current.isDateInToday(chatState.lastGreetingDate ?? .distantPast) else { return }
                    chatState.messages.removeAll()
                    await chatState.runGreetingSequence()
                }
            }
    }
}

// MARK: - Event Handlers

@MainActor
private struct ChatEventHandlers: ViewModifier {
    var chatState: ChatState
    let feedbackBus: FeedbackActionBus
    let speechSynthesizer: SpeechSynthesizer

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .widgetActionTapped)) { notification in
                if let action = notification.object as? WidgetAction {
                    chatState.input = action.displayText
                    chatState.pendingWidgetPayload = action.payload
                    chatState.sendMessage(speechSynthesizer: speechSynthesizer)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stockTickerTapped)) { notification in
                if let query = notification.object as? String {
                    chatState.input = query
                    chatState.sendMessage(speechSynthesizer: speechSynthesizer)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .podcastEpisodeTapped)) { notification in
                if let query = notification.object as? String {
                    chatState.input = query
                    chatState.sendMessage(speechSynthesizer: speechSynthesizer)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .newsArticleTapped)) { notification in
                if let query = notification.object as? String {
                    chatState.input = query
                    chatState.sendMessage(speechSynthesizer: speechSynthesizer)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .widgetExplainRequested)) { notification in
                if let action = notification.object as? WidgetExplainAction {
                    chatState.runWidgetAction(action)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toolTipTryAction)) { notification in
                if let query = notification.object as? String {
                    chatState.input = query
                }
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: BrowserBridge.contextUpdatedNotification)) { _ in
                Task {
                    let ctx = await BrowserBridge.shared.lastBrowserContext
                    withAnimation {
                        chatState.browserContextTitle = ctx?.hasContent == true ? ctx?.title : nil
                    }
                }
            }
            #endif
            .onChange(of: feedbackBus.lastAction) { _, action in
                guard let action else { return }
                handleFeedback(action)
            }
            .onChange(of: chatState.quickLookURL) { _, url in
                guard let url else { return }
                QuickLookCoordinator.shared.preview(url: url)
                chatState.quickLookURL = nil
            }
    }

    private func handleFeedback(_ action: FeedbackActionBus.Action) {
        switch action {
        case .clarify:
            break
        case .cancel:
            chatState.feedbackContext = nil
            chatState.messages.removeAll { $0.widgetType == "FeedbackWidget" }
            Task {
                let personalized = await Personalizer.shared.personalize("Feedback dismissed.")
                chatState.messages.append(Message(role: "agent", content: personalized))
            }
        case .send:
            let summary: String = {
                if let ctx = chatState.feedbackContext, !ctx.originalFeedback.isEmpty {
                    return ctx.originalFeedback
                }
                if let lastFeedback = chatState.messages.last(where: {
                    $0.role == "agent" && $0.widgetType == "FeedbackWidget"
                }), let data = lastFeedback.widgetData as? FeedbackWidgetData {
                    return data.summary
                }
                return ""
            }()
            chatState.feedbackContext = nil
            chatState.messages.removeAll { $0.widgetType == "FeedbackWidget" }
            Task {
                let success = await FeedbackSender.shared.send(summary: summary, feedbackID: feedbackBus.feedbackID ?? "")
                let baseMsg = success
                    ? "Feedback received \u{2014} thanks for taking the time."
                    : "Couldn't send feedback right now. Try again later."
                let personalized = await Personalizer.shared.personalize(baseMsg)
                chatState.messages.append(Message(role: "agent", content: personalized))
            }
        }
        feedbackBus.lastAction = nil
    }
}
