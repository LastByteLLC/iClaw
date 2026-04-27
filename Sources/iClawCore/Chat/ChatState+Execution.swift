import SwiftUI

extension ChatState {

    var currentStageName: String? {
        guard let state = progressState else { return nil }
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

    func confirmRecording(speechManager: SpeechManager) {
        if speechManager.isRecording {
            speechManager.stopRecording()
        }
        let transcript = speechManager.lastTranscript
        if !transcript.isEmpty {
            input = transcript
            speechManager.lastTranscript = ""
        }
    }

    func runGreetingSequence() async {
        lastGreetingDate = Date()

        let proactiveResults = await HeartbeatManager.shared.drainResults()
        for result in proactiveResults {
            var msg = Message(role: "agent", content: result.text)
            msg.widgetType = result.widgetType
            msg.widgetData = result.widgetData
            msg.isGreeting = true
            messages.append(msg)
        }

        var greetingMsg = Message(role: "agent", content: await GreetingManager.shared.generateGreeting())
        greetingMsg.isGreeting = true
        messages.append(greetingMsg)

        async let tipTask = GreetingManager.shared.generateTipCard()
        async let repeatTask = GreetingManager.shared.generatePredictedRepeat()

        if let tipCard = await tipTask {
            var msg = Message(role: "agent", content: tipCard.tipText)
            msg.widgetType = "ToolTipCard"
            msg.widgetData = tipCard
            msg.isGreeting = true
            messages.append(msg)
        }

        if let result = await repeatTask {
            var msg = Message(role: "agent", content: result.text)
            msg.widgetType = result.widgetType
            msg.widgetData = result.widgetData
            msg.isGreeting = true
            messages.append(msg)
        }
    }

    func runWidgetAction(_ action: WidgetExplainAction) {
        guard !isThinking else { return }
        isThinking = true
        thinkingStartTime = Date()
        thinkingElapsed = 0
        stageHistory = []
        isBreadcrumbExpanded = false
        thinkingPhrase = PhraseGenerator.shared.randomPhrase(ofType: .thinking) ?? thinkingPhrases.randomElement()!

        currentTask = Task {
            let progressStream = ExecutionEngine.shared.makeProgressStream()
            let progressTask = Task { @MainActor in
                for await update in progressStream {
                    guard !Task.isCancelled else { break }
                    withAnimation(.snappy) {
                        progressState = update
                        if let stage = currentStageName,
                           stageHistory.last != stage {
                            stageHistory.append(stage)
                        }
                    }
                }
            }

            do {
                let (response, wType, wData, isError, _) = await ExecutionEngine.shared.run(input: action.prompt)
                progressTask.cancel()
                guard !Task.isCancelled else { return }
                progressState = nil
                isThinking = false

                var agentMessage = Message(role: "agent", content: response, widgetType: wType, widgetData: wData)
                agentMessage.replyToID = action.sourceMessageID
                agentMessage.modelName = ChatView.nonAFMModelName()
                if isError {
                    agentMessage.isError = true
                    agentMessage.errorAction = ErrorActionResolver.resolve(from: response)
                }

                let saved = try await DatabaseManager.shared.saveMemory(
                    Memory(id: nil, role: "agent", content: response, embedding: nil, created_at: Date(), is_important: false)
                )
                agentMessage.memoryID = saved.id
                messages.append(agentMessage)
            } catch {
                progressTask.cancel()
                guard !Task.isCancelled else { return }
                progressState = nil
                isThinking = false
                let errorMsg = await Personalizer.shared.personalizeError("Error: \(error.localizedDescription)")
                var msg = Message(role: "agent", content: errorMsg)
                msg.isError = true
                msg.replyToID = action.sourceMessageID
                messages.append(msg)
                Log.ui.error("\(error)")
            }
        }
    }

    func sendMessage(speechSynthesizer: SpeechSynthesizer) {
        guard !isThinking else { return }

        if let skillFile = attachedFiles.first,
           attachedFiles.count == 1,
           skillFile.url.pathExtension.lowercased() == "md",
           isAgentSkill(url: skillFile.url) {
            let url = skillFile.url
            input = ""
            attachedFiles = []
            attachmentSuggestions = []
            SettingsNavigation.shared.importSkill(from: url)
            return
        }

        guard !input.isEmpty else { return }

        if let persist = parsePersistCommand(input) {
            input = ""
            NotificationCenter.default.post(name: .iClawPersistHUD, object: persist)
            return
        }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/clear" {
            input = ""
            withAnimation(.snappy) {
                messages.removeAll { !$0.isGreeting }
            }
            return
        }

        Task { await TipDonations.donateMessageSent() }
        var userContent: String
        let capturedReply = replyContext
        let capturedAttachments = attachedFiles
        let capturedFeedback = feedbackContext

        if let feedback = capturedFeedback {
            userContent = "\(feedback.serializedPrefix())\n\(input)"
        } else if let reply = capturedReply {
            userContent = "[Replying to: \"\(reply.userMessage.content)\" → \"\(reply.agentMessage.content)\"]\n\(input)"
        } else {
            userContent = input
        }

        for file in capturedAttachments {
            userContent = "[Attached: \(file.url.path)]\n\(userContent)"
        }

        var userMessage = Message(role: "user", content: input)
        userMessage.replyToID = capturedReply?.agentMessage.id
        if let file = capturedAttachments.first {
            userMessage.attachmentName = file.fileName
            userMessage.attachmentCategory = file.fileCategory
            userMessage.attachmentURL = file.url
        }
        if skillModeState.isActive {
            userMessage.modeGroupId = skillModeState.modeGroupId
        }
        messages.append(userMessage)
        previousInput = input
        input = ""
        replyContext = nil
        feedbackContext = nil
        attachedFiles = []
        attachmentSuggestions = []
        pastedHashes = []
        isThinking = true
        thinkingStartTime = Date()
        thinkingElapsed = 0
        stageHistory = []
        isBreadcrumbExpanded = false
        thinkingPhrase = PhraseGenerator.shared.randomPhrase(ofType: .thinking) ?? thinkingPhrases.randomElement()!

        let pillWasAnchored = contextPillState.isAnchored
        if skillModeState.isActive {
            contextPillState.dismiss()
        } else {
            contextPillState.dismiss()
        }

        let capturedWidgetPayload = pendingWidgetPayload
        pendingWidgetPayload = nil
        let capturedRecoveryHint = pendingRecoveryHint
        pendingRecoveryHint = nil

        currentTask = Task {
            await ExecutionEngine.shared.setFollowUpBoost(pillWasAnchored)
            let toolNameTracker = ToolNameTracker()
            let progressStream = ExecutionEngine.shared.makeProgressStream()
            let progressTask = Task { @MainActor in
                for await update in progressStream {
                    guard !Task.isCancelled else { break }
                    if case .executing(let toolName, _, _) = update {
                        toolNameTracker.name = toolName
                    }
                    withAnimation(.snappy) {
                        progressState = update
                        if let stage = currentStageName,
                           stageHistory.last != stage {
                            stageHistory.append(stage)
                        }
                    }
                }
            }

            do {
                let (response, wType, wData, isError, toolSuggestions) = await ExecutionEngine.shared.run(
                    input: userContent,
                    widgetPayload: capturedWidgetPayload,
                    recoveryHint: capturedRecoveryHint
                )
                progressTask.cancel()
                guard !Task.isCancelled else { return }
                progressState = nil
                isThinking = false

                let userMessageId = userMessage.id
                if let mode = await ExecutionEngine.shared.activeSkillMode() {
                    let groupId = await ExecutionEngine.shared.activeModeGroupId() ?? UUID()
                    if !skillModeState.isActive {
                        let icon = ToolManifest.entry(for: mode.name)?.icon ?? "sparkles"
                        skillModeState.activate(name: mode.config.displayName, icon: icon, groupId: groupId, tintHex: mode.config.tintColor)
                        if let idx = messages.lastIndex(where: { $0.id == userMessageId }) {
                            messages[idx].modeGroupId = groupId
                        }
                    }
                } else if skillModeState.isActive {
                    exitSkillMode()
                }

                let resolvedToolName = ChatView.toolNameFromWidgetOrProgress(wType, progressState: nil) ?? toolNameTracker.name
                if skillModeState.isActive {
                    contextPillState.dismiss()
                } else if !isError, let toolName = resolvedToolName, ToolManifest.showsInUI(for: toolName) {
                    let ner = InputParsingUtilities.extractNamedEntities(from: userContent)
                    let richEntities = ExtractedEntities(
                        names: ner.people, places: ner.places, organizations: ner.orgs,
                        urls: [], phoneNumbers: [], emails: [], ocrText: nil
                    )
                    let entity = PrimaryEntityExtractor.extract(
                        toolName: toolName, entities: richEntities, input: userContent
                    )
                    let icon = PrimaryEntityExtractor.icon(for: toolName)
                    contextPillState.show(toolName: ToolManifest.displayName(for: toolName), primaryEntity: entity, toolIcon: icon)
                } else {
                    contextPillState.dismiss()
                }
                await ExecutionEngine.shared.setFollowUpBoost(false)

                let userMessageID = userMessage.id
                let savedUser = try await DatabaseManager.shared.saveMemory(
                    Memory(id: nil, role: "user", content: userContent, embedding: nil, created_at: Date(), is_important: false)
                )
                if let idx = messages.lastIndex(where: { $0.id == userMessageID }) {
                    messages[idx].memoryID = savedUser.id
                }

                let (cleanedResponse, suggestions) = ChatView.parseSuggestions(from: response)
                let finalResponse = cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && wType == nil
                    ? String(localized: "empty_response_fallback", bundle: .iClawCore)
                    : cleanedResponse
                var agentMessage = Message(role: "agent", content: finalResponse, widgetType: wType, widgetData: wData)
                Log.ui.debug("Message widget: type=\(wType ?? "nil"), data=\(wData == nil ? "nil" : String(describing: type(of: wData!)))")
                agentMessage.modelName = ChatView.nonAFMModelName()
                if skillModeState.isActive {
                    agentMessage.modeGroupId = skillModeState.modeGroupId
                }
                if !suggestions.isEmpty {
                    agentMessage.suggestedQueries = suggestions
                } else if let toolSuggestions, !toolSuggestions.isEmpty {
                    agentMessage.suggestedQueries = toolSuggestions
                }
                let executedToolName = toolNameTracker.name
                let contextualSuggestions: [String]? = ChatView.buildContextualSuggestions(
                    isError: isError,
                    toolName: executedToolName,
                    existingSuggestions: agentMessage.suggestedQueries
                )

                if isError {
                    agentMessage.isError = true
                    agentMessage.errorAction = ErrorActionResolver.resolve(from: response)
                    agentMessage.originalInput = userMessage.content
                }

                if let contextual = contextualSuggestions, agentMessage.suggestedQueries == nil {
                    agentMessage.suggestedQueries = contextual
                }

                let savedAgent = try await DatabaseManager.shared.saveMemory(
                    Memory(id: nil, role: "agent", content: cleanedResponse, embedding: nil, created_at: Date(), is_important: false)
                )
                agentMessage.memoryID = savedAgent.id
                messages.append(agentMessage)

                if !NSApp.isActive, !isError {
                    let notifBody = String(cleanedResponse.prefix(256))
                    let msgID = agentMessage.id
                    Task {
                        await NotificationEngine.shared.deliver(
                            title: "iClaw",
                            body: notifBody,
                            source: "prompt",
                            messageID: msgID
                        )
                    }
                }

                if UserDefaults.standard.bool(forKey: AppConfig.autoSpeakResponsesKey),
                   !agentMessage.isError,
                   !cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !podcastPlayer.isActive {
                    speechSynthesizer.speak(text: cleanedResponse, messageID: agentMessage.id)
                }
            } catch {
                progressTask.cancel()
                guard !Task.isCancelled else { return }
                progressState = nil
                isThinking = false
                let errorMsg = await Personalizer.shared.personalizeError("Error: \(error.localizedDescription)")
                var msg = Message(role: "agent", content: errorMsg)
                msg.isError = true
                msg.errorAction = ErrorActionResolver.resolve(from: errorMsg)
                msg.originalInput = userMessage.content
                messages.append(msg)
                Log.ui.error("\(error)")
            }
        }
    }

    // MARK: - Private Helpers

    private func isAgentSkill(url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        var hasName = false
        var hasExamples = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") { hasName = true }
            if trimmed.hasPrefix("## ") && trimmed.lowercased().contains("examples") { hasExamples = true }
            if hasName && hasExamples { return true }
        }
        return false
    }

    private func parsePersistCommand(_ text: String) -> Bool? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "/persist on" { return true }
        if trimmed == "/persist off" { return false }
        return nil
    }

    @MainActor
    class ToolNameTracker {
        var name: String?
    }
}
