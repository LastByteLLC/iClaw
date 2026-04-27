import Foundation
import iClawCore
import OSLog

/// Focused stress test for follow-up detection accuracy.
///
/// Generates multi-turn conversation scenarios via an external LLM, executes them
/// through the real engine, evaluates whether follow-ups, pivots, and refinements
/// are correctly detected, and produces a detailed metrics report.
///
/// Usage:
/// - **GUI**: Select "Follow-Up" mode in the stress test app
/// - **CLI**: `make stress-test` then select Follow-Up mode, or use the
///   `FollowUpStressRunner` API directly
@Observable
public final class FollowUpStressRunner: @unchecked Sendable {

    // MARK: - Output Types

    public struct TurnResult: Codable, Sendable {
        public let turnIndex: Int
        public let input: String
        public let expectedRelation: String  // continuation, refinement, drill_down, pivot, meta
        public let expectedTool: String
        // Routing accuracy: what tool did the router select?
        public let routedToolName: String
        // Execution result: what widget did the tool produce?
        public let actualWidgetType: String?
        public let responseSnippet: String
        public let isError: Bool
        public let routedCorrectly: Bool    // Was the RIGHT tool selected?
        public let executedCorrectly: Bool  // Did the tool succeed (no error/timeout)?
        public let durationMs: Int
    }

    public struct ConversationResult: Codable, Sendable {
        public let id: Int
        public let turns: [TurnResult]
        public let correctRouting: Int
        public let correctExecution: Int
        public let totalTurns: Int
    }

    public struct FollowUpReport: Codable, Sendable {
        public let date: String
        public let totalConversations: Int
        public let totalTurns: Int
        public let totalTurnPairs: Int
        // Routing accuracy — was the correct tool selected?
        public let routingAccuracy: Double
        public let continuationRoutingAccuracy: Double
        public let refinementRoutingAccuracy: Double
        public let drillDownRoutingAccuracy: Double
        public let pivotRoutingAccuracy: Double
        public let metaRoutingAccuracy: Double
        // Execution accuracy — did the tool succeed?
        public let executionAccuracy: Double
        public let overallAccuracy: Double
        public let avgDurationMs: Int
        public let conversations: [ConversationResult]
        public let providerName: String
        public let modelName: String
    }

    // MARK: - State

    public var phase: StressPhase = .idle
    public var isRunning = false
    public var totalTarget = 0
    public var completedCount = 0
    public var currentItem: String = ""
    public var report: FollowUpReport?

    public enum StressPhase: String, Sendable {
        case idle, generating, executing, synthesizing, done, failed
    }

    private var provider: (any LLMProvider)?
    private var modelOption: ModelOption?
    private let log = Logger(subsystem: "com.geticlaw.iClaw.stress", category: "followup")
    private let outputDir: String

    public init() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        self.outputDir = "/tmp/iclaw_followup_stress/\(timestamp)"
    }

    // MARK: - Control

    func start(conversationCount: Int, provider: any LLMProvider, modelOption: ModelOption) {
        guard !isRunning else { return }
        self.provider = provider
        self.modelOption = modelOption
        isRunning = true
        totalTarget = conversationCount

        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
                let result = await runPipeline(count: conversationCount)
                self.report = result
                phase = .done
            } catch {
                log.error("Follow-up stress test failed: \(error)")
                phase = .failed
            }
            isRunning = false
        }
    }

    // MARK: - Pipeline

    private func runPipeline(count: Int) async -> FollowUpReport {
        // Phase 1: Generate conversation scenarios
        phase = .generating
        currentItem = "Generating \(count) conversation scenarios..."
        let scenarios = await generateScenarios(count: count)

        // Phase 2: Execute through real engine
        phase = .executing
        let results = await executeScenarios(scenarios)

        // Phase 3: Synthesize report
        phase = .synthesizing
        let report = synthesize(results: results)

        // Write output
        writeJSON(report, to: "report.json")
        writeMarkdown(report)

        return report
    }

    // MARK: - Scenario Generation

    struct Scenario: Sendable {
        let id: Int
        let turns: [(input: String, expectedRelation: String, expectedTool: String)]
    }

    private func generateScenarios(count: Int) async -> [Scenario] {
        guard let provider else { return generateBuiltInScenarios() }

        var scenarios: [Scenario] = []
        let batchSize = 5
        var nextId = 0

        for batchStart in stride(from: 0, to: count, by: batchSize) {
            let thisBatch = min(batchSize, count - batchStart)
            currentItem = "Generating scenarios \(batchStart + 1)-\(batchStart + thisBatch)..."

            // Track which starting tools have been used to enforce diversity
            let usedStarts = Set(scenarios.map { $0.turns.first?.expectedTool ?? "" })
            let avoidList = usedStarts.isEmpty ? "" : "\nDo NOT start any scenario with: \(usedStarts.joined(separator: ", ")). Use different tools."

            let prompt = """
            Generate exactly \(thisBatch) UNIQUE multi-turn conversation test scenarios for a macOS voice assistant.
            Each scenario has 3-5 turns. EVERY scenario must start with a DIFFERENT tool — no two scenarios should begin the same way.

            For each turn specify: the user's input, the expected turn relation, and the expected tool.

            Relations: continuation (same tool, new param), refinement (same tool, adjust/correct), drill_down (detail on result), pivot (new topic), meta (about the system)

            Tools: weather, stocks, timer, calculator, translate, news, maps, convert, time, podcast, random, calendar, dictionary, reminders, contacts, system

            Rules:
            - First turn is always "pivot" (new conversation)
            - Use realistic, varied natural language — no two scenarios should use the same phrasing
            - Each scenario must use at LEAST 2 different tools (via pivots)
            - Include at least one follow-up pattern per scenario (continuation, refinement, or drill_down)
            \(avoidList)

            Format:
            ---
            relation|tool|user input
            relation|tool|user input
            ---
            relation|tool|user input
            ...

            Generate \(thisBatch) diverse scenarios now:
            """

            do {
                let response = try await provider.generateText(prompt)
                let parsed = parseScenarios(response.text, startId: nextId)
                scenarios.append(contentsOf: parsed)
                nextId += parsed.count
                completedCount = scenarios.count
            } catch {
                log.error("Scenario generation failed: \(error)")
            }
        }

        // If LLM generation produced too few, pad with built-in scenarios
        if scenarios.count < count {
            let builtIn = generateBuiltInScenarios()
            let needed = count - scenarios.count
            for scenario in builtIn.prefix(needed) {
                scenarios.append(Scenario(
                    id: nextId,
                    turns: scenario.turns
                ))
                nextId += 1
            }
        }

        return scenarios
    }

    private func parseScenarios(_ raw: String, startId: Int) -> [Scenario] {
        var scenarios: [Scenario] = []
        var currentTurns: [(input: String, expectedRelation: String, expectedTool: String)] = []
        var nextId = startId

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !currentTurns.isEmpty {
                    scenarios.append(Scenario(id: nextId, turns: currentTurns))
                    nextId += 1
                    currentTurns = []
                }
                continue
            }

            let parts = trimmed.split(separator: "|", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let relation = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
            let tool = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
            let input = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty else { continue }

            let validRelations = ["continuation", "refinement", "drill_down", "pivot", "meta"]
            guard validRelations.contains(relation) else { continue }

            currentTurns.append((input: input, expectedRelation: relation, expectedTool: tool))
        }

        if !currentTurns.isEmpty {
            scenarios.append(Scenario(id: nextId, turns: currentTurns))
        }

        return scenarios
    }

    /// Built-in scenarios that don't require an LLM provider.
    private func generateBuiltInScenarios() -> [Scenario] {
        [
            Scenario(id: 0, turns: [
                ("what's the weather in Paris", "pivot", "weather"),
                ("and London?", "continuation", "weather"),
                ("in celsius", "refinement", "weather"),
                ("set a timer for 5 minutes", "pivot", "timer"),
                ("why did you use that tool", "meta", "meta"),
            ]),
            Scenario(id: 1, turns: [
                ("AAPL stock price", "pivot", "stocks"),
                ("and TSLA?", "continuation", "stocks"),
                ("check my email", "pivot", "email"),
                ("from John", "continuation", "email"),
            ]),
            Scenario(id: 2, turns: [
                ("latest tech news", "pivot", "news"),
                ("read the first one", "drill_down", "news"),
                ("what about sports?", "continuation", "news"),
                ("translate hello to French", "pivot", "translate"),
                ("and Spanish?", "continuation", "translate"),
            ]),
            Scenario(id: 3, turns: [
                ("directions to the airport", "pivot", "maps"),
                ("by walking instead", "refinement", "maps"),
                ("define serendipity", "pivot", "dictionary"),
                ("how does that work", "meta", "meta"),
            ]),
            Scenario(id: 4, turns: [
                ("convert 10 miles to km", "pivot", "convert"),
                ("the other way around", "refinement", "convert"),
                ("roll a dice", "pivot", "random"),
                ("again", "continuation", "random"),
                ("what time is it in Tokyo", "pivot", "time"),
                ("and London?", "continuation", "time"),
            ]),
            Scenario(id: 5, turns: [
                ("weather forecast this weekend", "pivot", "weather"),
                ("tomorrow?", "continuation", "weather"),
                ("just the temperature", "refinement", "weather"),
                ("what about the wind specifically", "drill_down", "weather"),
                ("is that accurate", "meta", "meta"),
            ]),
            Scenario(id: 6, turns: [
                ("research quantum computing", "pivot", "search"),
                ("tell me more about that", "drill_down", "search"),
                ("open Safari", "pivot", "system"),
                ("what tools do you have", "meta", "meta"),
            ]),
            Scenario(id: 7, turns: [
                ("podcast about history", "pivot", "podcast"),
                ("what about science?", "continuation", "podcast"),
                ("translate hello to French", "pivot", "translate"),
                ("and Spanish?", "continuation", "translate"),
                ("define serendipity", "pivot", "dictionary"),
            ]),
            // Scenarios targeting known failure patterns:
            Scenario(id: 8, turns: [
                ("what's the weather in Berlin", "pivot", "weather"),
                ("in celsius", "refinement", "weather"),
                ("tomorrow?", "continuation", "weather"),
                ("find nearby coffee shops", "pivot", "maps"),
            ]),
            Scenario(id: 9, turns: [
                ("show me the stock price for AAPL", "pivot", "stocks"),
                ("$TSLA", "continuation", "stocks"),
                ("why that tool?", "meta", "meta"),
                ("set a timer for 10 minutes", "pivot", "timer"),
                ("add 5 more minutes", "continuation", "timer"),
            ]),
            Scenario(id: 10, turns: [
                ("give me the latest headlines", "pivot", "news"),
                ("the first one", "drill_down", "news"),
                ("find the nearest restaurant", "pivot", "maps"),
                ("in Fahrenheit", "meta", "meta"),
            ]),
            Scenario(id: 11, turns: [
                ("convert 100 dollars to euros", "pivot", "convert"),
                ("using today's rate", "refinement", "convert"),
                ("what's the weather in New York", "pivot", "weather"),
                ("and Boston?", "continuation", "weather"),
                ("in Fahrenheit", "refinement", "weather"),
                ("tomorrow?", "continuation", "weather"),
            ]),
            Scenario(id: 12, turns: [
                ("what's the forecast for Paris", "pivot", "weather"),
                ("Berlin", "continuation", "weather"),
                ("today?", "continuation", "weather"),
                ("next week?", "continuation", "weather"),
                ("check the price of MSFT", "pivot", "stocks"),
                ("and TSLA?", "continuation", "stocks"),
            ]),
            Scenario(id: 13, turns: [
                ("latest news", "pivot", "news"),
                ("tell me about the first one", "drill_down", "news"),
                ("translate that to Spanish", "pivot", "translate"),
                ("and French?", "continuation", "translate"),
                ("remind me to call John at 3 PM", "pivot", "calendar"),
            ]),
        ]
    }

    // MARK: - Execution

    private func executeScenarios(_ scenarios: [Scenario]) async -> [ConversationResult] {
        var results: [ConversationResult] = []
        // Overall timeout: 3 minutes prevents the test from running indefinitely
        // when network calls stall or the LLM session hangs.
        let overallDeadline = Date().addingTimeInterval(180)

        for (i, scenario) in scenarios.enumerated() {
            guard Date() < overallDeadline else {
                log.warning("Overall timeout reached after \(i)/\(scenarios.count) conversations")
                break
            }

            currentItem = "Conversation \(i + 1)/\(scenarios.count)"

            // Filter out tools that hang without system configuration:
            // - Email/ReadEmail: hang if Mail.app isn't set up
            // - Transcribe: hangs without microphone permission
            let blockedTools: Set<String> = ["Email", "ReadEmail", "Transcribe"]
            let safeTools = ToolRegistry.coreTools.filter { !blockedTools.contains($0.name) }

            let engine = ExecutionEngine(
                preprocessor: InputPreprocessor(),
                router: ToolRouter(
                    availableTools: safeTools,
                    fmTools: []
                ),
                conversationManager: ConversationManager(),
                finalizer: OutputFinalizer(),
                planner: ExecutionPlanner()
            )

            var turnResults: [TurnResult] = []
            var routingCorrect = 0
            var executionCorrect = 0

            for (turnIdx, turn) in scenario.turns.enumerated() {
                let start = Date()

                // 10-second timeout per turn — keeps the stress test responsive.
                let turnResult: (String, String?, (any Sendable)?, Bool, [String]?)
                do {
                    turnResult = try await withThrowingTaskGroup(of: (String, String?, (any Sendable)?, Bool, [String]?).self) { group in
                        group.addTask {
                            await engine.run(input: turn.input)
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(10))
                            throw CancellationError()
                        }
                        let result = try await group.next()!
                        group.cancelAll()
                        return result
                    }
                } catch {
                    turnResult = ("Timed out after 10 seconds", nil, nil, true, nil)
                    log.warning("Turn \(turnIdx) timed out: \(turn.input)")
                }

                let (response, wType, _, isError, _) = turnResult
                let duration = Int(Date().timeIntervalSince(start) * 1000)

                // Get the routed tool name directly from the engine (not widget type)
                let routedNames = await engine.lastRoutedToolNames
                let routedName = routedNames.first?.lowercased() ?? "unknown"

                // Evaluate ROUTING: did the router pick the right tool?
                let expectedLower = turn.expectedTool.lowercased()
                let routedCorrectly: Bool
                if turn.expectedRelation == "meta" {
                    routedCorrectly = routedName == "conversational"
                } else {
                    // Normalize tool names for comparison (e.g., "stocks" matches "StockTool")
                    let priorTool = turnIdx > 0 ? scenario.turns[turnIdx - 1].expectedTool.lowercased() : ""
                    let routedNorm = routedName.replacingOccurrences(of: "tool", with: "")
                        .replacingOccurrences(of: "core", with: "")
                    routedCorrectly = routedNorm.contains(expectedLower)
                        || expectedLower.contains(routedNorm)
                        || (turn.expectedRelation != "pivot" && turnIdx > 0
                            && (routedNorm.contains(priorTool) || priorTool.contains(routedNorm)))
                }

                // Evaluate EXECUTION: did the tool complete without error?
                let executedOK = !isError

                if routedCorrectly { routingCorrect += 1 }
                if executedOK { executionCorrect += 1 }

                turnResults.append(TurnResult(
                    turnIndex: turnIdx,
                    input: turn.input,
                    expectedRelation: turn.expectedRelation,
                    expectedTool: turn.expectedTool,
                    routedToolName: routedNames.first ?? "unknown",
                    actualWidgetType: wType,
                    responseSnippet: String(response.prefix(200)),
                    isError: isError,
                    routedCorrectly: routedCorrectly,
                    executedCorrectly: executedOK,
                    durationMs: duration
                ))
            }

            results.append(ConversationResult(
                id: scenario.id,
                turns: turnResults,
                correctRouting: routingCorrect,
                correctExecution: executionCorrect,
                totalTurns: turnResults.count
            ))
            completedCount = i + 1
        }

        return results
    }

    // MARK: - Synthesis

    private func synthesize(results: [ConversationResult]) -> FollowUpReport {
        let allTurns = results.flatMap(\.turns)
        let totalPairs = allTurns.filter { $0.turnIndex > 0 }.count

        func routingAccuracyFor(_ relation: String) -> Double {
            let relevant = allTurns.filter { $0.expectedRelation == relation && $0.turnIndex > 0 }
            guard !relevant.isEmpty else { return 1.0 }
            let correct = relevant.filter(\.routedCorrectly).count
            return Double(correct) / Double(relevant.count)
        }

        let totalRouted = results.reduce(0) { $0 + $1.correctRouting }
        let totalExecuted = results.reduce(0) { $0 + $1.correctExecution }
        let totalTurns = results.reduce(0) { $0 + $1.totalTurns }
        let routingAcc = totalTurns > 0 ? Double(totalRouted) / Double(totalTurns) : 0
        let execAcc = totalTurns > 0 ? Double(totalExecuted) / Double(totalTurns) : 0
        let overallAcc = totalTurns > 0 ? Double(min(totalRouted, totalExecuted)) / Double(totalTurns) : 0
        let avgDuration = allTurns.isEmpty ? 0 : allTurns.reduce(0) { $0 + $1.durationMs } / allTurns.count

        return FollowUpReport(
            date: ISO8601DateFormatter().string(from: Date()),
            totalConversations: results.count,
            totalTurns: totalTurns,
            totalTurnPairs: totalPairs,
            routingAccuracy: routingAcc,
            continuationRoutingAccuracy: routingAccuracyFor("continuation"),
            refinementRoutingAccuracy: routingAccuracyFor("refinement"),
            drillDownRoutingAccuracy: routingAccuracyFor("drill_down"),
            pivotRoutingAccuracy: routingAccuracyFor("pivot"),
            metaRoutingAccuracy: routingAccuracyFor("meta"),
            executionAccuracy: execAcc,
            overallAccuracy: overallAcc,
            avgDurationMs: avgDuration,
            conversations: results,
            providerName: provider?.displayName ?? "Built-in",
            modelName: modelOption?.name ?? "N/A"
        )
    }

    // MARK: - Output

    private func writeJSON<T: Encodable>(_ value: T, to filename: String) {
        let dir = outputDir
        writeJSONFile(value, to: filename, in: dir)
        log.info("Wrote \(dir)/\(filename)")
    }

    private func writeMarkdown(_ report: FollowUpReport) {
        var md = "# Follow-Up Stress Test Report\n\n"
        md += "**Date:** \(report.date)\n"
        md += "**Provider:** \(report.providerName) (\(report.modelName))\n\n"

        md += "## Summary\n"
        md += "| Metric | Value |\n|--------|-------|\n"
        md += "| Conversations | \(report.totalConversations) |\n"
        md += "| Total Turns | \(report.totalTurns) |\n"
        md += "| Turn Pairs | \(report.totalTurnPairs) |\n"
        md += "| **Routing Accuracy** | **\(String(format: "%.1f", report.routingAccuracy * 100))%** |\n"
        md += "| Execution Accuracy | \(String(format: "%.1f", report.executionAccuracy * 100))% |\n"
        md += "| Overall Accuracy | \(String(format: "%.1f", report.overallAccuracy * 100))% |\n"
        md += "| Avg Duration | \(report.avgDurationMs)ms |\n\n"

        md += "## Per-Relation Routing Accuracy\n"
        md += "| Relation | Routing |\n|----------|----------|\n"
        md += "| Continuation | \(String(format: "%.1f", report.continuationRoutingAccuracy * 100))% |\n"
        md += "| Refinement | \(String(format: "%.1f", report.refinementRoutingAccuracy * 100))% |\n"
        md += "| Drill-Down | \(String(format: "%.1f", report.drillDownRoutingAccuracy * 100))% |\n"
        md += "| Pivot | \(String(format: "%.1f", report.pivotRoutingAccuracy * 100))% |\n"
        md += "| Meta | \(String(format: "%.1f", report.metaRoutingAccuracy * 100))% |\n\n"

        md += "## Conversations\n\n"
        for conv in report.conversations {
            let routePct = conv.totalTurns > 0 ? Double(conv.correctRouting) / Double(conv.totalTurns) * 100 : 0
            md += "### Conversation \(conv.id) (routing: \(String(format: "%.0f", routePct))%)\n"
            for turn in conv.turns {
                let routeIcon = turn.routedCorrectly ? "R" : "!R"
                let execIcon = turn.executedCorrectly ? "OK" : "ERR"
                md += "- [\(routeIcon)|\(execIcon)] **\(turn.expectedRelation)** → `\(turn.input)` (expected: \(turn.expectedTool), routed: \(turn.routedToolName), widget: \(turn.actualWidgetType ?? "none"))\n"
            }
            md += "\n"
        }

        let path = "\(outputDir)/report.md"
        try? md.write(toFile: path, atomically: true, encoding: .utf8)
        log.info("Wrote \(path)")
    }
}
