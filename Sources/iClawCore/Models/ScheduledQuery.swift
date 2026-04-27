import Foundation
import GRDB

/// A user-defined recurring automation persisted in GRDB.
///
/// Users create automations via natural language ("check $AAPL every hour").
/// HeartbeatManager executes due automations and delivers results via NotificationEngine.
public struct ScheduledQuery: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "automations"

    public var id: Int64?
    /// The natural language query to execute (e.g., "check $AAPL").
    public var query: String
    /// Resolved tool name (e.g., "Stocks"). Nil = re-route each execution.
    public var toolName: String?
    /// Repeat interval in seconds. Minimum: `AppConfig.minimumAutomationIntervalSeconds`.
    public var intervalSeconds: Int
    /// When this automation should next fire.
    public var nextRunDate: Date
    /// When it last fired successfully.
    public var lastRunDate: Date?
    /// Truncated last result text (max 200 chars) for Settings preview.
    public var lastResult: String?
    /// Whether this automation is active. Toggled by user or auto-paused on failures.
    public var isActive: Bool
    /// When the automation was created.
    public var createdAt: Date
    /// Consecutive failure count. Auto-paused after `AppConfig.automationMaxConsecutiveFailures`.
    public var failureCount: Int
    /// Human-readable label (e.g., "AAPL price every hour").
    public var label: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(
        id: Int64? = nil,
        query: String,
        toolName: String? = nil,
        intervalSeconds: Int,
        nextRunDate: Date,
        lastRunDate: Date? = nil,
        lastResult: String? = nil,
        isActive: Bool = true,
        createdAt: Date = Date(),
        failureCount: Int = 0,
        label: String
    ) {
        self.id = id
        self.query = query
        self.toolName = toolName
        self.intervalSeconds = intervalSeconds
        self.nextRunDate = nextRunDate
        self.lastRunDate = lastRunDate
        self.lastResult = lastResult
        self.isActive = isActive
        self.createdAt = createdAt
        self.failureCount = failureCount
        self.label = label
    }
}
