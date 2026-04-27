import Foundation
import NaturalLanguage

/// Lightweight synchronous preference detector for conversational turns.
///
/// The async `extractKnowledge` path also picks up preferences, but it runs
/// in a detached Task after the turn returns. Turn N+1 often fires before
/// the extraction completes, so tools that read from UserDefaults /
/// ConversationState would still see the old value on the very next turn.
///
/// This detector covers the narrow but valuable case of unit-system
/// preferences expressed with a handful of structural patterns. When a
/// match is found, it writes to both `ConversationState.userPreferences`
/// and the mirrored `UserDefaults` key so downstream tools pick it up on
/// the same turn the preference was stated.
///
/// Language coverage: English-heavy by nature — unit vocabulary is a small
/// universal set (metric, imperial, celsius, fahrenheit, SI) that appears
/// nearly unchanged across languages. When the user's language isn't
/// covered, the async `extractKnowledge` path still catches the preference
/// and surfaces it via the `<ctx>` `Preferences:` line on subsequent turns.
enum PreferenceDetector {

    struct Match: Sendable {
        let key: String
        let value: String
    }

    /// Structural unit-vocabulary — a small set of language-stable tokens
    /// that signal the user's unit-system preference. Checked as substrings
    /// against the lowercased input so inflected forms (métrico, metrisch,
    /// métriques, métrique, metrico) still match.
    private static let metricTokens: [String] = [
        "metric", "metrico", "metrique", "metrico", "metrisch", "metrique",
        "celsius", "celsio", "centigrade",
        " si ", " si.", "sistema internacional",
        "международн",  // Russian "international"
    ]

    private static let imperialTokens: [String] = [
        "imperial", "imperiale",
        "fahrenheit", "farenheit",
        " us ", "us customary", "customary units",
    ]

    /// Structural marker indicating the user is STATING a preference
    /// rather than asking about units. Matches first-person + a
    /// preference-expressing verb OR an imperative ("please use X",
    /// "from now on use X"). Kept multilingual-friendly via a small
    /// curated list that can be expanded per language in a future pass.
    private static let preferenceVerbTokens: [String] = [
        "prefer", "prefiero", "préfère", "bevorzug",  // EN/ES/FR/DE
        "use ", "usa ", "utilise", "nutze",
        "want ", "quiero", "veux", "möchte",
        "remember", "recuerda", "souviens", "merke",
        "please", "por favor", "s'il vous plaît", "bitte",
        "from now on", "a partir de ahora", "à partir de maintenant", "ab jetzt",
    ]

    /// Detect a preference from user input. Returns nil when no strong
    /// structural match. Caller commits the match to state + UserDefaults.
    static func detect(in input: String) -> Match? {
        let lower = " " + input.lowercased() + " "

        // Require a preference-expressing marker — guards against asking
        // "what does celsius mean?" (no marker) from triggering a write.
        let hasPrefMarker = preferenceVerbTokens.contains { lower.contains($0) }
        guard hasPrefMarker else { return nil }

        if metricTokens.contains(where: { lower.contains($0) }) {
            return Match(key: "unit_system", value: "metric")
        }
        if imperialTokens.contains(where: { lower.contains($0) }) {
            return Match(key: "unit_system", value: "imperial")
        }
        return nil
    }
}
