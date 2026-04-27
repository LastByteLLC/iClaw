#if os(macOS)
import Foundation
import CoreServices
import AppKit

/// Closure type for extracting a word from natural language input via LLM.
/// When `nil`, the real `LanguageModelSession` is used.
public typealias WordExtractor = @Sendable (String) async throws -> String

/// Data for DictionaryWidgetView.
public struct DictionaryWidgetData: Sendable {
    public let word: String
    public let phonetic: String
    public let definition: String
    public let correctedFrom: String?

    public init(word: String, phonetic: String, definition: String, correctedFrom: String? = nil) {
        self.word = word
        self.phonetic = phonetic
        self.definition = definition
        self.correctedFrom = correctedFrom
    }
}

public struct DictionaryTool: CoreTool, Sendable {
    public let name = "Dictionary"
    public let schema = "dictionary definition lookup meaning word define synonyms antonyms etymology pronunciation thesaurus slang vocabulary lexicon"
    public let isInternal = false
    public let category = CategoryEnum.offline

    private let wordExtractor: WordExtractor?

    public init(wordExtractor: WordExtractor? = nil) {
        self.wordExtractor = wordExtractor
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ToolIO(
                    text: "No word provided. Try: define <word>",
                    status: .error
                )
            }

            // Use LLM to extract the word to look up
            var word: String
            do {
                word = try await extractWordViaLLM(from: trimmed)
            } catch {
                word = trimmed
                    .replacingOccurrences(of: "?", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard !word.isEmpty else {
                return ToolIO(
                    text: "Could not determine which word to look up from: '\(trimmed)'",
                    status: .error
                )
            }

            // Attempt lookup
            var correctedFrom: String? = nil
            if let result = lookupDefinition(word) {
                return buildResult(word: word, raw: result, correctedFrom: nil)
            }

            // Word not found — try spellcheck correction
            if let suggestion = spellCheck(word), suggestion.lowercased() != word.lowercased() {
                if let result = lookupDefinition(suggestion) {
                    correctedFrom = word
                    return buildResult(word: suggestion, raw: result, correctedFrom: correctedFrom)
                }
            }

            return ToolIO(
                text: "No definition found for '\(word)'.",
                status: .error
            )
        }
    }

    // MARK: - Dictionary Lookup

    private func lookupDefinition(_ word: String) -> String? {
        let cfWord = word as CFString
        let range = CFRangeMake(0, CFStringGetLength(cfWord))
        guard let ref = DCSCopyTextDefinition(nil, cfWord, range)?.takeRetainedValue() else {
            return nil
        }
        return ref as String
    }

    // MARK: - Spellcheck

    private func spellCheck(_ word: String) -> String? {
        let checker = NSSpellChecker.shared
        let misspelledRange = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )

        // If the whole word is misspelled, get suggestions
        if misspelledRange.location != NSNotFound {
            let guesses = checker.guesses(
                forWordRange: misspelledRange,
                in: word,
                language: "en",
                inSpellDocumentWithTag: 0
            )
            return guesses?.first
        }

        return nil
    }

    // MARK: - Result Builder

    private func buildResult(word: String, raw: String, correctedFrom: String?) -> ToolIO {
        // Parse phonetic from raw definition (format: "word pho·net·ic | foʊˈnɛtɪk | ...")
        let phonetic = extractPhonetic(from: raw)

        var definition = raw
        if definition.count > 500 {
            definition = String(definition.prefix(497)) + "..."
        }

        var text: String
        if let original = correctedFrom {
            text = "(Did you mean '\(word)'? Showing definition for '\(word)' instead of '\(original)'.)\n\(word): \(definition)"
        } else {
            text = "\(word): \(definition)"
        }

        let widgetData = DictionaryWidgetData(
            word: word,
            phonetic: phonetic,
            definition: definition,
            correctedFrom: correctedFrom
        )

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "DictionaryWidget",
            widgetData: widgetData
        )
    }

    private func extractPhonetic(from raw: String) -> String {
        // DCS format often has: "word | fəˈnɛtɪk |" — extract between pipes
        let parts = raw.components(separatedBy: "|")
        if parts.count >= 2 {
            let phonetic = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !phonetic.isEmpty {
                return phonetic
            }
        }
        return ""
    }

    // MARK: - LLM Word Extraction

    private func extractWordViaLLM(from input: String) async throws -> String {
        let prompt = "Extract the single word the user wants defined from this input. Output ONLY the word, nothing else. If the input is already a single word, output that word.\n\nInput: \(input)"

        let rawResponse: String
        if let extractor = wordExtractor {
            rawResponse = try await extractor(input)
        } else {
            rawResponse = try await LLMAdapter.shared.generateWithInstructions(
                prompt: prompt,
                instructions: makeInstructions {
                    Directive("You extract dictionary lookup words. Output ONLY a single word, no punctuation, no explanation.")
                }
            )
        }

        return rawResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }
}
#endif
