import Foundation

/// Ephemeral cache for tool outputs with TTL and LRU eviction.
/// Prevents re-execution of expensive tools on follow-up questions.
public actor ScratchpadCache {
    public static let shared = ScratchpadCache()

    public struct Entry: Sendable {
        public let toolName: String
        public let textSummary: String
        public let widgetType: String?
        public let isVerifiedData: Bool
        public let timestamp: Date
        public let ttl: TimeInterval

        // widgetData stored separately since `any Sendable` can't be in a struct directly
        // without losing equatability — we store it as an opaque box
        let _widgetData: (any Sendable)?

        public var widgetData: (any Sendable)? { _widgetData }

        public init(
            toolName: String,
            textSummary: String,
            widgetData: (any Sendable)? = nil,
            widgetType: String? = nil,
            isVerifiedData: Bool = false,
            timestamp: Date = Date(),
            ttl: TimeInterval = ScratchpadCache.defaultTTL
        ) {
            self.toolName = toolName
            self.textSummary = textSummary
            self._widgetData = widgetData
            self.widgetType = widgetType
            self.isVerifiedData = isVerifiedData
            self.timestamp = timestamp
            self.ttl = ttl
        }

        var isExpired: Bool {
            Date().timeIntervalSince(timestamp) > ttl
        }
    }

    private var storage: [String: Entry] = [:]
    private var accessOrder: [String] = []
    private let maxEntries = 10

    /// TTL per tool type (seconds).
    public static let ttlMap: [String: TimeInterval] = [
        "Weather": 1800,
        "Stocks": 300,
        "Maps": 3600,
        "WebFetch": 600,
        "WebSearch": 600,
        "Wikipedia": 3600,
    ]
    public static let defaultTTL: TimeInterval = 600

    /// Returns the cached entry if it exists and is not expired.
    public func lookup(key: String) -> Entry? {
        evictExpired()
        guard let entry = storage[key] else { return nil }
        if entry.isExpired {
            storage.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
            return nil
        }
        // Update LRU order
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        return entry
    }

    /// Stores an entry, evicting LRU if at capacity.
    public func store(key: String, entry: Entry) {
        // Remove existing entry if updating
        if storage[key] != nil {
            accessOrder.removeAll { $0 == key }
        }

        storage[key] = entry
        accessOrder.append(key)

        // Evict LRU if over capacity
        while storage.count > maxEntries {
            if let oldest = accessOrder.first {
                storage.removeValue(forKey: oldest)
                accessOrder.removeFirst()
            } else {
                break
            }
        }
    }

    /// Removes all expired entries.
    public func evictExpired() {
        let expiredKeys = storage.filter { $0.value.isExpired }.map { $0.key }
        for key in expiredKeys {
            storage.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
        }
    }

    /// Clears all entries.
    public func reset() {
        storage.removeAll()
        accessOrder.removeAll()
    }

    /// Returns current entry count (for testing).
    public var count: Int { storage.count }

    // MARK: - Key Derivation

    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "need", "dare", "ought",
        "used", "to", "of", "in", "for", "on", "with", "at", "by", "from",
        "as", "into", "through", "during", "before", "after", "above", "below",
        "between", "out", "off", "over", "under", "again", "further", "then",
        "once", "here", "there", "when", "where", "why", "how", "all", "both",
        "each", "few", "more", "most", "other", "some", "such", "no", "nor",
        "not", "only", "own", "same", "so", "than", "too", "very", "just",
        "but", "and", "or", "if", "what", "what's", "whats", "which", "who",
        "whom", "this", "that", "these", "those", "i", "me", "my", "myself",
        "we", "our", "you", "your", "he", "him", "his", "she", "her", "it",
        "its", "they", "them", "their", "tell", "get", "show", "give", "find",
        "s", "t", "re", "ve", "ll", "d", "m",  // Contraction fragments (what's → what + s)
    ]

    /// Tools where input order matters (e.g., "USD to EUR" ≠ "EUR to USD").
    /// For these tools the cache key preserves original word order instead of sorting.
    private static let directionalTools: Set<String> = ["Convert", "Translate"]

    /// Derives a deterministic cache key from tool name and input.
    /// Strips stop words and lowercases. For most tools, words are sorted so that
    /// "weather London" and "London weather" share a cache entry. For directional
    /// tools (Convert, Translate), word order is preserved to avoid collisions like
    /// "USD to EUR" vs "EUR to USD".
    public static func makeKey(toolName: String, input: String) -> String {
        var words = input.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }

        if !directionalTools.contains(toolName) {
            words.sort()
        }

        let suffix = words.joined(separator: "+")
        return "\(toolName):\(suffix)"
    }
}
