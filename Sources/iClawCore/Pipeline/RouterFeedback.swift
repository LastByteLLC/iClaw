import Foundation
import os

/// In-memory per-session tracker of tool failures. When a tool's output
/// fails the `ToolOutputClassifier` quality gate, the engine calls
/// `RouterFeedback.shared.recordFailure`. On the next routing decision,
/// `MLToolResolution` calls `scoreAdjustment(for:input:)` which downweights
/// any tool that recently failed on a semantically similar input.
///
/// Cleared on `engine.reset()` or CLI `reset` command. No persistence by
/// design — stale negative signal hurts more than it helps across sessions.
///
/// Uses `OSAllocatedUnfairLock` rather than an actor so the router can
/// consult it from sync code (evaluateMLResults) without an `await` hop.
public final class RouterFeedback: @unchecked Sendable {
    public static let shared = RouterFeedback()

    private struct Failure {
        let tool: String
        let inputTokens: Set<String>
        let at: Date
    }

    private let state = OSAllocatedUnfairLock<[Failure]>(initialState: [])
    private let capacity = 16
    private let ttlSeconds: TimeInterval = 300
    private let penalty: Double = 0.20
    private let similarityThreshold = 0.5

    private init() {}

    /// Records a tool failure for the given input.
    ///
    /// Emits an `info`-level log and an Instruments "router.misprediction"
    /// event so post-launch analysis has grep-able and trace-able evidence
    /// of which tools most often produce bad decisions. The in-memory state
    /// is still scoped to a single session; the log and signpost provide
    /// the cross-session signal.
    public func recordFailure(tool: String, input: String) {
        let tokens = Self.distinctiveTokens(input)
        guard !tokens.isEmpty else { return }
        state.withLock { list in
            list.append(Failure(tool: tool, inputTokens: tokens, at: Date()))
            if list.count > capacity {
                list.removeFirst(list.count - capacity)
            }
        }
        Log.router.info("router.misprediction tool=\(tool) input=\(input.prefix(80))")
        Self.signposter.emitEvent(
            "router.misprediction",
            "tool=\(tool, privacy: .public)"
        )
    }

    private static let signposter = OSSignposter(
        subsystem: "com.podlp.iclaw",
        category: "RouterFeedback"
    )

    /// Returns a downward adjustment (≤ 0) to the confidence of `tool`
    /// given `input`. Zero when no matching recent failure exists.
    public func scoreAdjustment(for tool: String, input: String) -> Double {
        let currentTokens = Self.distinctiveTokens(input)
        guard !currentTokens.isEmpty else { return 0 }

        let snapshot = state.withLock { $0 }
        let now = Date()
        let relevant = snapshot.filter { $0.tool == tool && now.timeIntervalSince($0.at) < ttlSeconds }
        guard !relevant.isEmpty else { return 0 }

        var maxSim: Double = 0
        for f in relevant {
            let union = currentTokens.union(f.inputTokens)
            guard !union.isEmpty else { continue }
            let inter = currentTokens.intersection(f.inputTokens)
            let sim = Double(inter.count) / Double(union.count)
            if sim > maxSim { maxSim = sim }
        }
        return maxSim >= similarityThreshold ? -penalty : 0
    }

    public func clear() {
        state.withLock { $0.removeAll() }
    }

    private static func distinctiveTokens(_ input: String) -> Set<String> {
        let lower = input.lowercased()
        let tokens = lower.components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 4 }
        return Set(tokens)
    }
}
