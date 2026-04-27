import Foundation

/// Per-turn structured trace collector for the Meta-Harness loop.
///
/// Two artifact streams are collected:
///   • LLM calls — one record per real backend invocation (generate /
///     generateStructured). Captures site, prompt/response char counts, wall
///     time, backend, and any error. The `site` is an optional task-local
///     tag set by the caller (OutputFinalizer, AgentPlanner, etc.) — this
///     keeps LLMAdapter's API unchanged while still attributing calls.
///   • Router stages — one record per stage that *won* the routing decision
///     (`winning stage`). Non-winning stage evaluations are intentionally
///     not recorded here: they would dominate the trace and the winner plus
///     the input usually tells you everything anyway.
///
/// The collector is installed for the duration of one ExecutionEngine turn
/// via `TurnTraceCollector.$current.withValue(collector) { ... }`. Code
/// running inside that scope reads `TurnTraceCollector.current` and records
/// as needed. When the scope exits, the snapshot is retrieved by the
/// orchestrator (CLI, tests) and attached to whatever output channel the
/// caller provides.
public actor TurnTraceCollector {

    /// Current collector for the running task tree. `nil` outside a turn
    /// (GUI production calls, CLI turns not requesting tracing).
    @TaskLocal public static var current: TurnTraceCollector?

    /// Current caller tag. Set by code that calls into `LLMAdapter` so that
    /// the adapter can attribute the call without API changes. Fallback:
    /// "unknown".
    ///
    /// Example:
    /// ```
    /// TurnTraceCollector.$currentSite.withValue("OutputFinalizer") {
    ///     let text = try await LLMAdapter.shared.generateText(prompt)
    /// }
    /// ```
    @TaskLocal public static var currentSite: String?

    public struct LLMCall: Sendable, Encodable {
        public let site: String
        public let kind: String            // "generate" | "generateStructured" | "generateForExtraction"
        public let backend: String         // "AFM" | "Ollama" | "test"
        public let promptChars: Int
        public let responseChars: Int
        public let ms: Int
        public let error: String?          // nil on success
    }

    public struct RouterStage: Sendable, Encodable {
        public let stage: String           // "attachment" | "followUp" | "chip" | "ticker" | "url" | "skill" | "ml" | "mlVerifier" | "heuristic" | "llmFallback" | "conversational" | …
        public let decision: String        // tool name, "conversational", "clarification", etc.
        public let confidence: Double?     // lastRouteConfidence equivalent
        public let reason: String?         // short human-readable note
    }

    public struct Snapshot: Sendable, Encodable {
        public let llmCalls: [LLMCall]
        public let routerStages: [RouterStage]
        public let llmCallCount: Int
        public let llmTotalPromptChars: Int
        public let llmTotalResponseChars: Int
        public let llmTotalMs: Int
    }

    private var llmCalls: [LLMCall] = []
    private var routerStages: [RouterStage] = []

    public init() {}

    public func recordLLMCall(_ call: LLMCall) {
        llmCalls.append(call)
    }

    public func recordRouterStage(_ stage: RouterStage) {
        routerStages.append(stage)
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            llmCalls: llmCalls,
            routerStages: routerStages,
            llmCallCount: llmCalls.count,
            llmTotalPromptChars: llmCalls.reduce(0) { $0 + $1.promptChars },
            llmTotalResponseChars: llmCalls.reduce(0) { $0 + $1.responseChars },
            llmTotalMs: llmCalls.reduce(0) { $0 + $1.ms }
        )
    }
}
