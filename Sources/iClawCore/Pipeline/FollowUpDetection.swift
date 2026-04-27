import CoreML
import Foundation
import NaturalLanguage

// MARK: - Follow-Up Detection Pipeline

extension ToolRouter {

    /// Checks if the input references a result from the prior turn using a
    /// three-layer detection pipeline:
    ///
    /// 1. **Slot-based** — structured parameter matching (short inputs filling prior tool slots)
    /// 2. **ML classifier** — trained turn-pair model predicting relation type
    /// 3. **NLP heuristics** — anaphora, entity overlap, keywords, embedding similarity
    ///
    /// The ML classifier determines the *type* of follow-up (continuation, refinement,
    /// drill-down, meta) which informs how the engine handles the result. Pivots fall
    /// through to normal routing. Meta queries go to conversational mode.
    func checkFollowUp(input: String) async -> RoutingResult? {
        // Find the most recent non-empty context. Conversational turns produce
        // empty contexts (no tool name), but the user's intent chain may still
        // reference an earlier tool turn. E.g., #wiki photosynthesis → "explain
        // light reactions" (conversational) → "what role does water play?" should
        // still detect the WikipediaSearch context at depth 1.
        guard let lastContext = priorContextStack.first(where: { !$0.isEmpty }) else {
            return nil
        }

        // Explicit signals always override follow-up detection.
        // Chips (#tool), tickers ($AAPL), and URLs are deliberate user intent —
        // they must reach their dedicated routing stages, not be swallowed here.
        if !InputParsingUtilities.extractToolChipNames(from: input).isEmpty {
            return nil
        }
        if !InputParsingUtilities.extractTickerSymbols(from: input).isEmpty {
            return nil
        }
        if input.contains("://") {
            return nil
        }

        // Meta-query escape: questions about iClaw itself ("what can you do?",
        // "who are you", etc.) must reach the meta-query stage (2b), not be
        // swallowed by the follow-up classifier as a continuation. Uses the
        // async variant so the multilingual classifier catches non-English
        // meta queries when the classifier flag is on.
        if await isMetaQueryAsync(input: input) {
            return nil
        }

        let priorToolName = lastContext.toolNames.first ?? "unknown"

        // Extract NER entities once — reused across all three detection layers.
        let cachedNER = InputParsingUtilities.extractNamedEntities(from: input)

        // Layer 1: Slot-based detection — ONLY for very short inputs (1-2 words)
        // where NER confirms the input is genuinely a slot value (a place name,
        // a person name, a ticker symbol). The extractLocation fallback is too
        // permissive for anything longer — "5 min", "usd to eur", "latest news"
        // all get falsely matched as locations.
        let inputWords = input.split(separator: " ").count
        if inputWords <= 2 {
            let entities = cachedNER
            let extractedEntities = ExtractedEntities(
                names: entities.people, places: entities.places,
                organizations: entities.orgs, urls: [], phoneNumbers: [],
                emails: [], ocrText: nil
            )

            // Only trust slot matches backed by NER, explicit patterns ($TICKER),
            // or temporal expressions (NSDataDetector .date) for tools with date slots
            let hasNEREntity = !entities.places.isEmpty || !entities.people.isEmpty || !entities.orgs.isEmpty
            let hasTicker = !InputParsingUtilities.extractTickerSymbols(from: input).isEmpty
            let hasDate: Bool = {
                guard SlotExtractors.date(input, nil) != nil else { return false }
                // Only treat date detection as a slot signal when the prior tool
                // actually declares a date slot — prevents "on which day?" after
                // News from pivoting to Calendar via date detection.
                let priorSlots = ToolSlotRegistry.slotsForTool(named: priorToolName)
                return priorSlots.contains { $0.type == .date }
            }()

            if hasNEREntity || hasTicker || hasDate {
                let slotSignal = lastContext.detectSlotSignal(input: input, entities: extractedEntities)
                switch slotSignal {
                case .continuation(let toolName, let slot, _):
                    if let result = resolveToolByNameAny(toolName) {
                        Log.router.debug("Slot continuation: '\(slot)' filled for \(toolName)")
                        return result
                    }
                default:
                    break
                }
            }
        }

        // Layer 1b: Pivot signal bypass — skip ML follow-up when the input has
        // strong signals of a different domain than the prior tool.
        //
        // Two checks:
        // a) Intent verbs: "find", "set", "translate", etc. are self-contained
        //    commands, not follow-ups. Layer 3 NLP still catches anaphoric ones.
        // b) Domain mismatch: NER entities that belong to a different tool's domain
        //    (e.g., org "AAPL" after Weather, place "Berlin" after Stocks) signal
        //    a pivot. Without this, the ML classifier's [PRIOR_TOOL:] marker biases
        //    short domain-switching inputs toward false continuations.
        let pivotVerbs: Set<String> = [
            "find", "search", "set", "translate", "convert", "define", "calculate",
            "open", "launch", "play", "create", "generate", "send", "compose",
            "write", "remind", "schedule", "navigate", "directions", "check",
        ]
        let firstWord = String(input.split(separator: " ").first ?? "").lowercased()
        var skipMLFollowUp = pivotVerbs.contains(firstWord)

        // Domain mismatch: NER orgs (tickers) after non-stock tools, or tool-specific
        // keywords that clearly don't belong to the prior tool's domain.
        if !skipMLFollowUp && inputWords <= 4 {
            let priorLower = priorToolName.lowercased()
            let inputLower = input.lowercased()

            // Org entities (tickers like AAPL, MSFT) after non-stock tools → pivot
            if !cachedNER.orgs.isEmpty && !priorLower.contains("stock") {
                let stockKeywords = ["stock", "price", "quote", "share"]
                if stockKeywords.contains(where: { inputLower.contains($0) }) {
                    skipMLFollowUp = true
                }
            }

            // Place entities + weather/map keywords after non-weather/map tools → pivot
            if !cachedNER.places.isEmpty && !priorLower.contains("weather") && !priorLower.contains("map") && !priorLower.contains("time") {
                let geoKeywords = ["weather", "forecast", "temperature", "directions", "map"]
                if geoKeywords.contains(where: { inputLower.contains($0) }) {
                    skipMLFollowUp = true
                }
            }
        }

        // Layer 2: ML follow-up classifier.
        //
        // Always consulted unless the pivot signal bypass (Layer 1b) fired.
        // The classifier determines the turn relation (continuation, pivot,
        // retry, meta, etc.) and routes accordingly. False continuations
        // are caught by the cross-validation step inside classifyFollowUp(),
        // which checks domain coherence and confidence advantage against
        // the tool classifier.
        //
        // Previous versions gated this on word count (<5) or NLP signals
        // (anaphora, follow-up phrases, entity absence). That gate missed
        // utility tool follow-ups ("how much time is left?" after Timer)
        // because utility tools produce no NER entities and follow-ups
        // don't always use demonstrative pronouns. With 23K+ training
        // examples, topic-switch pivots, and robust cross-validation,
        // the classifier handles all inputs safely.
        var mlRejectedFollowUp = false
        if !skipMLFollowUp {
            followUpWasOverridden = false
            if let mlResult = classifyFollowUp(
                priorTool: priorToolName,
                priorInput: lastContext.userInput,
                currentInput: input,
                context: lastContext,
                cachedNER: cachedNER
            ) {
                return mlResult
            }
            // classifyFollowUp returned nil. If it explicitly decided this is
            // NOT a follow-up (pivot or cross-validation override), skip NLP
            // heuristics which would incorrectly re-route on entity overlap
            // (e.g., "Tell me about the history of London" after Weather→London).
            mlRejectedFollowUp = followUpWasOverridden
        }

        // Layer 3: NLP heuristic fallback (existing multi-signal approach).
        // Skip if the ML classifier already made an explicit "not a follow-up" decision.
        guard !mlRejectedFollowUp else { return nil }
        let lastIndex = priorContextStack.count - 1
        for (depth, context) in priorContextStack.enumerated() {
            guard !context.isEmpty else { continue }
            let isLast = depth == lastIndex
            guard let match = context.detectFollowUp(input: input, allowDefault: isLast) else { continue }

            if let url = match.url {
                if let fetchTool = availableTools.first(where: { $0.name == ToolNames.webFetch }),
                   !currentSuppressedTools.contains(ToolNames.webFetch) {
                    Log.router.debug("Follow-up NLP (depth \(depth)) — routing to WebFetch: \(url)")
                    let augmentedTool = FollowUpWebFetchProxy(wrapped: fetchTool, url: url)
                    return .tools([augmentedTool])
                }
            }

            if let priorName = match.priorToolName {
                // Entity-only matches (no anaphora, action verbs, or short-input signals)
                // are cross-validated against the tool classifier. If the classifier
                // confidently predicts a DIFFERENT tool, the entity overlap is coincidental
                // (e.g., "tell me about the history of London" after Weather→London).
                if match.isEntityOnlyMatch,
                   let toolLabel = toolClassifierModel?.predictedLabel(for: input) {
                    let hypotheses = toolClassifierModel?.predictedLabelHypotheses(for: input, maximumCount: 1) ?? [:]
                    let toolConf = hypotheses[toolLabel] ?? 0
                    let resolvedTool = LabelRegistry.lookup(toolLabel)?.tool ?? toolLabel
                    if toolConf > MLThresholdsConfig.shared.followUp.metaThreshold && !ToolNameNormalizer.matches(resolvedTool, priorName) {
                        Log.router.debug("Follow-up NLP entity-only match rejected: tool classifier predicts \(resolvedTool) (conf \(String(format: "%.2f", toolConf))) ≠ prior \(priorName)")
                        continue
                    }
                }
                if !currentSuppressedTools.contains(priorName),
                   let result = resolveToolByNameAny(priorName) {
                    Log.router.debug("Follow-up NLP (depth \(depth)) — re-routing to \(priorName)")
                    return result
                }
            }
        }
        return nil
    }

    /// Detects retry intent in user input. These are short imperative phrases
    /// that mean "re-execute the prior tool with the same input."
    /// Kept as a static method so it can be used in the follow-up gate without
    /// needing full NLP infrastructure.
    /// Domain keywords per tool, loaded from Config/ToolDomainKeywords.json.
    /// Used by cross-validation coherence check to verify tool predictions
    /// are semantically related to the input before overriding follow-up detection.
    static var toolDomainKeywords: [String: [String]] {
        _toolDomainKeywords
    }

    /// Uses the ML follow-up classifier to determine turn relation and route accordingly.
    /// Returns nil for pivots (fall through to normal routing) and when classifier
    /// is unavailable or low-confidence.
    func classifyFollowUp(
        priorTool: String,
        priorInput: String,
        currentInput: String,
        context: PriorTurnContext,
        cachedNER: (places: [String], people: [String], orgs: [String])? = nil
    ) -> RoutingResult? {
        // The follow-up NLModel is loaded eagerly at init (sync, ~1ms).
        // We use it directly rather than the FollowUpClassifier actor
        // because this method is sync and can't await.

        // Format the turn pair for classification
        let formatted = "[PRIOR_TOOL:\(priorTool)] [PRIOR] \(priorInput) [CURRENT] \(currentInput)"

        // Use the NLModel directly since we can't await the actor here.
        // The model is loaded at startup via ToolRouter initialization.
        guard let prediction = followUpModel?.predictedLabel(for: formatted) else {
            return nil
        }
        let hypotheses = followUpModel?.predictedLabelHypotheses(for: formatted, maximumCount: 5) ?? [:]
        let confidence = hypotheses[prediction] ?? 0

        guard let relation = FollowUpClassifier.TurnRelation(rawValue: prediction) else {
            return nil
        }

        // Confidence thresholds per relation type:
        // - Pivot: low bar (0.5) — just falls through to normal routing
        // - Retry: low bar (0.3) — inherently unambiguous ("again", "retry")
        // - Meta: moderate bar (0.7) — questions about the system
        // - Continuation/refinement/drill_down: high bar (0.85) — false
        //   follow-ups are worse than missed follow-ups
        //
        // Short inputs (≤2 words) get a lower threshold (0.3) because:
        // - MaxEnt has inherently low confidence for short feature vectors
        // - 1-2 word inputs are almost always follow-ups ("Paris", "tomorrow",
        //   "details") — they can't stand alone as queries
        // - Obvious new queries at this length are caught by the pivot verb
        //   bypass and chip/ticker detection before reaching this point
        let thresholds = MLThresholdsConfig.shared.followUp
        let currentWordCount = currentInput.split(separator: " ").count
        let nonPivotThreshold: Double
        if currentWordCount <= 2 {
            nonPivotThreshold = thresholds.boostedNonPivotThreshold
        } else if followUpBoostActive {
            nonPivotThreshold = thresholds.boostedNonPivotThreshold
        } else {
            nonPivotThreshold = thresholds.nonPivotThreshold
        }

        if relation == .pivot {
            guard confidence > thresholds.pivotThreshold else { return nil }
        } else if relation == .retry {
            guard confidence > thresholds.retryThreshold else { return nil }
        } else if relation == .meta {
            guard confidence > thresholds.metaThreshold else { return nil }
        } else {
            guard confidence > nonPivotThreshold else { return nil }
        }

        lastDetectedTurnRelation = relation

        switch relation {
        case .pivot:
            // Fall through to normal routing
            Log.router.debug("Follow-up ML: pivot (conf \(String(format: "%.2f", confidence)))")
            followUpWasOverridden = true
            return nil

        case .meta:
            // No tool needed — respond conversationally
            Log.router.debug("Follow-up ML: meta (conf \(String(format: "%.2f", confidence)))")
            return .conversational

        case .continuation, .refinement, .retry:
            // If the prior tool is suppressed (ingredient validation failure), fall through
            let toolName = context.toolNames.first ?? ""
            if currentSuppressedTools.contains(toolName) {
                Log.router.debug("Follow-up ML: \(relation.rawValue) → \(toolName) suppressed, falling through")
                lastDetectedTurnRelation = nil
                return nil
            }

            // Linguistic-signal gate for .continuation and .refinement: a real
            // follow-up has anaphora ("it", "that"), an action verb
            // ("summarize", "explain"), a follow-up phrase ("also", "and",
            // "next"), or entity overlap with the prior turn. A 4+ word query
            // with none of those signals is a pivot the classifier miscalled —
            // the [PRIOR_TOOL:X] marker biases it toward continuation. Only
            // gate on longer inputs; 1–2 word utterances ("Paris", "tomorrow")
            // are legitimately context-free follow-ups handled elsewhere.
            // Example: prior "Weather in Paris" → current "Find a restaurant"
            // has no signal and no entity overlap → pivot.
            if (relation == .continuation || relation == .refinement) && currentWordCount >= 4 {
                let lowerInput = currentInput.lowercased()
                let hasLinguisticSignal = PriorTurnContext.containsAnaphora(lowerInput)
                    || PriorTurnContext.containsActionVerb(lowerInput)
                    || PriorTurnContext.containsFollowUpPhrase(lowerInput)
                if !hasLinguisticSignal {
                    let priorEntityStrings = (context.entities?.places ?? [])
                        + (context.entities?.names ?? [])
                        + (context.entities?.organizations ?? [])
                    let priorEntityTokens: Set<String> = Set(
                        priorEntityStrings.flatMap { $0.lowercased().split(separator: " ").map(String.init) }
                    )
                    let currentTokens = Set(
                        lowerInput.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                    )
                    if currentTokens.isDisjoint(with: priorEntityTokens) {
                        Log.router.debug("Follow-up overridden: \(relation.rawValue) without signal (conf \(String(format: "%.2f", confidence))) — no anaphora, verb, phrase, or entity overlap with prior turn")
                        lastDetectedTurnRelation = nil
                        followUpWasOverridden = true
                        return nil
                    }
                }
            }
            // Cross-validate: if the tool classifier strongly predicts a different
            // tool AND the prediction is semantically coherent with the input,
            // override the follow-up. Without the coherence check, weak/spurious
            // tool predictions (e.g., Weather for "how did you calculate that?")
            // override legitimate follow-ups.
            // Skip cross-validation for retry — the user explicitly wants the same tool.
            if relation != .retry,
               let toolLabel = toolClassifierModel?.predictedLabel(for: currentInput) {
                let toolHypotheses = toolClassifierModel?.predictedLabelHypotheses(for: currentInput, maximumCount: 1) ?? [:]
                let toolConf = toolHypotheses[toolLabel] ?? 0
                let resolvedTool = LabelRegistry.lookup(toolLabel)?.tool ?? toolLabel
                if toolConf > thresholds.crossValidationThreshold && !ToolNameNormalizer.matches(resolvedTool, priorTool) {
                    // Two independent override paths — either is sufficient:
                    //
                    // 1. Domain coherence: the tool's keywords appear in the input.
                    //    Proves the input is about the tool's domain (e.g., "weather"
                    //    keyword → Weather tool). Catches specific-domain tools.
                    //
                    // 2. Confidence advantage: the tool classifier is at least as
                    //    confident as the bias-corrected follow-up classifier.
                    //    The follow-up classifier has ~0.1 continuation bias from
                    //    the [PRIOR_TOOL:X] marker. The tool classifier judges the
                    //    input IN ISOLATION (no bias). Subtracting the bias from
                    //    the follow-up confidence levels the comparison.
                    //    Catches general-purpose tools (WikipediaSearch, Research)
                    //    that have no narrow domain keywords.
                    let domainWords = Self._toolDomainKeywords[resolvedTool] ?? []
                    let inputLowerForCoherence = currentInput.lowercased()
                    let hasCoherence = !domainWords.isEmpty && domainWords.contains(where: { keyword in
                        // Multi-word keywords ("what time", "square root") checked
                        // against the full input. Single-word keywords checked as
                        // substring of individual tokens for partial matches.
                        if keyword.contains(" ") {
                            return inputLowerForCoherence.contains(keyword)
                        } else {
                            return inputLowerForCoherence.split(separator: " ")
                                .contains(where: { $0.contains(keyword) })
                        }
                    })
                    // Check if the PRIOR tool also has domain coherence with the input.
                    // If so, the follow-up gets stronger — the input references the
                    // prior tool's domain ("time left" after Timer, "forecast" after
                    // Weather), so the confidence advantage bar is raised.
                    let priorDomainWords = Self._toolDomainKeywords[priorTool] ?? []
                    let priorHasCoherence = !priorDomainWords.isEmpty && priorDomainWords.contains(where: { keyword in
                        if keyword.contains(" ") {
                            return inputLowerForCoherence.contains(keyword)
                        } else {
                            return inputLowerForCoherence.split(separator: " ")
                                .contains(where: { $0.contains(keyword) })
                        }
                    })
                    // Require larger confidence margin when prior tool has coherence
                    let confidenceMargin = priorHasCoherence ? thresholds.confidenceMarginWithCoherence : thresholds.confidenceMarginWithout
                    let hasConfidenceAdvantage = toolConf > confidence + confidenceMargin

                    // Path 3: Entity mismatch — new NER entities with no connection to prior turn.
                    // Only for continuation/refinement (drill_down legitimately introduces new entities).
                    let currentNER = cachedNER ?? InputParsingUtilities.extractNamedEntities(from: currentInput)
                    let hasNewEntities = !currentNER.places.isEmpty || !currentNER.people.isEmpty || !currentNER.orgs.isEmpty
                    let entityMismatch: Bool
                    if hasNewEntities {
                        let priorEnts = priorContextStack.first?.entities
                        let priorText = (priorContextStack.first?.ingredients.joined(separator: " ") ?? "").lowercased()
                        let priorEntityText = [
                            priorEnts?.places ?? [],
                            priorEnts?.names ?? [],
                            priorEnts?.organizations ?? []
                        ].flatMap { $0 }.joined(separator: " ").lowercased()

                        let allCurrentEntities = currentNER.places + currentNER.people + currentNER.orgs
                        let hasOverlap = allCurrentEntities.contains { entity in
                            let lower = entity.lowercased()
                            return priorEntityText.contains(lower) || priorText.contains(lower)
                        }
                        entityMismatch = !hasOverlap
                    } else {
                        entityMismatch = false
                    }

                    if hasCoherence || hasConfidenceAdvantage || entityMismatch {
                        let reason = hasCoherence ? "domain coherence" : hasConfidenceAdvantage ? "confidence advantage (\(String(format: "%.2f", toolConf)) > \(String(format: "%.2f", confidence)) + \(String(format: "%.2f", confidenceMargin)))" : "entity mismatch (new entities not in prior turn)"
                        Log.router.debug("Follow-up overridden: tool classifier predicts \(resolvedTool) (conf \(String(format: "%.2f", toolConf))) via \(reason) ≠ prior \(priorTool)")
                        lastDetectedTurnRelation = nil
                        followUpWasOverridden = true
                        return nil // Fall through to normal routing
                    } else {
                        Log.router.debug("Follow-up cross-validation suppressed: \(resolvedTool) (conf \(String(format: "%.2f", toolConf))) — no coherence and no confidence advantage over follow-up (\(String(format: "%.2f", confidence)))")
                    }
                }
            }
            // Re-route to the prior tool
            if let result = resolveToolByNameAny(toolName) {
                Log.router.debug("Follow-up ML: \(relation.rawValue) → \(toolName) (conf \(String(format: "%.2f", confidence)))")
                return result
            }
            return nil

        case .drillDown:
            // Check for ordinal matches first, then re-route to prior tool or WebFetch
            if let ordinalMatch = context.matchOrdinal(currentInput.lowercased()),
               let url = ordinalMatch.url,
               let fetchTool = availableTools.first(where: { $0.name == ToolNames.webFetch }),
               !currentSuppressedTools.contains(ToolNames.webFetch) {
                Log.router.debug("Follow-up ML: drill_down → WebFetch (ordinal)")
                let augmentedTool = FollowUpWebFetchProxy(wrapped: fetchTool, url: url)
                return .tools([augmentedTool])
            }
            // Fall back to re-routing to prior tool
            if let toolName = context.toolNames.first,
               !currentSuppressedTools.contains(toolName),
               let result = resolveToolByNameAny(toolName) {
                Log.router.debug("Follow-up ML: drill_down → \(toolName) (conf \(String(format: "%.2f", confidence)))")
                return result
            }
            return nil
        }
    }
}
