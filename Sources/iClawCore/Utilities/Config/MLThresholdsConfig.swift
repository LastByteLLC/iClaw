import Foundation

/// ML confidence thresholds loaded from MLThresholds.json.
/// Centralizes all magic numbers used in follow-up detection, routing, and retrieval.
struct MLThresholdsConfig: Decodable {
    let followUp: FollowUpThresholds
    let routing: RoutingThresholds
    let autoRecall: AutoRecallThresholds
    let knowledgeRetrieval: KnowledgeRetrievalThresholds

    struct FollowUpThresholds: Decodable {
        let pivotThreshold: Double
        let retryThreshold: Double
        let nonPivotThreshold: Double
        let boostedNonPivotThreshold: Double
        let metaThreshold: Double
        let crossValidationThreshold: Double
        let confidenceMarginWithCoherence: Double
        let confidenceMarginWithout: Double
    }

    struct RoutingThresholds: Decodable {
        let highConfidence: Double
        let mediumConfidence: Double
        let shortInputThreshold: Double
        let disambiguationGap: Double
    }

    struct AutoRecallThresholds: Decodable {
        let similarityThreshold: Double
        let maxResults: Int
    }

    struct KnowledgeRetrievalThresholds: Decodable {
        let cosineSimilarityFloor: Double
        let relevanceThreshold: Double
    }

    static let shared: MLThresholdsConfig = ConfigLoader.load("MLThresholds", as: MLThresholdsConfig.self) ?? .defaults

    static let defaults = MLThresholdsConfig(
        followUp: FollowUpThresholds(
            pivotThreshold: 0.5, retryThreshold: 0.3, nonPivotThreshold: 0.85,
            boostedNonPivotThreshold: 0.3, metaThreshold: 0.7, crossValidationThreshold: 0.3,
            confidenceMarginWithCoherence: 0.3, confidenceMarginWithout: 0.1
        ),
        routing: RoutingThresholds(
            highConfidence: 0.75, mediumConfidence: 0.35,
            shortInputThreshold: 0.7, disambiguationGap: 0.1
        ),
        autoRecall: AutoRecallThresholds(similarityThreshold: 0.70, maxResults: 2),
        knowledgeRetrieval: KnowledgeRetrievalThresholds(cosineSimilarityFloor: 0.4, relevanceThreshold: 0.45)
    )
}
