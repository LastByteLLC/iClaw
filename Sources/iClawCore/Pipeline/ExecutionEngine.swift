import Foundation
import Combine
import FoundationModels
import NaturalLanguage
import Translation
import os

/// Closure type for injecting a test LLM responder into the execution engine.
/// When `nil`, the real `LanguageModelSession` is used.
public typealias LLMResponder = ToolAwareLLMResponder

/// ExecutionEngine handles the core logic of the iClaw processing loop using an Enum-based Finite State Machine (FSM).
/// Adheres to Swift 6 strict concurrency requirements using an actor to manage internal state.
public actor ExecutionEngine {

    /// Possible states for the ExecutionEngine FSM.
    ///
    /// Flow: idle -> preprocessing -> routing -> [planning] -> toolExecution -> finalization -> idle
    /// With branches to disambiguation or error at any point.
    public enum State: Sendable, Equatable {
        case idle
        case preprocessing // NER, OCR
        case routing // ML, Tool chips
        case planning // Multi-step decomposition (new)
        case disambiguation(options: [String]) // User choice if ML ties
        case toolExecution(callCount: Int) // Tracking max calls
        case finalization // SOUL + Tuples
        case error(message: String)
    }

    /// Result of a routing state handler, indicating what the main loop should do next.
    enum RoutingAction {
        /// Re-enter the while loop (e.g., after validation retry).
        case continueLoop
        /// Proceed to finalization.
        case proceedToFinalization
        /// Return immediately from run() with this result.
        case earlyReturn(text: String, widgetType: String?, widgetData: (any Sendable)?, isError: Bool, suggestedQueries: [String]? = nil)
    }

    // MARK: - Cached Patterns

    /// Pre-compiled pattern for attachment tag detection (avoids regex compilation every turn).
    static let attachedTagPattern = "\\[Attached: ([^\\]]+)\\]"

    // MARK: - Properties

    private(set) var currentState: State = .idle
    var toolCallCounter: Int = 0
    var currentIngredients: [String] = []
    var currentEntities: ExtractedEntities?

    /// Strips `[VERIFIED]` / `[CACHED]` prefixes from an ingredient string to get raw content.
    static func stripIngredientPrefixes(_ text: String) -> String {
        var t = text
        for prefix in ["[VERIFIED] [CACHED] ", "[VERIFIED] ", "[CACHED] "] {
            if t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
                break
            }
        }
        return t
    }

    /// Returns `true` if `currentIngredients` already contains content identical to `candidate`
    /// after stripping prefix tags.
    func ingredientAlreadyPresent(_ candidate: String) -> Bool {
        let strippedCandidate = Self.stripIngredientPrefixes(candidate)
        return currentIngredients.contains { existing in
            Self.stripIngredientPrefixes(existing) == strippedCandidate
        }
    }
    var currentFMTools: [any FMToolDescriptor] = []
    var lastWidgetType: String?
    var lastWidgetData: (any Sendable)?
    var lastSuggestedQueries: [String]?
    /// Per-turn set of tool names that have already had their fallback tried,
    /// so we don't loop. Capped at 1 fallback per tool per turn.
    var fallbackAttempted: Set<String> = []
    /// Pre-formed user-facing text that finalization should emit verbatim,
    /// bypassing the LLM. Used by handleDisambiguation and any other stage
    /// that knows the exact output and doesn't need generation. Prevents the
    /// LLM from echoing or paraphrasing internal planner instructions.
    var pendingDirectResponse: String?
    var currentWidgetPayload: [String: String]?
    var hadToolError: Bool = false
    var currentAttachmentPath: String?
    /// Stores injected context/user block content for leak detection in cleanLLMResponse.
    var injectedContextWords: Set<String> = []
    /// Distinctive 4-gram phrases from brain+soul+ingredients. If the response
    /// contains several of these as contiguous word sequences, it's echoing
    /// its own system prompt rather than answering. Language-independent:
    /// tokenization is over `.alphanumerics.inverted`, so any script works.
    var injectedPhraseGrams: Set<String> = []
    /// Tools suppressed during ingredient validation re-routing.
    var suppressedTools: Set<String> = []
    /// Whether ingredient validation has already retried this turn.
    var hasValidationRetried: Bool = false
    /// Ingredients stashed when validation triggered a re-route. If the
    /// re-routed path produces nothing substantive, these are merged back into
    /// `currentIngredients` (tagged `[UNVALIDATED]`) so finalization + extractive
    /// fallback have something to work with instead of a blank turn.
    var shelvedIngredients: [String] = []
    /// Tool name that was denied consent during this turn (for prior context propagation).
    var consentDeniedToolName: String?
    /// When true, consent-requiring tools are silently skipped (used by heartbeat/greeting background runs).
    var skipConsentThisTurn: Bool = false
    /// Set when auto-translation fails — signals the router that input may be non-English
    /// and ML classification confidence should be treated with lower trust.
    var translationFailed: Bool = false

    /// The most recent ConversationalGate decision, set during preprocessing.
    /// `.conversational` / `.clarification` / `.replyElaboration` short-circuit
    /// routing; `.candidateScope` scopes the router's output; `.toolSignal`
    /// lets the router run normally with a hinted hard-signal tool.
    /// The finalizer reads this to choose its prompt mode.
    var currentGateDecision: ConversationalGate.Decision?

    /// Handles to background LLM-using tasks (knowledge extraction +
    /// quality assessment) spawned at turn end. The adapter is an actor —
    /// when these tasks are in flight, a foreground turn that also needs
    /// the LLM queues behind them. To keep turn N+1 responsive we CANCEL
    /// unfinished background work from turn N before scheduling turn N's
    /// new tasks (the prior work is stale by then anyway). This bounds
    /// adapter queue depth to "one background + one foreground" in the
    /// worst case, eliminating the pileup that produced the earlier
    /// 40-second timeouts on rapid follow-up turns.
    private var pendingKnowledgeTask: Task<Void, Never>?
    private var pendingQualityTask: Task<Void, Never>?

    /// The tool name(s) selected by the router for the current turn.
    /// Set during routing, before tool execution. Allows callers to distinguish
    /// routing accuracy from execution success (a tool can be correctly routed
    /// but fail at execution due to network/permission errors).
    public internal(set) var lastRoutedToolNames: [String] = []

    /// Per-turn diagnostic telemetry. Populated during routing and execution
    /// so external harnesses (CLI, autonomous test loop) can reason about
    /// which stage fired, whether a pivot was detected, and classifier
    /// confidence — without having to grep logs.
    public struct TurnTelemetry: Sendable {
        public enum RoutingOutcome: String, Sendable {
            case tools              // one or more real tools ran
            case fmTools            // FM tool(s) dispatched
            case mixed              // mix of core + FM
            case disambiguation     // router returned ambiguous choices
            case conversational     // conversational fallback
            case clarification      // tool asked user for more info
            case error              // routing itself failed
        }
        public var routingOutcome: RoutingOutcome = .conversational
        public var realToolNames: [String] = []   // synthetic labels filtered out
        public var pivotDetected: Bool = false
        public var followUpDetected: Bool = false
        public var classifierLabel: String?       // ML tool classifier label
        public var classifierConfidence: Double?
        public var followUpOutcome: String?       // continuation/pivot/refine/…
    }

    public internal(set) var lastTurnTelemetry: TurnTelemetry = TurnTelemetry()

    /// Snapshot of the per-turn `TurnTraceCollector`. Populated at the end of
    /// `run(input:)`. Consumed by the CLI trace writer and the meta-harness
    /// evaluator for causal reasoning over router stages + LLM call budgets.
    /// `nil` before any turn has run; never cleared (always reflects the most
    /// recent turn).
    public internal(set) var lastTurnTrace: TurnTraceCollector.Snapshot?

    /// The detected turn relation for the current input (set during routing).
    /// Used to augment tool input for refinements.
    var currentTurnRelation: FollowUpClassifier.TurnRelation?

    /// URL fetched via FollowUpWebFetchProxy or direct WebFetch this turn.
    /// Captured so `updatePriorContext()` can store it as a reference for follow-ups.
    var lastWebFetchURL: String?

    /// Caller-provided hint for this turn's finalization (R5: manual retry button).
    /// Cleared in `resetRunState`. When `.minimal`, the recovery ladder skips
    /// Tier 1 and starts at Tier 2.
    var currentRecoveryHint: RecoveryHint?

    /// When true, browser content is the focal point -- skip tool routing.
    var browserContextIsFocalPoint = false

    /// Cached translation availability checker (avoids per-turn allocation).
    /// LanguageAvailability is a stateless query API; safe for concurrent read access.
    nonisolated(unsafe) static let translationAvailability = LanguageAvailability()

    let preprocessor: InputPreprocessor
    let router: ToolRouter
    let conversationManager: ConversationManager
    let finalizer: OutputFinalizer
    let planner: ExecutionPlanner
    let agentRunner: AgentRunner
    let llmAdapter: LLMAdapter
    let llmResponder: LLMResponder?
    let argumentExtractor: ToolArgumentExtractor
    let widgetLayoutGenerator: WidgetLayoutGenerator
    let skillCache: SkillCache
    let toolVerifier: ToolVerifier

    // MARK: - Performance Timing

    var stageStart: ContinuousClock.Instant = .now
    var stageDurations: [(stage: String, ms: Double)] = []

    /// OSSignposter used to emit FSM state-transition events. Visible in
    /// Instruments under the "Points of Interest" track — lets you see a
    /// turn's pipeline trace without parsing logs. Categories per state.
    nonisolated static let signposter = OSSignposter(
        subsystem: "com.podlp.iclaw",
        category: "ExecutionEngine"
    )

    // MARK: - Turn State Snapshot (for reset-correctness testing)

    /// A lightweight equatable snapshot of all turn-scoped state. Designed as a
    /// forcing function: when a maintainer adds a new property that should
    /// reset between turns, they must add a field here (counts or presence,
    /// not full equality — `(any Sendable)?` isn't Equatable). The matching
    /// test in `TurnResetTests.swift` fails when `resetRunState()` forgets to
    /// clear a property, making state-leak bugs (M8-style, where a stale
    /// `translationFailed` flag survived into the next turn) visible at the
    /// test boundary instead of in production.
    public struct TurnStateSnapshot: Equatable, Sendable {
        public var toolCallCounter: Int = 0
        public var ingredientCount: Int = 0
        public var entitiesPresent: Bool = false
        public var fmToolCount: Int = 0
        public var hasWidgetType: Bool = false
        public var hasWidgetData: Bool = false
        public var hasSuggestedQueries: Bool = false
        public var fallbackAttemptedCount: Int = 0
        public var pendingDirectResponsePresent: Bool = false
        public var widgetPayloadPresent: Bool = false
        public var hadToolError: Bool = false
        public var attachmentPathPresent: Bool = false
        public var injectedContextWordCount: Int = 0
        public var injectedPhraseGramCount: Int = 0
        public var suppressedToolCount: Int = 0
        public var hasValidationRetried: Bool = false
        public var shelvedIngredientCount: Int = 0
        public var consentDeniedToolNamePresent: Bool = false
        public var skipConsentThisTurn: Bool = false
        public var translationFailed: Bool = false
        public var gateDecisionPresent: Bool = false
        public var turnRelationPresent: Bool = false
        public var webFetchURLPresent: Bool = false
        public var recoveryHintPresent: Bool = false
        public var browserContextIsFocalPoint: Bool = false

        public static let empty = TurnStateSnapshot()
    }

    /// Returns the current turn-scoped state as an equatable snapshot. Intended
    /// for test assertions that `resetRunState()` returns everything to `.empty`.
    public func debugTurnSnapshot() -> TurnStateSnapshot {
        TurnStateSnapshot(
            toolCallCounter: toolCallCounter,
            ingredientCount: currentIngredients.count,
            entitiesPresent: currentEntities != nil,
            fmToolCount: currentFMTools.count,
            hasWidgetType: lastWidgetType != nil,
            hasWidgetData: lastWidgetData != nil,
            hasSuggestedQueries: lastSuggestedQueries != nil,
            fallbackAttemptedCount: fallbackAttempted.count,
            pendingDirectResponsePresent: pendingDirectResponse != nil,
            widgetPayloadPresent: currentWidgetPayload != nil,
            hadToolError: hadToolError,
            attachmentPathPresent: currentAttachmentPath != nil,
            injectedContextWordCount: injectedContextWords.count,
            injectedPhraseGramCount: injectedPhraseGrams.count,
            suppressedToolCount: suppressedTools.count,
            hasValidationRetried: hasValidationRetried,
            shelvedIngredientCount: shelvedIngredients.count,
            consentDeniedToolNamePresent: consentDeniedToolName != nil,
            skipConsentThisTurn: skipConsentThisTurn,
            translationFailed: translationFailed,
            gateDecisionPresent: currentGateDecision != nil,
            turnRelationPresent: currentTurnRelation != nil,
            webFetchURLPresent: lastWebFetchURL != nil,
            recoveryHintPresent: currentRecoveryHint != nil,
            browserContextIsFocalPoint: browserContextIsFocalPoint
        )
    }

    // MARK: - Progress Stream (Phase 1)

    let _progressContinuation = OSAllocatedUnfairLock<AsyncStream<ProgressUpdate>.Continuation?>(initialState: nil)

    /// Creates a new progress stream. Subscribe before calling `run()`.
    public nonisolated func makeProgressStream() -> AsyncStream<ProgressUpdate> {
        AsyncStream { continuation in
            _progressContinuation.withLock { $0 = continuation }
        }
    }

    func emitProgress(_ update: ProgressUpdate) {
        _progressContinuation.withLock { _ = $0?.yield(update) }
    }

    func finishProgress() {
        _progressContinuation.withLock { $0?.finish() }
    }

    public static let shared = ExecutionEngine(
        preprocessor: InputPreprocessor(),
        router: ToolRouter(availableTools: ToolRegistry.coreTools, fmTools: ToolRegistry.fmTools),
        conversationManager: ConversationManager(),
        finalizer: OutputFinalizer(),
        planner: ExecutionPlanner(),
        agentRunner: AgentRunner()
    )

    // MARK: - Initializer

    public init(
        preprocessor: InputPreprocessor = InputPreprocessor(),
        router: ToolRouter = ToolRouter(availableTools: []),
        conversationManager: ConversationManager = ConversationManager(),
        finalizer: OutputFinalizer = OutputFinalizer(),
        planner: ExecutionPlanner = ExecutionPlanner(),
        agentRunner: AgentRunner = AgentRunner(),
        llmAdapter: LLMAdapter = .shared,
        llmResponder: LLMResponder? = nil,
        argumentExtractor: ToolArgumentExtractor = ToolArgumentExtractor(),
        widgetLayoutGenerator: WidgetLayoutGenerator? = nil,
        skillCache: SkillCache = .shared
    ) {
        self.preprocessor = preprocessor
        self.router = router
        self.conversationManager = conversationManager
        self.finalizer = finalizer
        self.planner = planner
        self.agentRunner = agentRunner
        self.llmAdapter = llmAdapter
        self.llmResponder = llmResponder
        self.argumentExtractor = argumentExtractor
        self.widgetLayoutGenerator = widgetLayoutGenerator ?? WidgetLayoutGenerator(llmAdapter: llmAdapter)
        self.skillCache = skillCache
        self.toolVerifier = ToolVerifier()
    }

    // MARK: - Skill Mode Passthroughs

    /// Activates a skill mode on the router.
    public func activateSkillMode(name: String, config: ModeConfig, groupId: UUID) async {
        await router.activateMode(name: name, config: config, groupId: groupId)
    }

    /// Deactivates the current skill mode on the router.
    public func deactivateSkillMode() async {
        await router.deactivateMode()
    }

    /// Returns the currently active skill mode, if any.
    public func activeSkillMode() async -> (name: String, config: ModeConfig)? {
        await router.activeMode
    }

    /// Returns the current mode group ID, if any.
    public func activeModeGroupId() async -> UUID? {
        await router.activeModeGroupId
    }

    // MARK: - Execution Loop

    /// Runs the execution loop for a given input or intent.
    /// - Parameter input: The initial input string or user request.
    /// - Returns: A final result or error.
    public func run(
        input: String,
        skipConsent: Bool = false,
        widgetPayload: [String: String]? = nil,
        recoveryHint: RecoveryHint? = nil
    ) async -> (text: String, widgetType: String?, widgetData: (any Sendable)?, isError: Bool, suggestedQueries: [String]?) {
        // Install a fresh per-turn trace collector for the duration of this run.
        // Router stages and LLMAdapter calls running anywhere in this task tree
        // write into it via `TurnTraceCollector.current`; at end of turn we
        // snapshot into `lastTurnTrace` for the CLI/evaluator to read.
        let collector = TurnTraceCollector()
        let result = await TurnTraceCollector.$current.withValue(collector) {
            await runInner(
                input: input,
                skipConsent: skipConsent,
                widgetPayload: widgetPayload,
                recoveryHint: recoveryHint
            )
        }
        self.lastTurnTrace = await collector.snapshot()
        return result
    }

    /// Records the router's winning stage for the most recent `router.route(...)`
    /// call to the task-local `TurnTraceCollector`, if one is installed. No-op
    /// outside a traced turn.
    private func recordRouterStageTrace(result: ToolRouter.RoutingResult) async {
        guard let collector = TurnTraceCollector.current else { return }
        let stage = await router.lastRouteStage ?? "unknown"
        let confidence = await router.lastRouteConfidence
        let decision: String
        switch result {
        case .tools(let t): decision = t.first.map { $0.name } ?? "empty"
        case .fmTools(let t): decision = t.first.map { $0.name } ?? "empty"
        case .mixed(let c, _): decision = c.first.map { $0.name } ?? "empty"
        case .requiresDisambiguation(let choices): decision = "disambiguation(\(choices.joined(separator: ",")))"
        case .conversational: decision = "conversational"
        case .needsUserClarification: decision = "clarification"
        }
        await collector.recordRouterStage(.init(
            stage: stage, decision: decision, confidence: confidence, reason: nil
        ))
    }

    /// Inner body of `run(input:)`. Extracted so the outer `run` can install
    /// a TaskLocal trace collector without rewriting the entire loop.
    private func runInner(
        input: String,
        skipConsent: Bool,
        widgetPayload: [String: String]?,
        recoveryHint: RecoveryHint?
    ) async -> (text: String, widgetType: String?, widgetData: (any Sendable)?, isError: Bool, suggestedQueries: [String]?) {
        Log.engine.debug("Starting processing for input: '\(input)'")
        skipConsentThisTurn = skipConsent
        currentWidgetPayload = widgetPayload
        currentRecoveryHint = recoveryHint
        stageDurations = []
        stageStart = .now
        let turnStart = ContinuousClock.now
        await transitionTo(.preprocessing)

        // Parse and strip [Attached: /path] prefix (regex cached as static)
        var processedInput = input
        if let attachRange = input.range(of: Self.attachedTagPattern, options: .regularExpression) {
            let tag = String(input[attachRange])
            // Extract path from between brackets
            if let pathStart = tag.range(of: "[Attached: ")?.upperBound,
               let pathEnd = tag.range(of: "]")?.lowerBound {
                currentAttachmentPath = String(tag[pathStart..<pathEnd])
            }
            // Strip the tag and any trailing newline
            processedInput = input.replacingCharacters(in: attachRange, with: "")
            if processedInput.hasPrefix("\n") {
                processedInput = String(processedInput.dropFirst())
            }
            Log.engine.debug("Attachment detected: \(self.currentAttachmentPath ?? "nil")")
        }

        while currentState != .idle && !isErrorState(currentState) {
            switch currentState {
            case .preprocessing:
                processedInput = await TurnTraceCollector.$currentSite.withValue("preprocessing") {
                    await handlePreprocessing(processedInput: processedInput)
                }

            case .routing:
                let action = await TurnTraceCollector.$currentSite.withValue("routing") {
                    await handleRouting(processedInput: processedInput)
                }
                switch action {
                case .continueLoop:
                    continue
                case .proceedToFinalization:
                    break
                case .earlyReturn(let text, let widgetType, let widgetData, let isError, let suggestedQueries):
                    return (text, widgetType, widgetData, isError, suggestedQueries)
                }

            case .planning:
                await TurnTraceCollector.$currentSite.withValue("planning") {
                    await handlePlanning()
                }

            case .disambiguation(let options):
                await handleDisambiguation(options: options, processedInput: processedInput)

            case .toolExecution(let callCount):
                await TurnTraceCollector.$currentSite.withValue("toolExecution") {
                    await handleToolExecution(callCount: callCount)
                }

            case .finalization:
                let result = await TurnTraceCollector.$currentSite.withValue("finalization") {
                    await handleFinalization(processedInput: processedInput, turnStart: turnStart)
                }
                return result

            case .error(let message):
                Log.engine.error("\(message)")
                // Loop will exit due to isErrorState

            case .idle:
                break
            }
        }

        let resultMessage: String
        if case .error(let message) = currentState {
            resultMessage = message
        } else {
            resultMessage = await Personalizer.shared.personalize("Something went wrong. Try again.")
        }

        Log.engine.debug("Processing complete.")
        resetRunState()
        await transitionTo(.idle)
        finishProgress()
        return (resultMessage, nil as String?, nil as (any Sendable)?, true, nil as [String]?)
    }

    // MARK: - State Handlers

    /// Handles the preprocessing state: entity extraction, spellcheck, translation,
    /// toxicity filtering, and context injection.
    private func handlePreprocessing(processedInput: String) async -> String {
        Log.engine.debug("Preprocessing input...")
        emitProgress(.processing(description: "Preprocessing"))
        var result = processedInput
        self.translationFailed = false
        let entities = await preprocessor.extractEntities(input: result)
        // Merge widget payload into entities if present (from WidgetAction tap)
        if let wp = currentWidgetPayload, !wp.isEmpty {
            self.currentEntities = ExtractedEntities(
                names: entities.names, places: entities.places,
                organizations: entities.organizations, urls: entities.urls,
                phoneNumbers: entities.phoneNumbers, emails: entities.emails,
                ocrText: entities.ocrText, correctedInput: entities.correctedInput,
                detectedLanguage: entities.detectedLanguage, widgetPayload: wp
            )
        } else {
            self.currentEntities = entities
        }
        Log.engine.debug("Extracted entities: \(String(describing: entities))")

        // Apply spellcheck corrections
        if let corrected = entities.correctedInput {
            result = corrected
            Log.engine.debug("Spellcheck corrected: \(corrected)")
        }

        // Auto-translate non-English input to English before routing.
        // The ML classifier and heuristics are trained on English; translating
        // first ensures consistent routing regardless of input language.
        // The detected language is preserved for response language matching.
        if let lang = entities.detectedLanguage, !lang.hasPrefix("en"), lang != "und" {
            do {
                let source = Locale.Language(identifier: lang)
                let target = Locale.Language(identifier: "en")
                let status = await Self.translationAvailability.status(from: source, to: target)
                if status == .installed || status == .supported {
                    let session = TranslationSession(installedSource: source, target: target)
                    let response = try await session.translate(result)
                    Log.engine.debug("Auto-translated from \(lang): '\(result.prefix(40))' -> '\(response.targetText.prefix(40))'")
                    result = response.targetText
                }
            } catch {
                Log.engine.debug("Auto-translate failed for \(lang): \(error)")
                // Flag translation failure so the router knows the input is non-English.
                // Without this, the English-trained ML classifier may mis-route.
                self.translationFailed = true
            }
        }

        // Sanitize profanity -- clean the input for routing and LLM
        let toxicity = await ToxicityClassifier.shared.check(result)
        if toxicity.isToxic {
            result = toxicity.cleanedText
            Log.engine.debug("Profanity sanitized (confidence: \(toxicity.confidence))")
        }

        // Inject passive screen context as ingredient if enabled
        #if os(macOS)
        if UserDefaults.standard.bool(forKey: AppConfig.screenContextEnabledKey),
           let screenText = await ScreenContextManager.shared.currentScreenContext {
            currentIngredients.append("Screen context (what's currently visible): \(screenText)")
        }
        #endif

        // Inject browser context from Safari extension if available
        #if os(macOS)
        browserContextIsFocalPoint = false
        if UserDefaults.standard.bool(forKey: AppConfig.browserBridgeEnabledKey),
           let ctx = await BrowserBridge.shared.lastBrowserContext {
            if ctx.hasContent {
                // User explicitly pushed full content -- use data chunk budget
                let charLimit = AppConfig.retrievedDataChunks * 4
                let compacted = ContentCompactor.compact(ctx.fullText ?? "", limit: charLimit)
                let label = ctx.selectionOnly ? "BROWSER SELECTION" : "BROWSER PAGE"
                currentIngredients.append("[\(label)] \(ctx.title) (\(ctx.url))\n\(compacted)")
                // If user pushed content and query doesn't have strong tool signals,
                // treat the browser content as the focal point (skip tool routing)
                if !hasExplicitRoutingSignal(result) {
                    browserContextIsFocalPoint = true
                }
            } else if !ctx.url.isEmpty {
                // Lightweight metadata -- always inject if available
                currentIngredients.append("[BROWSER] Currently browsing: \(ctx.title) (\(ctx.url))")
                // Check if user is referencing browser content
                if Self.queryReferencesBrowser(result) {
                    await BrowserBridge.shared.requestFullContent()
                }
            }
        }
        #endif

        // Inject relevant knowledge memories
        if UserDefaults.standard.bool(forKey: AppConfig.knowledgeMemoryEnabledKey) {
            let memories = await KnowledgeMemoryManager.shared.retrieve(for: result, limit: AppConfig.knowledgeMemoryMaxPerTurn)
            for entry in memories {
                currentIngredients.append("[MEMORY] \(entry.key): \(entry.value)")
            }
        }

        // Synchronous preference detection: if the user is stating a
        // preference this turn (unit system, etc.) commit it NOW so downstream
        // tools see it on the very same turn and on all subsequent turns.
        // The async `extractKnowledge` path still runs later and catches
        // broader preferences (food, relationships, etc.).
        if let match = PreferenceDetector.detect(in: result) {
            await conversationManager.setPreference(key: match.key, value: match.value)
            Self.mirrorPreferenceToUserDefaults(key: match.key, value: match.value)
            Log.engine.debug("Preference recorded (sync): \(match.key)=\(match.value)")
        }

        // Phase-5 user-fact detection: multilingual ML classifier runs
        // alongside (NOT instead of) the English PreferenceDetector when the
        // feature flag is on. High-confidence non-`none` predictions persist
        // to `state.userFacts` for injection into the `<ctx>` block on
        // subsequent turns. Medium-confidence predictions optionally consult
        // the LLM judge when its own flag is also on.
        if AppConfig.useClassifierUserFacts {
            let factStart = ContinuousClock.now
            if let probe = await UserFactClassifier.shared.classify(result) {
                var judgeCalled = false
                var via = "classifier"
                let resolvedLabel: UserFactClassifier.Label?
                switch probe.confidenceTier {
                case .high:
                    resolvedLabel = probe.label
                case .medium:
                    if AppConfig.useLLMJudge {
                        judgeCalled = true
                        let judgeLabel = await LLMJudge.shared.judgeUserFact(
                            input: result, classifierHint: probe
                        )
                        resolvedLabel = judgeLabel ?? probe.label
                        if judgeLabel != nil { via = "judge" }
                    } else {
                        resolvedLabel = probe.label
                    }
                case .low:
                    resolvedLabel = nil
                    via = "skipped"
                }
                if let label = resolvedLabel, label != .none {
                    await conversationManager.recordUserFact(
                        category: label.rawValue, value: result
                    )
                } else if probe.label == .none || probe.confidenceTier == .low {
                    // Linguistic fallback via NLTagger: detect first-person
                    // declarative shape using POS tags. No English phrase list.
                    // Patterns recognized:
                    //   (pronoun=i/my) + (verb=am/is/be) + (noun/adj)
                    //   (pronoun=my) + (noun) + (verb=is) + (noun)
                    // Covers "My name is X", "I'm allergic to X", "I have a dog",
                    // "I live in X", "I work at X" multilingually (the lexical
                    // class tags apply in every language NLTagger supports).
                    if let fact = FactHeuristic.detect(in: result) {
                        await conversationManager.recordUserFact(
                            category: fact.category, value: result
                        )
                    }
                }
                let elapsed = factStart.duration(to: .now)
                let ms = Int(elapsed.components.seconds * 1000
                             + elapsed.components.attoseconds / 1_000_000_000_000_000)
                ClassifierTelemetry.record(
                    classifier: "userfact",
                    label: probe.label.rawValue,
                    confidence: probe.confidence,
                    tier: String(describing: probe.confidenceTier),
                    resolvedVia: via,
                    judgeCalled: judgeCalled,
                    latencyMs: ms
                )
            }
        }

        // ConversationalGate: language-neutral positive-evidence classifier.
        // The gate decides whether the router is worth running at all.
        // Skipping routing for evidence-free inputs prevents the ML
        // classifier from surfacing false positives on small talk, emotional
        // disclosures, or knowledge questions that don't carry a clear
        // tool signal. Browser-focal mode wins outright.
        let gateReplyPayload: String? = {
            guard result.hasPrefix("[Replying to:"),
                  let close = result.firstIndex(of: "]") else { return nil }
            return String(result[result.index(after: close)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        let gateChips = InputParsingUtilities.extractToolChipNames(from: result)
        let gateTickers = InputParsingUtilities.extractTickerSymbols(from: result)
        let gateSignals = ConversationalGate.Signals(
            input: result,
            replyPayload: gateReplyPayload,
            entities: self.currentEntities ?? ExtractedEntities(
                names: [], places: [], organizations: [],
                urls: [], phoneNumbers: [], emails: [],
                ocrText: nil, correctedInput: nil, detectedLanguage: nil
            ),
            chipsPresent: gateChips,
            tickersPresent: gateTickers,
            priorTool: await router.priorContext?.toolNames.first
        )
        var gateDecision = ConversationalGate.evaluate(gateSignals)

        // Intent-classifier arbitration: the gate relies on language-neutral
        // structural evidence (entities, interrogative punctuation, chips).
        // Its coverage is incomplete in two directions:
        //   (a) it can over-fire — NER tags incidental nouns as entities,
        //       promoting a conversational turn to `.candidateScope`;
        //   (b) it can under-fire — short tool queries ("weather today"),
        //       declarative tool requests ("latest episodes of the Lex
        //       Fridman podcast"), and tool-name-bearing questions ("news
        //       on Iran") lack structural entities that map to the right
        //       tool, so the gate falls through to conversational/
        //       clarification. The ML intent classifier fires in both
        //       directions — we let it DEMOTE *and* PROMOTE the gate.
        //
        // Invariant: `.toolSignal` (chip/URL/ticker/numeric/phone/email) and
        // `.replyElaboration` are never touched. Those are hard evidence
        // (or explicit UI affordance) and always win.
        let arbitrable: Bool = {
            switch gateDecision.kind {
            case .candidateScope, .conversational, .clarification: return true
            case .toolSignal, .replyElaboration: return false
            }
        }()
        if AppConfig.useClassifierIntentRouting, arbitrable {
            let intentStart = ContinuousClock.now
            if let intent = await ConversationIntentClassifier.shared.classify(result) {
                var judgeCalled = false
                var via = "classifier"
                let topLabel = intent.label
                let demoteSet: Set<ConversationIntentClassifier.Label> = [.meta, .conversation, .refinement]
                // Judge runs at medium tier to confirm either a soft demote OR
                // a soft promote — both directions need a second opinion when
                // the classifier is in the 0.60–0.85 range. Never at high
                // (classifier alone is enough) or low (skip arbitration).
                //
                // Promote confirmation is the 2026-04 "find podcasts about
                // technology" case: classifier said `tool_action` at 0.83
                // (medium), the structural gate said conversational, and the
                // LLM fabricated a podcast list. High-tier-only promote would
                // have missed that. Calling the judge on medium-tier
                // tool_action gives us a second signal before short-circuiting
                // the router.
                let isDemoteCandidate = demoteSet.contains(topLabel)
                    && (gateDecision.kind == .toolSignal || gateDecision.kind == .candidateScope)
                let isPromoteCandidate = topLabel == .toolAction
                    && (gateDecision.kind == .conversational || gateDecision.kind == .clarification)
                var judgeLabel: ConversationIntentClassifier.Label?
                if intent.confidenceTier == .medium,
                   AppConfig.useLLMJudge,
                   isDemoteCandidate || isPromoteCandidate {
                    judgeCalled = true
                    judgeLabel = await LLMJudge.shared.judgeIntent(
                        input: result, classifierHint: intent
                    )
                    if judgeLabel != nil { via = "judge" }
                } else if intent.confidenceTier == .low {
                    via = "skipped"
                }

                var overrode = false

                // DEMOTE path: classifier's top label is in the conversational
                // set. Require classifier-AND-judge agreement for medium tier
                // (task C); classifier alone is enough at high tier. This
                // prevents a medium-tier `tool_action` + aggressive judge
                // demotion — the 2026-04 "when is my next meeting?" failure.
                //
                // Follow-up continuations (anaphora / ordinal / action verb
                // against a prior tool turn) are never demoted: phrases like
                // "the first one", "tell me more", "summarize it" have the
                // surface shape of conversation but semantically reference a
                // tool result, and the router's follow-up detector needs a
                // chance to route them to WebFetch (drill-down) or re-invoke
                // the prior tool. Demoting here skips the router entirely.
                if demoteSet.contains(topLabel) && !gateDecision.isFollowUpContinuation {
                    let canDemote: Bool = {
                        switch intent.confidenceTier {
                        case .high: return true
                        case .medium: return judgeLabel.map { demoteSet.contains($0) } ?? false
                        case .low: return false
                        }
                    }()
                    if canDemote,
                       gateDecision.kind == .toolSignal || gateDecision.kind == .candidateScope {
                        gateDecision = ConversationalGate.Decision(
                            kind: .conversational,
                            reason: "classifier-intent=\(topLabel.rawValue)"
                        )
                        overrode = true
                    }
                }

                // PROMOTE path (task A + medium-tier extension): gate said
                // `.conversational` / `.clarification` but the classifier says
                // this is a tool turn. Flip the gate back to `.candidateScope`
                // with `isClassifierPromoted = true` so the router runs AND
                // the protected-tool filter bypasses. High tier is classifier-
                // only; medium tier requires judge confirmation (mirrors the
                // demote path — avoids reintroducing false-positives the gate
                // was designed to catch while recovering the "find podcasts
                // about technology" class of misses).
                if topLabel == .toolAction,
                   gateDecision.kind == .conversational || gateDecision.kind == .clarification {
                    let canPromote: Bool = {
                        switch intent.confidenceTier {
                        case .high: return true
                        case .medium: return judgeLabel == .toolAction
                        case .low: return false
                        }
                    }()
                    if canPromote {
                        gateDecision = ConversationalGate.Decision(
                            kind: .candidateScope,
                            candidateToolHints: [],
                            reason: "classifier-promote=\(topLabel.rawValue)",
                            isClassifierPromoted: true
                        )
                        overrode = true
                    }
                }

                let elapsed = intentStart.duration(to: .now)
                let ms = Int(elapsed.components.seconds * 1000
                             + elapsed.components.attoseconds / 1_000_000_000_000_000)
                ClassifierTelemetry.record(
                    classifier: "intent",
                    label: intent.label.rawValue,
                    confidence: intent.confidence,
                    tier: String(describing: intent.confidenceTier),
                    resolvedVia: via,
                    judgeCalled: judgeCalled,
                    latencyMs: ms,
                    divergedFromLegacy: overrode
                )
            }
        }

        // Skill-coverage promote: before short-circuiting a `.conversational`
        // or `.clarification` gate to finalization, check whether a loaded
        // user skill would match the input at ≥90% coverage. Skills carry
        // explicit user-defined examples (e.g. "Research how mRNA vaccines
        // work") that the gate's NER-driven hints can't see. Without this
        // promote the router's skill matcher never runs on gate-conversational
        // turns — `testResearchSkillRouting` asserts exactly this flow.
        let arbitrableKind = gateDecision.kind == .conversational
            || gateDecision.kind == .clarification
        if arbitrableKind {
            if let skillMatch = await router.checkSkillExamples(input: result),
               skillMatch.coverage >= 0.9 {
                Log.engine.debug("Gate promoted by skill match: \(skillMatch.skill.name) (coverage \(Int(skillMatch.coverage * 100))%)")
                gateDecision = ConversationalGate.Decision(
                    kind: .candidateScope,
                    candidateToolHints: [],
                    reason: "skill-promote=\(skillMatch.skill.name)",
                    isClassifierPromoted: true
                )
            }
        }

        // Synonym-map promote: same rationale as the skill promote, but for
        // curated synonym phrases ("top stories" → News, "headlines" → News,
        // "current events" → News, "check my email" → ReadEmail, …). These
        // are explicit user-visible tool mappings that shouldn't be lost to
        // the gate's short-circuit just because the input is 1–2 tokens.
        if gateDecision.kind == .conversational || gateDecision.kind == .clarification {
            let synonymHit = await router.matchesAnySynonym(input: result)
            if synonymHit {
                Log.engine.debug("Gate promoted by synonym match for '\(result.prefix(40))'")
                gateDecision = ConversationalGate.Decision(
                    kind: .candidateScope,
                    candidateToolHints: [],
                    reason: "synonym-promote",
                    isClassifierPromoted: true
                )
            }
        }

        // Embedding-similarity promote: when the skill + synonym + classifier
        // signals all missed, compare the input to each tool's `schema` via
        // `NLEmbedding` and promote to candidateScope if the top candidate
        // exceeds a high-confidence threshold. Catches short tool queries
        // whose surface form isn't in the classifier's training data
        // ("Define pulchritude", "synonyms for happy", "etymology of X")
        // without requiring a new synonym entry per tool.
        if gateDecision.kind == .conversational || gateDecision.kind == .clarification {
            // Hybrid schema-overlap + sentence-embedding signal. Sentence
            // embedding alone is weak on short queries because the tool's
            // schema is long and many tools' schemas overlap semantically.
            // A token-level overlap with the tool's schema catches precise
            // intents ("define X" → Dictionary, "synonyms for X" → Dictionary,
            // "etymology of X" → Dictionary) that embedding misses. The
            // schema strings themselves are structural metadata, not
            // hardcoded English in code — they describe each tool's surface.
            if let promoted = await router.schemaTokenOverlapPromote(input: result) {
                Log.engine.debug("Gate promoted by schema-token overlap → \(promoted)")
                gateDecision = ConversationalGate.Decision(
                    kind: .candidateScope,
                    candidateToolHints: [promoted],
                    reason: "schema-token-promote=\(promoted)",
                    isClassifierPromoted: true
                )
            }
        }

        self.currentGateDecision = gateDecision
        Log.engine.debug("Gate: \(String(describing: gateDecision.kind)) — \(gateDecision.reason) · hints: \(gateDecision.candidateToolHints.joined(separator: ","))")

        #if os(macOS)
        let browserIsFocal = self.browserContextIsFocalPoint
        #else
        let browserIsFocal = false
        #endif

        // Attachment-prefixed turns (`[Attached: path]` stripped earlier in
        // handlePreprocessing) are explicit tool intents — do not short-
        // circuit to conversational even if the stripped text looks bare.
        let hasAttachment = self.currentAttachmentPath != nil

        if !browserIsFocal && currentRecoveryHint == nil && !hasAttachment {
            switch gateDecision.kind {
            case .replyElaboration:
                // Emit the routing progress event so UI/subscribers see the
                // stage transition even when the gate short-circuits — the
                // router isn't called, but observability-wise the turn still
                // went through routing semantically (the gate IS our router
                // for these turns). `AgentArchitectureTests.testProgress-
                // ConversationalRoute` pins this expectation.
                emitProgress(.routing)
                // The brain-conversational variant already tells the LLM to
                // expand on the prior turn when there's no new input. Adding
                // a narrative ingredient here ("Expand on your previous…")
                // led to verbatim echoes. The `currentRecoveryHint`/empty
                // ingredients signal is enough for the finalizer to behave.
                lastRoutedToolNames = ["conversational"]
                await transitionTo(.finalization)
                return result
            case .conversational:
                emitProgress(.routing)
                // Brain-conversational handles the "just answer" directive.
                // No ingredient needed — empty ingredients + conversational
                // brain is unambiguous and avoids instruction-text echoes.
                lastRoutedToolNames = ["conversational"]
                await transitionTo(.finalization)
                return result
            case .clarification:
                emitProgress(.routing)
                // Emit a localized, user-facing clarification question
                // directly, bypassing the LLM. Prevents the prior "[CLARIFY]
                // No matching tool…" ingredient from being echoed verbatim.
                let clar = String(localized: "Could you tell me a bit more about what you're looking for?", bundle: .iClawCore)
                pendingDirectResponse = clar
                lastRoutedToolNames = ["conversational"]
                await transitionTo(.finalization)
                return result
            case .toolSignal, .candidateScope:
                break  // Fall through to routing; hints are available via currentGateDecision.
            }
        }

        await transitionTo(.routing)
        return result
    }

    /// Handles the routing state: multi-intent splitting, tool routing,
    /// and ingredient validation.
    private func handleRouting(processedInput: String) async -> RoutingAction {
        Log.engine.debug("Routing intent...")
        emitProgress(.routing)

        // Multi-intent decomposition: split compound queries before routing.
        // If detected, route and execute each sub-query independently.
        // Strip the [Replying to: "Q" → "A"] prefix first so the splitter doesn't
        // treat quoted prior-assistant sentences as standalone sub-queries. When
        // the payload after the prefix is empty (user hit reply with no new text),
        // there is no compound intent — skip splitting entirely.
        let splitInput: String = {
            guard processedInput.hasPrefix("[Replying to:"),
                  let closing = processedInput.firstIndex(of: "]") else {
                return processedInput
            }
            return String(processedInput[processedInput.index(after: closing)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        if !splitInput.isEmpty,
           let subQueries = IntentSplitter.split(input: splitInput, entities: currentEntities),
           subQueries.count > 1 {
            Log.engine.debug("Multi-intent detected: \(subQueries.count) sub-queries")
            emitProgress(.processing(description: "Processing \(subQueries.count) requests"))

            for (index, subQuery) in subQueries.enumerated() {
                guard toolCallCounter < AppConfig.maxToolCallsPerTurn else { break }
                Log.engine.debug("Sub-query \(index + 1): \(subQuery.text.prefix(60))")

                let subEntities = subQuery.entities ?? currentEntities
                let subRouteResult = await router.route(input: subQuery.text, suppressedTools: suppressedTools)
                await recordRouterStageTrace(result: subRouteResult)

                switch subRouteResult {
                case .tools(let tools):
                    for t in tools { lastRoutedToolNames.append(t.name) }
                    let savedEntities = currentEntities
                    currentEntities = subEntities
                    await executeCoreTools(tools, input: subQuery.text)
                    currentEntities = savedEntities
                case .fmTools(let fmTools):
                    for t in fmTools { lastRoutedToolNames.append(t.name) }
                    let approved = await filterByConsent(fmTools)
                    self.currentFMTools.append(contentsOf: approved)
                case .mixed(let core, let fm):
                    for t in core { lastRoutedToolNames.append(t.name) }
                    for t in fm { lastRoutedToolNames.append(t.name) }
                    let savedEntities = currentEntities
                    currentEntities = subEntities
                    await executeCoreTools(core, input: subQuery.text)
                    currentEntities = savedEntities
                    let approved = await filterByConsent(fm)
                    self.currentFMTools.append(contentsOf: approved)
                case .conversational, .requiresDisambiguation, .needsUserClarification:
                    break // Skip non-tool sub-queries
                }
            }

            // Proceed directly to finalization -- skip the normal routing loop
            if case .routing = currentState {
                await transitionTo(.finalization)
            }
            return .proceedToFinalization
        }

        // Phase 4: ReAct loop -- iterate for multi-step queries
        var iteration = 0

        // For routing, prepend the attachment path so the router can make
        // file-type-aware decisions. The path is stripped again before finalization.
        let routingInput: String
        if let path = currentAttachmentPath {
            routingInput = path + "\n" + processedInput
        } else {
            routingInput = processedInput
        }

        while iteration < AppConfig.maxReActIterations {
            iteration += 1
            if iteration > 1 {
                emitProgress(.reactIteration(current: iteration, total: AppConfig.maxReActIterations))
            }

            // If browser content is the focal point, skip tool routing entirely
            #if os(macOS)
            let routingResult: ToolRouter.RoutingResult
            if browserContextIsFocalPoint {
                routingResult = .conversational
                Log.engine.info("Browser content is focal point -- skipping tool routing")
            } else {
                routingResult = await router.route(input: routingInput, suppressedTools: suppressedTools)
            }
            #else
            let routingResult = await router.route(input: routingInput, suppressedTools: suppressedTools)
            #endif
            await recordRouterStageTrace(result: routingResult)

            // Gate scope filter — entity-required tools must have their
            // entity type in the gate's hints to be allowed through.
            //
            // The gate's candidate hints reflect what the current input's
            // structural evidence actually points to: a place entity →
            // Weather/Maps; a person or organization → WikipediaSearch; a
            // ticker → Stocks; contact info → Messages/Email. Tools that
            // require a specific kind of entity ("entity-required tools")
            // should only fire when the gate found that entity. Without it,
            // the ML classifier is almost certainly firing on a noisy
            // feature — classic false positives include:
            //   • "how are you today?" → Stocks (keyword "today" + profile bias)
            //   • "thanks for the help" → Help (keyword "help")
            //   • "tell me about X" → Messages (keyword "tell")
            //
            // "Open" tools (WikipediaSearch, WebSearch, Calculator, Help,
            // Dictionary, Research) don't need an entity to be meaningful
            // on an interrogative input and are NOT in this protected set.
            //
            // Hard toolSignal (chip/URL/ticker/numeric) and follow-up
            // continuations skip the filter entirely.
            // Weather/Maps removed: the ML tool classifier picks these on
            // unambiguous astronomy / time-of-day queries ("what time is
            // sunset?", "moon phase tonight") that have no NER entity. The
            // gate's interrogative hint set is [WikipediaSearch, WebSearch]
            // — without Weather/Maps in the hints, protection blocked the
            // legit route and surfaced as `SunriseSunsetE2ETests` regressions.
            // The classifier's high-confidence prediction is more reliable
            // than the protection list at this point (Phase 2.5-v2 metrics).
            let protectedToolNames: Set<String> = [
                "messages", "automate", "email", "stocks",
                "calendar", "podcast", "news", "timer",
                "reminders", "readfile", "writefile",
                "random", "time", "help"
            ]
            let routeConfidence = await router.lastRouteConfidence ?? 0
            let highConfidenceRoute = routeConfidence >= AppConfig.routeHighConfidenceThreshold
            let scopedResult: ToolRouter.RoutingResult = {
                guard let gate = self.currentGateDecision,
                      gate.kind == .candidateScope,
                      !gate.candidateToolHints.isEmpty,
                      !gate.isFollowUpContinuation,
                      !gate.isClassifierPromoted,
                      !highConfidenceRoute else {
                    if highConfidenceRoute {
                        Log.router.debug("Gate protected-tool filter: bypassed (route confidence \(String(format: "%.2f", routeConfidence)) ≥ \(AppConfig.routeHighConfidenceThreshold))")
                    }
                    return routingResult
                }
                let hints = Set(gate.candidateToolHints.map { $0.lowercased() })
                func isBlocked(_ name: String) -> Bool {
                    let lower = name.lowercased()
                    return protectedToolNames.contains(lower) && !hints.contains(lower)
                }
                switch routingResult {
                case .tools(let tools):
                    let kept = tools.filter { !isBlocked($0.name) }
                    if kept.isEmpty {
                        Log.router.debug("Gate protected-tool filter: dropped \(tools.map(\.name)) → conversational")
                        return .conversational
                    }
                    return .tools(kept)
                case .fmTools(let tools):
                    let kept = tools.filter { !isBlocked($0.name) }
                    if kept.isEmpty {
                        Log.router.debug("Gate protected-tool filter: dropped FM \(tools.map(\.name)) → conversational")
                        return .conversational
                    }
                    return .fmTools(kept)
                case .mixed(let core, let fm):
                    let keptCore = core.filter { !isBlocked($0.name) }
                    let keptFM = fm.filter { !isBlocked($0.name) }
                    if keptCore.isEmpty && keptFM.isEmpty {
                        return .conversational
                    }
                    if keptCore.isEmpty { return .fmTools(keptFM) }
                    if keptFM.isEmpty { return .tools(keptCore) }
                    return .mixed(core: keptCore, fm: keptFM)
                case .requiresDisambiguation(let choices):
                    // Each disambiguation choice must pass the same test as
                    // a direct tool route: if the choice references a
                    // protected tool name AND that tool is not in the gate's
                    // hints, drop it. If no choices survive, collapse the
                    // disambiguation to a conversational response — the
                    // prompt lacked evidence for any of the offered tools.
                    let keptChoices = choices.filter { choice in
                        let lower = choice.lowercased()
                        let matchedProtectedName = protectedToolNames.first(where: { lower.contains($0) })
                        guard let protectedName = matchedProtectedName else {
                            return true  // not a protected tool, allow
                        }
                        // Protected: allow only if that name is in hints.
                        return hints.contains(protectedName)
                    }
                    if keptChoices.isEmpty {
                        Log.router.debug("Gate protected-tool filter: dropped disambiguation \(choices) → conversational")
                        return .conversational
                    }
                    if keptChoices.count != choices.count {
                        return .requiresDisambiguation(choices: keptChoices)
                    }
                    return routingResult
                case .conversational, .needsUserClarification:
                    return routingResult
                }
            }()
            let filteredRoutingResult = scopedResult

            // Track routed tool names for evaluation (routing vs execution accuracy)
            switch filteredRoutingResult {
            case .tools(let t):
                lastRoutedToolNames = t.map(\.name)
                lastTurnTelemetry.routingOutcome = .tools
                lastTurnTelemetry.realToolNames = t.map(\.name)
            case .fmTools(let t):
                lastRoutedToolNames = t.map(\.name)
                lastTurnTelemetry.routingOutcome = .fmTools
                lastTurnTelemetry.realToolNames = t.map(\.name)
            case .mixed(let c, let f):
                lastRoutedToolNames = c.map(\.name) + f.map(\.name)
                lastTurnTelemetry.routingOutcome = .mixed
                lastTurnTelemetry.realToolNames = c.map(\.name) + f.map(\.name)
            case .conversational:
                lastRoutedToolNames = ["conversational"]
                lastTurnTelemetry.routingOutcome = .conversational
                lastTurnTelemetry.realToolNames = []
            case .requiresDisambiguation:
                lastRoutedToolNames = ["disambiguation"]
                lastTurnTelemetry.routingOutcome = .disambiguation
                lastTurnTelemetry.realToolNames = []
            case .needsUserClarification:
                lastRoutedToolNames = ["clarification"]
                lastTurnTelemetry.routingOutcome = .clarification
                lastTurnTelemetry.realToolNames = []
            }

            // Skill cache check -- if a cached skill with cacheDuration is active,
            // return cached ingredients and skip tool execution.
            if let skill = await router.currentSkill,
               let duration = skill.cacheDuration,
               duration != .none,
               let cached = await skillCache.lookup(skillName: skill.name, input: processedInput) {
                Log.engine.debug("Skill cache hit for '\(skill.name)'. Skipping tool execution.")
                currentIngredients.append("Skill Instruction: \(skill.systemPrompt)")
                currentIngredients.append(contentsOf: cached.ingredients)
                if let wt = cached.widgetType { lastWidgetType = wt }
                if let wd = cached.widgetData { lastWidgetData = wd }
                break
            }

            switch filteredRoutingResult {
            case .tools(let tools):
                Log.engine.debug("Routing matched \(tools.count) Core tools.")
                if let skillPrompt = await router.currentSkill?.systemPrompt {
                    currentIngredients.append("Skill Instruction: \(skillPrompt)")
                }

                // Skill-driven WebFetch → pre-fetch path.
                // When a skill references webfetch, we extract URLs from the skill
                // instruction, pick the best one based on user input keywords, fetch
                // it eagerly, and inject the result as ingredients. This is more
                // reliable than FM tool injection (the on-device LLM often outputs
                // JSON instead of calling the tool).
                if let skill = await router.currentSkill,
                   tools.count == 1, tools[0].name == ToolNames.webFetch,
                   skill.tools.contains(where: { $0.name.lowercased() == "webfetch" }) {
                    let urls = Self.extractURLs(from: skill.systemPrompt)
                    if !urls.isEmpty {
                        let fetchURL = Self.selectBestURL(from: urls, for: processedInput)
                        Log.engine.debug("Skill pre-fetch: \(fetchURL.absoluteString)")
                        do {
                            let backend = HTTPFetchBackend()
                            let result = try await backend.fetch(url: fetchURL)
                            let compacted = ContentCompactor.compact(result.text)
                            currentIngredients.append("[VERIFIED] Fetched from \(fetchURL.host ?? "API"):\n\(compacted)")
                        } catch {
                            Log.engine.debug("Skill pre-fetch failed: \(error.localizedDescription)")
                            currentIngredients.append("[ERROR] Failed to fetch data: \(error.localizedDescription)")
                        }
                    }
                    break
                }

                // For refinements, augment the input with prior context so the
                // argument extractor sees both the original query and the modification.
                // e.g., prior "weather in Paris" + current "in celsius" ->
                //   "weather in Paris, in celsius"
                var toolInput: String
                let turnRelation = await router.lastDetectedTurnRelation
                currentTurnRelation = turnRelation
                if turnRelation == .retry,
                   let priorInput = await router.priorUserInput {
                    // Retry: re-execute with the prior input (user wants same query again)
                    toolInput = priorInput
                    Log.engine.debug("Retry: using prior input -> \(toolInput)")
                } else if turnRelation == .refinement,
                   let priorInput = await router.priorUserInput {
                    toolInput = "\(priorInput), \(processedInput)"
                    Log.engine.debug("Refinement: merged input -> \(toolInput)")
                } else {
                    toolInput = processedInput
                }

                // If this is a tool-help redirect, override input with structured context
                if let helpTarget = await router.helpContextToolName,
                   tools.count == 1, tools[0].name == ToolNames.help {
                    toolInput = "tool:\(helpTarget)"
                }

                // Prewarm the LLM while tools execute -- finalization is imminent.
                // The model pre-processes the brain+soul prefix tokens in parallel
                // with tool network calls, reducing finalization latency.
                await llmAdapter.prewarmForFinalization()

                // Check if the query needs multi-step planning.
                // Skip the planner LLM call for short, clear queries -- the ML
                // classifier already identified the tool with confidence, and
                // adding a planner call just adds 2-5s of latency for nothing.
                // Only invoke the planner for longer queries (>6 words) that
                // might genuinely need multi-step decomposition.
                let plannerWordCount = toolInput.split(separator: " ").count
                if let firstTool = tools.first {
                    if plannerWordCount > 6 {
                        let agentPlan = await planner.plan(input: toolInput, routedToolName: firstTool.name)
                        if agentPlan.isMultiStep {
                            Log.engine.debug("Multi-step plan with \(agentPlan.steps.count) steps via AgentRunner")
                            emitProgress(.planning)
                            await executeAgentPlan(agentPlan, query: toolInput, primaryTool: firstTool.name)
                        } else {
                            await executeCoreTools(tools, input: toolInput)
                        }
                    } else {
                        // Short query -- execute directly, no planning overhead
                        await executeCoreTools(tools, input: toolInput)
                    }
                } else {
                    await executeCoreTools(tools, input: toolInput)
                }

                // Ingredient validation -- check if tool output is relevant.
                // Skip when input contains a chip (#tool) -- the user explicitly chose the tool.
                let wasChipRouted = !InputParsingUtilities.extractToolChipNames(from: processedInput).isEmpty
                if let firstTool = tools.first,
                   !hasValidationRetried,
                   !wasChipRouted,
                   !(await validateIngredients(toolName: firstTool.name, prompt: processedInput)) {
                    Log.engine.debug("Ingredient validation failed for '\(firstTool.name)'. Re-routing with suppression.")
                    hasValidationRetried = true
                    suppressedTools.insert(firstTool.name)
                    // Feed the misprediction signal so the router downweights this
                    // tool for semantically similar inputs later in the session —
                    // and so the `router.misprediction` log/signpost fires for
                    // post-launch analysis.
                    RouterFeedback.shared.recordFailure(
                        tool: firstTool.name, input: processedInput
                    )
                    // Stash — don't discard — the original ingredients. If the
                    // re-routed path yields nothing substantive, these are
                    // re-merged before finalization so the user doesn't go from
                    // "partial data" to "blank response" because of a cautious
                    // relevance verdict. Tag as [UNVALIDATED] so the model knows
                    // the data's relevance wasn't confirmed.
                    let tagged = currentIngredients.map { ingredient -> String in
                        if ingredient.hasPrefix("[UNVALIDATED]") { return ingredient }
                        return "[UNVALIDATED] \(ingredient)"
                    }
                    shelvedIngredients.append(contentsOf: tagged)
                    currentIngredients.removeAll()
                    lastWidgetType = nil
                    lastWidgetData = nil
                    hadToolError = false
                    toolCallCounter = 0
                    continue // Re-enters the while loop -> re-routes
                }

            case .fmTools(let fmTools):
                Log.engine.debug("Routing matched \(fmTools.count) FM tools.")
                if let skillPrompt = await router.currentSkill?.systemPrompt {
                    currentIngredients.append("Skill Instruction: \(skillPrompt)")
                }

                // Pre-read optimization: when an attachment is present and the
                // only FM tool is read_file, read the file content directly as
                // a Core-style ingredient. The on-device LLM often fails to call
                // FM tools reliably (returning JSON instead of a tool call).
                if let attachPath = currentAttachmentPath,
                   fmTools.count == 1,
                   fmTools[0].name == ToolNames.readFile {
                    if let fileContent = await preReadAttachmentContent(at: attachPath) {
                        currentIngredients.append(fileContent)
                        Log.engine.debug("Pre-read attachment content injected (\(fileContent.count) chars)")
                    } else {
                        // Pre-read failed — fall back to FM tool path
                        Log.engine.warning("Pre-read failed for \(attachPath), falling back to FM tool")
                        let approvedFM = await filterByConsent(fmTools)
                        self.currentFMTools = approvedFM
                        for fm in approvedFM {
                            Log.engine.debug("Routed FM tool: \(fm.name)")
                        }
                    }
                } else {
                    let approvedFM = await filterByConsent(fmTools)
                    self.currentFMTools = approvedFM
                    for fm in approvedFM {
                        Log.engine.debug("Routed FM tool: \(fm.name)")
                    }
                }

            case .mixed(core: let coreTools, fm: let fmTools):
                Log.engine.debug("Routing matched \(coreTools.count) Core and \(fmTools.count) FM tools.")
                if let skillPrompt = await router.currentSkill?.systemPrompt {
                    currentIngredients.append("Skill Instruction: \(skillPrompt)")
                }

                // Pre-read optimization for mixed routing with read_file
                if let attachPath = currentAttachmentPath,
                   fmTools.contains(where: { $0.name == ToolNames.readFile }) {
                    if let fileContent = await preReadAttachmentContent(at: attachPath) {
                        currentIngredients.append(fileContent)
                        Log.engine.debug("Pre-read attachment content injected in mixed route")
                    }
                    // Only pass remaining (non-read_file) FM tools to finalization
                    let remainingFM = fmTools.filter { $0.name != ToolNames.readFile }
                    if !remainingFM.isEmpty {
                        let approved = await filterByConsent(remainingFM)
                        self.currentFMTools = approved
                        for fm in approved {
                            Log.engine.debug("Routed FM tool: \(fm.name)")
                        }
                    }
                } else {
                    let approvedFM = await filterByConsent(fmTools)
                    self.currentFMTools = approvedFM
                    for fm in approvedFM {
                        Log.engine.debug("Routed FM tool: \(fm.name)")
                    }
                }
                await executeCoreTools(coreTools, input: processedInput)

            case .requiresDisambiguation(let choices):
                await transitionTo(.disambiguation(options: choices))
                break

            case .conversational:
                Log.engine.debug("Conversational mode -- no tool needed.")
                let lower = processedInput.lowercased()
                let hasFollowUpSignal = PriorTurnContext.containsAnaphora(lower)
                    || PriorTurnContext.containsActionVerb(lower)
                    || PriorTurnContext.containsFollowUpPhrase(lower)

                if let skill = await router.currentSkill {
                    currentIngredients.append("Skill Instruction: \(skill.systemPrompt)")
                } else if hasFollowUpSignal, let failureContext = await priorTurnFailureContext() {
                    // Prior turn failed AND the user is referencing it -- inject
                    // failure hint so the LLM can explain. Without a follow-up
                    // signal, a fresh unrelated query would otherwise inherit a
                    // stale "you tried to use Messages…" directive.
                    currentIngredients.append(failureContext)
                } else {
                    // Context-aware conversational: only inject prior context when
                    // the input actually references it (anaphora, follow-up phrases,
                    // entity overlap). Without these signals, emotional/meta/unrelated
                    // inputs like "you're useless" should NOT get prior tool data.
                    let priorFacts = await conversationManager.state.recentFacts
                    let priorSummaries = await conversationManager.state.recentToolResults
                    if hasFollowUpSignal && (!priorFacts.isEmpty || !priorSummaries.isEmpty) {
                        let priorData = priorFacts.map { $0.compact() }.joined(separator: "; ")
                        let priorTools = priorSummaries.map { "[\($0.toolName)] \($0.summary)" }.joined(separator: "\n")
                        let context = [priorData, priorTools].filter { !$0.isEmpty }.joined(separator: "\n")

                        // Math-aware: if prior tool was Calculator/Compute,
                        // instruct the LLM to explain with LaTeX step-by-step
                        let priorWasMath = priorSummaries.contains { ["Calculator", "Compute"].contains($0.toolName) }
                        let instruction = priorWasMath
                            ? "The user is asking about a math calculation. Explain step by step using LaTeX \\( \\) for formulas. Show each operation with actual numbers."
                            : "The user is asking about a prior result. Explain clearly using this context:"
                        currentIngredients.append("\(instruction)\n\(context)")
                    }
                    // No planner-instruction ingredient here when the
                    // branch is plain conversational — brain-conversational
                    // covers the "just answer" semantics. Prior ingredient
                    // ("No tool is needed…") was being echoed verbatim,
                    // including in the user's language (2026-04 audit).
                }

            case .needsUserClarification:
                Log.engine.debug("Needs user clarification.")
                // Guard: only short-circuit when no tool has produced output
                // this turn. A ReAct re-route that lands on .needsUser-
                // Clarification after a successful tool execution would
                // otherwise override a perfectly good widget + ingredients
                // with "Could you tell me a bit more…".
                let hasToolOutput = !currentIngredients.isEmpty || lastWidgetType != nil
                if !hasToolOutput {
                    let clar = String(localized: "Could you tell me a bit more about what you're looking for?", bundle: .iClawCore)
                    pendingDirectResponse = clar
                } else {
                    Log.engine.debug("Skipping clarification short-circuit — tool already produced output")
                }
            }
            break  // Default: single iteration
        }

        // R6: If ReAct re-routing didn't produce substantive ingredients but
        // we have shelved ones from the pre-retry attempt, merge them back.
        // "Partial data" beats "blank response" — the shelved data is tagged
        // [UNVALIDATED] so the model knows to hedge phrasing.
        if !shelvedIngredients.isEmpty {
            let hasSubstantive = currentIngredients.contains { IngredientFilter.isSubstantive($0) }
            let shelvedCount = shelvedIngredients.count
            if !hasSubstantive {
                Log.engine.debug("Re-route yielded nothing substantive; merging \(shelvedCount) shelved ingredient(s)")
                currentIngredients.append(contentsOf: shelvedIngredients)
            } else {
                Log.engine.debug("Re-route succeeded; discarding \(shelvedCount) shelved ingredient(s)")
            }
            shelvedIngredients.removeAll()
        }

        // Store skill result in cache if the skill declares a cache duration
        if let skill = await router.currentSkill,
           let duration = skill.cacheDuration,
           duration != .none {
            let toolIngredients = currentIngredients.filter { !$0.hasPrefix("Skill Instruction:") }
            if !toolIngredients.isEmpty {
                await skillCache.store(
                    skillName: skill.name,
                    input: processedInput,
                    ingredients: toolIngredients,
                    widgetType: lastWidgetType,
                    widgetData: lastWidgetData,
                    duration: duration
                )
                Log.engine.debug("Cached skill result for '\(skill.name)' with duration: \(duration.rawValue)")
            }
        }

        // Only transition to finalization if we didn't enter disambiguation
        if case .routing = currentState {
            await transitionTo(.finalization)
        }

        return .proceedToFinalization
    }

    /// Handles the planning state (currently a pass-through).
    private func handlePlanning() async {
        // Multi-step planning is invoked after routing when the planner detects
        // a complex query. It decomposes into steps and executes them sequentially.
        // Currently a placeholder -- planning is triggered inline during routing
        // via the ChainableTool protocol and the executePlan() method.
        await transitionTo(.finalization)
    }

    /// Handles the disambiguation state: uses AgentPlanner to resolve, falls back to user prompt.
    private func handleDisambiguation(options: [String], processedInput: String) async {
        Log.engine.debug("Disambiguating from \(options)...")

        // Communication channel disambiguation: when multiple channels
        // (iMessage, Email, etc.) are available and the input is ambiguous,
        // show pill buttons so the user picks the channel. No LLM call needed.
        //
        // Gate: the input must contain a communication-intent signal via NER
        // or the preprocessor's entities. We use a heuristic bag-of-intents
        // on the router's classifier label (which already indicates the top
        // domain). Without this gate, prompts like "Outline Lean Startup
        // methodology" that the classifier weakly overlaps with messaging
        // domains would get hijacked into an email/iMessage question.
        let topLabelLooksLikeComm: Bool = await {
            guard let label = await router.lastRoutingLabel else { return false }
            // Structural: compound labels use `domain.action`. Treat as comm
            // only when the domain itself is a messaging domain.
            let domain = label.components(separatedBy: ".").first?.lowercased() ?? label.lowercased()
            return CommunicationChannelResolver.isCommunicationDomain(domain)
        }()
        // Channel disambiguation only applies when the user is trying to
        // SEND something — read/search intents don't need a channel pick.
        // Derive from the action suffix of each option (`*.send`, `*.compose`
        // → send; `*.read`, `*.search` → read). If no option is a send intent,
        // skip channel disambig entirely.
        let hasSendIntent = options.contains { label in
            let suffix = label.components(separatedBy: ".").dropFirst().first?.lowercased() ?? ""
            return suffix == "send" || suffix == "compose" || suffix == "reply"
        }
        let rawChannels = options.compactMap { nameOrLabel -> CommunicationChannelResolver.Channel? in
            CommunicationChannelResolver.channels(matching: nameOrLabel)
        }
        // Deduplicate by tool name (email.compose + email.read both → Email)
        var seen = Set<String>()
        let channelChoices = rawChannels.filter { seen.insert($0.tool).inserted }
        if topLabelLooksLikeComm && hasSendIntent && rawChannels.count == options.count && channelChoices.count >= 2 {
            Log.engine.debug("Communication channel disambiguation: \(channelChoices.map(\.displayName))")
            // Build pill queries: prefix the original input with the channel chip
            let pills = channelChoices.map { channel in
                "#\(channel.chip) \(processedInput)"
            }
            self.lastSuggestedQueries = pills
            // Emit the user-facing disambiguation question directly rather than
            // telling the LLM to ask it — LLM paraphrase often leaks planner
            // words ("Ask them briefly..."). The pills carry the options UI;
            // the text is a one-line localized question.
            let separator = String(localized: " or ", bundle: .iClawCore)
            let channelList = channelChoices.map(\.displayName).joined(separator: separator)
            let fmt = String(localized: "Which would you like — %@?", bundle: .iClawCore)
            pendingDirectResponse = String(format: fmt, channelList)
            await transitionTo(.finalization)
            return
        }

        // General disambiguation: use AgentPlanner to auto-resolve.
        // This eliminates the 6.5% disambiguation rate that frustrated users
        // with unnecessary "did you mean?" prompts.
        //
        // Resolve compound labels (e.g., "search.wiki") to actual tool
        // names (e.g., "WikipediaSearch") before passing to the planner.
        if let topLabel = options.first {
            let resolvedName = LabelRegistry.lookup(topLabel)?.tool ?? topLabel
            let agentPlan = await planner.plan(input: processedInput, routedToolName: resolvedName)
            if let firstStep = agentPlan.steps.first {
                let tool: (any CoreTool)? = await router.findCoreTool(named: firstStep.toolName)
                if let tool {
                    Log.engine.debug("Disambiguation resolved by planner: \(tool.name)")
                    lastRoutedToolNames = [tool.name]
                    await executeCoreTools([tool], input: processedInput)
                    await transitionTo(.finalization)
                    return
                }
            }
        }

        // Personal-name detour: if the input contains a personal name NER entity
        // and no email/phone pattern, the user is almost certainly asking a
        // contact-info LOOKUP question (e.g., "What is Jamie Chen's email?",
        // "Is Noah a friend?"). Without this guard the router's weak signal
        // between messages.* and email.* wins and the user sees a generic
        // "Messages or Email?" disambig. Route to Contacts instead.
        let inputHasPersonName = !(currentEntities?.names.isEmpty ?? true)
        let hasEmailAddr = CommunicationChannelResolver.containsEmailAddress(processedInput)
        let hasPhone     = CommunicationChannelResolver.containsPhoneNumber(processedInput)
        if inputHasPersonName && !hasEmailAddr && !hasPhone {
            if let contacts = await router.findCoreTool(named: "Contacts") {
                Log.engine.debug("Disambiguation → Contacts (personal-name detour)")
                lastRoutedToolNames = [contacts.name]
                await executeCoreTools([contacts], input: processedInput)
                await transitionTo(.finalization)
                return
            }
        }

        // Fallback: ask the user ONLY if no tool has already produced output
        // this turn. A ReAct re-route that lands here after a successful
        // first-tier tool run should let the LLM finalize on real data.
        let hasToolOutput = !currentIngredients.isEmpty || lastWidgetType != nil
        if !hasToolOutput {
            let friendlyNames = options.map { ExecutionEngine.userFriendlyToolName($0) }
            let separator = String(localized: ", ", bundle: .iClawCore)
            let optionsList = friendlyNames.joined(separator: separator)
            let fmt = String(localized: "Could you tell me a bit more? I can help with: %@.", bundle: .iClawCore)
            pendingDirectResponse = String(format: fmt, optionsList)
        } else {
            Log.engine.debug("Skipping disambiguation short-circuit — tool already produced output")
        }
        await transitionTo(.finalization)
    }

    /// Handles the tool execution state (overflow guard).
    private func handleToolExecution(callCount: Int) async {
        // This state is primarily handled within the .routing case for matched tools.
        // It can also be used for multi-turn tool logic.
        if callCount >= AppConfig.maxToolCallsPerTurn {
            Log.engine.debug("Reached max tool calls (\(AppConfig.maxToolCallsPerTurn)). Finalizing.")
        }
        // Whether max reached or not, move to finalization
        await transitionTo(.finalization)
    }

    /// Handles the finalization state: assembles prompt, calls LLM, post-processes response,
    /// records turn data, and returns the final result.
    private func handleFinalization(
        processedInput: String,
        turnStart: ContinuousClock.Instant
    ) async -> (text: String, widgetType: String?, widgetData: (any Sendable)?, isError: Bool, suggestedQueries: [String]?) {
        Log.engine.debug("Finalizing output (SOUL + Ingredients)...")
        emitProgress(.finalizing)

        // Short-circuit: if a prior stage set `pendingDirectResponse`, emit it
        // as-is without invoking the LLM. Used by disambiguation and other
        // deterministic-output branches so internal planner text can never
        // leak via LLM paraphrase.
        if let direct = pendingDirectResponse, !direct.isEmpty {
            Log.engine.debug("Emitting pending direct response, bypassing LLM finalizer")
            await conversationManager.recordExchange(userInput: processedInput, assistantReply: direct)
            // Snapshot before reset, then clear per-turn state so nothing
            // leaks into the next turn. Without this, pendingDirectResponse
            // would persist across prompts and every subsequent tool call
            // would be short-circuited to the prior answer.
            let widgetType = lastWidgetType
            let widgetData = lastWidgetData
            let suggestions = lastSuggestedQueries
            await conversationManager.incrementTurnCount()
            resetRunState()
            await transitionTo(.idle)
            return (
                text: direct,
                widgetType: widgetType,
                widgetData: widgetData,
                isError: false,
                suggestedQueries: suggestions
            )
        }

        // Conversational / clarification / replyElaboration turns don't need
        // tool-oriented BRAIN rules ("Call available tools first…") or the
        // profile block ("Frequently used: …"). Leaving those in makes the
        // LLM narrate its tool setup in small talk, emotional replies, or
        // clarifications ("I'm not a recipe generator", "I don't need a tool
        // for that"). Swap to the conversational BRAIN variant and strip
        // the profile to name/email only. SOUL voice stays intact.
        //
        // Classification: the turn is conversational when EITHER
        //   (a) the gate short-circuited routing outright, OR
        //   (b) routing ran but the router fell through to `.conversational`
        //       and no FM tools are attached and ingredients carry no
        //       verifiable tool data.
        // Case (b) catches turns like "what should I make for dinner?" that
        // pass the gate's interrogative bar but never actually use a tool.
        let gateSaysConversational: Bool = {
            guard let kind = currentGateDecision?.kind else { return false }
            switch kind {
            case .conversational, .clarification, .replyElaboration: return true
            case .toolSignal, .candidateScope: return false
            }
        }()
        let routerFellThrough: Bool = {
            // The turn is effectively conversational when the final
            // finalization prompt will have no tool-sourced content:
            //   • no FM tool is attached (so LLM can't call one)
            //   • no `[VERIFIED]` / `[BROWSER]` / `[CACHED]` / `[ERROR]`
            //     ingredient is in the bag (so there's nothing for a
            //     tool-oriented BRAIN to narrate)
            // This catches three paths:
            //   (a) router returned `.conversational`/`.disambiguation`
            //   (b) router chose a Core tool that SELF-REFUSED silently
            //       (Calculator/Convert's evidence gate, empty-text error)
            //   (c) router chose a tool that raised but healing succeeded
            //       into a [VERIFIED] ingredient → actually NOT this path,
            //       the tool-data check excludes it
            guard currentFMTools.isEmpty else { return false }
            let toolDataMarkers = ["[VERIFIED]", "[BROWSER", "[CACHED]", "[ERROR]"]
            let hasToolData = currentIngredients.contains { ing in
                toolDataMarkers.contains(where: { ing.contains($0) })
            }
            return !hasToolData
        }()
        let isConversationalTurn: Bool = gateSaysConversational || routerFellThrough
        let brainContent = BrainProvider.content(for: isConversationalTurn ? .conversational : .tool)
        let soulContent = SoulProvider.current
        let rawUserContext = await UserProfileProvider.current(with: await conversationManager.state.userPreferences)
        let userContext: String = isConversationalTurn
            ? Self.stripProfileForConversation(rawUserContext)
            : rawUserContext

        // Detect pivot vs follow-up for context gating and memory suppression.
        // drill_down is a follow-up: the user is exploring a prior result
        // (e.g., "summarize that article" after news headlines). It routes to
        // a different tool (WebFetch) but the context is still relevant.
        let hasChip = !InputParsingUtilities.extractToolChipNames(from: processedInput).isEmpty
        let isFollowUp = currentTurnRelation == .continuation
            || currentTurnRelation == .refinement
            || currentTurnRelation == .drillDown
            || currentTurnRelation == .retry

        // Auto-memory retrieval: search long-term memory for relevant past context.
        // Skip when: (a) substantive ingredients exist, (b) explicit chip used,
        // (c) Help tool routed (meta-queries have their own data).
        let hasSubstantiveIngredients = currentIngredients.contains { IngredientFilter.isSubstantive($0) }
        let skipMemory = hasSubstantiveIngredients
            || hasChip
            || lastRoutedToolNames.contains("Help")
        if !skipMemory {
            // Skip memory retrieval on the first turn of a fresh session.
            // NLEmbedding.sentenceEmbedding() cold-starts the entire NaturalLanguage
            // framework (~5-30s), which deadlocks the actor pipeline on cold start.
            // The LLM already has user profile data in the <user> block and
            // conversation facts in <ctx> -- memory recall is supplementary.
            // On subsequent turns (turnCount > 0), the model is warm and retrieval is fast.
            let turnCount = await conversationManager.state.turnCount
            if turnCount > 0 {
                let query = processedInput
                do {
                    let recalled = try await DatabaseManager.shared.searchMemoriesScored(
                        query: query, limit: MLThresholdsConfig.shared.autoRecall.maxResults, threshold: MLThresholdsConfig.shared.autoRecall.similarityThreshold
                    )
                    for (memory, score) in recalled {
                        let snippet = String(memory.content.prefix(300))
                        let ingredient = "[RECALLED] Previously discussed: \(snippet)"
                        if !ingredientAlreadyPresent(ingredient) {
                            currentIngredients.append(ingredient)
                            Log.engine.debug("Auto-recalled memory (score: \(String(format: "%.3f", score))): \(snippet.prefix(80))...")
                        }
                    }
                } catch {
                    Log.engine.debug("Auto-memory retrieval failed: \(error)")
                }
            }
        }

        // No-data branch: the former "No data was retrieved. Respond based only
        // on your knowledge, or ask the user for more information." ingredient
        // was being paraphrased into user output (including in the user's
        // language — Spanish output leaked the Spanish paraphrase). Brain
        // already tells the LLM to hedge when ingredients are empty, so no
        // ingredient is needed here. Keeping the branch as a no-op comment
        // so the intent is discoverable.

        // Context relevance gating: on pivot turns (different tool, no follow-up,
        // or explicit chip), use minimal context to prevent stale data from
        // dominating the LLM's attention over this turn's ingredients.
        let priorToolNames = await router.priorContext?.toolNames ?? []
        // Filter synthetic routing metadata -- only real tool names
        // participate in pivot detection. "disambiguation", "clarification",
        // and "conversational" are routing outcomes, not tool pivots.
        let syntheticNames: Set<String> = ["disambiguation", "clarification", "conversational"]
        let currentToolNames = lastRoutedToolNames.filter { !syntheticNames.contains($0) }
        let priorRealTools = priorToolNames.filter { !syntheticNames.contains($0) }
        // Pivot when: not a follow-up AND any of:
        //  (1) explicit chip
        //  (2) prior turn had no real tool context (synthetic/conversational/initial) —
        //      no signal to continue from, so safer to isolate
        //  (3) current + prior tool sets disjoint
        let isPivot = !isFollowUp && (
            hasChip ||
            priorRealTools.isEmpty ||
            (!currentToolNames.isEmpty &&
             Set(currentToolNames).isDisjoint(with: Set(priorRealTools)))
        )
        lastTurnTelemetry.pivotDetected = isPivot
        lastTurnTelemetry.followUpDetected = isFollowUp
        lastTurnTelemetry.classifierLabel = await router.lastRoutingLabel
        lastTurnTelemetry.classifierConfidence = await router.lastRouteConfidence
        var conversationContext: String?
        if isPivot {
            Log.engine.debug("Pivot detected -- using minimal context to prevent stale data leakage")
            conversationContext = await conversationManager.minimalContext()
        } else {
            conversationContext = await conversationManager.conversationContext()
        }

        // Conversational turns: strip tool-advertising lines from the
        // conversation context too. Both `conversationContext()` and
        // `minimalContext()` inject the profile block via `profileContext()`,
        // so the same "Frequently used: … / Common topics: …" lines leak
        // into `<ctx>` unless we filter them here.
        if isConversationalTurn, let ctx = conversationContext {
            conversationContext = Self.stripProfileForConversation(ctx)
        }

        // Capture context/user block words for leak detection in cleanLLMResponse.
        // If the LLM regurgitates these blocks, the guardrail will detect the overlap.
        let contextLeakSource = [conversationContext, userContext].compactMap { $0 }.joined(separator: " ")
        injectedContextWords = Set(
            contextLeakSource.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count > 3 }  // Skip short words ("the", "and", etc.)
        )
        // Build phrase-level fingerprint of brain+soul ONLY. Context and user
        // blocks are excluded: `conversationContext` carries prior-turn
        // ingredients ("Recent data: [VERIFIED] London is 5 hours ahead."), and
        // a follow-up response that legitimately reuses that data produces
        // 4-gram overlaps that are not echoes of the system scaffold. Context
        // regurgitation is caught separately by the word-level `injectedContextWords`
        // >60% overlap check above. Works across languages via
        // `.alphanumerics.inverted` tokenization.
        let phraseSource = [brainContent, soulContent]
            .compactMap { $0 }
            .joined(separator: " ")
        injectedPhraseGrams = Self.phraseGrams(of: phraseSource, n: 4)

        // Build adaptive turn budget based on actual component sizes.
        // Uses real tokenizer on macOS 26.4+ for identity tokens.
        let stateTokens = await conversationManager.stateTokenCost
        let schemaTokens = currentFMTools.isEmpty ? 0 : min(currentFMTools.count * 150, AppConfig.targetedToolSchemas)
        let identityTokens = await llmAdapter.countTokens(for: brainContent + soulContent + userContext)
        let turnBudget = AppConfig.buildTurnBudget(
            identitySize: identityTokens,
            conversationStateSize: stateTokens,
            toolSchemaSize: schemaTokens
        )
        Log.engine.debug("Turn budget: \(turnBudget.availableForData) tokens for data (state=\(stateTokens), schemas=\(schemaTokens))")

        // When FM tools need a file path, include it in the user prompt
        // so the LLM knows what to pass to the tool
        var userPromptForFinalizer = processedInput
        if let path = currentAttachmentPath, !currentFMTools.isEmpty {
            userPromptForFinalizer = "File: \(path)\n\(processedInput)"
        }

        // Call OutputFinalizer with conversation context
        let fmTools = currentFMTools.map { $0.makeTool() }
        let fmOverride: String? = {
            guard !fmTools.isEmpty else { return nil }
            let names = fmTools.map { $0.name }.joined(separator: " or ")
            return "You MUST call the \(names) tool to answer. Do NOT answer from memory — your training knowledge is stale and will be wrong. Use the tool-calling mechanism; never output JSON or function-call syntax as text."
        }()

        let detectedLang = currentEntities?.detectedLanguage
        let isAFM = await llmAdapter.isAFM

        // Recovery ladder: start at .full by default. Caller's RecoveryHint
        // (e.g., manual Retry button) forces .minimal. Emotionally-charged
        // inputs that collide with SOUL guardrails also preemptively start at
        // .minimal. On recoverable failures, escalate to .minimal, then .bare.
        let ladderStart: OutputFinalizer.RecoveryLevel = effectiveRecoveryStart(
            hint: currentRecoveryHint, input: processedInput, pivotDetected: isPivot
        )
        Log.engine.debug("Finalization ladder starts at: \(ladderStart)")
        let ladder: [OutputFinalizer.RecoveryLevel] = Self.ladderFrom(ladderStart)
        let tempsByLevel: [OutputFinalizer.RecoveryLevel: Double?] = [
            .full: nil,                          // backend default
            .minimal: LLMTemperature.recovery,   // 1.0 — max spread to break determinism
            .bare: LLMTemperature.recovery,
        ]
        let timeoutsByLevel: [OutputFinalizer.RecoveryLevel: UInt64] = [
            .full: 15_000_000_000,
            .minimal: 8_000_000_000,
            .bare: 5_000_000_000,
        ]

        var cleanedText = ""
        var attemptedLevels: [OutputFinalizer.RecoveryLevel] = []
        var lastAdapterError: LLMAdapter.AdapterError?
        var lastNSError: NSError?
        var finalPrompt = ""

        ladderLoop: for level in ladder {
            attemptedLevels.append(level)
            // Pivot turns and non-full tiers drop userContext entirely.
            let userCtxForLevel = (level != .full || isPivot) ? "" : userContext
            let ctxForLevel = (level == .full) ? conversationContext : nil

            var output = await finalizer.finalize(
                level: level,
                ingredients: currentIngredients,
                brainContent: brainContent,
                soulContent: soulContent,
                userContext: userCtxForLevel,
                userPrompt: userPromptForFinalizer,
                hasFMTools: !currentFMTools.isEmpty,
                conversationContext: ctxForLevel,
                maxDataTokens: turnBudget.availableForData,
                responseLanguage: detectedLang,
                backendIsAFM: isAFM
            )
            var mergedInstructions = Self.mergeInstructions(output.instructions, fmOverride)

            // Budget pre-validate only on the Full tier; Tier 2/3 are
            // structurally smaller and won't exceed the window.
            if level == .full {
                let estimatedTotal = await llmAdapter.countGuardTokens(
                    prompt: output.prompt, tools: fmTools, instructions: mergedInstructions
                )
                if estimatedTotal > AppConfig.totalContextBudget {
                    let overage = estimatedTotal - AppConfig.totalContextBudget
                    let reducedDataBudget = max(200, turnBudget.availableForData - overage)
                    Log.engine.warning("Final prompt exceeds budget (\(estimatedTotal) tokens), re-finalizing with \(reducedDataBudget) data tokens")
                    output = await finalizer.finalize(
                        level: level,
                        ingredients: currentIngredients,
                        brainContent: brainContent,
                        soulContent: soulContent,
                        userContext: userCtxForLevel,
                        userPrompt: userPromptForFinalizer,
                        hasFMTools: !currentFMTools.isEmpty,
                        conversationContext: ctxForLevel,
                        maxDataTokens: reducedDataBudget,
                        responseLanguage: detectedLang,
                        backendIsAFM: isAFM
                    )
                    mergedInstructions = Self.mergeInstructions(output.instructions, fmOverride)

                    let reEstimated = await llmAdapter.countGuardTokens(
                        prompt: output.prompt, tools: fmTools, instructions: mergedInstructions
                    )
                    if reEstimated > AppConfig.totalContextBudget {
                        Log.engine.warning("Re-finalized prompt still exceeds budget (\(reEstimated) tokens). Stripping conversation context.")
                        output = await finalizer.finalize(
                            level: level,
                            ingredients: currentIngredients,
                            brainContent: brainContent,
                            soulContent: soulContent,
                            userContext: userCtxForLevel,
                            userPrompt: userPromptForFinalizer,
                            hasFMTools: !currentFMTools.isEmpty,
                            conversationContext: nil,
                            maxDataTokens: max(200, reducedDataBudget - (reEstimated - AppConfig.totalContextBudget)),
                            responseLanguage: detectedLang,
                            backendIsAFM: isAFM
                        )
                        mergedInstructions = Self.mergeInstructions(output.instructions, fmOverride)
                    }
                }
            }

            finalPrompt = output.prompt
            Log.engine.debug("Finalization [\(level)] prompt:\n\(finalPrompt)")

            // Call LLM with level-specific temperature and timeout.
            let temperature = tempsByLevel[level] ?? nil
            let timeoutNs = timeoutsByLevel[level] ?? 15_000_000_000
            let rawText: String
            do {
                rawText = try await Self.generateWithTimeout(
                    adapter: llmAdapter,
                    responder: llmResponder,
                    prompt: finalPrompt,
                    tools: fmTools,
                    instructions: mergedInstructions,
                    temperature: temperature,
                    timeoutNs: timeoutNs
                )
            } catch let adapterError as LLMAdapter.AdapterError {
                lastAdapterError = adapterError
                if case .assetsUnavailable = adapterError { break ladderLoop }
                Log.engine.info("Tier \(level) failed with \(adapterError) — escalating")
                continue
            } catch is CancellationError {
                // User dismissed — propagate out of the ladder.
                resetRunState()
                await transitionTo(.idle)
                finishProgress()
                return ("", nil, nil, false, nil)
            } catch {
                // NE busy (VisualGeneration) — escalate with the NSError retained
                // so the outer path below can still apply its delay+retry if needed.
                let ns = error as NSError
                if ns.code == 1013 || ns.domain.contains("VisualGeneration") {
                    lastNSError = ns
                    try? await Task.sleep(nanoseconds: AppConfig.neuralEngineBusyRetryDelay)
                }
                Log.engine.info("Tier \(level) threw \(error) — escalating")
                continue
            }
            Log.engine.debug("LLM [\(level)] response: \(rawText)")

            cleanedText = cleanLLMResponse(rawText)

            // Classify the outcome; escalate or accept.
            let decision = classifyFinalization(
                cleaned: cleanedText,
                hasSubstantiveIngredients: hasSubstantiveIngredients,
                level: level
            )
            switch decision {
            case .accept:
                break ladderLoop
            case .escalate(let reason):
                Log.engine.info("Tier \(level) \(reason) — escalating")
                continue
            }
        }

        // After the ladder: if we still have nothing and the last error is
        // unrecoverable, surface the appropriate UX.
        if cleanedText.isEmpty, case .assetsUnavailable = lastAdapterError {
            let msg = "The on-device model isn't available right now. Check that Apple Intelligence is enabled in System Settings > Apple Intelligence & Siri."
            await transitionTo(.error(message: msg))
            currentFMTools = []
            finishProgress()
            return (msg, nil, nil, true, nil)
        }

        // Retain diagnostic for logs even if we recovered.
        if let lastAdapterError {
            Log.engine.debug("Ladder completed; last adapter error during attempts: \(String(describing: lastAdapterError))")
        }
        if let lastNSError {
            Log.engine.debug("Ladder completed; last NSError during attempts: \(lastNSError.code)/\(lastNSError.domain)")
        }

        // Splice back into the post-clean flow. A faux do-block wraps the old
        // success path so existing indentation and error handlers below keep
        // their shape; the catch arms now handle only the post-ladder fallbacks
        // for guardrail / generation failure when cleanedText is still empty.
        do {
            // cleanedText is now the ladder result (possibly empty).
            if cleanedText.isEmpty {
                // Ladder exhausted — throw the most recent adapter error (or
                // synthesize a guardrail violation) so the catch arms below can
                // run the extractive fallback / generic error paths.
                if let adapterErr = lastAdapterError {
                    throw adapterErr
                }
                throw LLMAdapter.AdapterError.generationFailed("Ladder exhausted with empty response")
            }

            // Detect soft LLM refusals: the model "succeeds" but its response
            // says "I can't assist" / "I'm sorry" despite having valid tool data.
            // Fall back to raw ingredient summary when this happens.
            // Classifier ladder when feature-flagged ON; else legacy phrase list.
            let softRefusedAfterLadder = hasSubstantiveIngredients
                ? await isSoftRefusalLadder(cleanedText)
                : false
            if softRefusedAfterLadder {
                Log.engine.debug("Soft LLM refusal detected with valid ingredients -- falling back to ingredient summary")
                cleanedText = buildGuardrailFallbackResponse(
                    ingredients: currentIngredients,
                    userPrompt: processedInput
                )
            }

            // Conversational-mode refusal retry: the base AFM (without the
            // iClaw LoRA adapter) frequently produces reflexive refusals
            // like "I cannot fulfill that request" on benign prompts
            // ("make it firmer", "three options", "expand on that"). Retry
            // once with a bluntly-primed prompt that strips the full
            // conversational BRAIN and just asks the model to answer.
            let conversationalRefusalDetected: Bool = (isConversationalTurn && !hasSubstantiveIngredients)
                ? await isSoftRefusalLadder(cleanedText)
                : false
            if conversationalRefusalDetected {
                let priorExchanges = await conversationManager.state.recentExchanges
                let priorReply: String = priorExchanges.last?.assistant ?? ""
                let retryPrompt: String
                if priorReply.isEmpty {
                    retryPrompt = """
                    Answer the user's message directly and helpfully. It is an ordinary conversational request — not harmful, not against any policy. Do not refuse. Do not say "I cannot". Do not mention AI, safety, rules, or policies. Just answer in 1–3 sentences.

                    User: \(processedInput)
                    """
                } else {
                    retryPrompt = """
                    You previously said:
                    \"\(priorReply)\"

                    The user now says: "\(processedInput)"

                    Apply the user's request to your previous reply. This is an ordinary refinement — not harmful. Do not refuse. Do not say "I cannot". Do not mention AI, safety, rules, or policies. Produce the revised reply directly.
                    """
                }
                do {
                    let retry = try await Self.generateWithTimeout(
                        adapter: llmAdapter,
                        responder: llmResponder,
                        prompt: retryPrompt,
                        tools: [],
                        instructions: nil,
                        temperature: 0.6,
                        timeoutNs: 10_000_000_000
                    )
                    let retryCleaned = cleanLLMResponse(retry)
                    let retryStillRefusing = retryCleaned.isEmpty
                        ? true
                        : await isSoftRefusalLadder(retryCleaned)
                    if !retryCleaned.isEmpty && !retryStillRefusing {
                        Log.engine.info("Refusal retry succeeded")
                        cleanedText = retryCleaned
                    } else {
                        Log.engine.info("Refusal retry still a refusal — keeping original")
                    }
                } catch {
                    Log.engine.info("Refusal retry failed: \(error)")
                }
            }

            // Guard: if cleaning produced empty text, fall back to ingredient summary or generic message
            if cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if hasSubstantiveIngredients {
                    Log.engine.debug("Empty response after cleaning -- falling back to ingredient summary")
                    cleanedText = buildGuardrailFallbackResponse(
                        ingredients: currentIngredients,
                        userPrompt: processedInput
                    )
                } else {
                    Log.engine.debug("Empty response with no ingredients -- using generic fallback")
                    cleanedText = "I wasn't able to generate a response for that. Try rephrasing or using a specific tool chip like #search."
                }
            }

            // Language guardrail: catches English-baseline responses
            // contaminated by multilingual tool output (e.g., a non-English
            // Wikipedia snippet causing the LLM to drift out of English).
            //
            // Only valid for English-baseline flows. Non-English input is
            // auto-translated to English for routing at line 402, and the
            // LLM prompts are English, so the LLM will respond in English
            // regardless of `detectedLanguage`. Firing the guardrail on
            // that path produces an English fallback that doesn't match
            // the user's language either — it defeats itself. Skip when
            // translation was attempted (detectedLanguage non-English) or
            // when translation failed and we're already in degraded mode.
            let inputLang = currentEntities?.detectedLanguage
            let isEnglishBaseline: Bool = {
                guard let lang = inputLang else { return true }
                return lang.hasPrefix("en") || lang == "und"
            }()
            if !cleanedText.isEmpty && isEnglishBaseline && !translationFailed {
                let systemCode = Locale.current.language.languageCode?.identifier ?? "en"
                let expectedNL = NLLanguage(rawValue: inputLang ?? systemCode)
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(cleanedText)
                if let responseLang = recognizer.dominantLanguage,
                   responseLang != expectedNL && responseLang != .undetermined {
                    Log.engine.warning("Language mismatch: expected \(expectedNL.rawValue), got \(responseLang.rawValue) -- falling back")
                    if hasSubstantiveIngredients {
                        cleanedText = buildGuardrailFallbackResponse(
                            ingredients: currentIngredients,
                            userPrompt: processedInput
                        )
                    }
                }
            }

            // Check for skill/tool-specific custom widget before dynamic widget generation
            if self.lastWidgetType == nil {
                let skillName = await router.currentSkill?.name
                if let (wType, wData) = SkillWidgetParser.buildWidget(
                    skillName: skillName,
                    toolNames: self.lastRoutedToolNames,
                    ingredients: currentIngredients,
                    responseText: cleanedText
                ) {
                    self.lastWidgetType = wType
                    self.lastWidgetData = wData
                }
            }

            // Generate dynamic widget if no tool widget was returned.
            // Text-heavy tools (encyclopedic / help / research) already return
            // prose the user reads directly — a dynamic widget on top of that
            // truncates the answer and adds no structured value. Suppress the
            // widget for those tools; structured tools (weather, stocks,
            // compute, calendar) still get one generated.
            let dynamicWidgetsEnabled = UserDefaults.standard.bool(forKey: AppConfig.dynamicWidgetsEnabledKey)
            let widgetSuppressedTools: Set<String> = [
                "WikipediaSearch", "WebSearch", "WebFetch", "Research", "Help"
            ]
            let lastTool = self.lastRoutedToolNames.last ?? ""
            let toolSuppressesWidget = widgetSuppressedTools.contains(lastTool)
            if dynamicWidgetsEnabled && self.lastWidgetType == nil && !self.hadToolError && !toolSuppressesWidget {
                let substantive = currentIngredients.filter {
                    IngredientFilter.isSubstantive($0)
                }
                let combined = substantive.joined()

                // Use ingredients if substantial, otherwise fall back to
                // the LLM response text itself (covers conversational turns
                // where the model generates structured info without tools).
                let widgetSource: [String]
                if combined.count >= WidgetLayoutGenerator.minIngredientLength {
                    widgetSource = substantive
                } else if cleanedText.count >= WidgetLayoutGenerator.minIngredientLength {
                    widgetSource = [cleanedText]
                } else if !currentFMTools.isEmpty && cleanedText.count >= 50 {
                    // FM tools produce synthesized text -- use a lower threshold
                    widgetSource = [cleanedText]
                } else {
                    widgetSource = []
                }

                if !widgetSource.isEmpty {
                    if let layout = await widgetLayoutGenerator.generateLayout(
                        ingredients: widgetSource,
                        userPrompt: processedInput
                    ) {
                        self.lastWidgetType = "DynamicWidget"
                        self.lastWidgetData = layout
                    }
                }
            }

            // Store widget info, suggestions, and error state before resetting
            let wType = self.lastWidgetType
            let wData = self.lastWidgetData
            let wasError = self.hadToolError
            let toolSuggestions = self.lastSuggestedQueries

            // Record turn in structured conversation state.
            // Gate on success: failed turns only increment the counter,
            // preventing stale topics from echoing in subsequent context.
            let toolName = Self.toolNameFromWidget(wType)
            if !wasError {
                let toolResultSummaries: [(toolName: String, summary: String)]
                if let name = toolName {
                    let substantive = IngredientFilter.substantive(currentIngredients)
                    let combined = substantive.joined(separator: " ").prefix(200)
                    toolResultSummaries = [(toolName: name, summary: String(combined))]
                } else {
                    toolResultSummaries = []
                }
                await conversationManager.recordTurn(
                    userInput: processedInput,
                    entities: currentEntities,
                    toolResults: toolResultSummaries
                )
                // Record the verbatim exchange so the next turn's `<ctx>`
                // block includes `Recent exchange: User: … Assistant: …`.
                // This is what carries conversational continuity — topic
                // / entity / fact summaries alone aren't enough for the
                // LLM to resolve pronouns and references like "expand on
                // the second paragraph" or "back to the recipe".
                await conversationManager.recordExchange(
                    userInput: processedInput,
                    assistantReply: cleanedText
                )
            } else {
                await conversationManager.incrementTurnCount()
            }

            // Record structured facts from tool execution into progressive memory.
            // Facts are ~10 tokens each and enable entity-anchored follow-up detection.
            if let name = toolName {
                let substantiveIngredients = IngredientFilter.substantive(currentIngredients)
                let fakeToolIO = ToolIO(text: substantiveIngredients.joined(separator: "\n"), status: wasError ? .error : .ok)
                let facts = FactCompressorRegistry.compress(toolName: name, result: fakeToolIO)
                if !facts.isEmpty {
                    await conversationManager.recordFacts(facts)
                }
            }

            // User profile learning: record tool usage, entities, and time patterns.
            // Refresh cached profile context for next turn's prompt.
            let profileToolNames = lastRoutedToolNames.filter { $0 != "conversational" && $0 != "disambiguation" && $0 != "clarification" }
            let profileEntities = currentEntities
            let convManager = conversationManager
            Task.detached {
                for name in profileToolNames {
                    await UserProfileManager.shared.recordToolUsage(name)
                    await UserProfileManager.shared.recordTimePattern(toolName: name)
                }
                await UserProfileManager.shared.recordEntities(profileEntities)
                await convManager.refreshProfileContext()
            }

            // Knowledge memory: extract personal facts from user input (background).
            // Cancel any still-pending extraction from the prior turn first
            // so we don't stack LLM work on the adapter.
            if UserDefaults.standard.bool(forKey: AppConfig.knowledgeMemoryEnabledKey),
               shouldAttemptKnowledgeExtraction(from: processedInput) {
                pendingKnowledgeTask?.cancel()
                let knowledgeInput = processedInput
                let knowledgeAdapter = llmAdapter
                let capturedConvManager = conversationManager
                pendingKnowledgeTask = Task.detached {
                    guard !Task.isCancelled else { return }
                    if let result = await extractKnowledge(from: knowledgeInput, adapter: knowledgeAdapter) {
                        guard !Task.isCancelled else { return }
                        let category = KnowledgeCategory(rawValue: result.category) ?? .personal
                        let entry = KnowledgeEntry(
                            category: category,
                            key: result.key,
                            value: result.value,
                            source: .userStated
                        )
                        do {
                            try await KnowledgeMemoryManager.shared.upsert(entry)
                        } catch {
                            Log.engine.debug("Knowledge upsert failed: \(error)")
                        }
                        // Preferences also land in ConversationState so they
                        // appear in `<ctx>` as `Preferences: k=v` on every
                        // subsequent turn. Known unit/system keys are mirrored
                        // into UserDefaults so tools that already read from
                        // there (WeatherTool) pick them up without further
                        // plumbing.
                        if category == .preference {
                            await capturedConvManager.setPreference(
                                key: result.key, value: result.value
                            )
                            Self.mirrorPreferenceToUserDefaults(
                                key: result.key, value: result.value
                            )
                        }
                    }
                }
            }

            // Post-turn quality assessment (background, never blocks response).
            // Only runs on tool-assisted turns to gauge tool response quality.
            // Same cancel-before-schedule discipline as knowledge extraction.
            if !profileToolNames.isEmpty && !wasError {
                pendingQualityTask?.cancel()
                let qualityQuery = processedInput
                let qualityResponse = String(cleanedText.prefix(200))
                let qualityTools = profileToolNames
                let qualityAdapter = llmAdapter
                // Ungrounded answers (tool routed but no ingredient produced) get
                // capped at 2/5 regardless of how confident they sound.
                let qualityHadOutput = hasSubstantiveIngredients
                pendingQualityTask = Task.detached {
                    guard !Task.isCancelled else { return }
                    await Self.assessQuality(
                        query: qualityQuery,
                        response: qualityResponse,
                        toolNames: qualityTools,
                        hadToolOutput: qualityHadOutput,
                        llmResponder: nil,
                        llmAdapter: qualityAdapter
                    )
                }
            }

            // Update prior context for follow-up routing before resetting
            await updatePriorContext(userInput: processedInput)

            // Reset counter, ingredients, entities, and widget info for next run
            let turnRelation = currentTurnRelation
            resetRunState()
            await transitionTo(.idle)

            // Emit performance metrics
            emitTurnPerformance(turnStart: turnStart, toolName: wType.flatMap { Self.toolNameFromWidget($0) }, turnRelation: turnRelation)

            // If the tool had an error but the LLM produced a substantive response
            // (not a refusal or empty), the user still gets useful information.
            // Don't flag it as an error -- the LLM recovered gracefully.
            // On the error-flag path, use the ladder when available. We're
            // already in an async context so the await is cheap; the ladder
            // returns the legacy result when the flag is off anyway.
            let textLooksRefusal: Bool
            if wasError, cleanedText.count >= 30 {
                textLooksRefusal = await isSoftRefusalLadder(cleanedText)
            } else {
                textLooksRefusal = cleanedText.count < 30
            }
            let effectiveError = wasError && textLooksRefusal

            finishProgress()
            return (cleanedText, wType, wData, effectiveError, toolSuggestions)
        } catch let adapterError as LLMAdapter.AdapterError {
            Log.engine.error("LLM generation error: \(adapterError)")

            switch adapterError {
            case .guardrailViolation:
                // Fall back to extractive summary from ingredients (no LLM)
                let fallback = buildGuardrailFallbackResponse(
                    ingredients: currentIngredients,
                    userPrompt: processedInput
                )
                let wType = self.lastWidgetType
                let wData = self.lastWidgetData
                let suggestions = self.lastSuggestedQueries
                resetRunState()
                await transitionTo(.idle)
                finishProgress()
                return (fallback, wType, wData, false, suggestions)

            case .assetsUnavailable:
                let msg = "The on-device model isn't available right now. Check that Apple Intelligence is enabled in System Settings > Apple Intelligence & Siri."
                await transitionTo(.error(message: msg))
                currentFMTools = []
                finishProgress()
                return (msg, nil, nil, true, nil)

            case .generationFailed(let detail):
                // If we have substantive ingredients, fall back to raw summary
                // instead of returning a generic error. This handles the 15s
                // finalization timeout -- the user gets the tool data even if
                // the LLM personalization timed out.
                if hasSubstantiveIngredients {
                    Log.engine.info("LLM finalization failed (\(detail.prefix(50))...) -- falling back to ingredient summary")
                    let fallback = buildGuardrailFallbackResponse(
                        ingredients: currentIngredients,
                        userPrompt: processedInput
                    )
                    let wType = self.lastWidgetType
                    let wData = self.lastWidgetData
                    let suggestions = self.lastSuggestedQueries
                    resetRunState()
                    await transitionTo(.idle)
                    finishProgress()
                    return (fallback, wType, wData, false, suggestions)
                }
                let msg = "The on-device model hit a temporary issue. Try rephrasing your request or try again shortly."
                await transitionTo(.error(message: msg))
                currentFMTools = []
                finishProgress()
                return (msg, nil, nil, true, nil)
            }
        } catch is CancellationError {
            // Task was cancelled (e.g., user dismissed) -- return empty
            resetRunState()
            await transitionTo(.idle)
            finishProgress()
            return ("", nil, nil, false, nil)
        } catch {
            // VisualGeneration state conflict: Neural Engine is busy with ImageCreator.
            // Retry once after a delay, then fall back to extractive summary.
            let nsError = error as NSError
            if nsError.code == 1013 || nsError.domain.contains("VisualGeneration") {
                Log.engine.info("Neural Engine busy (VisualGeneration) -- retrying finalization after 5s")
                try? await Task.sleep(nanoseconds: AppConfig.neuralEngineBusyRetryDelay)
                guard !Task.isCancelled else {
                    resetRunState()
                    await transitionTo(.idle)
                    finishProgress()
                    return ("", nil, nil, false, nil)
                }
                do {
                    let text: String
                    if let responder = llmResponder {
                        text = try await responder(finalPrompt, fmTools)
                    } else {
                        let response = try await llmAdapter.guardedGenerate(
                            prompt: finalPrompt,
                            tools: fmTools,
                            maxTokens: AppConfig.generationSpace,
                            sampling: LLMCallProfile.finalAnswer.sampling
                        )
                        text = response.content
                    }
                    let cleanedText = cleanLLMResponse(text)
                    let wType = self.lastWidgetType
                    let wData = self.lastWidgetData
                    let wasError = self.hadToolError
                    let suggestions = self.lastSuggestedQueries
                    resetRunState()
                    await transitionTo(.idle)
                    finishProgress()
                    return (cleanedText, wType, wData, wasError, suggestions)
                } catch {
                    Log.engine.error("LLM retry after VisualGeneration also failed: \(error)")
                    // Fall back to extractive summary instead of failing completely
                    let fallback = buildGuardrailFallbackResponse(
                        ingredients: currentIngredients,
                        userPrompt: processedInput
                    )
                    let wType = self.lastWidgetType
                    let wData = self.lastWidgetData
                    let suggestions = self.lastSuggestedQueries
                    resetRunState()
                    await transitionTo(.idle)
                    finishProgress()
                    return (fallback, wType, wData, false, suggestions)
                }
            }

            Log.engine.error("LLM Final Response failed: \(error)")
            let msg = "The on-device model hit a temporary issue. Try again shortly."
            await transitionTo(.error(message: msg))

            currentFMTools = []
            finishProgress()
            return (msg, nil, nil, true, nil)
        }
    }

    // MARK: - State Management

    func transitionTo(_ newState: State) async {
        #if DEBUG
        Self.assertValidTransition(from: currentState, to: newState)
        #endif
        let now = ContinuousClock.now
        let elapsed = stageStart.duration(to: now)
        let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000 + Double(elapsed.components.seconds) * 1000
        stageDurations.append((String(describing: currentState), ms))
        stageStart = now
        Log.engine.debug("Transition: \(String(describing: self.currentState)) -> \(String(describing: newState)) [\(String(format: "%.0f", ms))ms]")
        // Emit an Instruments Points-of-Interest event for every transition so
        // post-mortem traces show the full FSM sequence without log grepping.
        let fromName: StaticString = Self.signpostName(for: currentState)
        let toName: StaticString = Self.signpostName(for: newState)
        Self.signposter.emitEvent(
            "transition",
            "\(fromName, privacy: .public) → \(toName, privacy: .public) (\(Int(ms))ms)"
        )
        self.currentState = newState
    }

    /// Stable per-state static string for OSSignposter. Avoids allocating
    /// strings on every transition — OSSignposter requires StaticString for
    /// names. Returns a coarse label when the state carries a payload.
    private static func signpostName(for state: State) -> StaticString {
        switch state {
        case .idle: return "idle"
        case .preprocessing: return "preprocessing"
        case .routing: return "routing"
        case .planning: return "planning"
        case .disambiguation: return "disambiguation"
        case .toolExecution: return "toolExecution"
        case .finalization: return "finalization"
        case .error: return "error"
        }
    }

    /// Validates that a state transition is legal. Debug-only assertion.
    private static func assertValidTransition(from current: State, to next: State) {
        let valid: Bool
        switch (current, next) {
        case (.idle, .preprocessing): valid = true
        case (.preprocessing, .routing), (.preprocessing, .error): valid = true
        case (.routing, .planning), (.routing, .toolExecution),
             (.routing, .disambiguation), (.routing, .finalization),
             (.routing, .error), (.routing, .idle): valid = true
        case (.planning, .toolExecution), (.planning, .finalization),
             (.planning, .error): valid = true
        case (.disambiguation, .finalization), (.disambiguation, .idle),
             (.disambiguation, .error): valid = true
        case (.toolExecution, .finalization), (.toolExecution, .routing),
             (.toolExecution, .error), (.toolExecution, .idle): valid = true
        case (.finalization, .idle), (.finalization, .error): valid = true
        case (.error, .idle): valid = true
        // Allow any state to transition to .idle (error recovery) or .error
        case (_, .idle): valid = true
        case (_, .error): valid = true
        default: valid = false
        }
        if !valid {
            Log.engine.error("Invalid state transition: \(String(describing: current)) → \(String(describing: next))")
        }
    }

    private func isErrorState(_ state: State) -> Bool {
        if case .error = state {
            return true
        }
        return false
    }

    /// Resets all conversation state for a fresh session. Clears router follow-up
    /// context, conversation memory, and per-turn state. Called by CLI daemon reset.
    public func resetConversation() async {
        await router.clearPriorContext()
        await conversationManager.reset()
        // Abort any in-flight background LLM work — it's scoped to a
        // conversation that no longer exists.
        pendingKnowledgeTask?.cancel()
        pendingQualityTask?.cancel()
        pendingKnowledgeTask = nil
        pendingQualityTask = nil
        resetRunState()
    }

    func resetRunState() {
        toolCallCounter = 0
        currentIngredients = []
        currentEntities = nil
        currentFMTools = []
        currentTurnRelation = nil
        currentGateDecision = nil
        lastWidgetType = nil
        lastWidgetData = nil
        lastSuggestedQueries = nil
        currentWidgetPayload = nil
        hadToolError = false
        currentAttachmentPath = nil
        injectedContextWords = []
        injectedPhraseGrams = []
        browserContextIsFocalPoint = false
        // Clear browser full text (metadata persists for follow-ups)
        Task { await BrowserBridge.shared.clearFullText() }
        suppressedTools = []
        hasValidationRetried = false
        consentDeniedToolName = nil
        skipConsentThisTurn = false
        lastWebFetchURL = nil
        currentRecoveryHint = nil
        shelvedIngredients = []
        pendingDirectResponse = nil
        fallbackAttempted = []
        lastTurnTelemetry = TurnTelemetry()
    }

    // MARK: - External Control

    /// Sets the follow-up boost flag on the router. Called by the UI when
    /// the context pill is anchored/unanchored.
    public func setFollowUpBoost(_ active: Bool) async {
        await router.setFollowUpBoost(active)
    }

    /// Used to resolve disambiguation from the UI or external source.
    public func resolveDisambiguation(with choice: String) async {
        guard case .disambiguation = currentState else {
            Log.engine.debug("Disambiguation not requested in current state \(String(describing: self.currentState)).")
            return
        }

        Log.engine.debug("Disambiguation resolved with '\(choice)' -- falling through to conversational.")
        // Brain-conversational handles "just answer" semantics; no ingredient
        // needed here. The user's choice is in `choice` and conversation
        // context; let the LLM answer directly.
        await transitionTo(.finalization)
    }

    public func reset() async {
        await transitionTo(.idle)
        resetRunState()
        await router.clearPriorContext()
        RouterFeedback.shared.clear()
    }
}
