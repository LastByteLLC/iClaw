import Foundation
import FoundationModels
import AppIntents

/// Closure type for injecting a test LLM responder into the TranslateTool.
public typealias TranslateLLMResponder = SimpleLLMResponder

/// Translation tool using on-device Foundation Models for translation.
/// Implements CoreTool protocol and exposes an AppIntent for macOS 25+ integration.
///
/// Parsing strategy (3-stage):
/// 1. **Quote + language extraction** — if the input has quoted text, that's the text to translate.
///    The target language is identified from the rest of the input.
/// 2. **Language pattern matching** — detects `"to <language>"` patterns in the input,
///    splits text and language accordingly.
/// 3. **LLM normalization fallback** — asks the LLM to extract text and target language
///    from arbitrary natural language, then translates. The LLM extracts, not translates.
public struct TranslateTool: CoreTool, Sendable {
    public let name = "Translate"
    public let schema = "Translate text from one language to another."
    public let isInternal = false
    public let category = CategoryEnum.offline

    private static let supportedLanguages: [String] = ConfigLoader.loadStringArray("TranslateLanguages")

    /// Pre-compiled regex for matching quoted text (single, double, or smart quotes).
    private static let quotePattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[""''"'`](.+?)[""''"'`]"#, options: []
    )

    /// Pre-compiled regex for "to/into <language>" with optional "from <language>" prefix.
    private static let langPattern: NSRegularExpression? = {
        let langs = supportedLanguages.joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "(?:from\\s+\\w+\\s+)?(?:to|into)\\s+(\(langs))",
            options: .caseInsensitive
        )
    }()

    private let llmResponder: TranslateLLMResponder?

    public init(llmResponder: TranslateLLMResponder? = nil) {
        self.llmResponder = llmResponder
    }

    // MARK: - Parsing

    struct ParsedRequest: Sendable {
        let text: String
        let targetLanguage: String?
    }

    /// Multi-stage parser. Returns the text to translate and the target language.
    func parseTranslationRequest(_ input: String) async -> ParsedRequest {
        // Stage 1: Try quote extraction + language detection
        if let result = Self.parseViaQuotes(input) {
            return result
        }

        // Stage 2: Try language pattern matching (no quotes)
        if let result = Self.parseViaLanguagePattern(input) {
            return result
        }

        // Stage 3: LLM normalization fallback
        if let result = await llmNormalize(input: input) {
            return result
        }

        // Last resort: treat entire input (minus "translate" prefix) as text, no language
        let stripped = Self.stripTranslatePrefix(input)
        return ParsedRequest(text: stripped.isEmpty ? input : stripped, targetLanguage: nil)
    }

    // MARK: - Stage 1: Quote Extraction

    /// Extracts quoted text as the translation target, and identifies language from the rest.
    /// Handles: "Translate 'hello' into French", "translate "the sky is blue" to Spanish"
    private static func parseViaQuotes(_ input: String) -> ParsedRequest? {
        guard let quotePattern,
              let quoteMatch = quotePattern.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let textRange = Range(quoteMatch.range(at: 1), in: input) else {
            return nil
        }

        let quotedText = String(input[textRange])
        guard !quotedText.isEmpty else { return nil }

        // Find language in the non-quoted portion
        let language = detectLanguage(in: input)

        return ParsedRequest(text: quotedText, targetLanguage: language)
    }

    // MARK: - Stage 2: Language Pattern

    /// Splits on "to <language>" when no quotes are present.
    /// Handles: "translate hello to French", "how do you say goodbye in Spanish"
    private static func parseViaLanguagePattern(_ input: String) -> ParsedRequest? {
        guard let langPattern,
              let match = langPattern.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let langRange = Range(match.range(at: 1), in: input) else {
            return nil
        }

        let language = input[langRange].lowercased()
        let fullMatchRange = Range(match.range, in: input)!

        // Text is everything outside the language pattern, minus "translate" prefix
        var text = input
        text.removeSubrange(fullMatchRange)
        text = stripTranslatePrefix(text)
        text = stripQuotes(text)

        guard !text.isEmpty else { return nil }
        return ParsedRequest(text: text, targetLanguage: language)
    }

    // MARK: - Stage 3: LLM Normalization

    /// Asks the LLM to extract the text and target language from arbitrary input.
    /// The LLM does NOT translate — it only parses.
    private func llmNormalize(input: String) async -> ParsedRequest? {
        let prompt = """
Extract the text to translate and the target language from this request. \
Output ONLY in the format: LANGUAGE|TEXT
If no target language is specified, output: unknown|TEXT
Examples:
- "Translate this sentence: Hello, how are you? into French" → french|Hello, how are you?
- "how do you say thank you in Japanese" → japanese|thank you
- "say good morning in Korean" → korean|good morning
- "translate bonjour" → unknown|bonjour

Input: \(input)
Output:
"""

        do {
            let response: String
            if let responder = llmResponder {
                response = try await responder(prompt)
            } else {
                // Translate request normalization (text|language) — greedy + 50-token cap.
                response = try await LLMAdapter.shared.generateText(prompt, profile: .normalization)
            }

            let line = response.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .first ?? ""
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }

            let lang = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
            let text = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }

            let targetLang = (lang == "unknown" || lang.isEmpty) ? nil : lang
            // Validate the language is in our supported list
            let validatedLang = targetLang.flatMap { l in
                Self.supportedLanguages.first { $0 == l }
            }

            return ParsedRequest(text: text, targetLanguage: validatedLang ?? targetLang)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Detects a supported language name anywhere in the input string.
    private static func detectLanguage(in input: String) -> String? {
        let lowered = input.lowercased()
        // Check longest language names first to avoid partial matches
        for lang in supportedLanguages.sorted(by: { $0.count > $1.count }) {
            if lowered.contains(lang) {
                return lang
            }
        }
        return nil
    }

    /// Strips "translate", "say", "how do you say" etc. from the beginning.
    /// Uses a simple approach: remove the first verb/phrase before the actual content.
    private static func stripTranslatePrefix(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()

        // Remove leading "translate" (anchored)
        if lowered.hasPrefix("translate") {
            text = String(text.dropFirst("translate".count))
        }

        return text
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Strips surrounding quotes (single, double, smart).
    private static func stripQuotes(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespaces)
        let quoteChars: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"),
            ("\u{2018}", "\u{2019}"), ("`", "`")
        ]
        for (open, close) in quoteChars {
            if text.first == open && text.last == close && text.count > 2 {
                text = String(text.dropFirst().dropLast())
                break
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Execution

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let parsed = await parseTranslationRequest(input)

            guard !parsed.text.isEmpty else {
                return ToolIO(
                    text: "Please provide text to translate.",
                    status: .error
                )
            }

            let target = parsed.targetLanguage ?? "English"

            // Detect multi-target: "Spanish, French, and German" or "Spanish and French"
            let targets = Self.splitLanguageList(target)

            if targets.count > 1 {
                return await translateMultiTarget(text: parsed.text, targets: targets)
            }

            let instruction = "You are a translator. Translate the following text to \(target). Output ONLY the translated text, nothing else."
            do {
                let translated: String
                if let responder = llmResponder {
                    translated = try await responder("TRANSLATE:\(parsed.text)|\(target)")
                } else {
                    translated = try await LLMAdapter.shared.generateWithInstructions(
                        prompt: parsed.text, instructions: instruction
                    )
                }
                return ToolIO(
                    text: translated,
                    status: .ok
                )
            } catch {
                return ToolIO(
                    text: "Translation failed: \(error.localizedDescription)",
                    status: .error
                )
            }
        }
    }

    /// Splits "Spanish, French, and German" into ["Spanish", "French", "German"]
    private static func splitLanguageList(_ input: String) -> [String] {
        let cleaned = input
            .replacingOccurrences(of: ", and ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
        let parts = cleaned.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Only treat as multi-target if we found valid languages
        guard parts.count > 1 else { return [input] }
        let valid = parts.filter { lang in
            supportedLanguages.contains(lang.lowercased())
        }
        return valid.count > 1 ? valid : [input]
    }

    private func translateMultiTarget(text: String, targets: [String]) async -> ToolIO {
        var translations: [String] = []
        for target in targets {
            let instruction = "You are a translator. Translate the following text to \(target). Output ONLY the translated text, nothing else."
            do {
                let translated: String
                if let responder = llmResponder {
                    translated = try await responder("TRANSLATE:\(text)|\(target)")
                } else {
                    translated = try await LLMAdapter.shared.generateWithInstructions(
                        prompt: text, instructions: instruction
                    )
                }
                translations.append("\(target): \(translated)")
            } catch {
                translations.append("\(target): (translation failed)")
            }
        }
        return ToolIO(
            text: translations.joined(separator: "\n"),
            status: .ok
        )
    }
}

/// AppIntent wrapping TranslateTool.
public struct TranslateIntent: AppIntent {
    public static var title: LocalizedStringResource { "Translate Text" }
    public static var description: IntentDescription? { IntentDescription("Translates text using the iClaw TranslateTool.") }

    @Parameter(title: "Text to Translate")
    public var text: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = TranslateTool()
        let result = try await tool.execute(input: text, entities: nil)
        return .result(value: result.text)
    }
}
