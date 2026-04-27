import CoreML
import Foundation
import NaturalLanguage

/// Multilingual MaxEnt classifier that judges the QUALITY of an LLM response.
///
/// Replaces the English-only phrase lists in `LLMResponseCleaning.isSoftRefusal`
/// and the mid-response/leading strip regexes. Works on any language because
/// the MaxEnt features are character n-grams, word tokens, length buckets, and
/// detected input language — no hard-coded English vocabulary.
///
/// Six output labels:
///   • `ok` — usable response; ship it.
///   • `refusal` — reflexive refusal to a benign request. Retry with hardened
///     prompt or fall back to ingredient summary.
///   • `metaLeak` — template preamble or bracket-tag echo. Strip or regenerate.
///   • `emptyStub` — vague one-liner ("Okay.", "Sure.") that doesn't answer.
///   • `instructionEcho` — regurgitates prompt structure instead of answering.
///   • `pureIngredientEcho` — dumps raw ingredient/context block verbatim.
///
/// The classifier is the **fast path**. Callers that need higher confidence on
/// ambiguous cases escalate to an LLM judge.
///
/// Thread-safe via actor isolation. Model loads lazily on first `classify` call.
/// Gated behind `AppConfig.useClassifierResponseCleaning` — when `false`, the
/// legacy heuristic cleaning stays in effect.
public actor ResponsePathologyClassifier {
    public static let shared = ResponsePathologyClassifier()

    private var model: NLModel?
    private var isLoaded = false

    /// The six pathology labels produced by the trained model. Raw values
    /// match the `label` column in the training data.
    public enum Label: String, Sendable, CaseIterable {
        case ok
        case refusal
        case metaLeak = "meta_leak"
        case emptyStub = "empty_stub"
        case instructionEcho = "instruction_echo"
        case pureIngredientEcho = "pure_ingredient_echo"
    }

    /// Result returned from a classification call.
    public struct Result: Sendable {
        public let label: Label
        public let confidence: Double
        /// Top-3 alternatives with their scores, for LLM-judge fallback triage.
        public let hypotheses: [(label: Label, score: Double)]

        /// Whether the caller should act on this label directly (≥0.85) vs.
        /// escalate to an LLM judge (0.60–0.85) vs. ignore (<0.60).
        public var confidenceTier: ConfidenceTier {
            switch confidence {
            case 0.85...: return .high
            case 0.60..<0.85: return .medium
            default: return .low
            }
        }

        public enum ConfidenceTier: Sendable {
            case high, medium, low
        }
    }

    private init() {}

    // MARK: - Model Loading

    /// Loads the compiled `.mlmodelc` from the iClawCore bundle. Safe to call
    /// repeatedly — only loads once. Silent no-op if the bundle resource is
    /// missing (the engine falls back to heuristic cleaning).
    public func loadModel() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let modelURL = Bundle.iClawCore.url(
            forResource: "ResponsePathologyClassifier_MaxEnt",
            withExtension: "mlmodelc"
        ) else {
            Log.engine.debug("ResponsePathology model bundle not found (feature disabled)")
            return
        }

        do {
            let compiledModel = try MLModel(contentsOf: modelURL)
            model = try NLModel(mlModel: compiledModel)
            Log.engine.debug("ResponsePathology model loaded")
        } catch {
            Log.engine.debug("Failed to load ResponsePathology model: \(error)")
        }
    }

    // MARK: - Classification

    /// Classifies an LLM response. Returns `nil` if the model isn't loaded
    /// (caller should fall back to heuristics) or the input is empty/too short
    /// to classify meaningfully (< 2 chars).
    public func classify(_ response: String) -> Result? {
        loadModel()

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        guard let model else { return nil }

        let hypotheses = model.predictedLabelHypotheses(for: trimmed, maximumCount: 6)
        guard !hypotheses.isEmpty else { return nil }

        // Sort by score descending and map to typed labels.
        let sorted = hypotheses.sorted { $0.value > $1.value }
        let typed: [(label: Label, score: Double)] = sorted.compactMap { (raw, score) in
            guard let label = Label(rawValue: raw) else { return nil }
            return (label, score)
        }
        guard let top = typed.first else { return nil }

        return Result(
            label: top.label,
            confidence: top.score,
            hypotheses: Array(typed.prefix(3))
        )
    }

    /// Returns `true` only when the classifier is loaded AND the response is
    /// classified as `refusal` with high confidence. Useful for the narrow
    /// refusal-detection replacement path where false positives are costly.
    public func isHighConfidenceRefusal(_ response: String) -> Bool {
        guard let result = classify(response) else { return false }
        return result.label == .refusal && result.confidenceTier == .high
    }
}
