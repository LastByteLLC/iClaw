import Foundation
import EventKit
import os

/// Manages the periodic heartbeat that performs maintenance and proactive actions.
///
/// Two categories of heartbeat work:
/// - **Maintenance**: Memory compaction (runs every heartbeat)
/// - **Proactive**: Calendar awareness, weather alerts (runs via LLM, surfaces results when HUD opens)
///
/// Results from proactive actions are queued and delivered to the chat when the user next opens the HUD.
public actor HeartbeatManager {
    public static let shared = HeartbeatManager()

    /// Pending proactive results to show when the HUD opens.
    public struct ProactiveResult: Sendable {
        public let text: String
        public let widgetType: String?
        public let widgetData: (any Sendable)?
        public let source: String // e.g., "calendar", "weather"
    }

    private let db: DatabaseManager
    private let scheduledQueryStore: ScheduledQueryStore

    private var pendingResults: [ProactiveResult] = []

    public init(db: DatabaseManager = .shared, scheduledQueryStore: ScheduledQueryStore = .shared) {
        self.db = db
        self.scheduledQueryStore = scheduledQueryStore
    }

    /// Track which alerts we've already queued to prevent duplicates.
    /// Cleared when results are drained (user saw them).
    private var queuedAlertKeys: Set<String> = []

    /// Track event IDs we've already alerted on this session.
    private var alertedEventHashes: Set<String> = []

    /// Returns and clears any pending proactive results.
    public func drainResults() -> [ProactiveResult] {
        let results = pendingResults
        pendingResults = []
        queuedAlertKeys = []
        return results
    }

    /// Cap on pending results to prevent unbounded growth.
    private static let maxPendingResults = 5

    /// Allows external systems (NotificationEngine) to queue proactive results.
    public func queueProactiveResult(_ result: ProactiveResult) {
        guard pendingResults.count < Self.maxPendingResults else { return }
        pendingResults.append(result)
    }

    // MARK: - Heartbeat Execution

    /// Runs all heartbeat actions: maintenance + proactive + automations.
    public func runHeartbeat() async {
        Log.engine.debug("Heartbeat running...")

        // 1a. Maintenance: memory compaction
        do {
            try await db.compactMemoriesIfNeeded()
        } catch {
            Log.engine.error("Heartbeat compaction error: \(error)")
        }

        // 1b. Maintenance: knowledge memory consolidation
        if UserDefaults.standard.bool(forKey: AppConfig.knowledgeMemoryEnabledKey) {
            await KnowledgeMemoryManager.shared.consolidateIfNeeded()
        }

        // 1c. Maintenance: opportunistic phrase generation
        await PhraseGenerator.shared.generateIfNeeded(adapter: LLMAdapter.shared)

        // Skip proactive checks if we already have enough queued results
        guard pendingResults.count < Self.maxPendingResults else {
            Log.engine.debug("Heartbeat complete. Skipping proactive checks — \(self.pendingResults.count) results already queued.")
            return
        }

        // 2. Proactive: calendar awareness
        await checkUpcomingEvents()

        // 3. Proactive: weather shift detection
        await checkWeatherShift()

        // 4. Scheduled automations
        await executeOverdueAutomations()

        let count = pendingResults.count
        Log.engine.debug("Heartbeat complete. \(count) proactive result(s) queued.")
    }

    // MARK: - Scheduled Automations

    /// Executes automations that are past their nextRunDate.
    private func executeOverdueAutomations() async {
        let due: [ScheduledQuery]
        do {
            due = try await scheduledQueryStore.fetchDue()
        } catch {
            Log.engine.debug("Heartbeat automation fetch failed: \(error)")
            return
        }

        guard !due.isEmpty else { return }

        // Execute up to N per heartbeat to avoid blocking
        for query in due.prefix(AppConfig.automationMaxPerHeartbeat) {
            guard let queryId = query.id else { continue }

            // Catch-up: if >2 intervals overdue, skip to next future occurrence
            let now = Date()
            let overdueBy = now.timeIntervalSince(query.nextRunDate)
            if overdueBy > Double(query.intervalSeconds * 2) {
                let nextRun = now.addingTimeInterval(Double(query.intervalSeconds))
                do {
                    try await scheduledQueryStore.recordExecution(
                        id: queryId,
                        result: "(skipped — app was not running)",
                        nextRunDate: nextRun
                    )
                } catch {
                    Log.engine.debug("Automation skip recording failed for \(queryId): \(error)")
                }
                continue
            }

            // Route and execute the tool
            do {
                let result = await executeAutomationQuery(query)
                let nextRun = Date().addingTimeInterval(Double(query.intervalSeconds))
                try await scheduledQueryStore.recordExecution(
                    id: queryId,
                    result: result,
                    nextRunDate: nextRun
                )

                // Deliver via NotificationEngine
                await NotificationEngine.shared.deliver(
                    title: query.label,
                    body: result,
                    source: "automation",
                    sourceId: queryId
                )

                Log.engine.debug("Automation '\(query.label)' executed: \(result.prefix(80))")
            } catch {
                do {
                    try await scheduledQueryStore.recordFailure(id: queryId)
                } catch let recordError {
                    Log.engine.debug("Automation failure recording failed: \(recordError)")
                }
                Log.engine.debug("Automation '\(query.label)' failed: \(error)")
            }
        }
    }

    /// Executes a single automation query by routing to the appropriate tool.
    private func executeAutomationQuery(_ query: ScheduledQuery) async -> String {
        // If we know the tool name, use it directly
        if let toolName = query.toolName,
           let tool = ToolRegistry.coreTools.first(where: { $0.name == toolName }) {
            do {
                let result = try await tool.execute(input: query.query, entities: nil)
                return result.text
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }

        // Otherwise, run through the full engine (skip consent — user approved when creating the automation)
        let result = await ExecutionEngine.shared.run(input: query.query, skipConsent: true)
        return result.text
    }

    // MARK: - Calendar Awareness

    /// Checks for events starting within the next 30 minutes and queues an alert.
    /// Deduplicates by event content hash so the same event isn't alerted multiple times.
    /// Skipped entirely if the user hasn't already granted calendar access.
    private func checkUpcomingEvents() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            Log.engine.debug("Heartbeat: skipping calendar check — not yet authorized (\(String(describing: status)))")
            return
        }

        let tool = CalendarTool()
        do {
            let result = try await tool.execute(input: "events in the next 30 minutes", entities: nil)
            guard result.status == .ok else { return }

            // Only surface if there are actual events (not "no events")
            let lower = result.text.lowercased()
            if lower.contains("no event") || lower.contains("no upcoming") || lower.contains("nothing") || result.text.count < 20 {
                return
            }

            // Deduplicate: hash the event text to avoid re-alerting the same event
            let eventHash = "calendar:\(result.text.prefix(100))"
            guard !alertedEventHashes.contains(eventHash) else { return }
            alertedEventHashes.insert(eventHash)

            pendingResults.append(ProactiveResult(
                text: result.text,
                widgetType: result.outputWidget,
                widgetData: result.widgetData,
                source: "calendar"
            ))
        } catch {
            Log.engine.debug("Heartbeat calendar check failed: \(error)")
        }
    }

    // MARK: - Weather Shift Detection

    /// Checks if current weather conditions have changed significantly since last check.
    /// Only surfaces an alert for notable changes (rain starting, temperature drop >10°, etc.)
    /// Each shift type (rain, snow, temp) is only alerted once until results are drained.
    private func checkWeatherShift() async {
        let tool = WeatherTool()
        do {
            let result = try await tool.execute(input: "current weather", entities: nil)
            guard result.status == .ok else { return }

            // Compare with last known weather
            let current = result.text
            let lastWeather = lastWeatherSnapshot

            if let last = lastWeather {
                let alert = detectWeatherShift(previous: last, current: current)
                if let alert {
                    // Deduplicate: only queue each alert type once
                    let alertKey = "weather:\(alert.prefix(30))"
                    if !queuedAlertKeys.contains(alertKey) {
                        queuedAlertKeys.insert(alertKey)
                        pendingResults.append(ProactiveResult(
                            text: alert,
                            widgetType: nil,
                            widgetData: nil,
                            source: "weather"
                        ))
                    }
                }
            }

            lastWeatherSnapshot = current
        } catch {
            Log.engine.debug("Heartbeat weather check failed: \(error)")
        }
    }

    /// Persists across heartbeats within the actor.
    private var lastWeatherSnapshot: String?

    /// Simple heuristic: detect significant weather changes between snapshots.
    private func detectWeatherShift(previous: String, current: String) -> String? {
        let prevLower = previous.lowercased()
        let currLower = current.lowercased()

        // Rain starting
        let rainWords = ["rain", "shower", "drizzle", "thunderstorm", "storm"]
        let prevHasRain = rainWords.contains { prevLower.contains($0) }
        let currHasRain = rainWords.contains { currLower.contains($0) }

        if !prevHasRain && currHasRain {
            return "Weather alert: Rain has started in your area."
        }

        // Snow starting
        if !prevLower.contains("snow") && currLower.contains("snow") {
            return "Weather alert: Snow has started in your area."
        }

        // Temperature extraction and comparison
        if let prevTemp = extractTemperature(from: previous),
           let currTemp = extractTemperature(from: current) {
            let delta = currTemp - prevTemp
            if delta <= -10 {
                return "Weather alert: Temperature dropped \(Int(abs(delta)))° since last check."
            }
            if delta >= 10 {
                return "Weather alert: Temperature rose \(Int(delta))° since last check."
            }
        }

        return nil
    }

    /// Extracts the first temperature value from a weather string (e.g., "38°F" → 38).
    private func extractTemperature(from text: String) -> Double? {
        let pattern = #"(-?\d+(?:\.\d+)?)\s*°"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }
}
