import CoreML
import Foundation
import NaturalLanguage

/// Wraps the compiled CoreML MaxEnt text classifier for tool routing.
/// Thread-safe: all access goes through an actor-isolated lazy init.
public actor MLToolClassifier {
    public static let shared = MLToolClassifier()

    private var model: NLModel?
    private var isLoaded = false

    /// Prediction result with label and per-label confidence scores.
    public struct Prediction: Sendable {
        public let label: String
        public let confidence: [String: Double]
    }

    private init() {}

    /// Loads the compiled .mlmodelc from the app bundle.
    /// Safe to call multiple times — only loads once.
    public func loadModel() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let modelURL = Bundle.iClawCore.url(
            forResource: "ToolClassifier_MaxEnt_Merged",
            withExtension: "mlmodelc"
        ) else {
            Log.router.debug("Model bundle not found")
            return
        }

        do {
            let compiledModel = try MLModel(contentsOf: modelURL)
            model = try NLModel(mlModel: compiledModel)
            Log.router.debug("Model loaded successfully")
        } catch {
            Log.router.debug("Failed to load model: \(error)")
        }
    }

    /// Predicts the most likely tool label for the given text.
    /// Returns nil if the model isn't loaded.
    public func predict(text: String) -> Prediction? {
        guard let model else { return nil }

        let label = model.predictedLabel(for: text) ?? "none"
        let hypotheses = model.predictedLabelHypotheses(for: text, maximumCount: 5)
        return Prediction(label: label, confidence: hypotheses)
    }
}
