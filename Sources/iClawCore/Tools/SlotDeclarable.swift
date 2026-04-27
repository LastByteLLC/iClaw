import Foundation

/// A named parameter slot that a tool cares about. Used for:
/// 1. Follow-up detection: if a short input fills a slot of the prior tool, it's a continuation.
/// 2. Argument merging: during refinement, new slot values override prior values.
///
/// Each slot has a lightweight extractor that returns a value if the input
/// fills this slot, or nil otherwise. Extractors should be fast (no LLM calls).
public struct ToolSlot: Sendable {
    /// Slot name matching the tool's argument schema (e.g., "location", "query").
    public let name: String

    /// Semantic type for cross-tool slot comparison.
    public let type: SlotType

    /// Extracts a value for this slot from raw input + NER entities.
    /// Returns nil if the input doesn't fill this slot.
    public let extractor: @Sendable (String, ExtractedEntities?) -> String?

    public init(
        name: String,
        type: SlotType,
        extractor: @escaping @Sendable (String, ExtractedEntities?) -> String?
    ) {
        self.name = name
        self.type = type
        self.extractor = extractor
    }

    /// Semantic slot types. Used to detect when an input fills a slot of
    /// the same type across different tools (e.g., location slots in Weather
    /// vs Time indicate continuation if the prior tool was location-aware).
    public enum SlotType: String, Sendable {
        /// A geographic location (city, address, region).
        case location
        /// A person's name.
        case person
        /// A date or date range.
        case date
        /// A time of day or duration.
        case time
        /// A numeric value (count, amount, range).
        case number
        /// A free-text search query or topic.
        case query
        /// A unit of measurement (miles, kg, celsius).
        case unit
        /// A domain-specific entity (ticker symbol, language code, file path).
        case entity
    }
}

/// Tools that declare their parameter slots for follow-up detection
/// and argument merging.
///
/// Conforming tools list the slots they accept. The slot extractors are
/// lightweight — they reuse `InputParsingUtilities` and NER, never LLM calls.
/// Tools that don't conform are treated as having no slots (follow-up
/// detection falls back to NLP heuristics).
public protocol SlotDeclarable {
    /// The parameter slots this tool accepts.
    static var slots: [ToolSlot] { get }
}

// MARK: - Common Slot Extractors

/// Reusable extractors for common slot types, avoiding duplication across tools.
public enum SlotExtractors {

    /// Extracts a location from NER entities, falling back to prefix stripping.
    public static func location(
        prefixes: [String] = ["in", "for", "at", "near", "around"]
    ) -> @Sendable (String, ExtractedEntities?) -> String? {
        { input, entities in
            InputParsingUtilities.extractLocation(
                from: input, entities: entities, strippingPrefixes: prefixes
            )
        }
    }

    /// Extracts a person name from NER entities.
    public static let person: @Sendable (String, ExtractedEntities?) -> String? = { _, entities in
        entities?.names.first
    }

    /// Extracts a ticker symbol ($AAPL) from input.
    public static let ticker: @Sendable (String, ExtractedEntities?) -> String? = { input, _ in
        InputParsingUtilities.extractTickerSymbols(from: input).first
    }

    /// Extracts a free-text query (the input itself, after stripping filler).
    public static let query: @Sendable (String, ExtractedEntities?) -> String? = { input, _ in
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extracts a numeric value from input.
    public static let number: @Sendable (String, ExtractedEntities?) -> String? = { input, _ in
        // Find first number-like token
        let tokens = input.components(separatedBy: .whitespaces)
        for token in tokens {
            let cleaned = token.trimmingCharacters(in: .punctuationCharacters)
            if Double(cleaned) != nil {
                return cleaned
            }
        }
        return nil
    }

    /// Strips manifest-defined prefixes from input. Returns the remainder after the first
    /// matching prefix, or nil if no prefix matches. Used for query/topic slots.
    public static func manifestPrefixStrip(
        toolName: String
    ) -> @Sendable (String, ExtractedEntities?) -> String? {
        let prefixes = ToolManifest.prefixes(for: toolName)
        return { input, _ in
            let lower = input.lowercased()
            for prefix in prefixes {
                if lower.hasPrefix(prefix) {
                    let remainder = String(input.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty { return remainder }
                }
            }
            return nil
        }
    }

    /// Like `manifestPrefixStrip` but falls back to returning the full input if no prefix matches.
    /// Used for tools where any input is a valid query (Research, web_search, Create).
    public static func manifestPrefixStripOrInput(
        toolName: String
    ) -> @Sendable (String, ExtractedEntities?) -> String? {
        let prefixes = ToolManifest.prefixes(for: toolName)
        return { input, _ in
            let lower = input.lowercased()
            for prefix in prefixes {
                if lower.hasPrefix(prefix) {
                    let remainder = String(input.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainder.isEmpty { return remainder }
                }
            }
            return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Location extractor that reads prefixes from the ToolManifest.
    public static func manifestLocation(
        toolName: String
    ) -> @Sendable (String, ExtractedEntities?) -> String? {
        let prefixes = ToolManifest.prefixes(for: toolName)
        return { input, entities in
            InputParsingUtilities.extractLocation(
                from: input, entities: entities, strippingPrefixes: prefixes
            )
        }
    }

    /// Extracts a date/time expression. Lightweight — uses NSDataDetector.
    public static let date: @Sendable (String, ExtractedEntities?) -> String? = { input, _ in
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        if let match = detector.firstMatch(in: input, options: [], range: range) {
            return (input as NSString).substring(with: match.range)
        }
        return nil
    }
}
