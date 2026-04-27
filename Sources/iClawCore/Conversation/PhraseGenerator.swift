import Foundation
import GRDB

// MARK: - Phrase Type

/// Categories of phrases the system can generate opportunistically.
public enum PhraseType: String, Codable, Sendable, CaseIterable {
    case greeting       // Welcome messages shown on launch
    case thinking       // Displayed while LLM is processing
    case progress       // Stage descriptions during execution

    /// Maximum stored phrases per type. Oldest are purged beyond this.
    var maxCount: Int {
        switch self {
        case .greeting: 30
        case .thinking: 50
        case .progress: 20
        }
    }
}

// MARK: - Generated Phrase Record

public struct GeneratedPhrase: Codable, Sendable, FetchableRecord, MutablePersistableRecord, Equatable {
    public static let databaseTableName = "generated_phrases"

    public var id: Int64?
    public var type: String          // PhraseType raw value
    public var text: String
    public var language: String      // ISO language code, e.g. "en", "es"
    public var createdAt: Date

    public init(id: Int64? = nil, type: PhraseType, text: String, language: String = "en", createdAt: Date = Date()) {
        self.id = id
        self.type = type.rawValue
        self.text = text
        self.language = language
        self.createdAt = createdAt
    }

    public var phraseType: PhraseType {
        PhraseType(rawValue: type) ?? .thinking
    }
}

// MARK: - Database Migration

extension GeneratedPhrase {
    public static func registerMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createGeneratedPhrases") { db in
            try db.create(table: "generated_phrases") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("text", .text).notNull()
                t.column("language", .text).notNull().defaults(to: "en")
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_phrases_type", on: "generated_phrases", columns: ["type"])
        }
    }
}

// MARK: - Phrase Generator Manager

/// Opportunistically generates new phrases using the LLM during idle time.
/// Phrases are stored in the database and mixed in with predefined ones.
public actor PhraseGenerator {
    public static let shared = PhraseGenerator()

    private let dbQueue: DatabaseQueue?
    private var lastGeneration: Date?
    private static let minGenerationInterval: TimeInterval = 3600 * 6 // 6 hours

    private init() {
        self.dbQueue = DatabaseManager.shared.dbQueue
    }

    // MARK: - Retrieval

    /// Get a random phrase of the given type, mixing generated and predefined.
    /// Returns nil if no generated phrases exist (caller uses predefined fallback).
    public nonisolated func randomPhrase(ofType type: PhraseType) -> String? {
        guard let dbQueue else { return nil }
        return try? dbQueue.read { db in
            try GeneratedPhrase
                .filter(Column("type") == type.rawValue)
                .order(sql: "RANDOM()")
                .limit(1)
                .fetchOne(db)?.text
        }
    }

    /// Count of stored phrases for a type.
    public func count(ofType type: PhraseType) -> Int {
        guard let dbQueue else { return 0 }
        return (try? dbQueue.read { db in
            try GeneratedPhrase
                .filter(Column("type") == type.rawValue)
                .fetchCount(db)
        }) ?? 0
    }

    // MARK: - Generation

    /// Opportunistically generate new phrases if enough time has passed.
    /// Called from HeartbeatManager during idle periods.
    public func generateIfNeeded(adapter: LLMAdapter, userLanguage: String = Locale.current.language.languageCode?.identifier ?? "en") async {
        let now = Date()
        if let last = lastGeneration, now.timeIntervalSince(last) < Self.minGenerationInterval { return }

        // Pick a random type that needs more phrases
        let typesNeedingPhrases = PhraseType.allCases.filter { count(ofType: $0) < $0.maxCount }
        guard let targetType = typesNeedingPhrases.randomElement() else {
            // All types are full — purge oldest and generate fresh
            purgeOldest()
            lastGeneration = now
            return
        }

        await generate(type: targetType, count: 5, language: userLanguage, adapter: adapter)
        lastGeneration = now
    }

    /// Generate a batch of phrases for a specific type.
    private func generate(type: PhraseType, count: Int, language: String, adapter: LLMAdapter) async {
        let languageHint = language == "en" ? "" : " Write them in \(Locale.current.localizedString(forLanguageCode: language) ?? language)."

        let prompt: String
        switch type {
        case .greeting:
            prompt = """
            Generate \(count) short, friendly greeting messages for an AI assistant app. \
            They should be playful, varied, and welcoming. \
            Each on its own line, no numbering or quotes.\(languageHint)
            """
        case .thinking:
            prompt = """
            Generate \(count) short, witty "thinking" phrases for an AI assistant to show while processing. \
            They should be humorous, quirky, and under 6 words each. \
            Like: "Consulting the crystal ball...", "Neurons firing...", "Summoning the data spirits..." \
            Each on its own line, no numbering or quotes.\(languageHint)
            """
        case .progress:
            prompt = """
            Generate \(count) short progress stage labels for an AI assistant processing a request. \
            They should be professional but friendly, under 4 words each. \
            Like: "Analyzing context", "Connecting the dots", "Almost there" \
            Each on its own line, no numbering or quotes.\(languageHint)
            """
        }

        do {
            let response = try await adapter.generate(
                prompt: prompt,
                temperature: LLMCallProfile.phrases.temperature,
                maxTokens: LLMCallProfile.phrases.maxTokens,
                sampling: LLMCallProfile.phrases.sampling
            )
            let lines = response.content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count > 3 && $0.count < 80 }
                .prefix(count)

            guard let dbQueue else { return }
            try await dbQueue.write { db in
                for line in lines {
                    var phrase = GeneratedPhrase(type: type, text: line, language: language)
                    try phrase.insert(db)
                }
            }
            Log.engine.debug("Generated \(lines.count) \(type.rawValue) phrases (language: \(language))")
        } catch {
            Log.engine.debug("Phrase generation failed: \(error)")
        }
    }

    // MARK: - Maintenance

    /// Purge oldest phrases beyond the cap for each type.
    private func purgeOldest() {
        guard let dbQueue else { return }
        for type in PhraseType.allCases {
            let currentCount = count(ofType: type)
            if currentCount > type.maxCount {
                let excess = currentCount - type.maxCount
                do {
                    try dbQueue.write { db in
                        try db.execute(
                            sql: """
                                DELETE FROM generated_phrases WHERE id IN (
                                    SELECT id FROM generated_phrases
                                    WHERE type = ?
                                    ORDER BY createdAt ASC
                                    LIMIT ?
                                )
                                """,
                            arguments: [type.rawValue, excess]
                        )
                    }
                } catch {
                    Log.engine.debug("Phrase cleanup failed: \(error)")
                }
            }
        }
    }

    /// Clear all generated phrases (called from Settings).
    public func clearAll() throws {
        guard let dbQueue else { return }
        try dbQueue.write { db in
            _ = try GeneratedPhrase.deleteAll(db)
        }
    }
}
