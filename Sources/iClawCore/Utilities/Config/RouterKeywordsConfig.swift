import Foundation

/// Routing thresholds (loaded from RouterKeywords.json). The English
/// `conversationalKeywords` field was retired in favor of the multilingual
/// `ConversationIntentClassifier.conversation` class — see ToolRouter
/// stage 2d. Decoding tolerates the legacy field's presence in the JSON
/// for back-compat; only the thresholds are exposed to callers.
struct RouterKeywordsConfig: Decodable {
    let shortQueryWordLimit: Int
    let emojiThreshold: Double

    private enum CodingKeys: String, CodingKey {
        case shortQueryWordLimit, emojiThreshold
    }

    static let shared: RouterKeywordsConfig = ConfigLoader.load("RouterKeywords", as: RouterKeywordsConfig.self) ?? .defaults

    static let defaults = RouterKeywordsConfig(
        shortQueryWordLimit: 2,
        emojiThreshold: 0.4
    )
}
