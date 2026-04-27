import Foundation

/// A compressed, structured representation of a tool execution result.
///
/// Facts are the atomic unit of working memory. Each tool knows how to compress
/// its output into a ~10-token fact that preserves the essential data (prices,
/// temperatures, times, names) while discarding narrative. Five facts fit in
/// ~50-60 tokens vs ~300 tokens for the previous truncated summary approach.
///
/// Facts enable entity-anchored recall: "tell me more about that stock" matches
/// the fact key "$AAPL" without needing the follow-up classifier or vector search.
public struct Fact: Codable, Sendable, Equatable {
    /// The tool that produced this fact (e.g., "Stocks", "Weather").
    public let tool: String
    /// A compact key for entity matching (e.g., "$AAPL", "San Francisco", "Team standup").
    public let key: String
    /// The essential data value (e.g., "$286.05 +1.2%", "62°F partly cloudy").
    public let value: String
    /// When this fact was produced.
    public let timestamp: Date

    public init(tool: String, key: String, value: String, timestamp: Date = Date()) {
        self.tool = tool
        self.key = key
        self.value = value
        self.timestamp = timestamp
    }

    /// Compact string representation for injection into the LLM context.
    /// Targets ~10-15 tokens.
    public func compact() -> String {
        let time = timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(key): \(value) (\(time))"
    }

    /// Returns true if this fact is relevant to the given entity string.
    /// Uses case-insensitive substring matching on the key.
    public func matches(entity: String) -> Bool {
        let lowerKey = key.lowercased()
        let lowerEntity = entity.lowercased()
        return lowerKey.contains(lowerEntity) || lowerEntity.contains(lowerKey)
    }

    /// Returns true if this fact contradicts another — same tool + overlapping key
    /// but different value. Used to replace stale data in working memory rather than
    /// accumulating outdated entries (e.g., two weather facts for "San Francisco").
    public func contradicts(_ other: Fact) -> Bool {
        guard tool == other.tool else { return false }
        let keysOverlap = key.lowercased() == other.key.lowercased()
            || key.lowercased().contains(other.key.lowercased())
            || other.key.lowercased().contains(key.lowercased())
        guard keysOverlap else { return false }
        return value != other.value
    }

    /// Relevance score for eviction decisions. Higher = more relevant.
    /// Combines recency (decays over minutes) with entity overlap.
    public func relevanceScore(activeEntities: [String]) -> Double {
        let minutesAgo = Date().timeIntervalSince(timestamp) / 60.0
        let recency = 1.0 / (1.0 + minutesAgo / 10.0)
        let entityBoost = activeEntities.contains(where: { matches(entity: $0) }) ? 0.5 : 0.0
        return recency + entityBoost
    }
}

/// Extracts structured facts from tool output.
///
/// Each tool can conform to provide domain-specific compression. Tools that
/// don't conform get a generic fact extracted from the first significant line.
public protocol FactCompressor: Sendable {
    /// Attempts to extract one or more structured facts from a tool result.
    func compress(toolName: String, result: ToolIO) -> [Fact]
}

/// Default fact compressor that extracts the first significant line.
public struct GenericFactCompressor: FactCompressor, Sendable {
    public init() {}

    public func compress(toolName: String, result: ToolIO) -> [Fact] {
        guard result.status == .ok, !result.text.isEmpty else { return [] }
        let firstLine = result.text
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? result.text

        let truncated = String(firstLine.prefix(100))
        return [Fact(tool: toolName, key: toolName, value: truncated)]
    }
}

/// Registry of fact compressors keyed by tool name.
/// Falls back to `GenericFactCompressor` for unregistered tools.
///
/// Only tools with meaningful key extraction have specialized compressors.
/// All others use `GenericFactCompressor` which takes the first significant line.
public enum FactCompressorRegistry {
    private static let compressors: [String: any FactCompressor] = [
        ToolNames.stocks: StockFactCompressor(),
        ToolNames.weather: WeatherFactCompressor(),
    ]

    private static let fallback: any FactCompressor = GenericFactCompressor()

    /// Compresses a tool result into structured facts.
    public static func compress(toolName: String, result: ToolIO) -> [Fact] {
        let compressor = compressors[toolName] ?? fallback
        return compressor.compress(toolName: toolName, result: result)
    }
}

// MARK: - Domain-Specific Compressors

/// Extracts ticker symbol as key from stock output for entity-anchored recall.
struct StockFactCompressor: FactCompressor {
    func compress(toolName: String, result: ToolIO) -> [Fact] {
        guard result.status == .ok else { return [] }
        let firstLine = result.text.components(separatedBy: .newlines).first ?? result.text
        let words = firstLine.components(separatedBy: .whitespaces)
        let key = words.first(where: { $0.hasPrefix("$") || $0.allSatisfy { $0.isUppercase || $0 == "." } }) ?? "Stock"
        return [Fact(tool: toolName, key: key, value: String(firstLine.prefix(100)))]
    }
}

/// Extracts location name as key from weather output for entity-anchored recall.
struct WeatherFactCompressor: FactCompressor {
    func compress(toolName: String, result: ToolIO) -> [Fact] {
        guard result.status == .ok else { return [] }
        let firstLine = result.text.components(separatedBy: .newlines).first ?? result.text
        let parts = firstLine.components(separatedBy: ":")
        let key = parts.count > 1 ? parts[0].trimmingCharacters(in: .whitespaces) : "Weather"
        return [Fact(tool: toolName, key: key, value: String(firstLine.prefix(100)))]
    }
}
