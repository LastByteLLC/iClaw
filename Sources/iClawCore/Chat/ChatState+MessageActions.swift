import SwiftUI

extension ChatState {

    func startReply(to message: Message) {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }

        let userMsg: Message
        let agentMsg: Message

        if message.role == "agent" {
            agentMsg = message
            userMsg = idx > 0 ? messages[idx - 1] : message
        } else {
            userMsg = message
            agentMsg = idx < messages.count - 1 ? messages[idx + 1] : message
        }

        withAnimation(.quick) {
            replyContext = ReplyContext(userMessage: userMsg, agentMessage: agentMsg)
        }
    }

    func startFeedback(on message: Message) {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }

        var chain: [(user: String, agent: String)] = []
        var i = idx

        while chain.count < 3 && i >= 0 {
            let msg = messages[i]
            if msg.role == "agent" && i > 0 {
                let userMsg = messages[i - 1]
                if userMsg.role == "user" {
                    chain.insert((user: userMsg.content, agent: msg.content), at: 0)
                    i -= 2
                    continue
                }
            }
            i -= 1
        }

        withAnimation(.quick) {
            feedbackContext = FeedbackContext(messageChain: chain)
        }
    }

    func deleteMessage(_ message: Message) {
        messages.removeAll { $0.id == message.id }

        if let reply = replyContext,
           reply.userMessage.id == message.id || reply.agentMessage.id == message.id {
            replyContext = nil
        }

        if let memoryID = message.memoryID {
            Task {
                do {
                    try await DatabaseManager.shared.deleteMemory(id: memoryID)
                } catch {
                    Log.engine.debug("Memory deletion failed for id \(memoryID): \(error)")
                }
            }
        }
    }

    func retryMessage(_ message: Message, speechSynthesizer: SpeechSynthesizer) {
        guard let originalInput = message.originalInput, !originalInput.isEmpty else { return }
        guard !isThinking else { return }
        input = originalInput
        // Force Tier 2 (stripped-identity) on the retry. Consumed by the next
        // `sendMessage` call. If Tier 1 produced empty/refusal, repeating the
        // same path is likely to fail the same way; starting at Tier 2 drops
        // SOUL/user/ctx and bumps temperature to 1.0 to break determinism.
        pendingRecoveryHint = .minimal
        sendMessage(speechSynthesizer: speechSynthesizer)
    }

    func exitSkillMode() {
        guard let groupId = skillModeState.modeGroupId else {
            skillModeState.deactivate()
            return
        }

        let threadMessages = messages.filter { $0.modeGroupId == groupId }
        let summary = generateModeSummary(from: threadMessages)

        let firstIndex = messages.firstIndex(where: { $0.modeGroupId == groupId }) ?? messages.endIndex

        var summaryMessage = Message(role: "agent", content: "")
        summaryMessage.isModeSummary = true
        summaryMessage.modeSummary = summary
        summaryMessage.modeGroupId = groupId
        summaryMessage.modeName = skillModeState.displayName
        summaryMessage.modeIcon = skillModeState.icon

        messages.insert(summaryMessage, at: firstIndex)
        completedModeGroups.insert(groupId)

        Task {
            await ExecutionEngine.shared.deactivateSkillMode()
        }
        skillModeState.deactivate()
    }

    func handleEscape() {
        if isSearchActive {
            isSearchActive = false
            searchManager.searchQuery = ""
        } else if !attachedFiles.isEmpty {
            withAnimation(.quick) {
                attachedFiles = []
                attachmentSuggestions = []
                pastedHashes = []
            }
        } else if replyContext != nil {
            withAnimation(.quick) {
                replyContext = nil
            }
        } else if !input.isEmpty {
            input = ""
        } else if isThinking {
            currentTask?.cancel()
            currentTask = nil
            isThinking = false
        }
    }

    func toggleSearch() {
        if isSearchActive {
            isSearchActive = false
            searchManager.searchQuery = ""
        } else {
            isSearchActive = true
        }
    }

    // MARK: - Private

    private func generateModeSummary(from threadMessages: [Message]) -> String {
        let userMessages = threadMessages.filter { $0.role == "user" }
        guard !userMessages.isEmpty else { return String(localized: "Mode session", bundle: .iClawCore) }

        let turnCount = userMessages.count

        let allContent = userMessages.map(\.content).joined(separator: " ")
        let words = allContent.split(separator: " ")

        let significantWords = words.filter { $0.count > 3 }
        let topicSnippet: String
        if significantWords.count >= 3 {
            topicSnippet = significantWords.prefix(6).joined(separator: " ")
        } else if !words.isEmpty {
            topicSnippet = String(words.prefix(8).joined(separator: " "))
        } else {
            topicSnippet = userMessages.first?.content ?? String(localized: "session", bundle: .iClawCore)
        }

        let truncated = topicSnippet.count > 40
            ? String(topicSnippet.prefix(40)) + "..."
            : topicSnippet

        return "\(turnCount) turn\(turnCount == 1 ? "" : "s") · \(truncated)"
    }
}
