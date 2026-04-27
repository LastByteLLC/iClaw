import Foundation
import GRDB
import os

/// Persistent user profile that learns from usage patterns.
///
/// Tracks tool frequency, entity frequency, location patterns, and time-of-day usage.
/// Entries have a confidence score (0.0–1.0) that decays over time. The profile is
/// injected into ConversationState as lightweight context (~30 tokens).
///
/// No LLM calls — all learning is deterministic signal tracking.
public actor UserProfileManager {
    public static let shared = UserProfileManager()

    private let logger = Logger(subsystem: "com.geticlaw.iClaw", category: "UserProfile")

    // MARK: - Profile Entry

    public struct ProfileEntry: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
        public static let databaseTableName = "user_profile"

        public var id: Int64?
        public var category: String      // "tool_freq", "entity_freq", "location", "time_pattern", "quality"
        public var key: String           // e.g., "Weather", "London", "morning_tools"
        public var value: String         // e.g., "42" (count), "London" (city), "Weather,News" (tools)
        public var confidence: Double    // 0.0–1.0
        public var lastUpdated: Date

        public mutating func didInsert(_ inserted: InsertionSuccess) {
            id = inserted.rowID
        }
    }

    // MARK: - Database Migration

    /// Registers the user_profile migration. Call from DatabaseManager's migrator.
    public static func registerMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createUserProfile") { db in
            try db.create(table: "user_profile", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("category", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("lastUpdated", .datetime).notNull().defaults(to: Date())
            }
            try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_profile_cat_key ON user_profile(category, key)")
        }
    }

    // MARK: - Recording Signals

    /// Records a tool usage, incrementing its frequency count.
    public func recordToolUsage(_ toolName: String) async {
        await upsertEntry(category: "tool_freq", key: toolName, incrementBy: 1)
    }

    /// Records entity mentions (cities, people, tickers).
    public func recordEntities(_ entities: ExtractedEntities?) async {
        guard let entities else { return }
        for place in entities.places {
            await upsertEntry(category: "entity_freq", key: place, incrementBy: 1)
        }
        for name in entities.names {
            await upsertEntry(category: "entity_freq", key: name, incrementBy: 1)
        }
        for org in entities.organizations {
            await upsertEntry(category: "entity_freq", key: org, incrementBy: 1)
        }
    }

    /// Records a quality signal from the post-turn assessment.
    public func recordQualitySignal(toolName: String, score: Int) async {
        // Store as running average: value = "totalScore,count"
        await upsertQuality(toolName: toolName, score: score)
    }

    /// Records the hour of day for tool usage patterns.
    public func recordTimePattern(toolName: String) async {
        let hour = Calendar.current.component(.hour, from: Date())
        let period: String
        switch hour {
        case 5..<12: period = "morning"
        case 12..<17: period = "afternoon"
        case 17..<21: period = "evening"
        default: period = "night"
        }
        await upsertEntry(category: "time_pattern", key: "\(period)_\(toolName)", incrementBy: 1)
    }

    // MARK: - Querying

    /// Returns the user's most-used tools, sorted by frequency.
    public func topTools(limit: Int = 5) async -> [(name: String, count: Int)] {
        do {
            return try await DatabaseManager.shared.dbQueue.read { db in
                let rows = try ProfileEntry
                    .filter(Column("category") == "tool_freq")
                    .order(Column("confidence").desc)
                    .limit(limit)
                    .fetchAll(db)
                return rows.map { (name: $0.key, count: Int($0.value) ?? 0) }
            }
        } catch {
            logger.debug("topTools failed: \(error)")
            return []
        }
    }

    /// Returns the user's most-mentioned entities.
    public func topEntities(limit: Int = 5) async -> [(name: String, count: Int)] {
        do {
            return try await DatabaseManager.shared.dbQueue.read { db in
                let rows = try ProfileEntry
                    .filter(Column("category") == "entity_freq")
                    .order(Column("confidence").desc)
                    .limit(limit)
                    .fetchAll(db)
                return rows.map { (name: $0.key, count: Int($0.value) ?? 0) }
            }
        } catch {
            logger.debug("topEntities failed: \(error)")
            return []
        }
    }

    /// Returns the average quality score for a tool (1-5), or nil if no data.
    public func qualityScore(for toolName: String) async -> Double? {
        do {
            return try await DatabaseManager.shared.dbQueue.read { db in
                guard let entry = try ProfileEntry
                    .filter(Column("category") == "quality")
                    .filter(Column("key") == toolName)
                    .fetchOne(db) else { return nil }
                let parts = entry.value.split(separator: ",")
                guard parts.count == 2,
                      let total = Double(parts[0]),
                      let count = Double(parts[1]),
                      count > 0 else { return nil }
                return total / count
            }
        } catch {
            return nil
        }
    }

    /// Returns a compact profile summary for injection into conversation context.
    /// Designed to be ≤30 tokens.
    public func profileContext() async -> String? {
        let tools = await topTools(limit: 3)
        let entities = await topEntities(limit: 3)

        var parts: [String] = []
        if !tools.isEmpty {
            let toolNames = tools.map { $0.name }.joined(separator: ", ")
            parts.append("Frequently used: \(toolNames)")
        }
        if !entities.isEmpty {
            let entityNames = entities.map { $0.name }.joined(separator: ", ")
            parts.append("Common topics: \(entityNames)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    // MARK: - Confidence Decay

    /// Decays all confidence values by the given factor. Call once per day (e.g., on app launch).
    public func applyConfidenceDecay(factor: Double = 0.95) async {
        do {
            try await DatabaseManager.shared.dbQueue.write { db in
                try db.execute(sql: "UPDATE user_profile SET confidence = confidence * ?", arguments: [factor])
                // Prune entries below threshold
                try db.execute(sql: "DELETE FROM user_profile WHERE confidence < 0.05")
            }
        } catch {
            logger.debug("Confidence decay failed: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func upsertEntry(category: String, key: String, incrementBy: Int) async {
        do {
            try await DatabaseManager.shared.dbQueue.write { db in
                if var existing = try ProfileEntry
                    .filter(Column("category") == category)
                    .filter(Column("key") == key)
                    .fetchOne(db) {
                    let currentCount = Int(existing.value) ?? 0
                    existing.value = "\(currentCount + incrementBy)"
                    existing.confidence = min(1.0, existing.confidence + 0.05)
                    existing.lastUpdated = Date()
                    try existing.update(db)
                } else {
                    var entry = ProfileEntry(
                        id: nil,
                        category: category,
                        key: key,
                        value: "\(incrementBy)",
                        confidence: 0.3,
                        lastUpdated: Date()
                    )
                    try entry.insert(db)
                }
            }
        } catch {
            logger.debug("upsertEntry failed: \(error)")
        }
    }

    private func upsertQuality(toolName: String, score: Int) async {
        do {
            try await DatabaseManager.shared.dbQueue.write { db in
                if var existing = try ProfileEntry
                    .filter(Column("category") == "quality")
                    .filter(Column("key") == toolName)
                    .fetchOne(db) {
                    let parts = existing.value.split(separator: ",")
                    let total = (Double(parts.first ?? "0") ?? 0) + Double(score)
                    let count = (Double(parts.last ?? "0") ?? 0) + 1
                    existing.value = "\(Int(total)),\(Int(count))"
                    existing.lastUpdated = Date()
                    try existing.update(db)
                } else {
                    var entry = ProfileEntry(
                        id: nil,
                        category: "quality",
                        key: toolName,
                        value: "\(score),1",
                        confidence: 0.5,
                        lastUpdated: Date()
                    )
                    try entry.insert(db)
                }
            }
        } catch {
            logger.debug("upsertQuality failed: \(error)")
        }
    }
}
