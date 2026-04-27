import Foundation
import FoundationModels
import PDFKit
import UniformTypeIdentifiers
import Vision

extension ExecutionEngine {
    // MARK: - Input Cleaning

    internal func cleanInputForTool(_ input: String) -> String {
        var cleaned = InputParsingUtilities.stripToolChips(from: input)
        cleaned = InputParsingUtilities.stripTickerSymbols(from: cleaned)
        return cleaned
    }

    // MARK: - Prior Turn Context

    /// Checks if the prior turn failed and returns an explanatory ingredient for
    /// conversational follow-ups like "what were you going to do?" or "why didn't that work?"
    /// Returns nil if the prior turn succeeded or there's no prior context.
    func priorTurnFailureContext() async -> String? {
        guard let priorContext = await router.priorContext,
              let failure = priorContext.failureReason else {
            return nil
        }

        switch failure {
        case .consentDenied(let toolName):
            let friendly = Self.userFriendlyToolName(toolName)
            return "The user is asking about your previous attempt. You tried to use \(friendly) "
                + "but they declined permission. Explain briefly what you were going to do "
                + "and suggest alternatives or ask what they'd like instead."
        case .toolError(let toolName):
            let friendly = Self.userFriendlyToolName(toolName)
            return "The user is asking about a previous attempt that failed. "
                + "\(friendly.capitalized) encountered an error. Explain what went wrong briefly "
                + "and suggest trying again or an alternative approach."
        }
    }

    /// Builds a rich PriorTurnContext from the current turn's results and stores it
    /// on the router so the next turn can detect follow-ups via NLP.
    func updatePriorContext(userInput: String) async {
        // Extract titled URL references from ingredients or widget data.
        var refs: [PriorTurnContext.Reference] = []

        // Prefer widget data for News results -- it has full URLs even when
        // text ingredients truncate Google News redirect URLs for token savings.
        if let newsData = lastWidgetData as? NewsWidgetData {
            for article in newsData.articles {
                refs.append(PriorTurnContext.Reference(title: "\(article.title) — \(article.source)", url: article.link))
            }
        }

        // Fall back to parsing numbered headlines + URLs from ingredient text.
        if refs.isEmpty {
            for ingredient in currentIngredients {
                let lines = ingredient.components(separatedBy: "\n")
                var pendingTitle: String?
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    // Numbered headline: "1. Title -- Source (time)"
                    if let dotIdx = trimmed.firstIndex(of: "."),
                       trimmed.startIndex < dotIdx,
                       let num = Int(trimmed[trimmed.startIndex..<dotIdx]),
                       num >= 1 && num <= 20 {
                        let afterDot = String(trimmed[trimmed.index(after: dotIdx)...]).trimmingCharacters(in: .whitespaces)
                        if !afterDot.isEmpty {
                            pendingTitle = afterDot
                        }
                    }
                    else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                        if let title = pendingTitle {
                            refs.append(PriorTurnContext.Reference(title: title, url: trimmed))
                            pendingTitle = nil
                        }
                    }
                }
            }
        }

        // WebFetch fallback: when no references were extracted from ingredients
        // (WebFetch returns plain article text, not numbered headlines), store the
        // fetched URL so follow-up turns can re-fetch or reference it.
        if refs.isEmpty, let fetchedURL = lastWebFetchURL {
            let title = currentIngredients.first
                .flatMap { $0.components(separatedBy: "\n").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "Fetched page"
            refs.append(PriorTurnContext.Reference(title: title, url: fetchedURL))
        }
        lastWebFetchURL = nil

        // Collect tool names from this turn. Use lastRoutedToolNames (always correct)
        // instead of widget-based derivation (empty when tool doesn't produce a widget,
        // which breaks follow-up detection on the next turn).
        // Exclude consent-denied tools -- they never executed, so follow-up detection
        // should not route subsequent queries back to them.
        let deniedTools = consentDeniedToolName.map { Set([$0]) } ?? []
        let toolNames = lastRoutedToolNames.filter {
            $0 != "conversational" && $0 != "disambiguation" && $0 != "clarification"
            && !deniedTools.contains($0)
        }

        // Also extract entities from the ingredients text (output NER)
        let combinedOutput = currentIngredients.joined(separator: "\n")
        let outputNER = InputParsingUtilities.extractNamedEntities(from: combinedOutput)
        // Merge with input entities
        let mergedEntities = ExtractedEntities(
            names: (currentEntities?.names ?? []) + outputNER.people,
            places: (currentEntities?.places ?? []) + outputNER.places,
            organizations: (currentEntities?.organizations ?? []) + outputNER.orgs,
            urls: currentEntities?.urls ?? [],
            phoneNumbers: currentEntities?.phoneNumbers ?? [],
            emails: currentEntities?.emails ?? [],
            ocrText: currentEntities?.ocrText
        )

        // Propagate failure state so follow-up queries can explain what happened
        let failure: PriorTurnContext.FailureReason?
        if let deniedTool = consentDeniedToolName {
            failure = .consentDenied(toolName: deniedTool)
        } else if hadToolError, let errorTool = lastRoutedToolNames.first {
            failure = .toolError(toolName: errorTool)
        } else {
            failure = nil
        }

        let context = PriorTurnContext(
            toolNames: toolNames,
            userInput: userInput,
            entities: mergedEntities,
            ingredients: currentIngredients,
            references: refs,
            widgetType: lastWidgetType,
            widgetData: lastWidgetData,
            failureReason: failure
        )
        await router.setPriorContext(context)
        Log.engine.debug("Updated prior context: \(refs.count) refs, \(toolNames) tools, \(mergedEntities.places.count) places")
    }

    // MARK: - Consent Filtering

    /// Filters FM tools by consent policy and network availability.
    func filterByConsent(_ tools: [any FMToolDescriptor]) async -> [any FMToolDescriptor] {
        var approved: [any FMToolDescriptor] = []
        var deniedNames: [String] = []
        for tool in tools {
            // Network pre-flight for FM tools
            if tool.category == .online && !NetworkMonitor.shared.isConnected {
                Log.engine.debug("Offline -- skipping online FM tool '\(tool.name)'")
                hadToolError = true
                currentIngredients.append("You're currently offline. \(Self.userFriendlyToolName(tool.name).capitalized) needs an internet connection. Check your network and try again.")
                continue
            }
            if tool.consentPolicy.needsConsent {
                if skipConsentThisTurn {
                    Log.engine.debug("Skipping consent-requiring FM tool '\(tool.name)' (background run)")
                    continue
                }
                let friendly = Self.userFriendlyToolName(tool.name)
                emitProgress(.processing(description: "Waiting for permission to use \(friendly)…"))
                let result = await ConsentManager.shared.requestConsent(
                    policy: tool.consentPolicy, toolName: tool.name
                )
                if result == .denied {
                    Log.engine.debug("Consent denied for FM tool \(tool.name)")
                    deniedNames.append(tool.name)
                    continue
                }
            }
            approved.append(tool)
        }

        // When all FM tools were denied, inject a graceful conversational ingredient
        // instead of the generic "user declined" message that triggers guardrails.
        if approved.isEmpty && !deniedNames.isEmpty {
            let friendlyName = Self.userFriendlyToolName(deniedNames.first ?? "")
            currentIngredients.append(
                "You needed permission for \(friendlyName) but the user declined. "
                + "Briefly explain what you needed access to and ask if there's something else they'd like help with. "
                + "Do NOT apologize excessively or say you 'can't assist'."
            )
            consentDeniedToolName = deniedNames.first
        }

        return approved
    }

    // MARK: - Routing Signal Detection

    /// Detects if user query references browser content ("this page", "what am I looking at", etc.)
    static func queryReferencesBrowser(_ input: String) -> Bool {
        let lower = input.lowercased()
        let browserSignals = [
            "this page", "this site", "this article", "this website",
            "what am i looking at", "what's on safari", "what is on safari",
            "summarize this", "summarize the page", "the page",
            "on safari", "in my browser", "in safari",
            "current page", "current tab", "active tab",
        ]
        return browserSignals.contains { lower.contains($0) }
    }

    /// Detects unambiguous routing signals (chips, tickers, URLs).
    /// These are the same signals that take priority in ToolRouter stages 1-1c:
    /// tool chips (#weather), ticker symbols ($AAPL), and URLs (https://...).
    func hasExplicitRoutingSignal(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Tool chips: #weather, #crypto, etc.
        if trimmed.contains("#") && !InputParsingUtilities.extractToolChipNames(from: trimmed).isEmpty {
            return true
        }

        // Ticker symbols: $AAPL, $MSFT
        if trimmed.contains("$") && !InputParsingUtilities.extractTickerSymbols(from: trimmed).isEmpty {
            return true
        }

        // URLs: https://..., http://...
        if trimmed.contains("://") {
            return true
        }

        return false
    }

    // MARK: - Core Tool Execution

    /// Appends a successful tool result as an ingredient and caches it in the scratchpad.
    /// Skips the append if identical content (ignoring prefix tags) is already present.
    func appendToolResult(_ result: ToolIO, tool: any CoreTool, cleanInput: String) {
        Task.detached { await TipDonations.donateToolUsed() }
        // Bypass finalizer when the tool marks its text as already user-
        // ready. Prevents paraphrase drift on exact math / lookup results
        // (e.g., Calculator's "437 * 29 = 12,673" becoming `12\,673` LaTeX).
        if result.emitDirectly && !result.text.isEmpty {
            pendingDirectResponse = result.text
        }
        let ingredient = result.isVerifiedData ? "[VERIFIED] \(result.text)" : result.text
        if !ingredientAlreadyPresent(ingredient) {
            currentIngredients.append(ingredient)
        }

        // WebFetch fallback: when WebFetch couldn't find a URL, it returns
        // "Search the web for: <query>". Inject web_search FM tool so the
        // LLM can perform the search during finalization.
        if tool.name == ToolNames.webFetch && result.text.hasPrefix("Search the web for:") {
            if let webSearch = ToolRegistry.fmTools.first(where: { $0.name == ToolNames.webSearch }) {
                if !currentFMTools.contains(where: { $0.name == ToolNames.webSearch }) {
                    currentFMTools.append(webSearch)
                    Log.engine.debug("WebFetch fallback: injected web_search FM tool for LLM")
                }
            }
        }

        // Capture widget info if present
        if let widget = result.outputWidget {
            self.lastWidgetType = widget
            self.lastWidgetData = result.widgetData
        }

        // Capture tool-provided follow-up suggestions
        if let queries = result.suggestedQueries, !queries.isEmpty {
            self.lastSuggestedQueries = queries
        }

        // Phase 5: Store in scratchpad
        // Capture widget data and text eagerly to avoid existential boxing issues
        // when values cross the Task.detached boundary. The (any Sendable)? can
        // double-box the concrete type, causing `as? WeatherWidgetData` casts to
        // fail on retrieval.
        if result.status != .error {
            let cacheKey = ScratchpadCache.makeKey(toolName: tool.name, input: cleanInput)
            let ttl = ScratchpadCache.ttlMap[tool.name] ?? ScratchpadCache.defaultTTL
            let capturedText = result.text
            let capturedWidgetData = result.widgetData
            let capturedWidgetType = result.outputWidget
            let capturedVerified = result.isVerifiedData
            let capturedToolName = tool.name
            Task.detached {
                await ScratchpadCache.shared.store(key: cacheKey, entry: .init(
                    toolName: capturedToolName,
                    textSummary: capturedText,
                    widgetData: capturedWidgetData,
                    widgetType: capturedWidgetType,
                    isVerifiedData: capturedVerified,
                    timestamp: Date(),
                    ttl: ttl
                ))
            }
        }
    }

    // MARK: - Healing Loop (Phase 3)

    /// Attempts a single healing retry when a tool fails.
    /// Uses a short LLM call to produce a corrected input, then retries the tool once.
    func attemptHealingRetry(
        tool: any CoreTool,
        originalInput: String,
        errorMessage: String,
        entities: ExtractedEntities?
    ) async -> ToolIO? {
        emitProgress(.retrying(toolName: tool.name, reason: errorMessage))

        let healingPrompt = """
        Tool "\(tool.name)" failed with error: \(errorMessage)
        Original input: \(originalInput)
        Output ONLY a corrected input string, or the single word UNFIXABLE if the error is not recoverable by changing the input.
        """

        do {
            let correctedInput: String
            if let responder = llmResponder {
                correctedInput = try await responder(healingPrompt, [])
            } else {
                // Correcting a tool argument — we want a confident, structured
                // output, not creative rephrasing. Greedy + low temperature +
                // 60-token cap on the corrected value or "UNFIXABLE".
                correctedInput = try await llmAdapter.generateText(healingPrompt, profile: .healing)
            }

            let trimmed = correctedInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased() == "UNFIXABLE" || trimmed.isEmpty {
                return nil
            }

            // Retry with corrected input
            let retryResult = try await tool.execute(input: trimmed, entities: entities)
            if retryResult.status == .error {
                return nil
            }
            return retryResult
        } catch {
            Log.engine.error("Healing LLM call failed: \(error)")
            return nil
        }
    }

    // MARK: - Argument Extraction

    /// Attempts structured argument extraction for tools conforming to `ExtractableCoreTool`.
    /// Returns `nil` if the tool doesn't conform or extraction fails -- caller falls back to raw execution.
    func tryExtractAndExecute(tool: any CoreTool, input: String, entities: ExtractedEntities?) async -> ToolIO? {
        // Skip extraction for explicit chip invocations (user typed #weather etc.)
        if input.hasPrefix("#") { return nil }

        // Use a type-erased helper to open the existential
        return await _extractAndExecute(tool: tool, input: input, entities: entities)
    }

    /// Type-erased extraction helper.
    /// Uses the tool's own `extractAndExecute` trampoline (defined via protocol extension)
    /// to avoid a manual switch over every ExtractableCoreTool conformant.
    private func _extractAndExecute(tool: any CoreTool, input: String, entities: ExtractedEntities?) async -> ToolIO? {
        guard let extractable = tool as? any ExtractableCoreTool else { return nil }
        return await extractable.extractAndRun(input: input, entities: entities, extractor: argumentExtractor)
    }

    // MARK: - Chain Execution

    /// After executing a tool, checks if it implements ChainableTool and follows
    /// the chain until completion or budget exhaustion.
    func executeChainIfNeeded(tool: any CoreTool, result: ToolIO, originalInput: String) async {
        guard let chainable = tool as? (any ChainableTool),
              result.status == .ok,
              let nextStep = chainable.nextStep(result: result, originalInput: originalInput) else {
            return
        }

        switch nextStep {
        case .runTool(let name, let input):
            guard toolCallCounter < AppConfig.maxToolCallsPerTurn else {
                Log.engine.debug("Chain from \(tool.name) -> \(name) skipped: max tool calls reached")
                return
            }

            emitProgress(.chaining(fromTool: tool.name, toTool: name))
            Log.engine.debug("Chain: \(tool.name) -> \(name) with input: \(input.prefix(100))")

            // Find the target tool
            let targetTool: (any CoreTool)? = await router.findCoreTool(named: name)
            guard let target = targetTool else {
                Log.engine.debug("Chain target '\(name)' not found in registry")
                return
            }

            // Increment counter BEFORE execution to prevent off-by-one in recursive chains
            toolCallCounter += 1

            do {
                let chainResult = try await target.execute(input: input, entities: currentEntities)
                if chainResult.status == .ok {
                    appendToolResult(chainResult, tool: target, cleanInput: input)

                    // Recurse: the chained tool might also be chainable
                    await executeChainIfNeeded(tool: target, result: chainResult, originalInput: originalInput)
                }
            } catch {
                Log.engine.error("Chain tool '\(name)' failed: \(error)")
            }
        }
    }

    // MARK: - Agent Runner Integration

    /// Executes a multi-step plan via AgentRunner, then transfers results back
    /// into the engine's mutable state for finalization.
    ///
    /// AgentRunner provides: dynamic ingredient compaction, fact compression,
    /// LLM-based continuation checks, and mid-execution clarification.
    func executeAgentPlan(_ agentPlan: AgentPlan, query: String, primaryTool: String) async {
        // Infer domains from the plan's tool names
        let toolNames = Set(agentPlan.steps.map(\.toolName))
        let domains = ToolProvider.domains(for: toolNames)

        await transitionTo(.toolExecution(callCount: toolCallCounter))

        let result = await agentRunner.execute(
            plan: agentPlan,
            query: query,
            domains: domains.isEmpty ? Set(ToolDomain.allCases) : domains,
            entities: currentEntities
        )

        // Transfer AgentResult into engine state
        for ingredient in result.ingredients {
            if !ingredientAlreadyPresent(ingredient) {
                currentIngredients.append(ingredient)
            }
        }
        toolCallCounter += result.turnsUsed
        hadToolError = result.hadError

        if let wt = result.widgetType { lastWidgetType = wt }
        if let wd = result.widgetData { lastWidgetData = wd }

        // Record facts into progressive memory
        await conversationManager.recordFacts(result.facts)

        // Handle clarification: emit the agent-provided question directly as
        // user-facing text instead of embedding a planner instruction the
        // finalizer would paraphrase. `pendingDirectResponse` short-circuits
        // the LLM so the wording stays exactly as the agent intended.
        if let question = result.pendingQuestion {
            Log.engine.debug("AgentRunner requested clarification: \(question.prefix(80))")
            pendingDirectResponse = question
        }
    }

    // MARK: - Ingredient Validation (ReAct)

    /// Domain keywords per tool, loaded from Config/ToolDomainKeywords.json.
    /// Tools not listed are considered non-self-validating (require entity overlap check).
    static let toolDomainKeywords: [String: [String]] = {
        guard let config = ConfigLoader.load("ToolDomainKeywords", as: [String: [String]].self) else { return [:] }
        return config
    }()

    /// Returns true if the tool's output is self-validating for this prompt
    /// (i.e. the prompt is clearly within the tool's domain).
    func isToolSelfValidating(toolName: String, prompt: String) -> Bool {
        guard let keywords = Self.toolDomainKeywords[toolName] else { return false }
        let lower = prompt.lowercased()
        return keywords.contains { lower.contains($0) }
    }

    /// Checks if any entities from the prompt appear in the ingredients.
    func checkEntityOverlap(prompt: String, entities: ExtractedEntities?, ingredients: [String]) -> Bool {
        guard let entities else { return true } // No entities -> can't validate, assume OK
        let joined = ingredients.joined(separator: " ").lowercased()
        let allEntities = entities.names + entities.organizations + entities.places
        if allEntities.isEmpty { return true } // No entities to check
        return allEntities.contains { entity in
            joined.contains(entity.lowercased())
        }
    }

    /// Lightweight LLM call to validate ingredient relevance. Returns true if relevant.
    func validateIngredientsWithLLM(prompt: String, ingredients: [String]) async -> Bool {
        let summary = ingredients.joined(separator: " ")
        let truncated = String(summary.prefix(400))
        let validationPrompt = """
        The user asked: "\(prompt)"
        The system retrieved: "\(truncated)"
        Is the retrieved data relevant to what the user asked? Answer YES or NO only.
        """

        do {
            let response: String
            if let responder = llmResponder {
                response = try await responder(validationPrompt, [])
            } else {
                // YES/NO binary classification — deterministic + greedy + 5-token cap.
                response = try await llmAdapter.generateText(validationPrompt, profile: .validation)
            }
            let answer = response.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            Log.engine.debug("Ingredient validation LLM response: \(answer)")
            return answer.hasPrefix("YES")
        } catch {
            Log.engine.debug("Ingredient validation LLM call failed: \(error). Rejecting unvalidated ingredients.")
            return false // Fail-closed: reject ingredients that couldn't be validated
        }
    }

    /// Validates ingredients after tool execution. Returns true if ingredients are OK,
    /// false if they should be discarded and routing retried.
    func validateIngredients(toolName: String, prompt: String) async -> Bool {
        // Skip validation for tools with widgets (structured output)
        if lastWidgetType != nil { return true }

        // Skip if tool had an error (error handling is separate)
        if hadToolError { return true }

        // Skip if no ingredients to validate
        if currentIngredients.isEmpty { return true }

        // Skip if tool is self-validating for this prompt
        if isToolSelfValidating(toolName: toolName, prompt: prompt) { return true }

        // Cheap check: entity overlap
        if checkEntityOverlap(prompt: prompt, entities: currentEntities, ingredients: currentIngredients) {
            return true
        }

        // Expensive check: LLM validation
        Log.engine.debug("Ingredient validation: no entity overlap for '\(toolName)', checking with LLM...")
        return await validateIngredientsWithLLM(prompt: prompt, ingredients: currentIngredients)
    }

    // MARK: - Core Tool Execution (Phase 3: Healing, Phase 5: Scratchpad)

    func executeCoreTools(_ tools: [any CoreTool], input: String) async {
        var cleanInput = self.cleanInputForTool(input)
        // Prepend attachment path so file-aware tools (Read, Transcribe) receive it
        if let path = currentAttachmentPath {
            cleanInput = path + "\n" + cleanInput
        }

        // Focal entity injection: when the current turn is a follow-up
        // (continuation, drill-down, refinement, or retry) and the input
        // doesn't contain its own named entity, augment it with the prior
        // turn's focal entity. This enables:
        // - Cross-tool: "$AAPL" -> "any recent news about them?" (them -> Apple)
        // - Deep-turn: "#wiki Napoleon" -> "what year was he born?" (he -> Napoleon)
        // - Bare predicates: "born in 1769?" -> (implicit -> Napoleon)
        //
        // Uses turn relation (set by follow-up classifier) rather than
        // pronoun detection -- this catches all forms of implicit reference
        // without enumerating pronouns.
        let isFollowUpTurn = currentTurnRelation == .continuation
            || currentTurnRelation == .refinement
            || currentTurnRelation == .drillDown
            || currentTurnRelation == .retry
        if isFollowUpTurn {
            // Resolve focal entity from multiple sources, in priority order:
            // 1. Prior tool context's NER entities (most specific -- "Napoleon", "AAPL")
            //    Uses priorToolContext to look through conversational turns.
            // 2. Recent fact keys (domain-specific compressors produce good keys)
            // 3. Prior tool context's user input (last resort)
            let priorToolCtx = await router.priorToolContext
            let priorEntities = priorToolCtx?.entities
            let factKey = await conversationManager.state.recentFacts.first?.key

            // Resolve from structured sources first (NER entities, fact keys),
            // then fall back to short prior input for topic-driven tools.
            // Long prior inputs ("set a timer for 5 minutes") are NOT entity
            // names, but short ones ("DNA", "Brazil", "Napoleon") usually are.
            let priorToolNames = priorToolCtx?.toolNames ?? []
            let priorUserInput = priorToolCtx?.userInput
            let focalEntity: String? =
                priorEntities?.names.first
                ?? priorEntities?.organizations.first
                ?? priorEntities?.places.first
                ?? factKey.flatMap { key in
                    // Skip generic keys like tool names ("WikipediaSearch")
                    ToolRegistry.allToolNames.contains(key) ? nil : key
                }
                ?? priorUserInput.flatMap { input in
                    // Short prior input (<=3 words) from a topic-driven tool
                    // is likely the entity itself ("DNA", "Brazil", "CRISPR")
                    let words = input.split(separator: " ")
                    let isShortTopic = words.count <= 3
                    let isTopicTool = priorToolNames.contains(where: {
                        ["WikipediaSearch", "Research", "News"].contains($0)
                    })
                    return (isShortTopic && isTopicTool) ? input : nil
                }

            if let entity = focalEntity, !entity.isEmpty {
                let inputLower = cleanInput.lowercased()
                // Skip injection when the input already has its own NER entities.
                // "what about Jupiter?" has "Jupiter" -- the user's new topic takes
                // precedence over the prior entity. Only inject when the input has
                // NO entity of its own (pronouns, bare predicates, etc.).
                let inputHasOwnEntity = !(currentEntities?.names.isEmpty ?? true)
                    || !(currentEntities?.places.isEmpty ?? true)
                    || !(currentEntities?.organizations.isEmpty ?? true)
                if !inputHasOwnEntity && !inputLower.contains(entity.lowercased()) {
                    // Dual injection: augment BOTH text input AND NER entities.
                    //
                    // Text augmentation: tools using LLM-based argument extraction
                    // (ExtractableCoreTool) see the raw input text. Prepending the
                    // entity lets the LLM extractor parse it (e.g., "$AAPL: who is
                    // their CEO?" -> extracts ticker AAPL).
                    cleanInput = "\(entity): \(cleanInput)"
                    //
                    // NER augmentation: tools using entity-preferred extraction
                    // (e.g., WikipediaSearch) check entities before raw text.
                    // Re-running NER ensures they pick up the focal entity.
                    let augmentedNER = InputParsingUtilities.extractNamedEntities(from: cleanInput)
                    currentEntities = ExtractedEntities(
                        names: (currentEntities?.names ?? []) + augmentedNER.people,
                        places: (currentEntities?.places ?? []) + augmentedNER.places,
                        organizations: (currentEntities?.organizations ?? []) + augmentedNER.orgs,
                        urls: currentEntities?.urls ?? [],
                        phoneNumbers: currentEntities?.phoneNumbers ?? [],
                        emails: currentEntities?.emails ?? [],
                        ocrText: currentEntities?.ocrText
                    )
                    Log.engine.debug("Injected focal entity '\(entity)' for follow-up resolution")
                }
            }
        }

        let totalTools = tools.count
        var stepIndex = 0
        var anyToolExecuted = false
        var deniedToolNames: [String] = []

        for tool in tools {
            if toolCallCounter < AppConfig.maxToolCallsPerTurn {
                stepIndex += 1

                // Check consent before execution
                if tool.consentPolicy.needsConsent {
                    if skipConsentThisTurn {
                        Log.engine.debug("Skipping consent-requiring tool '\(tool.name)' (background run)")
                        continue
                    }
                    let friendly = Self.userFriendlyToolName(tool.name)
                    emitProgress(.processing(description: "Waiting for permission to use \(friendly)…"))
                    let result = await ConsentManager.shared.requestConsent(
                        policy: tool.consentPolicy, toolName: tool.name
                    )
                    if result == .denied {
                        Log.engine.debug("Consent denied for \(tool.name)")
                        deniedToolNames.append(tool.name)
                        continue
                    }
                }

                // Permission pre-flight: skip tools whose required permission was
                // previously rejected. Avoids wasting a tool-call slot on a predictable
                // failure, freeing it for an alternative tool or conversational fallback.
                if let requiredPerm = tool.requiredPermission,
                   PermissionManager.isRejected(requiredPerm) {
                    Log.engine.debug("Pre-flight: skipping '\(tool.name)' — \(requiredPerm.rawValue) permission previously rejected")
                    hadToolError = true
                    currentIngredients.append("\(requiredPerm.rawValue) access is needed for \(Self.userFriendlyToolName(tool.name)). Open System Settings to grant permission.")
                    continue
                }

                // Network pre-flight: skip online tools immediately when offline.
                // Avoids multi-retry HTTP timeout waste and provides clear feedback.
                if tool.category == .online && !NetworkMonitor.shared.isConnected {
                    Log.engine.debug("Offline -- skipping online tool '\(tool.name)'")
                    hadToolError = true
                    currentIngredients.append("You're currently offline. \(Self.userFriendlyToolName(tool.name).capitalized) needs an internet connection. Check your network and try again.")
                    continue
                }

                // Capture the URL from follow-up proxy so updatePriorContext()
                // can store it as a reference for subsequent follow-up turns.
                if let proxy = tool as? FollowUpWebFetchProxy {
                    lastWebFetchURL = proxy.url
                } else if tool.name == ToolNames.webFetch {
                    // Direct WebFetch -- capture URL from entities
                    lastWebFetchURL = currentEntities?.urls.first(where: {
                        $0.scheme == "http" || $0.scheme == "https"
                    })?.absoluteString
                }

                anyToolExecuted = true
                emitProgress(.executing(toolName: tool.name, step: stepIndex, totalSteps: totalTools))
                await transitionTo(.toolExecution(callCount: toolCallCounter))

                // Phase 5: Check scratchpad before execution
                let cacheKey = ScratchpadCache.makeKey(toolName: tool.name, input: cleanInput)
                if let cached = await ScratchpadCache.shared.lookup(key: cacheKey) {
                    let ingredient = (cached.isVerifiedData ? "[VERIFIED] [CACHED] " : "[CACHED] ") + cached.textSummary
                    if !ingredientAlreadyPresent(ingredient) {
                        currentIngredients.append(ingredient)
                    }
                    if let wt = cached.widgetType {
                        self.lastWidgetType = wt
                        self.lastWidgetData = cached.widgetData
                        Log.engine.debug("Cache widget: type=\(wt), data=\(cached.widgetData == nil ? "nil" : String(describing: type(of: cached.widgetData!)))")
                    } else {
                        Log.engine.debug("Cache hit but no widgetType for \(tool.name)")
                    }
                    toolCallCounter += 1
                    Log.engine.debug("Tool '\(tool.name)' served from cache.")
                    continue
                }

                let toolTimeoutSeconds = ToolManifest.timeout(for: tool.name)
                do {
                    // Inject progress handler for ResearchTool so it can emit
                    // step-by-step status updates during its multi-step execution.
                    let executableTool: any CoreTool
                    if tool is ResearchTool {
                        let continuation = _progressContinuation
                        let handler: @Sendable (String) -> Void = { description in
                            continuation.withLock { _ = $0?.yield(.processing(description: description)) }
                        }
                        executableTool = ResearchTool(progressHandler: handler)
                    } else {
                        executableTool = tool
                    }
                    // Try structured argument extraction for ExtractableCoreTool conformants.
                    // Skip extraction when the routing label indicates a sub-behavior that
                    // doesn't use extraction (e.g., "time" label -> clock path of unified
                    // TimeTool, which has no structured args -- only "timer" does).
                    emitProgress(.processing(description: "Understanding request..."))
                    let routingLabel = await router.lastRoutingLabel
                    let result: ToolIO
                    let skipExtraction = routingLabel == "time"  // Clock path of unified TimeTool

                    // Per-tool timeout from ToolManifest.json (or AppConfig.defaultToolTimeout).
                    // Capture actor-isolated values before entering the task group.
                    let capturedInput = cleanInput
                    let capturedEntities = currentEntities
                    let capturedSkipExtraction = skipExtraction
                    let capturedLabel = routingLabel
                    let toolResult: ToolIO = try await withThrowingTaskGroup(of: ToolIO.self) { group in
                        group.addTask {
                            try await Task.sleep(nanoseconds: UInt64(toolTimeoutSeconds) * 1_000_000_000)
                            throw ToolError.timeout(duration: TimeInterval(toolTimeoutSeconds))
                        }
                        group.addTask {
                            if !capturedSkipExtraction,
                               let extractedResult = await self.tryExtractAndExecute(tool: executableTool, input: capturedInput, entities: capturedEntities) {
                                return extractedResult
                            }
                            return try await executableTool.execute(input: capturedInput, entities: capturedEntities, routingLabel: capturedLabel)
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                    result = toolResult

                    if result.status == .error {
                        // Silent self-refusal: a tool may return (status:
                        // .error, text: "") to indicate "I can't operate on
                        // this input, please let the finalizer answer
                        // conversationally." Calculator's numeric-evidence
                        // gate and Convert's digit-evidence gate both use
                        // this pattern — they refuse rather than fabricate.
                        // Skip healing (would just re-invoke the tool on the
                        // same input) and skip [ERROR] ingredient injection
                        // (the finalizer would surface it as user-facing
                        // text). Downstream `routerFellThrough` detects the
                        // empty-tool-data turn and selects conversational
                        // BRAIN.
                        let trimmedError = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmedError.isEmpty {
                            Log.engine.debug("Tool '\(tool.name)' self-refused — falling through to conversational")
                        } else if let healed = await attemptHealingRetry(tool: tool, originalInput: cleanInput, errorMessage: result.text, entities: currentEntities) {
                            appendToolResult(healed, tool: tool, cleanInput: cleanInput)
                        } else {
                            hadToolError = true
                            currentIngredients.append("[ERROR] \(Self.userFriendlyToolName(tool.name)): \(result.text.prefix(120))")
                        }
                    } else {
                        if result.status == .partial {
                            Log.engine.warning("Tool '\(tool.name)' returned partial result (LLM normalization used)")
                        }
                        // Quality gate: if the tool succeeded structurally but
                        // produced off-topic or empty output, try the fallback
                        // ladder (max one swap per turn to stay within budget).
                        let quality = ToolOutputClassifier.score(input: cleanInput, tool: tool.name, output: result)
                        if (quality.verdict == .offTopic || quality.verdict == .failed),
                           !fallbackAttempted.contains(tool.name),
                           let fallbackName = ToolFallbackLadder.firstFallback(for: tool.name),
                           fallbackName != "conversational",
                           let fallbackTool = await router.findCoreTool(named: fallbackName) {
                            Log.engine.debug("Tool '\(tool.name)' verdict=\(quality.verdict.rawValue) (\(quality.reasons.joined(separator: ","))) — falling back to '\(fallbackName)'")
                            fallbackAttempted.insert(tool.name)
                            do {
                                let fbResult = try await fallbackTool.execute(input: cleanInput, entities: currentEntities)
                                let fbQuality = ToolOutputClassifier.score(input: cleanInput, tool: fallbackName, output: fbResult)
                                if fbQuality.verdict == .ok || fbQuality.verdict == .degraded {
                                    lastRoutedToolNames.append(fallbackName)
                                    appendToolResult(fbResult, tool: fallbackTool, cleanInput: cleanInput)
                                    GreetingManager.recordToolUsage(fallbackName)
                                    // Record the original tool's failure so
                                    // future similar inputs downweight it.
                                    RouterFeedback.shared.recordFailure(tool: tool.name, input: cleanInput)
                                } else {
                                    // Both failed — keep the original output so the user sees SOMETHING
                                    appendToolResult(result, tool: tool, cleanInput: cleanInput)
                                }
                            } catch {
                                appendToolResult(result, tool: tool, cleanInput: cleanInput)
                            }
                        } else {
                            appendToolResult(result, tool: tool, cleanInput: cleanInput)
                            GreetingManager.recordToolUsage(tool.name)
                        }
                    }

                    // Increment counter before chain check so chain respects total budget
                    toolCallCounter += 1

                    // Check for chain steps after successful execution
                    if result.status != .error {
                        await executeChainIfNeeded(tool: executableTool, result: result, originalInput: cleanInput)
                    }
                    Log.engine.debug("Tool '\(tool.name)' executed \(result.status == .error ? "with error" : "successfully").")
                } catch let toolError as ToolError {
                    // Structured error -- use isHealable to decide whether healing is worthwhile
                    let errorText = toolError.userMessage
                    if toolError.isHealable, let healed = await attemptHealingRetry(tool: tool, originalInput: cleanInput, errorMessage: errorText, entities: currentEntities) {
                        appendToolResult(healed, tool: tool, cleanInput: cleanInput)
                    } else {
                        hadToolError = true
                        currentIngredients.append("[ERROR] \(Self.userFriendlyToolName(tool.name)): \(errorText.prefix(120))")
                    }
                    Log.engine.error("Tool '\(tool.name)' threw ToolError: \(errorText)")
                } catch {
                    // Unstructured error -- check for offline before attempting healing
                    let nsError = error as NSError
                    let isOfflineError = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet
                    if isOfflineError {
                        // Skip healing + LLM personalization -- return a clear, direct message
                        hadToolError = true
                        currentIngredients.append("You're currently offline. \(Self.userFriendlyToolName(tool.name).capitalized) needs an internet connection. Check your network and try again.")
                    } else {
                        let errorText = "Tool '\(tool.name)' failed: \(error.localizedDescription)"
                        if let healed = await attemptHealingRetry(tool: tool, originalInput: cleanInput, errorMessage: errorText, entities: currentEntities) {
                            appendToolResult(healed, tool: tool, cleanInput: cleanInput)
                        } else {
                            hadToolError = true
                            currentIngredients.append("[ERROR] \(Self.userFriendlyToolName(tool.name)): \(errorText.prefix(120))")
                        }
                    }
                    Log.engine.error("Tool '\(tool.name)' threw: \(error)")
                }
            }
        }

        // Consent denial recovery: when ALL tools were denied and none executed,
        // replace the poison "user declined" ingredient with a graceful conversational
        // response that names the capability (not internal tool name).
        if !anyToolExecuted && !deniedToolNames.isEmpty {
            let friendlyName = Self.userFriendlyToolName(deniedToolNames.first ?? "")
            currentIngredients.removeAll()
            currentIngredients.append(
                "You needed permission for \(friendlyName) but the user declined. "
                + "Briefly explain what you needed access to and ask if there's something else they'd like help with. "
                + "Do NOT apologize excessively or say you 'can't assist'."
            )
            consentDeniedToolName = deniedToolNames.first
        }
    }

    // MARK: - Post-Turn Quality Assessment

    /// Background micro-prompt that rates response quality 1-5.
    /// Stores the signal in UserProfileManager for long-term routing optimization.
    /// Never blocks the response -- runs as a detached task.
    ///
    /// - Parameter hadToolOutput: true when at least one routed tool produced a
    ///   substantive ingredient this turn. When false, the LLM either never
    ///   invoked the tool or the tool returned nothing — so the response is
    ///   ungrounded and the score is capped at 2/5 regardless of how plausible
    ///   it sounds.
    static func assessQuality(
        query: String,
        response: String,
        toolNames: [String],
        hadToolOutput: Bool,
        llmResponder: LLMResponder?,
        llmAdapter: LLMAdapter
    ) async {
        if !hadToolOutput {
            for toolName in toolNames {
                await UserProfileManager.shared.recordQualitySignal(toolName: toolName, score: 2)
            }
            Log.engine.debug("Quality assessment: 2/5 (capped — no tool output) for \(toolNames.joined(separator: ", "))")
            return
        }

        let prompt = """
        Rate this response quality from 1-5. Output ONLY the number.
        1=wrong/irrelevant 2=partially relevant 3=acceptable 4=good 5=excellent

        User asked: \(query.prefix(100))
        Tools used: \(toolNames.joined(separator: ", "))
        Response: \(response.prefix(200))

        Score:
        """

        do {
            let result: String
            if let responder = llmResponder {
                result = try await responder(prompt, [])
            } else {
                // Rating (1-5) — ordinal classification. Greedy + 3-token cap on the digit.
                result = try await llmAdapter.generateText(prompt, profile: .scoring)
            }

            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // Extract the first digit (1-5)
            if let firstDigit = trimmed.first(where: { $0.isNumber }),
               let score = Int(String(firstDigit)),
               (1...5).contains(score) {
                for toolName in toolNames {
                    await UserProfileManager.shared.recordQualitySignal(toolName: toolName, score: score)
                }
                Log.engine.debug("Quality assessment: \(score)/5 for \(toolNames.joined(separator: ", "))")
            }
        } catch {
            // Silent failure -- quality assessment is non-critical
            Log.engine.debug("Quality assessment failed: \(error)")
        }
    }

    // MARK: - Attachment Pre-Read

    /// Reads an attached file's content and returns a truncated ingredient string.
    /// Handles text, code, PDF, images, and directories. Uses the same security
    /// checks as ReadFileTool. Skips SummarizationManager to avoid an extra LLM
    /// call — the finalizer LLM synthesizes the raw content.
    ///
    /// - Parameters:
    ///   - path: Absolute file path from `[Attached: ...]` tag
    ///   - maxCharacters: Maximum characters to include (default 4000, ~1000 tokens)
    /// - Returns: A `[FILE: filename]` ingredient string, or nil if unreadable
    func preReadAttachmentContent(at path: String, maxCharacters: Int = 4000) async -> String? {
        let expandedPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath()
        let resolvedPath = url.path

        // Security: same access check as ReadFileTool
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let allowedPrefixes = [home, "/tmp", "/var/folders"]
        guard allowedPrefixes.contains(where: { resolvedPath.hasPrefix($0) }) else {
            Log.engine.warning("Pre-read blocked: path outside allowed directories: \(resolvedPath)")
            return nil
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return "[FILE: \(url.lastPathComponent)] Error: File not found at \(path)."
        }

        if isDir.boolValue {
            return preReadDirectory(at: url)
        }

        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        if type.conforms(to: .image) {
            let analysis = await analyzeImageForPreRead(at: url)
            return "[FILE: \(filename)] Image analysis: \(analysis)"
        } else if type.conforms(to: .pdf) {
            if let pdf = PDFDocument(url: url) {
                let pageCount = pdf.pageCount
                var text = ""
                for i in 0..<min(pageCount, 5) {
                    if let pageText = pdf.page(at: i)?.string {
                        text += pageText
                        if text.count >= maxCharacters { break }
                    }
                }
                let snippet = String(text.prefix(maxCharacters))
                return "[FILE: \(filename)] PDF (\(pageCount) pages):\n\(snippet)"
            }
            return "[FILE: \(filename)] PDF could not be read."
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode)
                    || ["md", "csv", "json", "xml", "yaml", "yml", "toml", "log"].contains(ext) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let snippet = String(content.prefix(maxCharacters))
                return "[FILE: \(filename)]\n\(snippet)"
            }
            // UTF-8 failed — try Latin-1 as fallback
            if let content = try? String(contentsOf: url, encoding: .isoLatin1) {
                let snippet = String(content.prefix(maxCharacters))
                return "[FILE: \(filename)]\n\(snippet)"
            }
            return "[FILE: \(filename)] Could not read text content."
        } else {
            // Binary/unknown: report metadata only
            if let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath) {
                let size = attrs[.size] as? Int64 ?? 0
                return "[FILE: \(filename)] Binary file, \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
            }
            return "[FILE: \(filename)] Unknown file type."
        }
    }

    private func preReadDirectory(at url: URL) -> String? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.nameKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return nil }
        let fileList = contents.prefix(30).map { $0.lastPathComponent }.joined(separator: ", ")
        return "[FILE: \(url.lastPathComponent)/] Directory with \(contents.count) items: \(fileList)"
    }

    /// Lightweight image analysis using Vision framework (no LLM).
    /// Mirrors ReadFileTool.analyzeImage but callable from the engine actor.
    private func analyzeImageForPreRead(at url: URL) async -> String {
        guard let data = try? Data(contentsOf: url) else { return "Could not read image data." }
        let requestHandler = VNImageRequestHandler(data: data)
        let classifyRequest = VNClassifyImageRequest()
        let ocrRequest = VNRecognizeTextRequest()
        ocrRequest.recognitionLevel = .accurate

        do {
            try requestHandler.perform([classifyRequest, ocrRequest])
            var results: [String] = []
            if let observations = classifyRequest.results {
                let labels = observations.prefix(3).filter { $0.confidence > 0.8 }.map { $0.identifier }
                if !labels.isEmpty { results.append("Objects: \(labels.joined(separator: ", "))") }
            }
            if let ocrResults = ocrRequest.results {
                let topOCR = ocrResults.prefix(15).compactMap { $0.topCandidates(1).first?.string }
                if !topOCR.isEmpty { results.append("Text: \(topOCR.joined(separator: " ").prefix(300))") }
            }
            return results.isEmpty ? "No high-confidence visual data." : results.joined(separator: " | ")
        } catch {
            return "Vision analysis failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Performance

    func emitTurnPerformance(turnStart: ContinuousClock.Instant, toolName: String?, turnRelation: FollowUpClassifier.TurnRelation?) {
        func ms(for stage: String) -> Double {
            stageDurations.filter { $0.stage == stage }.reduce(0) { $0 + $1.ms }
        }
        let totalElapsed = turnStart.duration(to: .now)
        let totalMs = Double(totalElapsed.components.attoseconds) / 1_000_000_000_000_000 + Double(totalElapsed.components.seconds) * 1000

        let perf = TurnPerformance(
            totalMs: totalMs,
            preprocessingMs: ms(for: "preprocessing"),
            routingMs: ms(for: "routing"),
            extractionMs: ms(for: "planning"),
            executionMs: ms(for: "toolExecution(callCount: 1)") + ms(for: "toolExecution(callCount: 2)") + ms(for: "toolExecution(callCount: 3)"),
            validationMs: 0,
            finalizationMs: ms(for: "finalization"),
            widgetMs: 0,
            toolName: toolName,
            wasFollowUp: turnRelation == .continuation || turnRelation == .refinement || turnRelation == .retry,
            wasReRouted: hasValidationRetried
        )
        Log.engine.info("Turn perf: preprocess=\(String(format: "%.0f", perf.preprocessingMs))ms route=\(String(format: "%.0f", perf.routingMs))ms exec=\(String(format: "%.0f", perf.executionMs))ms final=\(String(format: "%.0f", perf.finalizationMs))ms total=\(String(format: "%.0f", perf.totalMs))ms")
        emitProgress(.performance(perf))
    }
}
