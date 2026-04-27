import CoreML
import Foundation
import NaturalLanguage

/// Closure type for injecting a test LLM responder into the tool router.
/// Parameters: (input, systemInstruction) -> toolName
public typealias RouterLLMResponder = DualInputLLMResponder

/// ToolRouter handles the intelligent selection of tools based on user input.
/// It uses a multi-stage approach: Tool Chips -> Synonym Expansion -> ML Classification -> Heuristic Overrides -> LLM Fallback -> Conversational.
/// Adheres to Swift 6 strict concurrency requirements.
public actor ToolRouter {

    /// Represents the outcome of the tool routing process.
    public enum RoutingResult {
        /// A specific set of Core tools (1-3) was identified.
        case tools([any CoreTool])

        /// A specific set of Foundation Model tools (1-3) was identified.
        case fmTools([any FMToolDescriptor])

        /// A mix of Core and Foundation Model tools was identified.
        case mixed(core: [any CoreTool], fm: [any FMToolDescriptor])

        /// ML was ambiguous between multiple intents.
        case requiresDisambiguation(choices: [String])

        /// No tool matched — pass directly to LLM for conversational response.
        case conversational

        /// No tools could be confidently matched; direct user input needed.
        case needsUserClarification

        /// The primary tool name from this routing result, if any.
        var primaryToolName: String? {
            switch self {
            case .tools(let tools): return tools.first?.name
            case .fmTools(let tools): return tools.first?.name
            case .mixed(let core, _): return core.first?.name
            default: return nil
            }
        }

        /// Whether this result selected an FM tool (which has system access capabilities).
        var isFMTool: Bool {
            switch self {
            case .fmTools: return true
            case .mixed: return true
            default: return false
            }
        }
    }

    let availableTools: [any CoreTool]
    let fmTools: [any FMToolDescriptor]
    let llmResponder: RouterLLMResponder?
    private let toolVerifier: ToolVerifier

    /// The currently matched skill.
    var currentSkill: Skill?
    var priorContextStack: [PriorTurnContext] = []
    /// Tools suppressed by ingredient validation (re-routing avoids these).
    var currentSuppressedTools: Set<String> = []
    /// Set by classifyFollowUp when it explicitly rejects a follow-up (pivot or cross-validation override).
    /// Prevents the NLP heuristic fallback from re-routing on entity overlap alone.
    var followUpWasOverridden = false

    /// When a help redirect fires (chip+help or natural language tool help),
    /// stores the original tool name so ExecutionEngine can pass it to HelpTool.
    /// Internal setter for extension access.
    public internal(set) var helpContextToolName: String?

    // MARK: - Skill Mode

    /// The currently active persistent mode (e.g. Rubber Duck).
    public private(set) var activeMode: (name: String, config: ModeConfig)?

    /// Group ID for tagging messages in the current mode session.
    public private(set) var activeModeGroupId: UUID?

    /// Set for one routing cycle after mode exit to prevent re-activation by entry phrases.
    var modeJustDeactivated = false

    /// Whether a mode is currently active.
    public var isInMode: Bool { activeMode != nil }

    /// Activates a mode. Called when a mode chip is toggled on or an entry phrase matches.
    public func activateMode(name: String, config: ModeConfig, groupId: UUID) {
        activeMode = (name, config)
        activeModeGroupId = groupId
        Log.router.debug("Mode activated: \(name)")
    }

    /// Deactivates the current mode.
    public func deactivateMode() {
        if let name = activeMode?.name {
            Log.router.debug("Mode deactivated: \(name)")
        }
        activeMode = nil
        activeModeGroupId = nil
        modeJustDeactivated = true
    }

    /// Loaded NLModel for follow-up turn-pair classification.
    /// Loaded eagerly at init to avoid async in the sync checkFollowUp() path.
    let followUpModel: NLModel?

    /// Loaded NLModel for tool classification, used to cross-validate follow-up
    /// predictions. When the follow-up classifier says "continuation" but the
    /// tool classifier strongly predicts a different tool, we treat it as a pivot.
    let toolClassifierModel: NLModel?

    /// When true, the context pill is anchored — the user explicitly indicated
    /// their next input is a follow-up. Boosts follow-up detection confidence.
    var followUpBoostActive = false

    /// The turn relation detected during the most recent `route()` call.
    /// Set by `checkFollowUp()` → `classifyFollowUp()`. Read by ExecutionEngine
    /// to determine argument merging strategy. Internal setter for extension access.
    public internal(set) var lastDetectedTurnRelation: FollowUpClassifier.TurnRelation?

    /// The ML label that triggered tool selection (e.g., "time", "timer",
    /// "search.wiki"). Set during `resolveLabel()`, read by ExecutionEngine
    /// to pass to tools that handle multiple intents (unified Time tool).
    /// Internal setter for extension access.
    public internal(set) var lastRoutingLabel: String?

    /// A calibrated confidence score in `[0.0, 1.0]` for the most recent
    /// routing decision. Hard-evidence stages (chips, URLs, tickers, skill
    /// high-coverage, follow-up, attachment hint, explicit mode) set `1.0`.
    /// ML stages set the classifier's top-1 confidence. Weak stages
    /// (tentative-skill fallback, LLM fallback) set values below `0.70`.
    /// `nil` when the route ended conversational or needed clarification.
    ///
    /// Read by ExecutionEngine's protected-tool filter — routes at or above
    /// `AppConfig.routeHighConfidenceThreshold` bypass the filter, because
    /// the router already had strong evidence and the gate's hint set is
    /// only an auxiliary signal.
    public internal(set) var lastRouteConfidence: Double?

    /// Name of the routing stage that produced the most recent decision.
    /// Written alongside `lastRouteConfidence` via `stampStage(_:confidence:)`.
    /// Read by ExecutionEngine for `TurnTraceCollector` emission.
    /// Stable stage names: modeOverride, modeChip, replyBypass, attachment,
    /// followUp, chip, remoteChip, ticker, url, modeEntry, skill, encoding,
    /// toolHelp, metaQuery, shortInput, mlVerifier, ml, commSafety,
    /// tentativeSkill, wikiFallback, llmFallback, conversationalFallback.
    public internal(set) var lastRouteStage: String?

    /// Helper: record both stage name and confidence in one call. Called
    /// immediately before returning from `route()` so the trace collector
    /// picks up the winning stage.
    func stampStage(_ name: String, confidence: Double? = nil) {
        lastRouteStage = name
        lastRouteConfidence = confidence
    }

    /// The prior user input from the context stack, available after follow-up detection.
    /// Used by ExecutionEngine to augment input for refinements.
    public var priorUserInput: String? {
        priorContextStack.first?.userInput
    }

    /// The most recent prior turn context. Used by ExecutionEngine to check
    /// for failure state when handling conversational follow-ups.
    public var priorContext: PriorTurnContext? {
        priorContextStack.first
    }

    /// The most recent non-empty prior context. Looks through conversational
    /// turns (which produce empty contexts) to find the last tool-bearing
    /// context. Used for entity resolution in follow-up turns — e.g., after
    /// wiki → conversational → follow-up, the wiki context has the entities.
    public var priorToolContext: PriorTurnContext? {
        priorContextStack.first(where: { !$0.isEmpty })
    }

    /// Token budget for tool schemas as defined in AppConfig (600 tokens).
    /// Assuming an average of 150 tokens per schema, we limit to 3 tools.
    let maxToolsToReturn = 3

    public init(availableTools: [any CoreTool], fmTools: [any FMToolDescriptor] = [], llmResponder: RouterLLMResponder? = nil, toolVerifier: ToolVerifier = ToolVerifier()) {
        self.availableTools = availableTools
        self.fmTools = fmTools
        self.llmResponder = llmResponder
        self.toolVerifier = toolVerifier

        // Load follow-up classifier eagerly (sync, ~1ms for 19KB model)
        if let modelURL = Bundle.iClawCore.url(forResource: "FollowUpClassifier_MaxEnt", withExtension: "mlmodelc"),
           let mlModel = try? MLModel(contentsOf: modelURL),
           let nlModel = try? NLModel(mlModel: mlModel) {
            self.followUpModel = nlModel
        } else {
            self.followUpModel = nil
        }

        // Load tool classifier eagerly for follow-up cross-validation (~2ms for 540KB model)
        if let modelURL = Bundle.iClawCore.url(forResource: "ToolClassifier_MaxEnt_Merged", withExtension: "mlmodelc"),
           let mlModel = try? MLModel(contentsOf: modelURL),
           let nlModel = try? NLModel(mlModel: mlModel) {
            self.toolClassifierModel = nlModel
        } else {
            self.toolClassifierModel = nil
        }
    }

    /// Sets the follow-up boost flag. When true, the context pill is anchored
    /// and the user has explicitly indicated their next input is a follow-up.
    /// This lowers the ML confidence threshold for follow-up detection.
    public func setFollowUpBoost(_ active: Bool) {
        followUpBoostActive = active
    }

    /// Pushes a new turn context onto the stack for follow-up detection.
    /// Called by ExecutionEngine after each successful run. Older entries
    /// beyond `AppConfig.maxPriorContextDepth` are evicted.
    public func setPriorContext(_ context: PriorTurnContext) {
        guard !context.isEmpty else { return }
        priorContextStack.insert(context, at: 0)
        if priorContextStack.count > AppConfig.maxPriorContextDepth {
            priorContextStack.removeLast()
        }
    }

    /// Clears the entire context stack (e.g., on conversation reset).
    public func clearPriorContext() {
        priorContextStack.removeAll()
    }

    /// Finds a CoreTool by name (case-insensitive via ToolNameNormalizer).
    /// Used by ExecutionEngine for chain execution and plan steps.
    public func findCoreTool(named name: String) -> (any CoreTool)? {
        availableTools.first { ToolNameNormalizer.matches($0.name, name) }
    }

    /// Pairs of tools the verifier LLM consistently confuses because their
    /// names share a prefix but their capabilities don't. When the ML classifier
    /// picks the left side and the verifier tries to "correct" to the right,
    /// the swap is rejected and the ML pick stands.
    ///
    /// `CalendarEvent → Calendar` is the canonical case: "when is my next
    /// meeting?" gets correctly classified as CalendarEvent (EventKit lookup),
    /// then the verifier LLM swaps it to Calendar (date arithmetic), which then
    /// silently falls back to "Today: <date>" and the finalizer fabricates an
    /// answer. Other pairs can be added here as they're identified.
    private static let blockedVerifierSwaps: [(from: String, to: String)] = [
        ("CalendarEvent", "Calendar")
    ]

    static func isBlockedVerifierSwap(from original: String, to replacement: String) -> Bool {
        blockedVerifierSwaps.contains { pair in
            pair.from.caseInsensitiveCompare(original) == .orderedSame
                && pair.to.caseInsensitiveCompare(replacement) == .orderedSame
        }
    }

    /// Main entry point for tool routing logic.
    /// - Parameter input: The user's natural language input string.
    /// - Returns: A `RoutingResult` indicating the selected tools or need for clarification.
    public func route(input: String, suppressedTools: Set<String> = []) async -> RoutingResult {
        // Strip [Replying to: ...] prefix before any classifier sees it.
        let hadReplyPrefix = input.hasPrefix("[Replying to:")
        let input = Self.stripReplyPrefix(input)

        currentSkill = nil
        helpContextToolName = nil
        lastDetectedTurnRelation = nil
        lastRouteConfidence = nil
        lastRouteStage = nil
        self.currentSuppressedTools = suppressedTools

        // Reply-context conversational bypass: when the user replies to a prior
        // message, the stripped query is often a generic follow-up ("use this in
        // a sentence", "explain more", "simplify it") that has no tool signal.
        // The full [Replying to:] context gives the LLM everything it needs.
        //
        // Signal hierarchy (highest to lowest):
        //   1. Structural signals — chip/ticker/URL → always route.
        //   2. ML intent classifier on the stripped payload — if it confidently
        //      says tool_action, don't bypass. The classifier covers verbs like
        //      "draft an email", "summarize this", "write a reply" that the
        //      hardcoded verb list misses, in every language.
        //   3. Hardcoded verb fallback — kept for when the classifier is
        //      unavailable, low-confidence, or not loaded in tests.
        if hadReplyPrefix {
            let hasChip = !InputParsingUtilities.extractToolChipNames(from: input).isEmpty
            let hasTicker = !InputParsingUtilities.extractTickerSymbols(from: input).isEmpty
            let hasURL = input.contains("://")
            // Classifier-based tool-intent check: high-tier `toolAction` wins over
            // the verb heuristic. The classifier is multilingual and already loaded
            // by the engine — re-querying with the stripped payload is ~16ms cached.
            var classifierSaysTool = false
            if AppConfig.useClassifierIntentRouting,
               let intent = await ConversationIntentClassifier.shared.classify(input),
               intent.label == .toolAction,
               intent.confidenceTier == .high {
                classifierSaysTool = true
            }
            let first = String(input.split(separator: " ").first ?? "").lowercased()
            let toolVerbs: Set<String> = [
                "play", "search", "find", "translate", "convert", "calculate",
                "set", "create", "open", "launch", "send", "schedule", "define",
                "navigate", "remind", "compose", "check",
            ]
            let hasToolVerb = toolVerbs.contains(first)
            if !hasChip && !hasTicker && !hasURL && !hasToolVerb && !classifierSaysTool {
                Log.router.debug("Reply-context conversational bypass (no tool signals in stripped query)")
                stampStage("replyBypass")
                return .conversational
            }
        }
        let skipModeActivation: Bool

        // Stage -1: Mode override — if a mode is active, intercept all routing
        if let mode = activeMode {
            if let modeResult = checkModeOverride(input: input, mode: mode) {
                skipModeActivation = false
                stampStage("modeOverride", confidence: 1.0)
                return modeResult
            }
            // Mode was just deactivated — prevent entry phrase re-activation
            skipModeActivation = modeJustDeactivated
        } else {
            skipModeActivation = false
        }
        modeJustDeactivated = false

        // Stage -1b: Mode chip activation — check for #rubberduck etc before normal chip routing
        if !skipModeActivation, let modeChipResult = checkModeChipActivation(input: input) {
            stampStage("modeChip", confidence: 1.0)
            return modeChipResult
        }


        // 0a. Attachment-aware routing hint
        if let attachmentResult = checkAttachmentHint(input: input) {
            stampStage("attachment", confidence: 1.0)
            return attachmentResult
        }

        // 0b. Follow-up detection — check if the user references a prior result
        if let followUpResult = await checkFollowUp(input: input) {
            Task { await TipDonations.donateFollowUpDetected() }
            stampStage("followUp", confidence: 1.0)
            return followUpResult
        }

        // 1. Check for explicit "Tool Chips" (e.g., #weather) or skill handles (e.g., #crypto)
        if let chippedResult = await checkToolChips(input: input) {
            stampStage("chip", confidence: 1.0)
            return chippedResult
        }

        // 1a2. Check for #remote chip — route to remote device
        #if CONTINUITY_ENABLED
        if let remoteResult = await checkRemoteChip(input: input) {
            stampStage("remoteChip", confidence: 1.0)
            return remoteResult
        }
        #endif

        // 1b. Check for ticker symbols (e.g., $META, $AAPL)
        if let tickerResult = checkTickerSymbols(input: input) {
            stampStage("ticker", confidence: 1.0)
            return tickerResult
        }

        // 1c. Check for URLs — auto-route to WebFetch for context fetching
        if let urlResult = checkURLs(input: input) {
            stampStage("url", confidence: 1.0)
            return urlResult
        }

        // 1d. Mode entry phrase detection — before skill matching
        if !skipModeActivation, let modeMatch = ToolManifest.modeForPhrase(input) {
            activateMode(name: modeMatch.name, config: modeMatch.config, groupId: UUID())
            stampStage("modeEntry", confidence: 1.0)
            return routeWithinMode(name: modeMatch.name, config: modeMatch.config)
        }

        // 2. Skill-based classification
        // High coverage (≥90%): accept immediately — the input closely matches an example.
        // Partial coverage (50-89%): tentative match — defer to ML for disambiguation.
        // This handles ambiguity like "give me a quote on AMD" (skill 67%, but ML → Stocks).
        var tentativeSkill: Skill?
        if let (skillMatch, coverage) = await checkSkillExamples(input: input) {
            if coverage >= 0.9 {
                Log.router.debug("Input matched skill: \(skillMatch.name) (coverage \(Int(coverage * 100))%)")
                self.currentSkill = skillMatch
                if let skillResult = buildSkillRoutingResult(for: skillMatch) {
                    stampStage("skill", confidence: 1.0)
                    return skillResult
                }
                Log.router.debug("Skill '\(skillMatch.name)' has no tool bindings — conversational with skill context.")
                stampStage("skillNoBindings")
                return .conversational
            } else {
                Log.router.debug("Tentative skill match: \(skillMatch.name) (coverage \(Int(coverage * 100))%) — deferring to ML")
                tentativeSkill = skillMatch
            }
        }

        // 2.5. Check for encoding format names — route to ConvertTool
        // Placed after skill matching to avoid false positives (e.g., "roman" in "Roman Empire").
        if let encodingResult = checkEncodingFormats(input: input) {
            stampStage("encoding", confidence: 1.0)
            return encodingResult
        }

        // 2a. Per-tool help detection — "weather help", "how do I use the calculator"
        if let toolHelpResult = checkToolHelpQuery(input: input) {
            stampStage("toolHelp", confidence: 1.0)
            return toolHelpResult
        }

        // 2b. Meta-query detection — questions about iClaw itself.
        // Phase 7b: uses the multilingual classifier ladder when enabled;
        // falls back to the English seed/embedding path when the classifier
        // flag is off or the classifier is low-confidence.
        if await isMetaQueryAsync(input: input) {
            if let helpTool = availableTools.first(where: { $0.name == ToolNames.help }) {
                Log.router.debug("Meta-query detected — routing to Help")
                stampStage("metaQuery", confidence: 1.0)
                return .tools([helpTool])
            }
            Log.router.debug("Meta-query detected — conversational")
            stampStage("metaQuery")
            return .conversational
        }

        // 2c. Emoji-dominated input bypass — emoji-only inputs like "🎲🎲🎲" or "🌤️"
        // are intentional actions, not conversational pleasantries. Detect via Unicode
        // properties (language-agnostic, no hardcoded emoji list) and let ML classify.
        let strippedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = strippedInput.unicodeScalars
        let emojiScalarCount = scalars.filter { $0.properties.isEmoji && $0.value > 0x238C }.count
        let isEmojiDominated = emojiScalarCount > 0 && Double(emojiScalarCount) / Double(max(1, scalars.count)) > RouterKeywordsConfig.shared.emojiThreshold

        // 2d. Very short non-actionable inputs → conversational.
        // Skip for emoji-dominated inputs (they're intentional actions).
        // Skip for explicit signals (chips, tickers, URLs).
        let trimmedWords = strippedInput
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let hasExplicitSignal = input.contains("#") || input.contains("$") || input.contains("://")
        let hasDiceNotation = strippedInput.range(of: #"\d*d\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
        if trimmedWords.count <= 2 && !hasExplicitSignal && !isEmojiDominated && !hasDiceNotation {
            let mlPeek = await classifyWithML(input: input)
            let topConf = mlPeek.first?.confidence ?? 0
            if topConf < MLThresholdsConfig.shared.routing.shortInputThreshold {
                Log.router.debug("Short non-actionable input → conversational: '\(input)'")
                stampStage("shortInput")
                return .conversational
            }
        }

        // 2d. Conversational bypass — REMOVED. The English keyword list
        // (joke/funny/humor/riddle) was redundant with
        // `ConversationIntentClassifier.conversation`, which fires
        // multilingually at the gate layer (Phase 5c) and short-circuits
        // before reaching the router. Keeping the keyword path was a
        // double-route bug magnet.

        // 2e. Synonym expansion — canonicalize input before ML
        let expandedInput = expandSynonyms(input: input)

        // 3. Use ML Classifier (trained MaxEnt model)
        let mlResults = await classifyWithML(input: expandedInput)

        // 4. Check ML confidence, apply verification or heuristic overrides
        let topMLConfidence = mlResults.first?.confidence ?? 0
        if var routingDecision = evaluateMLResults(mlResults, input: input) {
            // ToolVerifier: LLM-based routing validation for genuinely ambiguous results.
            //
            // Three confidence tiers:
            // - HIGH (≥0.75): Trust the ML classifier — fast path, no LLM call.
            // - MEDIUM (0.35-0.75): Verify with LLM (language-agnostic).
            // - LOW (<0.35): Fall through to LLM fallback routing (stage 5).
            let wordCount = input.split(separator: " ").count
            if topMLConfidence >= MLThresholdsConfig.shared.routing.mediumConfidence && topMLConfidence < MLThresholdsConfig.shared.routing.highConfidence,
               wordCount > 2,
               let toolName = routingDecision.primaryToolName {
                // Narrow the LLM's selection space to the ML classifier's
                // top-3 tool candidates, not the full 40+-tool catalog.
                // Empirically the 3B on-device model picks well from 3 but
                // poorly from 30 — this implements the "classifier narrows,
                // LLM disambiguates" pattern. The ML-committed `toolName`
                // is always included; the remaining slots are filled from
                // the next-highest-confidence resolved tool names, deduped.
                // If the classifier produced fewer than 3 distinct tools,
                // the list is padded with nothing — the LLM sees only the
                // real candidates. This keeps the selection task as small
                // and grounded as possible.
                let knownTools = Set(availableTools.map(\.name) + fmTools.map(\.name))
                var candidateTools: [String] = [toolName]
                for result in mlResults {
                    guard candidateTools.count < 3 else { break }
                    let resolved = LabelRegistry.lookup(result.label)?.tool ?? result.label
                    guard knownTools.contains(resolved),
                          !candidateTools.contains(resolved) else { continue }
                    candidateTools.append(resolved)
                }
                let verification = await toolVerifier.verify(
                    query: input,
                    suggestedTool: toolName,
                    availableTools: candidateTools
                )
                // Conversational escape: the verifier determined no tool is needed.
                // Guard: if input has strong messaging intent, redirect via the
                // communication channel resolver instead of going conversational.
                if verification.isConversational {
                    if CommunicationChannelResolver.hasCommunicationIntent(input) {
                        let toolNames = Set(availableTools.map(\.name))
                        let resolution = CommunicationChannelResolver.resolveFromIntent(
                            input: input, availableToolNames: toolNames
                        )
                        switch resolution {
                        case .definitive(let channel):
                            if let target = availableTools.first(where: { $0.name == channel.tool }) {
                                Log.router.debug("ToolVerifier said conversational but messaging intent → \(channel.tool)")
                                stampStage("verifierCommOverride", confidence: 0.8)
                                return .tools([target])
                            }
                        case .ambiguous(let channels):
                            Log.router.debug("ToolVerifier said conversational but messaging ambiguous: \(channels.map(\.tool))")
                            stampStage("verifierCommAmbiguous", confidence: 0.8)
                            return .requiresDisambiguation(choices: channels.map(\.tool))
                        case .notCommunication:
                            break
                        }
                    }
                    Log.router.debug("ToolVerifier: conversational — no tool needed for '\(input.prefix(40))'")
                    stampStage("verifierConversational")
                    return .conversational
                }
                if !verification.isCorrect, let betterTool = verification.betterTool {
                    // Don't let the verifier override FM tools with core tools.
                    let isFMtoCore = routingDecision.isFMTool && availableTools.contains(where: {
                        $0.name.caseInsensitiveCompare(betterTool) == .orderedSame
                    })
                    // Category-confusion guard: some tool pairs share a surface
                    // name ("Calendar" vs "CalendarEvent") but are semantically
                    // distinct. Verifier LLMs routinely confuse them, demoting
                    // event-lookup queries to date-arithmetic — which then
                    // silently falls back to "Today: <date>". Block these
                    // specific swaps; let the original ML pick stand.
                    let isBlockedCategorySwap = Self.isBlockedVerifierSwap(from: toolName, to: betterTool)
                    if isFMtoCore {
                        Log.router.debug("ToolVerifier suggested \(toolName) → \(betterTool) but blocked (FM→Core override not allowed)")
                    } else if isBlockedCategorySwap {
                        Log.router.info("ToolVerifier suggested \(toolName) → \(betterTool) but blocked (category-confusion swap)")
                    } else if let corrected = resolveToolByNameAny(betterTool) {
                        Log.router.info("ToolVerifier corrected: \(toolName) → \(betterTool) (\(verification.reason ?? ""))")
                        // Verifier-corrected route: LLM-validated, so confidence is
                        // higher than the raw medium-tier ML score.
                        stampStage("mlVerifier", confidence: max(topMLConfidence, 0.75))
                        return corrected
                    }
                }
            }
            // Fall through to heuristic overrides for cases the verifier didn't handle
            routingDecision = await applyHeuristicOverrides(input: input, decision: routingDecision)
            stampStage("ml", confidence: topMLConfidence)
            return routingDecision
        }

        // 4a2. Communication-intent safety net: if ML resolution failed (label not in
        // LabelRegistry, tool not registered) but input has messaging intent, redirect
        // via the communication channel resolver.
        if CommunicationChannelResolver.hasCommunicationIntent(input) {
            let toolNames = Set(availableTools.map(\.name))
            let resolution = CommunicationChannelResolver.resolveFromIntent(
                input: input, availableToolNames: toolNames
            )
            switch resolution {
            case .definitive(let channel):
                if let target = availableTools.first(where: { $0.name == channel.tool }) {
                    Log.router.debug("Communication safety net → \(channel.tool) (ML resolution failed)")
                    // Safety-net fires when ML resolution FAILED — it's a fallback, not
                    // high confidence. Kept below `routeHighConfidenceThreshold` (0.70)
                    // so the ExecutionEngine's protected-tool filter still arbitrates
                    // with the gate's structural hints. Prevents the 2026-04
                    // "whats Shawn's email?" → Messages misroute: the gate hinted
                    // [WikipediaSearch], safety net pushed 0.8 → filter bypassed → sent
                    // a literal iMessage of the word "email" to Shawn.
                    stampStage("commSafety", confidence: 0.5)
                    return .tools([target])
                }
            case .ambiguous(let channels):
                Log.router.debug("Communication safety net ambiguous: \(channels.map(\.tool))")
                stampStage("commSafetyAmbiguous", confidence: 0.5)
                return .requiresDisambiguation(choices: channels.map(\.tool))
            case .notCommunication:
                break
            }
        }

        // 4b. Tentative skill fallback: ML wasn't confident enough to route, but we
        // had a partial skill match earlier. Accept it now — the skill's intent is a
        // better signal than falling through to conversational.
        if let skill = tentativeSkill {
            Log.router.debug("Accepting tentative skill: \(skill.name) (ML inconclusive)")
            self.currentSkill = skill
            if let skillResult = buildSkillRoutingResult(for: skill) {
                // Tentative skill = partial coverage (<90%). Keep confidence below
                // the protected-filter bypass threshold; the gate's hints still
                // arbitrate in this case.
                stampStage("tentativeSkill", confidence: 0.5)
                return skillResult
            }
            stampStage("tentativeSkillNoBindings")
            return .conversational
        }

        // 4c. Knowledge-query fallback. "Tell me about X" / "What is Y" /
        // "Who was Z" are shaped like encyclopedic lookups. When the ML
        // classifier failed to pick a tool (common on pivot turns, where the
        // prior turn's topic biases the classifier away from a new subject)
        // we still want to route these to WikipediaSearch rather than drop
        // to conversational — the LLM will otherwise treat stale prior-turn
        // tool data as authoritative and refuse the new topic.
        if CommunicationChannelResolver.isKnowledgeQueryPhrasing(input),
           let wiki = availableTools.first(where: { $0.name == "WikipediaSearch" }) {
            Log.router.debug("Knowledge-query fallback → WikipediaSearch ('\(input.prefix(40))')")
            stampStage("wikiFallback", confidence: 0.6)
            return .tools([wiki])
        }

        // 5. Structural fast-path: if ML returned nil (no tool matched) and the
        // query is short (≤10 words), it's almost certainly conversational.
        let wordCount = input.split(separator: " ").count
        if wordCount <= 10 {
            Log.router.debug("Short unmatched query (\(wordCount) words) → conversational: '\(input.prefix(40))'")
            stampStage("shortUnmatched")
            return .conversational
        }

        // 5b. LLM fallback for longer ambiguous queries where the extra cost
        // of an LLM routing call is justified.
        if let llmDecision = await llmFallback(input: input) {
            // LLM fallback: structured but unverified. Keep below the bypass
            // threshold so protected-tool filter can still arbitrate.
            stampStage("llmFallback", confidence: 0.6)
            return llmDecision
        }

        // 6. Conversational fallback — no tool matched
        Log.router.debug("No tool matched — routing to conversational mode")
        stampStage("conversationalFallback")
        return .conversational
    }
}

// Marker extension for RoutingResult Sendability.
extension ToolRouter.RoutingResult: Sendable {}

/// Thin proxy that injects a matched follow-up URL into the tool input.
/// The wrapped tool (WebFetch) receives the URL so it can fetch the article.
struct FollowUpWebFetchProxy: CoreTool, Sendable {
    let wrapped: any CoreTool
    let url: String

    var name: String { wrapped.name }
    var schema: String { wrapped.schema }
    var isInternal: Bool { wrapped.isInternal }
    var category: CategoryEnum { wrapped.category }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        // Prepend the URL so WebFetchTool's URL detection picks it up
        let augmentedInput = "\(url) \(input)"
        return try await wrapped.execute(input: augmentedInput, entities: entities)
    }
}
