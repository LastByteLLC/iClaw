import Foundation
import FoundationModels

/// AppConfig defines the explicit token budgets and execution limits for iClaw's 4K context window.
/// Adheres to Swift 6 strict concurrency requirements.
public struct AppConfig: Sendable {
    // MARK: - Token Budgets (Total: SystemLanguageModel.default.contextSize, fallback 4096)
    //
    // Brain-Body-Soul architecture:
    //   brain  (100) — operational rules (BRAIN.md)
    //   soul   (80)  — personality (SOUL.md)
    //   user   (40)  — persistent user context (UserProfileProvider)
    //
    // Progressive memory (replaces 500-token state blob):
    //   facts  (60)  — 5 structured facts @ ~12 tokens each
    //   summary(80)  — incremental running summary of evicted facts
    //   state  (70)  — topics + entities + preferences + turn count
    //   workflow(50) — active workflow slot state
    //
    // Agent headroom (reclaimed from old state blob):
    //   ~220 tokens available for agent reasoning turns
    //
    // See Docs/TokenBudget.md for rationale.

    public static let brain = 100
    public static let soul = 80
    public static let user = 40
    public static let conversationStateBlob = 280
    public static let targetedToolSchemas = 600
    public static let retrievedDataChunks = 2000
    public static let generationSpace = 900

    /// Combined identity budget (brain + soul + user).
    public static var identityBudget: Int { brain + soul + user }
    
    /// Total available tokens in the context window.
    ///
    /// Reads `SystemLanguageModel.default.contextSize` when Apple Intelligence is
    /// available, falling back to `contextSizeFallback` (4096) on CI, older hardware,
    /// or when the model is otherwise unavailable. Resolved once at first access.
    public static let totalContextBudget: Int = {
        // `contextSize` is `@backDeployed(before: macOS 26.4)` — available on our
        // macOS 26.0 floor. Guard on model availability so CI runners and machines
        // without Apple Intelligence provisioned still get a sane budget.
        let isAvailable: Bool
        if case .available = SystemLanguageModel.default.availability {
            isAvailable = true
        } else {
            isAvailable = false
        }
        return resolveContextBudget(
            isAvailable: isAvailable,
            readContextSize: { SystemLanguageModel.default.contextSize }
        )
    }()

    /// Static fallback used when `SystemLanguageModel` cannot report a context size.
    public static let contextSizeFallback = 4096

    /// Testable resolution helper. When `isAvailable` is `false`,
    /// `readContextSize` is never invoked — this keeps the call site crash-safe
    /// on environments where reading the property would otherwise trap.
    static func resolveContextBudget(
        isAvailable: Bool,
        readContextSize: () -> Int
    ) -> Int {
        guard isAvailable else { return contextSizeFallback }
        return readContextSize()
    }
    
    // MARK: - Execution Limits
    
    public static let maxToolCallsPerTurn = 6
    public static let mlDisambiguationConfidenceThreshold = 0.1
    public static let maxRetriesPerTool = 1
    public static let maxReActIterations = 3
    public static let maxPriorContextDepth = 3

    // MARK: - ML Routing

    /// Minimum confidence threshold for ML classifier results (below this, fall through to LLM).
    public static let mlMinimumConfidenceThreshold = 0.2

    /// Minimum absolute confidence for the top label to trigger disambiguation.
    /// When both top candidates score below this, the classifier is guessing —
    /// fall through to LLM fallback instead of asking the user to choose between
    /// two weak predictions.
    public static let mlDisambiguationAbsoluteFloor: Double = 0.35

    /// Router confidence at or above which the ExecutionEngine's protected-tool
    /// filter is bypassed. The filter exists to catch ML false positives on
    /// protected tools (News/Calendar/Podcast/Timer/…), but when the ML classifier
    /// or a hard-evidence stage produced the route with high confidence, the
    /// filter is more harmful than helpful — blocking "news on Iran" because
    /// "Iran" as a place only hints Weather/Maps is the canonical failure mode.
    public static let routeHighConfidenceThreshold: Double = 0.70

    // MARK: - iMessage Integration

    public static let iMessagePollIntervalSeconds: TimeInterval = 5
    public static let iMessageTriggerPrefix = "hey claw"

    // MARK: - Browser Bridge

    public static let browserBridgeMaxMessageSize = 1_048_576

    // MARK: - Knowledge Memory

    public static let knowledgeMemoryMaxEntries = 200
    public static let knowledgeMemoryMaxPerTurn = 3
    public static let knowledgeMemoryConfidenceDecay = 0.95
    public static let knowledgeMemoryMinConfidence = 0.05
    public static let knowledgeMemoryRelevanceThreshold = 0.45
    public static let knowledgeMemoryEnabledKey = "knowledgeMemoryEnabled"

    // MARK: - Screen Context

    public static let screenContextMaxChars = 500
    public static let screenContextCaptureIntervalSeconds: TimeInterval = 30

    // MARK: - Automations

    public static let maxActiveAutomations = 10
    public static let minimumAutomationIntervalSeconds = 300 // 5 minutes
    public static let automationMaxConsecutiveFailures = 5
    public static let automationMaxPerHeartbeat = 3

    // MARK: - Email

    public static let maxReadEmailResults = 10
    public static let emailBodySnippetLimit = 400

    // MARK: - Greeting Constants

    public static let greetingHolidayLookaheadDays = 14
    public static let greetingMinHistoryForPhase3 = 3
    public static let greetingPhase3TimeoutSeconds: TimeInterval = 5
    public static let greetingQuoteFetchChance = 5 // 1-in-N chance per launch (e.g., 5 = 20%)

    // MARK: - Version

    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    public static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Public URLs

    public static let websiteURL = "https://geticlaw.com"
    public static let githubURL = "https://github.com/LastByteLLC/iClaw"
    public static let privacyPolicyURL = "https://geticlaw.com/privacy/"
    public static let tosURL = "https://geticlaw.com/terms/"
    public static let supportEmail = "hello@last-byte.org"
    public static let supportMailto = "mailto:hello@last-byte.org?subject=iClaw%20Support"
    public static let feedbackMailto = "mailto:hello@last-byte.org?subject=iClaw%20Feedback"

    // MARK: - App Store

    public static let appStoreID = "6742044186"

    // MARK: - Network Test Endpoints

    public static let speedTestURL = "https://www.apple.com/"

    // MARK: - API Endpoints

    public static let apiBaseURL = "https://geticlaw.com"
    public static let feedbackEndpoint = "/api/feedback"
    public static let crashLogEndpoint = "/api/crash-logs"

    // MARK: - Neural Engine Recovery

    public static let neuralEngineBusyRetryDelay: UInt64 = 5_000_000_000

    // MARK: - UserDefaults Keys

    public static let screenContextEnabledKey = "screenContextEnabled"
    public static let browserBridgeEnabledKey = "browserBridgeEnabled"
    public static let dynamicWidgetsEnabledKey = "dynamicWidgetsEnabled"
    public static let autoApproveActionsKey = "autoApproveActions"
    public static let autoSpeakResponsesKey = "autoSpeakResponses"
    public static let personalityLevelKey = "personalityLevel"
    public static let customPersonalityKey = "customPersonality"
    public static let temperatureUnitKey = "temperatureUnit"
    public static let ttsVoiceIdentifierKey = "ttsVoiceIdentifier"
    public static let hasAcceptedTOSKey = "hasAcceptedTOS"
    public static let hasSeenTutorialKey = "hasSeenTutorial"
    public static let textSizePreferenceKey = "textSizePreference"
    public static let notificationModeKey = "notificationMode"
    public static let heartbeatIntervalKey = "heartbeatInterval"
    public static let continuityEnabledKey = "continuityEnabled"
    public static let continuityDeviceIDKey = "continuityDeviceID"
    public static let sendAnonymousCrashDataKey = "sendAnonymousCrashData"
    public static let readEmailDefaultCountKey = "readEmailDefaultCount"
    public static let hotkeyKeyCodeKey = "hotkeyKeyCode"
    public static let hotkeyModifierFlagsKey = "hotkeyModifierFlags"

    // MARK: - Classifier-Over-Regex (Phases 1–7, always-on)
    //
    // Compile-time constants set to `true`. Started as UserDefaults flags
    // for staged rollout; the classifier ladder is now the production
    // path. Legacy English heuristics remain as low-confidence fallbacks
    // inside the ladder methods, not gated by a separate flag.

    /// `ResponsePathologyClassifier` drives refusal / meta-leak / empty-
    /// stub handling. Legacy `isSoftRefusal` phrase list is the low-
    /// confidence fallback inside `isSoftRefusalLadder`.
    public static let useClassifierResponseCleaning = true

    /// `ConversationIntentClassifier` produces 5-class intent labels that
    /// gate routing. Legacy `isMetaQuery` English seeds remain as the
    /// low-confidence fallback inside `isMetaQueryAsync`.
    public static let useClassifierIntentRouting = true

    /// `UserFactClassifier` runs alongside legacy `PreferenceDetector`;
    /// high-confidence non-`none` predictions persist to
    /// `ConversationState.userFacts` for `<ctx>` injection on later turns.
    public static let useClassifierUserFacts = true

    /// `LLMJudge` resolves `.medium`-confidence classifier outputs
    /// (0.60–0.85). Cached LRU 256 entries; ~200ms p95 added latency on
    /// cache miss.
    public static let useLLMJudge = true

    // Legacy UserDefaults keys preserved as constants so external scripts
    // (CLI probes, stress benches) that emit `setting useClassifier… true`
    // continue to compile. The handlers are now no-ops because the engine
    // consults the compile-time constants above. Safe to remove once all
    // external callers are updated.
    public static let useClassifierResponseCleaningKey = "useClassifierResponseCleaning"
    public static let useClassifierIntentRoutingKey = "useClassifierIntentRouting"
    public static let useClassifierUserFactsKey = "useClassifierUserFacts"
    public static let useLLMJudgeKey = "useLLMJudge"

    // MARK: - Network

    public static let networkRequestTimeout: TimeInterval = 10
    public static let maxDownloadSize = 5_000_000
    /// Default per-tool execution timeout in seconds (used when ToolManifest omits `timeout`).
    public static let defaultToolTimeout = 15
    /// Budget (seconds) for a one-shot retry after a tool times out.
    /// Prerequisites (permissions, location) should already be cached from the first attempt.
    public static let timeoutRecoveryBudget = 5

    // MARK: - Text-to-Speech

    public static let ttsCharacterThreshold = 300
    
    // MARK: - Adaptive Token Budget

    /// A per-turn budget computed from actual usage rather than static maximums.
    /// Components that aren't needed on a given turn release their tokens for data/generation.
    public struct TurnBudget: Sendable {
        public let identity: Int            // brain + soul + user (actual)
        public let conversationState: Int   // Actual serialized state size
        public let toolSchemas: Int         // Actual schemas selected
        public let generationSpace: Int

        /// Tokens available for tool output data, computed dynamically.
        public var availableForData: Int {
            max(0, totalContextBudget - identity - conversationState - toolSchemas - generationSpace)
        }

        /// Total tokens consumed by fixed components.
        public var fixedCost: Int {
            identity + conversationState + toolSchemas + generationSpace
        }
    }

    /// Builds a turn budget from actual component sizes. Components that aren't used
    /// release their tokens to `availableForData`.
    public static func buildTurnBudget(
        identitySize: Int = 0,
        conversationStateSize: Int = 0,
        toolSchemaSize: Int = 0
    ) -> TurnBudget {
        TurnBudget(
            identity: min(identitySize, identityBudget),
            conversationState: min(conversationStateSize, conversationStateBlob),
            toolSchemas: min(toolSchemaSize, targetedToolSchemas),
            generationSpace: generationSpace
        )
    }

    /// Estimates token count from a string using word-level heuristics.
    /// Handles CJK, code, and mixed content more accurately than char/4.
    public static func estimateTokens(for text: String) -> Int {
        TokenEstimator.estimate(text)
    }

    // MARK: - Validation

    /// Validates if the provided token counts fit within the total 4K window.
    public static func validateBudget(
        identity: Int,
        stateBlob: Int,
        toolSchemas: Int,
        dataChunks: Int
    ) -> Bool {
        let currentTotal = identity + stateBlob + toolSchemas + dataChunks
        return (currentTotal + generationSpace) <= totalContextBudget
    }

    /// Detailed budget check that ensures individual components don't exceed their allocations.
    public static func isComponentWithinBudget(
        identity: Int,
        stateBlob: Int,
        toolSchemas: Int,
        dataChunks: Int
    ) -> (isValid: Bool, overflows: [String]) {
        var overflows: [String] = []

        if identity > identityBudget { overflows.append("identity") }
        if stateBlob > conversationStateBlob { overflows.append("stateBlob") }
        if toolSchemas > targetedToolSchemas { overflows.append("toolSchemas") }
        if dataChunks > retrievedDataChunks { overflows.append("dataChunks") }

        let totalValid = validateBudget(
            identity: identity,
            stateBlob: stateBlob,
            toolSchemas: toolSchemas,
            dataChunks: dataChunks
        )

        if !totalValid { overflows.append("totalContext") }

        return (overflows.isEmpty, overflows)
    }
}
