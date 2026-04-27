import CoreML
import Foundation
import NaturalLanguage

/// Binary toxicity/profanity classifier using a trained MaxEnt CoreML model.
/// Detects profane or toxic language and provides cleaned text with profanity removed.
/// Thread-safe: all access goes through actor isolation.
public actor ToxicityClassifier {
    public static let shared = ToxicityClassifier()

    private var model: NLModel?
    private var isLoaded = false

    /// Result of a toxicity check.
    public struct Result: Sendable {
        /// Whether the input was classified as toxic.
        public let isToxic: Bool
        /// Confidence score for the toxic label (0.0–1.0).
        public let confidence: Double
        /// The input with profanity words removed/replaced.
        public let cleanedText: String
    }

    private init() {}

    // MARK: - Model Loading

    /// Loads the compiled .mlmodelc from the app bundle.
    public func loadModel() {
        guard !isLoaded else { return }
        isLoaded = true

        guard let modelURL = Bundle.iClawCore.url(
            forResource: "ToxicityClassifier_MaxEnt",
            withExtension: "mlmodelc"
        ) else {
            Log.engine.debug("Toxicity model bundle not found")
            return
        }

        do {
            let compiledModel = try MLModel(contentsOf: modelURL)
            model = try NLModel(mlModel: compiledModel)
            Log.engine.debug("Toxicity model loaded")
        } catch {
            Log.engine.debug("Failed to load toxicity model: \(error)")
        }
    }

    // MARK: - Classification

    /// Checks input for toxicity and returns a cleaned version.
    /// If the model isn't loaded, falls back to word-list detection only.
    public func check(_ input: String) -> Result {
        // Lazy model load on first use
        loadModel()

        let cleaned = Self.removeProfanity(from: input)
        let wordsRemoved = cleaned != input

        // ML classification — supplementary signal to word-level removal.
        // Word removal is the primary detection method (high precision).
        // ML adds coverage for novel profanity the word list doesn't catch.
        if let model {
            let hypotheses = model.predictedLabelHypotheses(for: input, maximumCount: 2)
            let toxicConf = hypotheses["toxic"] ?? 0.0
            // Require high ML confidence (>0.85) to flag without word removal,
            // to minimize false positives on normal queries.
            let isToxic = wordsRemoved || toxicConf > 0.85
            return Result(isToxic: isToxic, confidence: toxicConf, cleanedText: cleaned)
        }

        // Fallback: word-list only
        return Result(isToxic: wordsRemoved, confidence: wordsRemoved ? 1.0 : 0.0, cleanedText: cleaned)
    }

    // MARK: - Word-Level Profanity Removal

    /// Profanity word set — loaded once, used for word-level removal.
    /// Covers common profanity, mild expletives, and character-substitution evasions.
    private static let profanityWords: Set<String> = {
        var words: Set<String> = [
            // Strong
            "fuck", "fucking", "fuckin", "fck", "fuk", "fuq", "fvck", "phuck", "fcuk",
            "shit", "shitty", "sht", "shiit", "shyt",
            "bitch", "bich", "bytch",
            "asshole", "arsehole",
            "bullshit",
            "dickhead", "dumbass",
            "wtf", "stfu", "lmfao",
            // Mild (still cause Apple FM refusal)
            "damn", "dammit", "goddamn", "goddammit", "goddam", "damm",
            "hell",
            "crap", "krap",
            "ass", "azz",
            "piss", "pissed",
            "bastard",
            "bollocks", "bugger",
        ]
        // Don't include words that are commonly part of normal text:
        // "suck", "sucks" — too many false positives ("vacuum sucks")
        // "bloody" — common in British English ("bloody brilliant")
        // "screw" — common in normal usage ("screw in the bolt")
        return words
    }()

    /// Words that look like they contain profanity but are safe.
    /// Used to prevent false positives in substring matching.
    private static let safeWords: Set<String> = [
        "hello", "shell", "shelling", "shelter",
        "class", "classic", "classified", "classify",
        "assess", "assessment", "assistant", "assemble", "assembly", "assert", "assertion", "asset",
        "assume", "assumption", "assign", "assignment", "associate", "association",
        "compass", "bypass", "surpass", "trespass",
        "mass", "massage", "massive", "bass", "bassist", "embassy",
        "therapist", "cockpit", "cocktail", "cockatoo",
        "arsenal", "buttress", "butterfly", "button",
        "scunthorpe", "pussycat", "shitake",
        "damnation", "hellebore", "hellenic",
        "passover", "passage", "passenger", "passing", "passion", "passive",
        "grasshopper", "harassment",
    ]

    /// Character substitution map for normalizing evasion patterns.
    private static let charSubstitutions: [Character: Character] = [
        "@": "a", "$": "s", "0": "o", "1": "i", "3": "e",
        "!": "i", "*": "u",
    ]

    /// Removes profanity words from the input, preserving sentence structure.
    /// Handles ALL CAPS, character substitutions, and spaced-out letters.
    static func removeProfanity(from input: String) -> String {
        var result = input

        // Phase 1: Handle spaced-out profanity ("f u c k", "s h i t")
        result = collapseAndRemoveSpacedProfanity(result)

        // Phase 2: Word-by-word removal
        let words = result.components(separatedBy: .whitespacesAndNewlines)
        var cleanedWords: [String] = []

        for word in words {
            let stripped = word.trimmingCharacters(in: .punctuationCharacters)
            let lower = stripped.lowercased()

            // Skip safe words (avoid false positives)
            if safeWords.contains(lower) {
                cleanedWords.append(word)
                continue
            }

            // Check direct match
            if profanityWords.contains(lower) {
                continue // Remove the word
            }

            // Check with character substitutions normalized
            let normalized = String(lower.map { charSubstitutions[$0] ?? $0 })
            if normalized != lower && profanityWords.contains(normalized) {
                continue // Remove the word
            }

            cleanedWords.append(word)
        }

        result = cleanedWords.joined(separator: " ")

        // Clean up artifacts: multiple spaces, leading/trailing spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        result = result.trimmingCharacters(in: .whitespaces)

        return result
    }

    /// Detects and removes spaced-out profanity patterns like "f u c k" or "s h i t".
    private static func collapseAndRemoveSpacedProfanity(_ input: String) -> String {
        // Pattern: 3+ single letters separated by single spaces
        let pattern = "(?<=^|\\s)([a-zA-Z] ){2,}[a-zA-Z](?=\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var result = input

        let matches = regex.matches(in: input, range: range)
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let fragment = result[swiftRange]
            let collapsed = fragment.replacingOccurrences(of: " ", with: "").lowercased()
            if profanityWords.contains(collapsed) {
                result.replaceSubrange(swiftRange, with: "")
            }
        }

        return result
    }
}
