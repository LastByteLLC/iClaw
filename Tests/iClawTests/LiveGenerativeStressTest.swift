import XCTest
import Foundation
import FoundationModels
import os
@testable import iClawCore

// MARK: - Live Generative Stress Test

/// Uses on-device Apple Intelligence to generate novel, unpredictable prompts and runs them
/// through the REAL execution pipeline with REAL tools. An LLM judge evaluates each response
/// for correctness and clarity. Designed for ad-hoc runs only — not CI.
///
/// Unlike MadLibsStressTest (template-based), this generates truly novel prompts via LLM,
/// probing edge cases that templates can't anticipate.
///
/// Safety: Side-effect tools (Email, Create, Messages, Reminders, etc.) are replaced with spy
/// variants to prevent sending real messages/emails during testing.
///
/// Run:
///   swift test --filter iClawTests.LiveGenerativeStressTest/testLiveGenerative
///   STRESS_PROMPT_COUNT=200 swift test --filter iClawTests.LiveGenerativeStressTest
final class LiveGenerativeStressTest: XCTestCase {

    // MARK: - Configuration

    /// Total prompts to generate and execute. Override via environment: STRESS_PROMPT_COUNT=200
    static var promptCount: Int {
        if let env = ProcessInfo.processInfo.environment["STRESS_PROMPT_COUNT"],
           let count = Int(env) {
            return count
        }
        return 1000
    }

    /// Prompts generated per LLM call (kept small for on-device model context window).
    static let generationBatchSize = 10

    /// Prompts judged per LLM call.
    static let judgingBatchSize = 5

    /// Per-prompt execution timeout in seconds.
    static let promptTimeoutSeconds: UInt64 = 30

    /// Max consecutive generation failures before aborting prompt generation.
    static let maxConsecutiveFailures = 10

    /// Output base directory. Each run gets a timestamped subdirectory.
    static let outputBaseDir = "/tmp/iclaw_live_stress"

    // MARK: - Data Types

    struct GeneratedPrompt: Codable, Sendable {
        let text: String
        let category: String
        let difficulty: String  // easy, medium, hard, adversarial
    }

    struct PromptResult: Codable, Sendable {
        let index: Int
        let prompt: GeneratedPrompt
        let responseText: String
        let widgetType: String?
        let isError: Bool
        let timedOut: Bool
        let durationMs: Int
        var judgement: Judgement?
    }

    struct Judgement: Codable, Sendable {
        let routingScore: Int       // 1-5: did the right tool handle this?
        let clarityScore: Int       // 1-5: is the response clear and helpful?
        let overallScore: Int       // 1-5: overall quality
        let issues: [String]        // specific problems found
    }

    struct StressReport: Codable, Sendable {
        let date: String
        let totalPrompts: Int
        let totalErrors: Int
        let totalTimeouts: Int
        let totalElapsedSeconds: Int
        let avgDurationMs: Int
        let maxDurationMs: Int
        let avgRoutingScore: Double
        let avgClarityScore: Double
        let avgOverallScore: Double
        let unjudgedCount: Int
        let categoryBreakdown: [CategoryStats]
        let worstResults: [PromptResult]    // bottom 20 by overall score
        let issueFrequency: [String: Int]   // issue description → count
        let llmSynthesis: String            // LLM-generated gap analysis
    }

    struct CategoryStats: Codable, Sendable {
        let category: String
        let count: Int
        let avgRouting: Double
        let avgClarity: Double
        let avgOverall: Double
        let errorCount: Int
    }

    /// Sendable wrapper for engine.run() result, used for timeout racing.
    private struct EngineResult: Sendable {
        let text: String
        let widgetType: String?
        let isError: Bool
    }

    private struct PromptTimeoutError: Error {}

    // MARK: - Tool Descriptions for Prompt Generation

    // Compact tool list — fits within on-device model context window
    static let toolCategories = """
Core tools: Weather, Calculator, Convert (units/currency), Time, Timer, Maps, \
Translate, Stocks, News, Dictionary, Random (coin/dice), Email, ReadEmail, \
WebFetch, Podcast, Research, Create (images), Game (2048/Wordle/Sokoban/Sudoku), \
SystemInfo, Calendar, Read, Write, Rewrite, Transcribe, Today, Feedback.
FM tools: Calendar Events, Contacts, Notes, Reminders, Messages, Shortcuts, \
Spotlight, Wikipedia.
"""

    // MARK: - Safe Tool Lists

    /// CoreTools replaced with spies to prevent side effects.
    /// Email opens mailto: (disruptive), Create runs slow image generation.
    private static let sideEffectCoreToolNames: Set<String> = ["Email", "Create"]

    /// FM tools excluded to prevent real side effects (sending messages, creating events, etc.).
    private static let sideEffectFMToolNames: Set<String> = [
        "Messages", "Reminders", "Calendar Events", "Notes",
        "Shortcuts", "System Control", "App Manager", "Camera"
    ]

    /// Real tools for safe ones, spy replacements for dangerous ones.
    private static func buildSafeToolLists() -> (core: [any CoreTool], fm: [any FMToolDescriptor]) {
        var coreTools: [any CoreTool] = ToolRegistry.coreTools.filter {
            !sideEffectCoreToolNames.contains($0.name)
        }
        // Add spy replacements so prompts targeting these tools still route correctly
        for name in sideEffectCoreToolNames {
            let original = ToolRegistry.coreTools.first { $0.name == name }
            coreTools.append(SpyTool(
                name: name,
                schema: original?.schema ?? "\(name) tool.",
                category: original?.category ?? .offline,
                result: ToolIO(text: "[Spy: \(name) would execute here]", status: .ok)
            ))
        }

        let fmTools = ToolRegistry.fmTools.filter {
            !sideEffectFMToolNames.contains($0.name)
        }

        return (coreTools, fmTools)
    }

    // MARK: - Main Test

    /// This test requires Apple Intelligence and runs 1000+ prompts through the real engine.
    /// It hangs in CI and standard `swift test` runs. Run explicitly:
    ///   swift test --filter iClawTests.LiveGenerativeStressTest/testLiveGenerative
    func testLiveGenerative() async throws {
        // Skip in standard test runs — this test hangs without Apple Intelligence
        // and takes 10+ minutes even when available.
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_LIVE_STRESS"] == "1",
            "Live generative stress test skipped. Set RUN_LIVE_STRESS=1 to run."
        )
        try require(.appleIntelligence)

        let testStart = DispatchTime.now()
        let count = Self.promptCount
        let log = Logger(subsystem: "com.geticlaw.iClaw.stress", category: "live")
        log.info("Starting live generative stress test with \(count) prompts")

        // Timestamped output directory — won't overwrite previous runs
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let outputDir = "\(Self.outputBaseDir)/\(timestamp)"
        try FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true
        )

        // Reset caches to avoid stale state from prior test runs
        await ScratchpadCache.shared.reset()

        // Phase 1: Generate prompts
        log.info("Phase 1: Generating \(count) prompts via LLM...")
        let prompts = try await generatePrompts(count: count, log: log)
        log.info("Generated \(prompts.count) prompts")

        let promptsJSON = try JSONEncoder.prettyEncoder.encode(prompts)
        try promptsJSON.write(to: URL(fileURLWithPath: "\(outputDir)/prompts.json"))

        // Phase 2: Execute through real pipeline
        log.info("Phase 2: Executing \(prompts.count) prompts through real pipeline...")
        var results = try await executePrompts(prompts, outputDir: outputDir, log: log)
        let errorCount = results.filter { $0.isError }.count
        let timeoutCount = results.filter { $0.timedOut }.count
        log.info("Execution complete. Errors: \(errorCount), Timeouts: \(timeoutCount)")

        // Write raw results before judging (crash protection)
        try writeResults(results, to: "\(outputDir)/results_raw.json")

        // Phase 3: LLM-as-judge
        log.info("Phase 3: Judging \(results.count) results via LLM...")
        results = try await judgeResults(results, log: log)

        try writeResults(results, to: "\(outputDir)/results_judged.json")

        // Phase 4: Synthesize report
        let totalElapsed = Int((DispatchTime.now().uptimeNanoseconds - testStart.uptimeNanoseconds) / 1_000_000_000)
        log.info("Phase 4: Synthesizing report... (total elapsed: \(totalElapsed)s)")
        let report = try await synthesizeReport(results, totalElapsedSeconds: totalElapsed, log: log)

        let reportJSON = try JSONEncoder.prettyEncoder.encode(report)
        try reportJSON.write(to: URL(fileURLWithPath: "\(outputDir)/report.json"))
        let markdown = renderMarkdown(report, results: results)
        try markdown.write(toFile: "\(outputDir)/report.md", atomically: true, encoding: .utf8)

        // Print compact summary to terminal — full report is in the file
        let summary = renderTerminalSummary(report)
        print("\n" + String(repeating: "=", count: 80))
        print(summary)
        print(String(repeating: "=", count: 80))
        print("Full report: \(outputDir)/report.md")
        print("Raw results: \(outputDir)/results_judged.json")

        // Soft assertion (diagnostic, not hard pass/fail)
        if report.avgOverallScore < 3.0 {
            XCTFail("Average overall score \(String(format: "%.1f", report.avgOverallScore))/5 is below 3.0 — review \(outputDir)/report.md")
        }
    }

    // MARK: - Phase 1: Prompt Generation

    private func generatePrompts(count: Int, log: Logger) async throws -> [GeneratedPrompt] {
        var allPrompts: [GeneratedPrompt] = []
        let adapter = LLMAdapter.shared
        var batchNum = 0
        var consecutiveFailures = 0

        while allPrompts.count < count {
            batchNum += 1
            let remaining = count - allPrompts.count
            let batchSize = min(Self.generationBatchSize, remaining)

            let focusCategory = Self.categoryFocuses[batchNum % Self.categoryFocuses.count]
            let difficultyMix = Self.difficultyMixes[batchNum % Self.difficultyMixes.count]

            let prompt = """
Generate exactly \(batchSize) test prompts for a voice assistant called iClaw. \
Each prompt should be something a real user might type or say.
\(Self.toolCategories)
Focus: \(focusCategory)
Mix: \(difficultyMix)
Rules:
- Varied style: casual, formal, terse, verbose, typos, ALL CAPS
- Include ambiguous prompts that could match multiple tools
- Include some general conversation (no tool needed)
- Do NOT include the tool name
Format — one per line: category|difficulty|prompt text
Examples:
weather|easy|what's the weather in Tokyo
calculator|medium|what's 15% of 230
translate|hard|how do you say thank you in Korean
general|adversarial|asdfghjkl what even
Categories: weather, calculator, convert, time, timer, maps, translate, stocks, \
news, dictionary, random, email, reademail, webfetch, podcast, research, create, \
game, systeminfo, calendar, read, write, rewrite, today, feedback, \
contacts, reminders, messages, notes, shortcuts, spotlight, wikipedia, general
Difficulties: easy, medium, hard, adversarial
\(batchSize) lines, nothing else:
"""

            do {
                let response = try await adapter.generateText(prompt)
                let parsed = parseGeneratedPrompts(response)

                if parsed.isEmpty {
                    consecutiveFailures += 1
                    print("  Batch \(batchNum): no parseable prompts (failure \(consecutiveFailures)/\(Self.maxConsecutiveFailures))")
                    print("  Raw response: \(response.prefix(200))")
                    if consecutiveFailures >= Self.maxConsecutiveFailures {
                        print("  ABORTING: \(Self.maxConsecutiveFailures) consecutive failures")
                        break
                    }
                    continue
                }

                consecutiveFailures = 0
                allPrompts.append(contentsOf: parsed)
                print("  Batch \(batchNum): +\(parsed.count) (total: \(allPrompts.count)/\(count))")
            } catch {
                consecutiveFailures += 1
                print("  Batch \(batchNum) FAILED: \(error) (failure \(consecutiveFailures)/\(Self.maxConsecutiveFailures))")
                if consecutiveFailures >= Self.maxConsecutiveFailures {
                    print("  ABORTING: \(Self.maxConsecutiveFailures) consecutive failures")
                    break
                }
            }
        }

        return Array(allPrompts.prefix(count))
    }

    private func parseGeneratedPrompts(_ raw: String) -> [GeneratedPrompt] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 2)
                guard parts.count == 3 else { return nil }
                let category = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let difficulty = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
                let text = String(parts[2]).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return GeneratedPrompt(text: text, category: category, difficulty: difficulty)
            }
    }

    // Rotate focus categories across batches for diversity
    private static let categoryFocuses = [
        "Mix of weather, time, and calculator prompts",
        "Mix of stocks, news, and web fetch prompts",
        "Mix of translate, convert, and dictionary prompts",
        "Mix of maps, email, and calendar prompts",
        "Edge cases: confusable tools (convert vs calculator, time vs timer, read vs reademail, write vs rewrite)",
        "Adversarial: typos, fragments, mixed languages, emoji, nonsense",
        "Multi-intent: prompts asking for two things at once",
        "Conversational: greetings, opinions, jokes, philosophical questions (no tool needed)",
        "Mix of create, game, research, and podcast prompts",
        "Mix of system info, reminders, contacts, notes, messages, shortcuts",
    ]

    private static let difficultyMixes = [
        "8 easy, 5 medium, 2 hard",
        "5 easy, 5 medium, 3 hard, 2 adversarial",
        "3 easy, 5 medium, 5 hard, 2 adversarial",
        "0 easy, 5 medium, 5 hard, 5 adversarial",
        "10 easy, 3 medium, 2 hard",
    ]

    // MARK: - Phase 2: Execution

    private func executePrompts(
        _ prompts: [GeneratedPrompt],
        outputDir: String,
        log: Logger
    ) async throws -> [PromptResult] {
        var results: [PromptResult] = []

        // Real tools minus side-effect ones (Email, Create → spies; dangerous FM tools excluded)
        let (safeCore, safeFM) = Self.buildSafeToolLists()

        let engine = ExecutionEngine(
            preprocessor: InputPreprocessor(),
            router: ToolRouter(availableTools: safeCore, fmTools: safeFM),
            conversationManager: ConversationManager(),
            finalizer: OutputFinalizer(),
            planner: ExecutionPlanner()
            // llmResponder: nil → uses real Foundation Model
        )

        for (i, prompt) in prompts.enumerated() {
            let start = DispatchTime.now()

            // Race engine.run() against a per-prompt timeout
            var resultText: String
            var resultWidget: String?
            var resultIsError: Bool
            var timedOut = false

            do {
                let engineResult = try await withThrowingTaskGroup(of: EngineResult.self) { group in
                    group.addTask {
                        let r = await engine.run(input: prompt.text)
                        return EngineResult(text: r.text, widgetType: r.widgetType, isError: r.isError)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: Self.promptTimeoutSeconds * 1_000_000_000)
                        throw PromptTimeoutError()
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                resultText = engineResult.text
                resultWidget = engineResult.widgetType
                resultIsError = engineResult.isError
            } catch is PromptTimeoutError {
                resultText = "[TIMEOUT after \(Self.promptTimeoutSeconds)s]"
                resultWidget = nil
                resultIsError = true
                timedOut = true
            } catch {
                resultText = "[ERROR: \(error.localizedDescription)]"
                resultWidget = nil
                resultIsError = true
            }

            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

            results.append(PromptResult(
                index: i,
                prompt: prompt,
                responseText: resultText,
                widgetType: resultWidget,
                isError: resultIsError,
                timedOut: timedOut,
                durationMs: elapsed,
                judgement: nil
            ))

            // Progress logging every 25 prompts
            if (i + 1) % 25 == 0 || i == prompts.count - 1 {
                let errors = results.filter { $0.isError }.count
                let timeouts = results.filter { $0.timedOut }.count
                let avgMs = results.map(\.durationMs).reduce(0, +) / results.count
                print("[\(i + 1)/\(prompts.count)] errors=\(errors) timeouts=\(timeouts) avg=\(avgMs)ms last=\"\(prompt.text.prefix(50))\"")
            }

            // Checkpoint to disk every 100 prompts (crash protection)
            if (i + 1) % 100 == 0 {
                try writeResults(results, to: "\(outputDir)/results_checkpoint_\(i + 1).json")
            }
        }

        return results
    }

    // MARK: - Phase 3: LLM-as-Judge

    private func judgeResults(
        _ results: [PromptResult],
        log: Logger
    ) async throws -> [PromptResult] {
        var judged = results
        let adapter = LLMAdapter.shared

        // Match lines like #1|routing:5|... but not markdown headers like # Summary
        let judgementLinePattern = try NSRegularExpression(pattern: #"^#\d+\|"#)

        for batchStart in stride(from: 0, to: results.count, by: Self.judgingBatchSize) {
            let batchEnd = min(batchStart + Self.judgingBatchSize, results.count)
            let batch = Array(results[batchStart..<batchEnd])

            // Build compact prompt/response pairs
            var promptLines = ""
            for (j, r) in batch.enumerated() {
                let truncated = String(r.responseText.prefix(150))
                promptLines += "---\n#\(j + 1)\nPrompt: \(r.prompt.text)\nExpected: \(r.prompt.category)\nResponse: \(truncated)\nWidget: \(r.widgetType ?? "none")\nError: \(r.isError)\n"
            }

            let judgePrompt = """
Rate each AI response:
- routing (1-5): Right tool? 5=perfect, 1=wrong tool
- clarity (1-5): Clear and helpful? 5=excellent, 1=unusable
- overall (1-5): Overall quality
- issues: Brief problems (or "none")
\(promptLines)
Format: #N|routing:X|clarity:X|overall:X|issues:text
\(batch.count) lines:
"""

            do {
                let response = try await adapter.generateText(judgePrompt)
                let judgements = parseJudgements(response, count: batch.count, pattern: judgementLinePattern)

                if judgements.count < batch.count {
                    log.warning("Judge batch \(batchStart)-\(batchEnd): got \(judgements.count)/\(batch.count) judgements")
                }

                for (j, judgement) in judgements.enumerated() {
                    let idx = batchStart + j
                    if idx < judged.count {
                        judged[idx].judgement = judgement
                    }
                }

                if batchEnd % 50 == 0 || batchEnd == results.count {
                    let judgedCount = judged.filter { $0.judgement != nil }.count
                    print("Judged \(batchEnd)/\(results.count) (\(judgedCount) with scores)")
                }
            } catch {
                log.error("Judge batch \(batchStart)-\(batchEnd) failed: \(error.localizedDescription)")
            }
        }

        let unjudgedCount = judged.filter { $0.judgement == nil }.count
        if unjudgedCount > 0 {
            log.warning("\(unjudgedCount)/\(results.count) results could not be judged")
        }

        return judged
    }

    private func parseJudgements(_ raw: String, count: Int, pattern: NSRegularExpression) -> [Judgement] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let range = NSRange(line.startIndex..., in: line)
                return pattern.firstMatch(in: line, range: range) != nil
            }
            .prefix(count)
            .map { line -> Judgement in
                var routing = 3, clarity = 3, overall = 3
                var issues: [String] = []

                let parts = line.split(separator: "|")
                for part in parts {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("routing:") {
                        routing = Int(trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if trimmed.hasPrefix("clarity:") {
                        clarity = Int(trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if trimmed.hasPrefix("overall:") {
                        overall = Int(trimmed.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if trimmed.hasPrefix("issues:") {
                        let issueStr = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                        if issueStr.lowercased() != "none" && !issueStr.isEmpty {
                            issues = issueStr.split(separator: ";").map {
                                String($0).trimmingCharacters(in: .whitespaces)
                            }
                        }
                    }
                }

                return Judgement(
                    routingScore: max(1, min(5, routing)),
                    clarityScore: max(1, min(5, clarity)),
                    overallScore: max(1, min(5, overall)),
                    issues: issues
                )
            }
    }

    // MARK: - Phase 4: Report Synthesis

    private func synthesizeReport(
        _ results: [PromptResult],
        totalElapsedSeconds: Int,
        log: Logger
    ) async throws -> StressReport {
        let judged = results.filter { $0.judgement != nil }
        let errors = results.filter { $0.isError }
        let timeouts = results.filter { $0.timedOut }
        let durations = results.map(\.durationMs)

        // Category breakdown
        let grouped = Dictionary(grouping: results, by: { $0.prompt.category })
        let categoryStats: [CategoryStats] = grouped.map { _, items in
            let judgedItems = items.compactMap { $0.judgement }
            return CategoryStats(
                category: items[0].prompt.category,
                count: items.count,
                avgRouting: judgedItems.isEmpty ? 0 : Double(judgedItems.map(\.routingScore).reduce(0, +)) / Double(judgedItems.count),
                avgClarity: judgedItems.isEmpty ? 0 : Double(judgedItems.map(\.clarityScore).reduce(0, +)) / Double(judgedItems.count),
                avgOverall: judgedItems.isEmpty ? 0 : Double(judgedItems.map(\.overallScore).reduce(0, +)) / Double(judgedItems.count),
                errorCount: items.filter(\.isError).count
            )
        }.sorted { $0.avgOverall < $1.avgOverall }  // worst first

        // Issue frequency
        var issueFreq: [String: Int] = [:]
        for r in results {
            for issue in r.judgement?.issues ?? [] {
                issueFreq[issue, default: 0] += 1
            }
        }

        // Worst results (bottom 20 by overall score)
        let worst = results
            .filter { $0.judgement != nil }
            .sorted { ($0.judgement?.overallScore ?? 5) < ($1.judgement?.overallScore ?? 5) }
            .prefix(20)

        // LLM synthesis — compact prompt to fit on-device context window
        let synthesisInput = buildSynthesisPrompt(
            categoryStats: categoryStats,
            issueFreq: issueFreq,
            worst: Array(worst),
            totalErrors: errors.count,
            totalTimeouts: timeouts.count,
            totalPrompts: results.count
        )

        var synthesis = "LLM synthesis unavailable."
        do {
            synthesis = try await LLMAdapter.shared.generateText(synthesisInput)
        } catch {
            log.error("Synthesis failed: \(error.localizedDescription)")
        }

        let judgedScores = judged.compactMap { $0.judgement }

        return StressReport(
            date: ISO8601DateFormatter().string(from: Date()),
            totalPrompts: results.count,
            totalErrors: errors.count,
            totalTimeouts: timeouts.count,
            totalElapsedSeconds: totalElapsedSeconds,
            avgDurationMs: durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count,
            maxDurationMs: durations.max() ?? 0,
            avgRoutingScore: judgedScores.isEmpty ? 0 : Double(judgedScores.map(\.routingScore).reduce(0, +)) / Double(judgedScores.count),
            avgClarityScore: judgedScores.isEmpty ? 0 : Double(judgedScores.map(\.clarityScore).reduce(0, +)) / Double(judgedScores.count),
            avgOverallScore: judgedScores.isEmpty ? 0 : Double(judgedScores.map(\.overallScore).reduce(0, +)) / Double(judgedScores.count),
            unjudgedCount: results.count - judged.count,
            categoryBreakdown: categoryStats,
            worstResults: Array(worst),
            issueFrequency: issueFreq,
            llmSynthesis: synthesis
        )
    }

    // Kept compact — top 15 categories, top 10 issues, top 5 worst — to fit on-device context
    private func buildSynthesisPrompt(
        categoryStats: [CategoryStats],
        issueFreq: [String: Int],
        worst: [PromptResult],
        totalErrors: Int,
        totalTimeouts: Int,
        totalPrompts: Int
    ) -> String {
        var catLines = ""
        for s in categoryStats.prefix(15) {
            catLines += "\(s.category): n=\(s.count) R=\(String(format: "%.1f", s.avgRouting)) C=\(String(format: "%.1f", s.avgClarity)) O=\(String(format: "%.1f", s.avgOverall)) err=\(s.errorCount)\n"
        }

        var issueLines = ""
        for (issue, count) in issueFreq.sorted(by: { $0.value > $1.value }).prefix(10) {
            issueLines += "[\(count)x] \(issue)\n"
        }

        var worstLines = ""
        for r in worst.prefix(5) {
            let scores = r.judgement.map { "R:\($0.routingScore) C:\($0.clarityScore)" } ?? "?"
            worstLines += "- \"\(r.prompt.text.prefix(60))\" -> \"\(r.responseText.prefix(60))\" \(scores)\n"
        }

        return """
Analyze stress test results for iClaw AI assistant. Be specific and actionable.
\(totalPrompts) prompts, \(totalErrors) errors, \(totalTimeouts) timeouts.
Categories (worst first):
\(catLines)
Top issues:
\(issueLines)
Worst results:
\(worstLines)
Provide: 1) Top 5 gaps 2) Routing additions needed 3) Tools needing work 4) Training data gaps 5) Failure patterns
"""
    }

    // MARK: - Report Rendering

    /// Compact summary for terminal output — no full prompt/response log.
    private func renderTerminalSummary(_ report: StressReport) -> String {
        var s = ""
        s += "iClaw Live Stress Test Report\n"
        s += "Date: \(report.date)\n"
        s += "Prompts: \(report.totalPrompts) | Errors: \(report.totalErrors) | Timeouts: \(report.totalTimeouts)\n"
        s += "Total time: \(report.totalElapsedSeconds)s | Avg: \(report.avgDurationMs)ms | Max: \(report.maxDurationMs)ms\n"
        s += "Unjudged: \(report.unjudgedCount)\n\n"

        s += "Scores (1-5): Routing=\(String(format: "%.2f", report.avgRoutingScore))"
        s += " Clarity=\(String(format: "%.2f", report.avgClarityScore))"
        s += " Overall=\(String(format: "%.2f", report.avgOverallScore))\n\n"

        s += "Category Breakdown (worst first):\n"
        for c in report.categoryBreakdown {
            let name = c.category.padding(toLength: 16, withPad: " ", startingAt: 0)
            s += "  \(name) n=\(String(c.count).padding(toLength: 4, withPad: " ", startingAt: 0))"
            s += " R=\(String(format: "%.1f", c.avgRouting))"
            s += " C=\(String(format: "%.1f", c.avgClarity))"
            s += " O=\(String(format: "%.1f", c.avgOverall))"
            s += " err=\(c.errorCount)\n"
        }

        if !report.issueFrequency.isEmpty {
            s += "\nTop Issues:\n"
            for (issue, count) in report.issueFrequency.sorted(by: { $0.value > $1.value }).prefix(10) {
                s += "  [\(count)x] \(issue)\n"
            }
        }

        s += "\nLLM Gap Analysis:\n\(report.llmSynthesis)\n"
        return s
    }

    /// Full markdown report written to file — includes all prompt/response pairs for offline review.
    private func renderMarkdown(_ report: StressReport, results: [PromptResult]) -> String {
        var md = ""
        md += "# iClaw Live Generative Stress Test Report\n"
        md += "**Date**: \(report.date)\n"
        md += "**Prompts**: \(report.totalPrompts) | **Errors**: \(report.totalErrors) | **Timeouts**: \(report.totalTimeouts)\n"
        md += "**Total time**: \(report.totalElapsedSeconds)s | **Avg**: \(report.avgDurationMs)ms | **Max**: \(report.maxDurationMs)ms\n"
        md += "**Unjudged**: \(report.unjudgedCount)\n\n"

        md += "## Scores (1-5 scale)\n"
        md += "| Metric | Score |\n|--------|-------|\n"
        md += "| Routing | \(String(format: "%.2f", report.avgRoutingScore)) |\n"
        md += "| Clarity | \(String(format: "%.2f", report.avgClarityScore)) |\n"
        md += "| Overall | \(String(format: "%.2f", report.avgOverallScore)) |\n\n"

        md += "## Category Breakdown (worst first)\n"
        md += "| Category | Count | Routing | Clarity | Overall | Errors |\n"
        md += "|----------|-------|---------|---------|---------|--------|\n"
        for s in report.categoryBreakdown {
            md += "| \(s.category) | \(s.count) | \(String(format: "%.1f", s.avgRouting)) | \(String(format: "%.1f", s.avgClarity)) | \(String(format: "%.1f", s.avgOverall)) | \(s.errorCount) |\n"
        }

        md += "\n## Top Issues\n"
        for (issue, count) in report.issueFrequency.sorted(by: { $0.value > $1.value }).prefix(20) {
            md += "- **[\(count)x]** \(issue)\n"
        }

        md += "\n## Worst 20 Results\n"
        for r in report.worstResults {
            let scores = r.judgement.map { "R:\($0.routingScore) C:\($0.clarityScore) O:\($0.overallScore)" } ?? "unjudged"
            md += "### #\(r.index) [\(scores)]\n"
            md += "- **Prompt**: \(r.prompt.text.prefix(120))\n"
            md += "- **Category**: \(r.prompt.category) | **Difficulty**: \(r.prompt.difficulty)\n"
            md += "- **Response**: \(r.responseText.prefix(200))\n"
            md += "- **Widget**: \(r.widgetType ?? "none") | **Error**: \(r.isError) | **Timeout**: \(r.timedOut)\n"
            md += "- **Issues**: \(r.judgement?.issues.joined(separator: "; ") ?? "none")\n\n"
        }

        md += "## LLM Gap Analysis\n\(report.llmSynthesis)\n"

        // Full log in collapsible section (for file-based review, not terminal)
        md += "\n---\n## Full Prompt/Response Log\n"
        md += "<details><summary>Click to expand (\(results.count) entries)</summary>\n\n"
        for r in results {
            let j = r.judgement
            md += "**[\(r.index)] \(r.prompt.category)/\(r.prompt.difficulty)**\n"
            md += "Prompt: \(r.prompt.text)\n"
            md += "Response: \(r.responseText.prefix(300))\n"
            md += "Widget: \(r.widgetType ?? "none") | Error: \(r.isError) | Timeout: \(r.timedOut) | \(r.durationMs)ms\n"
            md += "Scores: R:\(j?.routingScore ?? 0) C:\(j?.clarityScore ?? 0) O:\(j?.overallScore ?? 0)\n"
            md += "Issues: \(j?.issues.joined(separator: "; ") ?? "none")\n---\n\n"
        }
        md += "</details>\n"

        md += "\n*Generated by LiveGenerativeStressTest*\n"
        return md
    }

    // MARK: - I/O Helpers

    private func writeResults(_ results: [PromptResult], to path: String) throws {
        let data = try JSONEncoder.prettyEncoder.encode(results)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - JSONEncoder Extension

private extension JSONEncoder {
    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
