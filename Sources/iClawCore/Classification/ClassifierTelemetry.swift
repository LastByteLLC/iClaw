import Foundation
import os

/// Structured telemetry emitter for classifier+judge decisions.
/// One call per dispatch decision. Produces log lines that are queryable via
/// Console.app and filterable by the `classifier` subsystem/category.
///
/// Fields (stable contract; changing these breaks downstream dashboards):
///   - classifier: name ("pathology", "intent", "userfact", "refusal-ladder")
///   - label: the resolved label (top of classifier OR judge verdict)
///   - confidence: 0.0–1.0
///   - tier: "high" | "medium" | "low" | "none" (nil classifier output)
///   - resolvedVia: "classifier" | "judge" | "legacy"
///   - judgeCalled: whether the LLM judge ran this turn
///   - cacheHit: whether the judge hit its LRU cache (if called)
///   - latencyMs: end-to-end decision latency including any judge call
///   - divergedFromLegacy: true if the resolved label differs from what
///     the legacy heuristic would have said. Absent → unknown.
///
/// Zero-cost when the log category is disabled (os.Logger inlines the check).
public enum ClassifierTelemetry {

    public static func record(
        classifier: String,
        label: String,
        confidence: Double,
        tier: String,
        resolvedVia: String,
        judgeCalled: Bool = false,
        cacheHit: Bool = false,
        latencyMs: Int = 0,
        divergedFromLegacy: Bool? = nil
    ) {
        let divergenceField: String
        if let diverged = divergedFromLegacy {
            divergenceField = diverged ? "yes" : "no"
        } else {
            divergenceField = "-"
        }

        // Format: key=value pairs, space-separated. Console filter:
        //   subsystem:com.geticlaw.iClaw category:classifier
        // Dashboard parser can tokenize key=value.
        Log.classifier.info("""
        classifier=\(classifier, privacy: .public) \
        label=\(label, privacy: .public) \
        conf=\(String(format: "%.2f", confidence), privacy: .public) \
        tier=\(tier, privacy: .public) \
        via=\(resolvedVia, privacy: .public) \
        judge=\(judgeCalled ? "y" : "n", privacy: .public) \
        cache=\(cacheHit ? "y" : "n", privacy: .public) \
        ms=\(latencyMs, privacy: .public) \
        diverge=\(divergenceField, privacy: .public)
        """)
    }

    /// Convenience wrapper for the legacy-fallback path (no classifier /
    /// flag off). Kept separate so the dashboards can count legacy turns
    /// without confusing them with classifier-abstain cases.
    public static func recordLegacy(
        classifier: String,
        label: String,
        reason: String
    ) {
        Log.classifier.info("""
        classifier=\(classifier, privacy: .public) \
        label=\(label, privacy: .public) \
        via=legacy reason=\(reason, privacy: .public)
        """)
    }
}
