import CoreML
import Foundation
import NaturalLanguage

/// Classifies the relationship between consecutive user turns.
///
/// Uses a MaxEnt CoreML model trained on turn pairs formatted as:
/// `[PRIOR_TOOL:X] [PRIOR] prior_input [CURRENT] current_input`
///
/// Predicts one of six turn relations:
/// - `continuation` — same topic, new/additional parameter
/// - `refinement` — same tool, correcting/adjusting parameters
/// - `drill_down` — wants detail on a specific result
/// - `retry` — re-execute the prior tool with the same/similar input
/// - `pivot` — entirely new topic
/// - `meta` — about the system itself
public actor FollowUpClassifier {
    public static let shared = FollowUpClassifier()

    private var model: NLModel?
    private var isLoaded = false

    /// The relationship between two consecutive turns.
    public enum TurnRelation: String, CaseIterable, Sendable {
        case continuation
        case refinement
        case drillDown = "drill_down"
        case retry
        case pivot
        case meta
    }

    /// Prediction result with the classified relation and confidence scores.
    public struct Prediction: Sendable {
        public let relation: TurnRelation
        public let confidence: Double
        public let allScores: [String: Double]
    }

    private init() {}

    /// Loads the compiled .mlmodelc from the app bundle.
    /// Safe to call multiple times — only loads once.
    public func loadModel() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let modelURL = Bundle.iClawCore.url(
            forResource: "FollowUpClassifier_MaxEnt",
            withExtension: "mlmodelc"
        ) else {
            Log.router.debug("FollowUpClassifier model bundle not found")
            return
        }

        do {
            let compiledModel = try MLModel(contentsOf: modelURL)
            model = try NLModel(mlModel: compiledModel)
            Log.router.debug("FollowUpClassifier loaded successfully")
        } catch {
            Log.router.debug("Failed to load FollowUpClassifier: \(error)")
        }
    }

    /// Classifies the relationship between a prior turn and the current input.
    ///
    /// - Parameters:
    ///   - priorTool: The compound label of the tool that ran in the prior turn (e.g., "weather", "email.read")
    ///   - priorInput: The user's input from the prior turn
    ///   - currentInput: The current user input
    /// - Returns: A `Prediction` with the classified relation, or nil if the model isn't loaded.
    public func classify(
        priorTool: String,
        priorInput: String,
        currentInput: String
    ) -> Prediction? {
        guard let model else { return nil }

        let formatted = "[PRIOR_TOOL:\(priorTool)] [PRIOR] \(priorInput) [CURRENT] \(currentInput)"
        let label = model.predictedLabel(for: formatted) ?? "pivot"
        let hypotheses = model.predictedLabelHypotheses(for: formatted, maximumCount: 5)
        let topConfidence = hypotheses[label] ?? 0

        guard let relation = TurnRelation(rawValue: label) else {
            return Prediction(relation: .pivot, confidence: topConfidence, allScores: hypotheses)
        }

        return Prediction(relation: relation, confidence: topConfidence, allScores: hypotheses)
    }

    /// Whether the model is loaded and ready to classify.
    public var isReady: Bool {
        model != nil
    }
}
