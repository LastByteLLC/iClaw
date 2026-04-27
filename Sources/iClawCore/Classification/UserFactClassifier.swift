import CoreML
import Foundation
import NaturalLanguage

/// Multilingual MaxEnt classifier that detects whether a user message
/// declares a durable LIFE FACT about themselves — and if so, which kind.
///
/// Replaces the English-only `PreferenceDetector.swift` vocabulary lists
/// (`metricTokens`, `imperialTokens`, `preferenceVerbTokens`) and the
/// scattered inline English checks in `mirrorPreferenceToUserDefaults` /
/// `ExecutionEngine`. Covers six fact families plus the `none` default.
///
/// Labels:
///   • `none` — no life fact declared (default for ~70% of turns).
///   • `selfIdentity` — name, age, pronouns, birthday.
///   • `dietary` — vegetarian, vegan, allergies, dietary restrictions.
///   • `family` — kids, partner, pets, household.
///   • `locationFact` — "I live in X", "based in Y", "moved to Z".
///   • `workFact` — job title, employer, role, profession.
///   • `preference` — persistent interaction preferences (units, language,
///     style, format, tone).
///
/// Downstream: when a fact is detected with high confidence, the engine
/// stores it in `ConversationState.userFacts` / profile so it persists
/// across turns and feeds the `<ctx>` block. Value-extraction (the
/// specific name, age, city, etc.) is deferred to a span-tagger in a
/// later phase OR an LLM extraction call when confidence is high.
///
/// Feature-flag gated via `AppConfig.useClassifierUserFactsKey`. When OFF
/// (default), the legacy `PreferenceDetector` + regex path is active.
///
/// Uses the same `[lang]` prefix technique as `ConversationIntentClassifier`
/// to lift multilingual accuracy.
///
/// Thread-safe actor. Model loads lazily.
public actor UserFactClassifier {
    public static let shared = UserFactClassifier()

    private var model: NLModel?
    private var isLoaded = false

    public enum Label: String, Sendable, CaseIterable {
        case none
        case selfIdentity = "self_identity"
        case dietary
        case family
        case locationFact = "location_fact"
        case workFact = "work_fact"
        case preference
    }

    public struct Result: Sendable {
        public let label: Label
        public let confidence: Double
        public let hypotheses: [(label: Label, score: Double)]

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

    public func loadModel() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let modelURL = Bundle.iClawCore.url(
            forResource: "UserFactClassifier_MaxEnt",
            withExtension: "mlmodelc"
        ) else {
            Log.engine.debug("UserFact model bundle not found (feature disabled)")
            return
        }

        do {
            let compiledModel = try MLModel(contentsOf: modelURL)
            model = try NLModel(mlModel: compiledModel)
            Log.engine.debug("UserFact model loaded")
        } catch {
            Log.engine.debug("Failed to load UserFact model: \(error)")
        }
    }

    /// Classify a user message. Returns `nil` if the model isn't loaded or
    /// the input is too short. Same `[lang]` prefix is applied as at
    /// training time via `NLLanguageRecognizer`.
    public func classify(_ input: String) -> Result? {
        loadModel()

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        guard let model else { return nil }

        let prefixed = Self.prefixForInference(trimmed)
        let hypotheses = model.predictedLabelHypotheses(for: prefixed, maximumCount: 7)
        guard !hypotheses.isEmpty else { return nil }

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

    /// True when the classifier decides this turn asserts a fact (any label
    /// other than `none`) with high confidence (≥0.85). The intended gate
    /// for the fact-persistence pipeline so ambiguous turns don't leak into
    /// user state.
    public func isHighConfidenceFact(_ input: String) -> (Label, Double)? {
        guard let result = classify(input),
              result.label != .none,
              result.confidenceTier == .high else {
            return nil
        }
        return (result.label, result.confidence)
    }

    /// Mirror of the training-time preprocessing.
    private static func prefixForInference(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let lang = recognizer.dominantLanguage?.rawValue ?? "un"
        return "[\(lang)] \(text)"
    }
}
