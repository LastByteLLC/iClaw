import Foundation
import NaturalLanguage

/// Loaded once from InputParsingLists.json.
private let inputParsingConfig: InputParsingConfig = {
    if let config = ConfigLoader.load("InputParsingLists", as: InputParsingConfig.self) {
        return config
    }
    return InputParsingConfig(fillerWords: ["what's", "the", "for", "in", "is", "what", "how's", "how", "get", "show", "me"],
                              strippableKeywords: ["weather", "forecast", "temperature", "time"])
}()

private struct InputParsingConfig: Decodable {
    let fillerWords: [String]
    let strippableKeywords: [String]

    var fillerWordSet: Set<String> { Set(fillerWords) }
}

enum InputParsingUtilities {
    // MARK: - Pre-compiled Regexes

    private static let chipRegex = try! NSRegularExpression(pattern: "#\\w+")
    private static let chipNameRegex = try! NSRegularExpression(pattern: "#(\\w+)")
    private static let spaceRegex = try! NSRegularExpression(pattern: "\\s{2,}")
    private static let tickerRegex = try! NSRegularExpression(pattern: "\\$([A-Za-z]{1,5})\\b")

    /// Extract city/location from input + NER entities.
    /// Shared by WeatherTool, TimeTool, and any location-aware tool.
    static func extractLocation(from input: String, entities: ExtractedEntities?, strippingPrefixes prefixes: [String]) -> String? {
        // First try NER entities
        if let place = entities?.places.first, !place.isEmpty {
            return place
        }

        // Fallback: strip known prefixes from input
        let lowerInput = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in prefixes {
            if lowerInput.hasPrefix(prefix) {
                let remainder = String(input.dropFirst(prefix.count))
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }

        // Try removing common keywords
        let keywords = inputParsingConfig.strippableKeywords
        var city = input
        for keyword in keywords {
            city = city.replacingOccurrences(of: keyword, with: "", options: .caseInsensitive)
        }
        city = city.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate: not just filler words
        let fillerWords = inputParsingConfig.fillerWordSet
        let components = city.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let isFiller = components.allSatisfy { fillerWords.contains($0) }

        if city.isEmpty || city.count < 2 || city.contains("?") || isFiller {
            return nil
        }

        // Clean punctuation
        let cleaned = city.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// NER extraction shared between InputPreprocessor and ModelManager.
    ///
    /// Apple's `NLTagger` name-type scheme is capitalization-sensitive: inputs like
    /// `"what time is it in london?"` yield no place entities because `london` is
    /// lowercase. We run a second pass on a title-cased copy when the first pass
    /// produced no entities and the input is all-lowercase — a common chat shape.
    /// Entities are merged uniquely so a user who capitalizes correctly in one
    /// phrase but not another still gets all of them.
    static func extractNamedEntities(from text: String) -> (places: [String], people: [String], orgs: [String]) {
        let first = tagNames(in: text)
        let allEmpty = first.places.isEmpty && first.people.isEmpty && first.orgs.isEmpty
        let isAllLowercase = text.rangeOfCharacter(from: .uppercaseLetters) == nil
        guard allEmpty && isAllLowercase && !text.isEmpty else { return first }

        let retagged = tagNames(in: titleCased(text))
        return (
            places: mergeUnique(first.places, retagged.places),
            people: mergeUnique(first.people, retagged.people),
            orgs: mergeUnique(first.orgs, retagged.orgs)
        )
    }

    /// Single-pass NLTagger name extraction. Used by `extractNamedEntities`.
    private static func tagNames(in text: String) -> (places: [String], people: [String], orgs: [String]) {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        var places: [String] = []
        var people: [String] = []
        var orgs: [String] = []

        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            let entity = String(text[range])
            switch tag {
            case .placeName:
                places.append(entity)
            case .personalName:
                people.append(entity)
            case .organizationName:
                orgs.append(entity)
            default:
                break
            }
            return true
        }
        return (places, people, orgs)
    }

    /// Capitalizes the first letter of each whitespace-separated token. Cheaper
    /// and locale-agnostic compared to `String.capitalized`, which downcases
    /// already-uppercase letters inside tokens (e.g. "USA" → "Usa").
    private static func titleCased(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false)
            .map { token -> String in
                guard let first = token.first else { return String(token) }
                return first.uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func mergeUnique(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in a + b where seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }

    /// Strip tool chips (#weather, #calculator) from input.
    static func stripToolChips(from input: String) -> String {
        let range = NSRange(location: 0, length: input.utf16.count)
        let cleaned = chipRegex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
        let collapsed = spaceRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.utf16.count), withTemplate: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract tool chip names from input.
    static func extractToolChipNames(from input: String) -> [String] {
        let nsString = input as NSString
        let matches = chipNameRegex.matches(in: input, options: [], range: NSRange(location: 0, length: nsString.length))
        return matches.map { nsString.substring(with: $0.range(at: 1)).lowercased() }
    }

    /// Extract ticker symbols prefixed with `$` (e.g. "$META", "$AAPL").
    /// Returns uppercase symbol strings without the `$`.
    static func extractTickerSymbols(from input: String) -> [String] {
        let nsString = input as NSString
        let matches = tickerRegex.matches(in: input, options: [], range: NSRange(location: 0, length: nsString.length))
        return matches.map { nsString.substring(with: $0.range(at: 1)).uppercased() }
    }

    /// Strip ticker symbols ($AAPL, $META) from input, leaving just the symbol for the tool.
    static func stripTickerSymbols(from input: String) -> String {
        let range = NSRange(location: 0, length: input.utf16.count)
        let cleaned = tickerRegex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "$1")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Common question prefixes stripped from lookup-style queries (Wikipedia, Dictionary, etc.).
    private static let questionPrefixes = [
        "what is ", "what are ", "what was ", "what were ",
        "what does ", "what do ",
        "who is ", "who was ", "who are ", "who were ",
        "who invented ", "who created ", "who discovered ",
        "who founded ", "who built ", "who designed ",
        "tell me about ", "look up ", "search for ",
        "wikipedia ", "wiki ", "info on ", "info about ",
        "explain ", "describe ", "define ",
        "where is ", "where are ", "when was ", "when did ",
        "how does ", "how did ", "how do ", "how was ", "how is ",
        "why is ", "why was ", "why did ", "why are ", "why were ",
        "the history of ", "history of ",
    ]

    /// Strips a leading question prefix (case-insensitive) from the input.
    /// Returns the input unchanged if no prefix matches.
    static func stripQuestionPrefix(from input: String) -> String {
        let lower = input.lowercased()
        for prefix in questionPrefixes {
            if lower.hasPrefix(prefix) {
                return String(input.dropFirst(prefix.count))
            }
        }
        return input
    }
}
