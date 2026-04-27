import Foundation
import FoundationModels

/// Multi-intent splitter that detects compound queries and decomposes them.
///
/// Two-stage approach:
/// 1. Fast heuristic path (<1ms): sentence boundary detection, ticker/arithmetic
///    pattern matching. Language-agnostic structural signals.
/// 2. LLM path (~1-2s): for queries that look compound but don't match structural
///    patterns. Uses `@Generable` structured output to decompose into sub-queries.
///    This path is inherently multi-lingual.
public enum IntentSplitter {

    /// A decomposed sub-query with its own entity context.
    public struct SubQuery: Sendable {
        public let text: String
        public let entities: ExtractedEntities?
    }

    /// Attempts to split a compound query into independent sub-queries.
    /// Returns `nil` if the input is a single-intent query (no split needed).
    public static func split(input: String, entities: ExtractedEntities?) -> [SubQuery]? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Too short to be compound
        guard trimmed.count >= 15 else { return nil }

        // Stage 1: Structural split on sentence boundaries (language-agnostic)
        // Periods, semicolons, and explicit list formatting are universal.
        if let structuralSplit = splitOnStructure(trimmed, entities: entities) {
            return structuralSplit
        }

        return nil
    }

    /// Async variant that falls back to LLM decomposition for ambiguous compound queries.
    /// Call this when the synchronous `split()` returns nil but you suspect multi-intent.
    public static func splitAsync(input: String, entities: ExtractedEntities?, llmAdapter: LLMAdapter = .shared) async -> [SubQuery]? {
        // Try synchronous first
        if let result = split(input: input, entities: entities) {
            return result
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }

        // Stage 2: LLM-based decomposition for ambiguous compounds
        let instructions = makeInstructions {
            Directive("""
            If this query asks for multiple independent things, split it into separate queries. \
            If it's a single request, return it unchanged. Output JSON: \
            {"queries": ["query1", "query2"]} or {"queries": ["original query"]}
            """)
        }

        do {
            let response = try await llmAdapter.generateStructured(
                prompt: trimmed,
                instructions: instructions,
                generating: IntentSplitResult.self,
                temperature: LLMTemperature.extraction
            )
            let queries = response.queries.filter { !$0.isEmpty }
            guard queries.count > 1 else { return nil }

            return queries.map { queryText in
                let filteredEntities = filterEntities(entities, relevantTo: queryText)
                return SubQuery(text: queryText, entities: filteredEntities)
            }
        } catch {
            Log.engine.debug("IntentSplitter LLM decomposition failed: \(error)")
            return nil
        }
    }

    // MARK: - Structural Split (Language-Agnostic)

    /// Splits on sentence boundaries when the sentences target different structural patterns.
    /// Detects: periods followed by capital letters, semicolons, numbered lists.
    private static func splitOnStructure(_ input: String, entities: ExtractedEntities?) -> [SubQuery]? {
        // 1. Sentence boundary split (". " followed by capital letter)
        let sentences = splitSentences(input)
        if sentences.count >= 2 {
            let firstHasQuestion = sentences[0].contains("?")
            let secondHasQuestion = sentences[1].contains("?")
            let mixedPunctuation = firstHasQuestion != secondHasQuestion
            let bothQuestions = firstHasQuestion && secondHasQuestion
            // Also split when sentences target different domains (e.g., weather + convert)
            let differentDomains = detectDomain(sentences[0]) != nil
                && detectDomain(sentences[1]) != nil
                && detectDomain(sentences[0]) != detectDomain(sentences[1])
            if mixedPunctuation || bothQuestions || differentDomains {
                return sentences.prefix(2).map { sentence in
                    SubQuery(text: sentence, entities: filterEntities(entities, relevantTo: sentence))
                }
            }
        }

        // 2. "and" conjunction split — only when halves belong to different domains.
        // Detects patterns like "weather in Paris and how's $AAPL" or "news and calculate 25% of 300".
        if let andResult = splitOnConjunction(input, entities: entities) {
            return andResult
        }

        return nil
    }

    /// Splits on " and " when the two halves contain signals from different tool domains.
    private static func splitOnConjunction(_ input: String, entities: ExtractedEntities?) -> [SubQuery]? {
        let lower = input.lowercased()
        // Find " and " as a conjunction (not "and" inside words like "android")
        guard let andRange = lower.range(of: " and ", options: .literal) else { return nil }

        let left = String(input[input.startIndex..<andRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let right = String(input[andRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Both halves must be substantial (≥3 words)
        guard left.split(separator: " ").count >= 2 && right.split(separator: " ").count >= 2 else { return nil }

        // Check that halves target different domains using lightweight keyword signals
        let leftDomain = detectDomain(left)
        let rightDomain = detectDomain(right)

        guard let ld = leftDomain, let rd = rightDomain, ld != rd else { return nil }

        return [
            SubQuery(text: left, entities: filterEntities(entities, relevantTo: left)),
            SubQuery(text: right, entities: filterEntities(entities, relevantTo: right))
        ]
    }

    /// Multilingual intent table for cross-lingual domain detection.
    private static let domainKeywords: MultilingualKeywords? = MultilingualKeywords.load("IntentSplitterKeywords")

    /// Lightweight domain detection via keyword signals and structural patterns.
    /// Uses `MultilingualKeywords` for stock/weather/news/translate detection;
    /// math + calendar still ride structural signals (digits, ticker pattern).
    private static func detectDomain(_ text: String) -> String? {
        let lower = text.lowercased()

        // Ticker pattern is universal: $AAPL works in every language.
        if text.contains("$") && text.range(of: #"\$[A-Z]{1,5}\b"#, options: .regularExpression) != nil { return "finance" }

        if let kw = domainKeywords {
            if kw.matches(intent: "stock_domain", in: text) { return "finance" }
            if kw.matches(intent: "weather_domain", in: text) { return "weather" }
            if kw.matches(intent: "news_domain", in: text) { return "news" }
            if kw.matches(intent: "translate_domain", in: text) { return "translation" }
        }

        // Math/calculation — digit + operator pattern is structural,
        // works across languages.
        if lower.range(of: #"\d+\s*[%+\-*/]"#, options: .regularExpression) != nil { return "math" }
        // Unit conversion — "convert X [unit] to [unit]" / "X [unit] to [unit]"
        // is a distinct domain from math even when the numeric-plus-operator
        // pattern doesn't fire. Keyword "convert" or "N UNIT to UNIT" shape
        // both indicate conversion.
        if lower.contains("convert") { return "convert" }
        if lower.range(of: #"\d+\s*\w+\s+(?:to|in)\s+\w+"#, options: .regularExpression) != nil { return "convert" }
        // Calendar/scheduling — keep English-only for now (scheduled to
        // migrate when Phase 8 generates the dedicated calendar config).
        if lower.contains("calendar") || lower.contains("schedule") || lower.contains("event") || lower.contains("meeting") { return "calendar" }

        return nil
    }

    /// Splits text into sentences respecting abbreviations and decimals.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])

            // Check for sentence boundary: ". " followed by uppercase
            if chars[i] == "." && i + 2 < chars.count && chars[i + 1] == " " && chars[i + 2].isUppercase {
                // Skip decimals (digit before period)
                if i > 0 && chars[i - 1].isNumber { i += 1; continue }

                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 5 { sentences.append(trimmed) }
                current = ""
            }

            i += 1
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if remaining.count > 5 { sentences.append(remaining) }

        return sentences
    }

    // MARK: - Entity Distribution

    /// Filters entities to only include those mentioned in the given text.
    private static func filterEntities(_ entities: ExtractedEntities?, relevantTo text: String) -> ExtractedEntities? {
        guard let entities else { return nil }
        let lower = text.lowercased()

        let names = entities.names.filter { lower.contains($0.lowercased()) }
        let places = entities.places.filter { lower.contains($0.lowercased()) }
        let orgs = entities.organizations.filter { lower.contains($0.lowercased()) }

        return ExtractedEntities(
            names: names,
            places: places,
            organizations: orgs,
            urls: entities.urls.filter { lower.contains($0.absoluteString.lowercased()) },
            phoneNumbers: [],
            emails: [],
            ocrText: nil,
            correctedInput: nil
        )
    }
}

// MARK: - @Generable Split Result

@Generable
struct IntentSplitResult: ConvertibleFromGeneratedContent, Sendable, Codable {
    @Guide(description: "The independent sub-queries. If the input is a single request, return it unchanged as a single-element array.")
    var queries: [String]
}

extension IntentSplitResult: JSONSchemaProviding {
    static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "queries": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "independent sub-queries, or single-element array if not splittable"
                ] as [String: Any]
            ],
            "required": ["queries"]
        ]
    }
}
