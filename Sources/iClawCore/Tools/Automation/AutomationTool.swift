import Foundation
import os

// MARK: - AutomationTool Arguments

public struct AutomationArgs: ToolArguments {
    public let action: String    // "create" | "list" | "cancel" | "pause" | "resume"
    public let query: String?    // The recurring query text
    public let interval: String? // "every hour", "daily at 8am", etc.
    public let id: Int?          // For cancel/pause/resume by ordinal
}

// MARK: - AutomationTool

/// Creates, lists, pauses, and cancels recurring automations.
///
/// Distinct from AutomateTool (which runs arbitrary AppleScript).
/// Users say things like "check $AAPL every hour" to create automations.
public struct AutomationTool: CoreTool, ExtractableCoreTool, Sendable {
    public typealias Args = AutomationArgs

    public let name = "Automation"
    public let schema = "Create, list, pause, or cancel recurring automated queries."
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(
        description: "Create a recurring automation"
    )

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Automation", fallback: #"{"action":"create|list|cancel|pause|resume","query":"string?","interval":"string?","id":"int?"}"#
    )

    // MARK: - Execution

    public func execute(args: AutomationArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        switch args.action.lowercased() {
        case "list":
            return try await listAutomations()
        case "cancel", "delete":
            return try await cancelAutomation(id: args.id, rawInput: rawInput)
        case "pause":
            return try await toggleAutomation(id: args.id, rawInput: rawInput, activate: false)
        case "resume":
            return try await toggleAutomation(id: args.id, rawInput: rawInput, activate: true)
        default:
            return try await createAutomation(args: args, rawInput: rawInput)
        }
    }

    /// Fallback for chip or raw text input.
    public func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let lower = input.lowercased()
        if lower.contains("list") || lower.contains("show") || lower.contains("my automation") {
            return try await listAutomations()
        }
        if lower.contains("cancel") || lower.contains("delete") || lower.contains("stop") || lower.contains("remove") {
            return try await cancelAutomation(id: nil, rawInput: input)
        }
        if lower.contains("pause") {
            return try await toggleAutomation(id: nil, rawInput: input, activate: false)
        }
        if lower.contains("resume") || lower.contains("unpause") {
            return try await toggleAutomation(id: nil, rawInput: input, activate: true)
        }
        // Default: try to create
        return try await createFromRawInput(input)
    }

    // MARK: - Create

    private func createAutomation(args: AutomationArgs, rawInput: String) async throws -> ToolIO {
        guard let queryText = args.query, !queryText.isEmpty else {
            return ToolIO(text: "What should the automation check? For example: 'check $AAPL every hour'.", status: .error)
        }

        // Parse interval
        let intervalSource = args.interval ?? rawInput
        guard let parsed = IntervalParser.parse(intervalSource) else {
            return ToolIO(text: "I couldn't understand the interval. Try 'every hour', 'daily at 8am', or 'every 30 minutes'.", status: .error)
        }

        // Validate minimum
        guard parsed.intervalSeconds >= AppConfig.minimumAutomationIntervalSeconds else {
            throw AutomationError.invalidInterval
        }

        let label = "\(queryText) \(parsed.displayLabel)"

        // Return confirmation widget — the widget's confirm button saves to DB
        let widgetData = AutomationWidgetData(
            mode: .confirmation(
                query: queryText,
                interval: parsed.displayLabel,
                intervalSeconds: parsed.intervalSeconds,
                nextRun: parsed.nextRunDate
            )
        )

        return ToolIO(
            text: "Automation: \(label). Next run: \(formatDate(parsed.nextRunDate)). Confirm to start.",
            status: .pending,
            outputWidget: "AutomationWidget",
            widgetData: widgetData
        )
    }

    private func createFromRawInput(_ input: String) async throws -> ToolIO {
        // Try to split "check X every Y" into query + interval
        guard let parsed = IntervalParser.parse(input) else {
            return ToolIO(text: "I couldn't understand the interval. Try something like 'check $AAPL every hour'.", status: .error)
        }

        guard parsed.intervalSeconds >= AppConfig.minimumAutomationIntervalSeconds else {
            throw AutomationError.invalidInterval
        }

        // Strip the interval part to get the query
        let queryText = stripIntervalPhrase(from: input)
        guard queryText.count >= 3 else {
            throw AutomationError.queryTooShort
        }

        let label = "\(queryText) \(parsed.displayLabel)"
        let widgetData = AutomationWidgetData(
            mode: .confirmation(
                query: queryText,
                interval: parsed.displayLabel,
                intervalSeconds: parsed.intervalSeconds,
                nextRun: parsed.nextRunDate
            )
        )

        return ToolIO(
            text: "Automation: \(label). Confirm to start.",
            status: .pending,
            outputWidget: "AutomationWidget",
            widgetData: widgetData
        )
    }

    // MARK: - List

    private func listAutomations() async throws -> ToolIO {
        let all = try await ScheduledQueryStore.shared.fetchAll()
        if all.isEmpty {
            return ToolIO(text: "No automations set up yet. Try 'check $AAPL every hour' to create one.", status: .ok)
        }

        let summaries = all.map { q in
            AutomationSummary(
                id: q.id ?? 0,
                label: q.label,
                interval: IntervalParser.formatSeconds(q.intervalSeconds),
                isActive: q.isActive,
                lastResult: q.lastResult,
                nextRun: q.nextRunDate
            )
        }

        let text: String = all.enumerated().map { i, q in
            let status = q.isActive ? "Active" : (q.failureCount >= AppConfig.automationMaxConsecutiveFailures ? "Failed" : "Paused")
            let label = q.label
            let num = i + 1
            return "\(num). " + label + " — " + status
        }.joined(separator: "\n")

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "AutomationWidget",
            widgetData: AutomationWidgetData(mode: .list(automations: summaries))
        )
    }

    // MARK: - Cancel / Toggle

    private func cancelAutomation(id: Int?, rawInput: String) async throws -> ToolIO {
        let all = try await ScheduledQueryStore.shared.fetchAll()
        guard !all.isEmpty else {
            return ToolIO(text: "No automations to cancel.", status: .ok)
        }

        if let targetId = resolveId(id: id, rawInput: rawInput, automations: all) {
            try await ScheduledQueryStore.shared.delete(id: targetId)
            let label = all.first(where: { $0.id == targetId })?.label ?? "Automation"
            return ToolIO(text: "Cancelled: \(label).", status: .ok)
        }

        // Ambiguous — list them
        let text = "Which automation? " + all.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: ", ")
        return ToolIO(text: text, status: .pending)
    }

    private func toggleAutomation(id: Int?, rawInput: String, activate: Bool) async throws -> ToolIO {
        let all = try await ScheduledQueryStore.shared.fetchAll()
        guard !all.isEmpty else {
            return ToolIO(text: "No automations to \(activate ? "resume" : "pause").", status: .ok)
        }

        if let targetId = resolveId(id: id, rawInput: rawInput, automations: all) {
            try await ScheduledQueryStore.shared.toggleActive(id: targetId)
            let label = all.first(where: { $0.id == targetId })?.label ?? "Automation"
            return ToolIO(text: "\(activate ? "Resumed" : "Paused"): \(label).", status: .ok)
        }

        let text = "Which automation? " + all.enumerated().map { "\($0.offset + 1). \($0.element.label)" }.joined(separator: ", ")
        return ToolIO(text: text, status: .pending)
    }

    // MARK: - Helpers

    private func resolveId(id: Int?, rawInput: String, automations: [ScheduledQuery]) -> Int64? {
        // By explicit ID/ordinal
        if let id {
            if id > 0 && id <= automations.count {
                return automations[id - 1].id
            }
            return Int64(id)
        }
        // By keyword match in label
        let lower = rawInput.lowercased()
        let match = automations.first { q in
            lower.contains(q.query.lowercased()) || lower.contains(q.label.lowercased())
        }
        // If only one automation, assume that one
        if automations.count == 1 { return automations[0].id }
        return match?.id
    }

    private func stripIntervalPhrase(from input: String) -> String {
        var text = input
        let patterns = [
            #"every\s+\d+\s*(hours?|minutes?|mins?|days?|hrs?)"#,
            #"every\s+(morning|evening|night|afternoon)"#,
            #"(hourly|daily|weekly)"#,
            #"at\s+\d{1,2}(:\d{2})?\s*(am|pm)?"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        if !Calendar.current.isDateInToday(date) {
            formatter.dateStyle = .short
        }
        return formatter.string(from: date)
    }
}

// MARK: - IntervalParser Extension

extension IntervalParser {
    /// Formats seconds into a human-readable interval string.
    public static func formatSeconds(_ seconds: Int) -> String {
        if seconds >= 86400 {
            let days = seconds / 86400
            return days == 1 ? "Daily" : "Every \(days) days"
        } else if seconds >= 3600 {
            let hours = seconds / 3600
            return hours == 1 ? "Hourly" : "Every \(hours)h"
        } else {
            let minutes = seconds / 60
            return "Every \(minutes)m"
        }
    }
}
