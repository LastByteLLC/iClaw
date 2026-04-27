import Foundation
import os

/// Protocol for tools that support proactive background pre-fetching.
///
/// Conforming tools declare pre-fetch configurations — canonical queries that
/// the scheduler runs before the user asks, populating the `ScratchpadCache`.
/// When the user later makes a matching query, the cached result is served
/// instantly instead of waiting for a network round-trip.
///
/// The integration is zero-touch: `ScratchpadCache` is already checked by
/// `ExecutionEngine.executeCoreTools()` before tool execution. Pre-fetched
/// entries use the same key format, so matching queries hit the cache naturally.
public protocol PreFetchable: Sendable {
    /// Returns pre-fetch configurations for this tool.
    /// Each entry describes a default query and how to execute it.
    func preFetchEntries() async -> [PreFetchEntry]
}

/// A single pre-fetch configuration: a canonical query + its cache metadata.
public struct PreFetchEntry: Sendable {
    /// Cache key in `ScratchpadCache.makeKey` format (e.g., "News:", "Weather:weather").
    public let cacheKey: String
    /// Human-readable label for logging.
    public let label: String
    /// How long the pre-fetched result remains valid (seconds).
    public let ttl: TimeInterval
    /// The tool name (for `ScratchpadCache.Entry`).
    public let toolName: String
    /// Closure that performs the actual fetch. Must be self-contained (no captured mutable state).
    public let fetch: @Sendable () async throws -> ToolIO

    public init(
        cacheKey: String,
        label: String,
        ttl: TimeInterval,
        toolName: String,
        fetch: @escaping @Sendable () async throws -> ToolIO
    ) {
        self.cacheKey = cacheKey
        self.label = label
        self.ttl = ttl
        self.toolName = toolName
        self.fetch = fetch
    }
}

/// Proactively populates `ScratchpadCache` with results for common queries.
///
/// The scheduler runs on a configurable interval and refreshes any entries
/// that are expired or missing. It integrates with the existing cache layer —
/// no changes to tool execution are needed beyond conforming to `PreFetchable`.
///
/// ## Usage
/// ```swift
/// // At app startup:
/// await PreFetchScheduler.shared.registerTool(NewsTool())
/// await PreFetchScheduler.shared.registerTool(WeatherTool())
/// await PreFetchScheduler.shared.start()
/// ```
///
/// ## Design Rationale
/// - **Leverages ScratchpadCache**: No new cache — pre-fetched results live in
///   the same cache the engine already checks, using the same key derivation.
/// - **TTL per entry**: News (8h) and weather (30min) have different freshness needs.
/// - **Graceful degradation**: Pre-fetch failures are logged but never surface errors.
/// - **Cancellation-safe**: The timer task respects `Task.isCancelled`.
public actor PreFetchScheduler {
    public static let shared = PreFetchScheduler()

    private var entries: [PreFetchEntry] = []
    private var timerTask: Task<Void, Never>?

    /// Default refresh interval (30 minutes). Individual entries may have shorter TTLs,
    /// in which case they'll be refreshed on the next sweep after expiry.
    private let defaultInterval: TimeInterval = 1800

    // MARK: - Registration

    /// Registers all pre-fetch entries from a tool.
    public func registerTool(_ tool: any PreFetchable) async {
        let newEntries = await tool.preFetchEntries()
        entries.append(contentsOf: newEntries)
    }

    /// Registers a single pre-fetch entry directly.
    public func register(_ entry: PreFetchEntry) {
        entries.append(entry)
    }

    // MARK: - Lifecycle

    /// Starts the periodic pre-fetch timer. Safe to call multiple times (restarts).
    public func start(interval: TimeInterval? = nil) {
        stop()
        let refreshInterval = interval ?? defaultInterval
        timerTask = Task { [weak self] in
            // Run initial pre-fetch immediately
            await self?.refreshStale()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                guard !Task.isCancelled else { break }
                await self?.refreshStale()
            }
        }
        Log.engine.debug("PreFetchScheduler started with \(self.entries.count) entries, interval \(interval ?? self.defaultInterval)s")
    }

    /// Stops the periodic timer.
    public func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Forces an immediate refresh of all stale entries.
    public func refreshNow() async {
        await refreshStale()
    }

    // MARK: - Refresh

    private func refreshStale() async {
        for entry in entries {
            // Skip if the cache already has a valid (non-expired) entry
            if let existing = await ScratchpadCache.shared.lookup(key: entry.cacheKey) {
                // lookup() returns nil for expired entries, so if we get here it's still valid
                _ = existing
                continue
            }

            do {
                let result = try await entry.fetch()
                guard result.status != .error else {
                    Log.engine.debug("PreFetch '\(entry.label)' returned error, skipping cache store")
                    continue
                }
                let cacheEntry = ScratchpadCache.Entry(
                    toolName: entry.toolName,
                    textSummary: result.text,
                    widgetData: result.widgetData,
                    widgetType: result.outputWidget,
                    isVerifiedData: result.isVerifiedData,
                    ttl: entry.ttl
                )
                await ScratchpadCache.shared.store(key: entry.cacheKey, entry: cacheEntry)
                Log.engine.debug("PreFetch '\(entry.label)' refreshed → \(entry.cacheKey)")
            } catch {
                Log.engine.debug("PreFetch '\(entry.label)' failed: \(error.localizedDescription)")
            }
        }
    }

    /// Current registration count (for testing).
    public var registrationCount: Int { entries.count }
}
