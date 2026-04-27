import Foundation

/// Cache duration declared by a skill in its `## Cache` section.
public enum CacheDuration: String, Codable, Sendable {
    case day
    case hour
    case session
    case none

    /// Returns the TTL in seconds for this cache duration.
    /// `.day` expires at midnight local time; `.hour` and `.session` use fixed intervals.
    func ttl() -> TimeInterval {
        switch self {
        case .day:
            let calendar = Calendar.current
            let now = Date()
            guard let midnight = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) else {
                return 3600 // Fallback: 1 hour
            }
            return midnight.timeIntervalSince(now)
        case .hour:
            return 3600
        case .session:
            return .infinity
        case .none:
            return 0
        }
    }
}

/// Actor-based cache for skill results, keyed by skill name + normalized input.
/// Uses `TTLCache<String>` internally with date-aware expiry for `.day` unit.
public actor SkillCache {
    public static let shared = SkillCache()

    private var storage: [String: Entry] = [:]
    private let maxEntries = 50

    private struct Entry {
        let ingredients: [String]
        let widgetType: String?
        let widgetData: (any Sendable)?
        let timestamp: Date
        let ttl: TimeInterval
    }

    public struct CachedResult: Sendable {
        public let ingredients: [String]
        public let widgetType: String?
        public let widgetData: (any Sendable)?
    }

    /// Looks up a cached skill result. Returns nil if expired or absent.
    public func lookup(skillName: String, input: String) -> CachedResult? {
        let key = Self.makeKey(skillName: skillName, input: input)
        guard let entry = storage[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > entry.ttl {
            storage.removeValue(forKey: key)
            return nil
        }
        return CachedResult(
            ingredients: entry.ingredients,
            widgetType: entry.widgetType,
            widgetData: entry.widgetData
        )
    }

    /// Stores a skill execution result in the cache.
    public func store(
        skillName: String,
        input: String,
        ingredients: [String],
        widgetType: String?,
        widgetData: (any Sendable)?,
        duration: CacheDuration
    ) {
        guard duration != .none else { return }
        let key = Self.makeKey(skillName: skillName, input: input)
        storage[key] = Entry(
            ingredients: ingredients,
            widgetType: widgetType,
            widgetData: widgetData,
            timestamp: Date(),
            ttl: duration.ttl()
        )
        if storage.count > maxEntries {
            if let oldest = storage.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                storage.removeValue(forKey: oldest)
            }
        }
    }

    /// Clears all cached entries.
    public func reset() {
        storage.removeAll()
    }

    /// Current entry count (for testing).
    public var count: Int { storage.count }

    // MARK: - Key Derivation

    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "can", "to", "of", "in", "for", "on",
        "with", "at", "by", "from", "what", "what's", "whats", "how",
        "i", "me", "my", "we", "our", "you", "your", "tell", "get",
        "show", "give", "find", "s", "t", "re", "ve", "ll", "d", "m",
    ]

    /// Derives a cache key from skill name + input, stripping stop words but preserving word order.
    static func makeKey(skillName: String, input: String) -> String {
        let words = input.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
        return "\(skillName):\(words.joined(separator: "+"))"
    }
}
