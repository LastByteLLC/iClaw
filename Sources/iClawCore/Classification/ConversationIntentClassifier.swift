import CoreML
import Foundation
import NaturalLanguage

/// Top-level multilingual intent classifier for user input. Runs BEFORE the
/// tool router, follow-up classifier, and conversational gate. Its job is to
/// answer: "What kind of turn is this?"
///
/// Five labels:
///   • `toolAction` — user wants a tool to run (weather, calc, stocks, …).
///   • `knowledge` — factual / explanatory question the LLM can answer from
///     priors without a live tool call.
///   • `conversation` — chat, opinion, creative writing, empathy, advice.
///   • `refinement` — user is transforming the assistant's prior reply
///     ("shorter", "in Spanish", "swap X for Y").
///   • `meta` — user is asking about the iClaw assistant itself.
///
/// Replaces the English-only heuristics audited in Phase 0:
///   - `isMetaQuery` English seeds + English `NLEmbedding` → `.meta` class
///   - `RouterKeywordsConfig.conversationalKeywords` → `.conversation` class
///   - Bits of the conversational-gate token-count heuristic → `.knowledge`
///     vs `.conversation` split
///   - Hardcoded refinement-directive prompt-engineering → `.refinement`
///     class drives structured handling
///
/// Feature-flag gated via `AppConfig.useClassifierIntentRoutingKey`. When the
/// flag is off (default), the legacy path is unchanged.
///
/// Thread-safe actor. Model loads lazily.
public actor ConversationIntentClassifier {
    public static let shared = ConversationIntentClassifier()

    private var model: NLModel?
    private var isLoaded = false

    public enum Label: String, Sendable, CaseIterable {
        case toolAction = "tool_action"
        case knowledge
        case conversation
        case refinement
        case meta
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
            forResource: "ConversationIntentClassifier_MaxEnt",
            withExtension: "mlmodelc"
        ) else {
            Log.engine.debug("ConversationIntent model bundle not found (feature disabled)")
            return
        }

        do {
            let compiledModel = try MLModel(contentsOf: modelURL)
            model = try NLModel(mlModel: compiledModel)
            Log.engine.debug("ConversationIntent model loaded")
        } catch {
            Log.engine.debug("Failed to load ConversationIntent model: \(error)")
        }
    }

    /// Returns a Result or `nil` when the model isn't loaded / the input is
    /// too short to classify. Callers should fall back to legacy heuristics
    /// when the return is `nil`.
    ///
    /// Input preprocessing: the trained model expects a `[lang]` prefix
    /// (e.g. `[en] weather in tokyo`) so MaxEnt can learn per-language
    /// features separately — this is the technique that lifted multilingual
    /// val-acc meaningfully during Phase 2.5. We detect the language via
    /// `NLLanguageRecognizer` and prepend before inference.
    public func classify(_ input: String) -> Result? {
        loadModel()

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        guard let model else { return nil }

        let prefixed = Self.prefixForInference(trimmed)
        let hypotheses = model.predictedLabelHypotheses(for: prefixed, maximumCount: 5)
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

    /// Prepends `[lang]` to the input to match the training-time
    /// preprocessing. Mirrors `MLTraining/add_language_prefix.swift`: uses
    /// `NLLanguageRecognizer.dominantLanguage` when available, falling back
    /// to `un` (unknown) for inputs the recognizer can't classify.
    private static func prefixForInference(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let lang = recognizer.dominantLanguage?.rawValue ?? "un"
        return "[\(lang)] \(text)"
    }
}
