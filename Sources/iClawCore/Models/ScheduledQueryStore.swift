import Foundation
import GRDB
import os

/// Persistence layer for scheduled automations.
/// All operations go through `DatabaseManager.shared.dbQueue`.
public actor ScheduledQueryStore {
    public static let shared = ScheduledQueryStore()

    private let logger = Logger(subsystem: "com.geticlaw.iClaw", category: "ScheduledQueryStore")

    // MARK: - Migration

    /// Registers the automations table migration. Call from DatabaseManager's migrator.
    public static func registerMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("createAutomations") { db in
            try db.create(table: "automations", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("query", .text).notNull()
                t.column("toolName", .text)
                t.column("intervalSeconds", .integer).notNull()
                t.column("nextRunDate", .datetime).notNull()
                t.column("lastRunDate", .datetime)
                t.column("lastResult", .text)
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
                t.column("failureCount", .integer).notNull().defaults(to: 0)
                t.column("label", .text).notNull()
            }
        }
    }

    // MARK: - CRUD

    /// Creates a new automation. Enforces `AppConfig.maxActiveAutomations`.
    public func create(_ query: ScheduledQuery) async throws -> ScheduledQuery {
        try await DatabaseManager.shared.dbQueue.write { db in
            let activeCount = try ScheduledQuery
                .filter(Column("isActive") == true)
                .fetchCount(db)
            guard activeCount < AppConfig.maxActiveAutomations else {
                throw AutomationError.limitReached
            }
            var record = query
            try record.insert(db)
            return record
        }
    }

    /// Fetches all automations, ordered by creation date descending.
    public func fetchAll() async throws -> [ScheduledQuery] {
        try await DatabaseManager.shared.dbQueue.read { db in
            try ScheduledQuery
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    /// Fetches only active automations.
    public func fetchActive() async throws -> [ScheduledQuery] {
        try await DatabaseManager.shared.dbQueue.read { db in
            try ScheduledQuery
                .filter(Column("isActive") == true)
                .fetchAll(db)
        }
    }

    /// Fetches automations that are due for execution.
    public func fetchDue(before date: Date = Date()) async throws -> [ScheduledQuery] {
        try await DatabaseManager.shared.dbQueue.read { db in
            try ScheduledQuery
                .filter(Column("isActive") == true)
                .filter(Column("nextRunDate") <= date)
                .order(Column("nextRunDate").asc)
                .fetchAll(db)
        }
    }

    /// Deletes an automation by ID.
    public func delete(id: Int64) async throws {
        try await DatabaseManager.shared.dbQueue.write { db in
            _ = try ScheduledQuery.deleteOne(db, id: id)
        }
    }

    /// Toggles the active state of an automation.
    public func toggleActive(id: Int64) async throws {
        try await DatabaseManager.shared.dbQueue.write { db in
            guard var record = try ScheduledQuery.fetchOne(db, id: id) else { return }
            record.isActive.toggle()
            if record.isActive {
                // Reset failure count and schedule next run from now
                record.failureCount = 0
                record.nextRunDate = Date().addingTimeInterval(Double(record.intervalSeconds))
            }
            try record.update(db)
        }
    }

    /// Records a successful execution: updates lastRunDate, lastResult, nextRunDate, resets failures.
    public func recordExecution(id: Int64, result: String, nextRunDate: Date) async throws {
        try await DatabaseManager.shared.dbQueue.write { db in
            guard var record = try ScheduledQuery.fetchOne(db, id: id) else { return }
            record.lastRunDate = Date()
            record.lastResult = String(result.prefix(200))
            record.nextRunDate = nextRunDate
            record.failureCount = 0
            try record.update(db)
        }
    }

    /// Records a failure. Auto-pauses after `AppConfig.automationMaxConsecutiveFailures`.
    public func recordFailure(id: Int64) async throws {
        try await DatabaseManager.shared.dbQueue.write { db in
            guard var record = try ScheduledQuery.fetchOne(db, id: id) else { return }
            record.failureCount += 1
            if record.failureCount >= AppConfig.automationMaxConsecutiveFailures {
                record.isActive = false
                Log.engine.info("Automation '\(record.label)' auto-paused after \(record.failureCount) consecutive failures")
            }
            // Still advance nextRunDate to avoid immediate retry
            record.nextRunDate = Date().addingTimeInterval(Double(record.intervalSeconds))
            try record.update(db)
        }
    }

    /// Returns the count of active automations.
    public func activeCount() async -> Int {
        do {
            return try await DatabaseManager.shared.dbQueue.read { db in
                try ScheduledQuery
                    .filter(Column("isActive") == true)
                    .fetchCount(db)
            }
        } catch {
            logger.debug("activeCount failed: \(error)")
            return 0
        }
    }
}

// MARK: - Errors

public enum AutomationError: LocalizedError {
    case limitReached
    case invalidInterval
    case queryTooShort

    public var errorDescription: String? {
        switch self {
        case .limitReached:
            return "Maximum of \(AppConfig.maxActiveAutomations) active automations reached."
        case .invalidInterval:
            return "Minimum interval is \(AppConfig.minimumAutomationIntervalSeconds / 60) minutes."
        case .queryTooShort:
            return "Automation query is too short."
        }
    }
}
