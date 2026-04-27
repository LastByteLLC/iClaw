import Foundation

/// Generic TTL (time-to-live) cache actor. Replaces duplicate cache actors
/// in StockTool and ConvertTool.
actor TTLCache<Value: Sendable> {
    private var storage: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int

    private struct Entry {
        let value: Value
        let timestamp: Date
    }

    init(ttl: TimeInterval, maxEntries: Int = 50) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    func get(_ key: String) -> Value? {
        guard let entry = storage[key],
              Date().timeIntervalSince(entry.timestamp) < ttl else {
            storage.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func set(_ key: String, value: Value) {
        storage[key] = Entry(value: value, timestamp: Date())
        if storage.count > maxEntries {
            if let oldest = storage.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                storage.removeValue(forKey: oldest)
            }
        }
    }
}
