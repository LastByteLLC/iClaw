#if os(iOS)
import Foundation
import UIKit

public struct DictionaryToolIOS: CoreTool, Sendable {
    public let name = "Dictionary"
    public let schema = "dictionary definition lookup meaning word define"
    public let isInternal = false
    public let category = CategoryEnum.offline

    private let wordExtractor: WordExtractor?

    public init(wordExtractor: WordExtractor? = nil) {
        self.wordExtractor = wordExtractor
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await timed {
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

            // Check if the word has a definition available
            var correctedFrom: String? = nil
            if await hasDefinition(for: word) {
                // Use LLM to provide the definition since UIReferenceLibraryViewController
                // can't return text programmatically
                let definition = try await definitionViaLLM(word)
                return buildResult(word: word, definition: definition, correctedFrom: nil)
            }

            // Try spellcheck correction
            if let suggestion = spellCheck(word), suggestion.lowercased() != word.lowercased() {
                if await hasDefinition(for: suggestion) {
                    correctedFrom = word
                    let definition = try await definitionViaLLM(suggestion)
                    return buildResult(word: suggestion, definition: definition, correctedFrom: correctedFrom)
                }
            }

            return ToolIO(
                text: "No definition found for '\(word)'.",
                status: .error
            )
        }
    }

    @MainActor
    private func hasDefinition(for word: String) -> Bool {
        UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: word)
    }

    private func spellCheck(_ word: String) -> String? {
        let checker = UITextChecker()
        let range = NSRange(location: 0, length: (word as NSString).length)
        let misspelledRange = checker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: "en"
        )
        if misspelledRange.location != NSNotFound {
            let guesses = checker.guesses(forWordRange: misspelledRange, in: word, language: "en")
            return guesses?.first
        }
        return nil
    }

    private func definitionViaLLM(_ word: String) async throws -> String {
        try await LLMAdapter.shared.generateWithInstructions(
            prompt: "Define: \(word)",
            instructions: makeInstructions {
                Directive("You are a dictionary. Provide a concise definition (2-3 sentences max) for the given word. Include the part of speech.")
            }
        )
    }

    private func buildResult(word: String, definition: String, correctedFrom: String?) -> ToolIO {
        var text: String
        if let original = correctedFrom {
            text = "(Did you mean '\(word)'? Showing definition for '\(word)' instead of '\(original)'.)\n\(word): \(definition)"
        } else {
            text = "\(word): \(definition)"
        }

        let widgetData = DictionaryWidgetData(
            word: word,
            phonetic: "",
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
