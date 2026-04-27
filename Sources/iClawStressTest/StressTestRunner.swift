import Foundation
import FoundationModels
import os
import iClawCore
import UserNotifications
import CoreLocation

// MARK: - Data Types

struct GeneratedPrompt: Codable, Sendable, Identifiable {
    let id: Int
    let text: String
    let category: String
    let difficulty: String
    var conversationId: Int? = nil
    var turnIndex: Int? = nil
}

enum ErrorCategory: String, Codable, Sendable {
    case contextWindowOverflow
    case timeout
    case guardrailViolation
    case assetsUnavailable
    case toolExecutionError
    case unknown

    static func categorize(_ responseText: String, timedOut: Bool, isError: Bool) -> ErrorCategory? {
        guard isError || timedOut else { return nil }
        if timedOut { return .timeout }
        if responseText.contains("context window") || responseText.contains("exceeds") && responseText.contains("budget") {
            return .contextWindowOverflow
        }
        if responseText.contains("guardrail") { return .guardrailViolation }
        if responseText.contains("assets") && responseText.contains("unavailable") { return .assetsUnavailable }
        if responseText.contains("[ERROR") { return .toolExecutionError }
        return .unknown
    }
}

struct PromptResult: Codable, Sendable, Identifiable {
    var id: Int { index }
    let index: Int
    let prompt: GeneratedPrompt
    let responseText: String
    let widgetType: String?
    let isError: Bool
    let timedOut: Bool
    let durationMs: Int
    var judgement: Judgement?
    var errorCategory: ErrorCategory?
}

struct Judgement: Codable, Sendable {
    let routingScore: Int
    let clarityScore: Int
    let overallScore: Int
    let issues: [String]
}

struct CategoryStats: Codable, Sendable, Identifiable {
    var id: String { category }
    let category: String
    let count: Int
    let avgRouting: Double
    let avgClarity: Double
    let avgOverall: Double
    let errorCount: Int
}

/// Follow-up detection metrics for the stress test report.
struct FollowUpMetrics: Codable, Sendable {
    /// Total turn pairs evaluated.
    let totalTurnPairs: Int
    /// Turn pairs where the follow-up tool matched the expected tool.
    let correctFollowUps: Int
    /// Turn pairs where a pivot was correctly NOT treated as a follow-up.
    let correctPivots: Int
    /// Accuracy: (correctFollowUps + correctPivots) / totalTurnPairs
    let accuracy: Double
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
    let worstResults: [PromptResult]
    let issueFrequency: [String: Int]
    let llmSynthesis: String
    let conversationCount: Int
    let conversationAvgOverall: Double
    let p50DurationMs: Int
    let p95DurationMs: Int
    let p99DurationMs: Int
    /// Follow-up detection metrics (nil if no conversations were tested).
    let followUpMetrics: FollowUpMetrics?
    /// Breakdown of error categories (only present when errors exist).
    let errorCategoryBreakdown: [String: Int]?
}

// MARK: - Spy Tool (prevents side effects)

private final class StressSpyTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum

    init(name: String, schema: String, category: CategoryEnum) {
        self.name = name
        self.schema = schema
        self.category = category
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        ToolIO(text: "[Spy: \(name) would execute here]", status: .ok)
    }
}

// MARK: - Runner

@Observable
@MainActor
final class StressTestRunner {

    enum Phase: String, CaseIterable {
        case idle = "Ready"
        case warmingUp = "Warming Up Permissions"
        case generating = "Generating Prompts"
        case executing = "Executing Pipeline"
        case judging = "Judging Responses"
        case synthesizing = "Synthesizing Report"
        case done = "Complete"
        case failed = "Failed"
    }

    // State
    var phase: Phase = .idle
    var progress: Double = 0
    var currentItem: String = ""
    var statusMessage: String = "Configure and press Run."
    var isRunning: Bool = false

    // Live stats
    var totalTarget: Int = 0
    var generatedCount: Int = 0
    var completedCount: Int = 0
    var errorCount: Int = 0
    var timeoutCount: Int = 0
    var judgedCount: Int = 0
    var avgDurationMs: Int = 0
    var elapsedSeconds: Int = 0

    // Results
    var results: [PromptResult] = []
    var report: StressReport?
    var outputDir: String = ""

    // Token tracking
    let tokenTracker = TokenTracker()

    // Config
    static let generationBatchSizeOnDevice = 10
    static let generationBatchSizeExternal = 50
    static let judgingBatchSize = 5
    static let promptTimeoutSeconds: UInt64 = 30
    static let maxConsecutiveFailures = 10
    static let outputBaseDir = "/tmp/iclaw_live_stress"

    private static let sideEffectCoreToolNames: Set<String> = ["Email", "Create"]
    private static let sideEffectFMToolNames: Set<String> = [
        "Messages", "Reminders", "Calendar Events", "Notes",
        "Shortcuts", "System Control", "App Manager", "Camera"
    ]

    private var runTask: Task<Void, Never>?
    private var provider: (any LLMProvider)?
    private var useExternalPrompts = false
    private let log = Logger(subsystem: "com.geticlaw.iClaw.stress", category: "runner")
    private var streamLogHandle: FileHandle?

    private func openStreamLog() {
        let path = "\(outputDir)/results_stream.jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        streamLogHandle = FileHandle(forWritingAtPath: path)
    }

    private func appendToStreamLog(_ result: PromptResult) {
        guard let handle = streamLogHandle else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(result),
              let line = String(data: data, encoding: .utf8) else { return }
        handle.write(Data((line + "\n").utf8))
    }

    private func closeStreamLog() {
        try? streamLogHandle?.close()
        streamLogHandle = nil
    }

    // MARK: - Control

    func start(promptCount: Int, provider: any LLMProvider, modelOption: ModelOption) {
        guard !isRunning else { return }
        self.provider = provider
        self.useExternalPrompts = !(provider is AppleFoundationProvider)
        isRunning = true
        totalTarget = promptCount
        tokenTracker.reset()
        tokenTracker.inputPricePer1M = modelOption.inputPricePer1M
        tokenTracker.outputPricePer1M = modelOption.outputPricePer1M
        phase = .warmingUp
        progress = 0
        generatedCount = 0
        completedCount = 0
        errorCount = 0
        timeoutCount = 0
        judgedCount = 0
        avgDurationMs = 0
        elapsedSeconds = 0
        results = []
        report = nil
        currentItem = ""
        statusMessage = "Starting..."

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        outputDir = "\(Self.outputBaseDir)/\(timestamp)"

        runTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(promptCount: promptCount)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        phase = .idle
        statusMessage = "Stopped."
    }

    // MARK: - Pipeline

    private func runPipeline(promptCount: Int) async {
        let wallStart = DispatchTime.now()

        // Timer to update elapsed seconds
        let timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                self.elapsedSeconds = Int((DispatchTime.now().uptimeNanoseconds - wallStart.uptimeNanoseconds) / 1_000_000_000)
            }
        }

        defer {
            timerTask.cancel()
            isRunning = false
        }

        do {
            try FileManager.default.createDirectory(
                atPath: outputDir, withIntermediateDirectories: true
            )
        } catch {
            phase = .failed
            statusMessage = "Failed to create output dir: \(error.localizedDescription)"
            return
        }

        await ScratchpadCache.shared.reset()

        // Phase 0: Warm up permissions
        phase = .warmingUp
        statusMessage = "Triggering permission dialogs..."
        await warmUpPermissions()
        if Task.isCancelled { return }

        // Phase 1: Generate
        phase = .generating
        statusMessage = "Generating prompts..."
        let prompts = await generatePrompts(count: promptCount)
        if Task.isCancelled { return }

        if prompts.isEmpty {
            phase = .failed
            statusMessage = "Failed to generate any prompts. Is Apple Intelligence available?"
            return
        }

        generatedCount = prompts.count
        writeJSON(prompts, to: "prompts.json")

        // Phase 1b: Generate conversation sequences
        let conversationPrompts = await generateConversationPrompts(
            count: prompts.count, startId: prompts.count
        )
        if Task.isCancelled { return }

        let allPrompts = prompts + conversationPrompts
        generatedCount = allPrompts.count
        writeJSON(allPrompts, to: "prompts.json")

        // Phase 2: Execute regular prompts
        phase = .executing
        statusMessage = "Running prompts through real pipeline..."
        openStreamLog()
        var currentResults = await executePrompts(prompts)
        if Task.isCancelled { closeStreamLog(); return }

        // Phase 2b: Execute conversation sequences
        if !conversationPrompts.isEmpty {
            statusMessage = "Running conversation sequences..."
            let convResults = await executeConversationSequences(conversationPrompts)
            currentResults.append(contentsOf: convResults)
        }
        closeStreamLog()
        if Task.isCancelled { return }

        results = currentResults
        writeJSON(currentResults, to: "results_raw.json")

        // Phase 3: Judge (regular prompts, then conversation groups)
        phase = .judging
        statusMessage = "LLM judging responses..."
        currentResults = await judgeResults(currentResults)
        if Task.isCancelled { return }

        // Context-aware judging for conversation prompts
        currentResults = await judgeConversationResults(currentResults)
        if Task.isCancelled { return }

        results = currentResults
        writeJSON(currentResults, to: "results_judged.json")

        // Export misroutes and validated prompts for classifier retraining
        exportForRetraining(currentResults)

        // Phase 4: Synthesize
        phase = .synthesizing
        statusMessage = "Synthesizing report..."
        let totalElapsed = Int((DispatchTime.now().uptimeNanoseconds - wallStart.uptimeNanoseconds) / 1_000_000_000)
        let finalReport = await synthesizeReport(currentResults, totalElapsedSeconds: totalElapsed)

        report = finalReport
        writeJSON(finalReport, to: "report.json")

        // Write markdown
        let markdown = renderMarkdown(finalReport, results: currentResults)
        try? markdown.write(toFile: "\(outputDir)/report.md", atomically: true, encoding: .utf8)

        phase = .done
        statusMessage = "Complete. Report saved to \(outputDir)/"
    }

    // MARK: - Phase 1: Generate

    private var generationBatchSize: Int {
        useExternalPrompts ? Self.generationBatchSizeExternal : Self.generationBatchSizeOnDevice
    }

    private func generatePrompts(count: Int) async -> [GeneratedPrompt] {
        var all: [GeneratedPrompt] = []
        guard let provider else { return all }
        var batchNum = 0
        var failures = 0

        while all.count < count && !Task.isCancelled {
            batchNum += 1
            let batchSize = min(generationBatchSize, count - all.count)
            let focuses = useExternalPrompts ? Self.externalCategoryFocuses : Self.categoryFocuses
            let focus = focuses[batchNum % focuses.count]
            let mix = Self.difficultyMixes[batchNum % Self.difficultyMixes.count]

            let prompt: String
            if useExternalPrompts {
                prompt = Self.makeAdversarialGenerationPrompt(batchSize: batchSize, focus: focus, mix: mix)
            } else {
                prompt = Self.makeStandardGenerationPrompt(batchSize: batchSize, focus: focus, mix: mix)
            }

            do {
                let response = try await provider.generateText(prompt)
                tokenTracker.record(response)
                let parsed = Self.parseGeneratedPrompts(response.text, startId: all.count)

                if parsed.isEmpty {
                    failures += 1
                    currentItem = "Batch \(batchNum): no parseable output (failure \(failures)/\(Self.maxConsecutiveFailures))"
                    if failures >= Self.maxConsecutiveFailures { break }
                    continue
                }

                failures = 0
                all.append(contentsOf: parsed)
                generatedCount = all.count
                progress = Double(all.count) / Double(count)
                currentItem = "Batch \(batchNum): +\(parsed.count) prompts"
            } catch {
                failures += 1
                currentItem = "Batch \(batchNum) error: \(error.localizedDescription)"
                log.error("Gen batch \(batchNum): \(error.localizedDescription)")
                if failures >= Self.maxConsecutiveFailures { break }
            }
        }

        return Array(all.prefix(count))
    }

    private static func parseGeneratedPrompts(_ raw: String, startId: Int) -> [GeneratedPrompt] {
        var id = startId
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 2)
                guard parts.count == 3 else { return nil }
                let category = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let difficulty = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
                let text = String(parts[2]).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                defer { id += 1 }
                return GeneratedPrompt(id: id, text: text, category: category, difficulty: difficulty)
            }
    }

    // MARK: - Prompt Templates

    private static func makeStandardGenerationPrompt(batchSize: Int, focus: String, mix: String) -> String {
        """
        Generate exactly \(batchSize) test prompts for a voice assistant called iClaw. \
        Each prompt should be something a real user might type or say.
        \(toolCategories)
        Focus: \(focus)
        Mix: \(mix)
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
    }

    private static func makeAdversarialGenerationPrompt(batchSize: Int, focus: String, mix: String) -> String {
        """
        Generate exactly \(batchSize) ADVERSARIAL test prompts for a voice assistant called iClaw. \
        Simulate how REAL users actually type — messy, informal, ambiguous.
        \(toolCategories)
        Focus: \(focus)
        Mix: \(mix)
        Prompt styles to include (vary across all):
        - Typos and autocorrect fails: "waether", "tge", "adn", "calculater"
        - Filler words: "um", "like", "so uh", "hey can you", "ok so"
        - Self-corrections: "no wait", "actually I meant", "scratch that", "never mind do"
        - Indirect requests: "is it gonna rain" not "weather", "how cold is it" not "temperature"
        - Fragments: "nyc weather", "5 min", "aapl price", "paris time"
        - Run-on multi-intent: "whats the weather and also set a timer", "check stocks then news"
        - Frustrated/ALL CAPS: "WHY WONT YOU TELL ME THE TIME", "UGH JUST CONVERT IT"
        - Mixed languages: "qué hora es in tokyo", "wie spät ist es in london"
        - Emoji-laden: "🌧️ london?", "⏰ nyc", "💰 btc price"
        - Extremely vague: "stuff", "you know what I mean", "the thing", "that one"
        - Sarcastic/rhetorical: "oh sure, what's the weather on mars", "like you'd know"
        - Stream-of-consciousness: run-on sentences without punctuation
        - Do NOT include the tool name
        Format — one per line: category|difficulty|prompt text
        Examples:
        weather|adversarial|is it gonna rain tmrw or waht
        calculator|hard|um like whats 15 percent of uh 230
        translate|adversarial|how do u say thx in korean lol
        general|adversarial|🤷 idk just do something
        stocks|hard|yo whats aapl at rn
        timer|medium|5 min pls
        Categories: weather, calculator, convert, time, timer, maps, translate, stocks, \
        news, dictionary, random, email, reademail, webfetch, podcast, research, create, \
        game, systeminfo, calendar, read, write, rewrite, today, feedback, \
        contacts, reminders, messages, notes, shortcuts, spotlight, wikipedia, general
        Difficulties: easy, medium, hard, adversarial
        \(batchSize) lines, nothing else:
        """
    }

    // MARK: - Permission Warmup

    private func warmUpPermissions() async {
        currentItem = "Requesting location permission..."
        let locManager = CLLocationManager()
        locManager.requestWhenInUseAuthorization()
        // Brief pause to let the dialog appear
        try? await Task.sleep(nanoseconds: 500_000_000)

        currentItem = "Requesting notification permission..."
        do {
            let _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log.info("Notification warmup: \(error.localizedDescription) (ok — permission triggered)")
        }

        currentItem = "Permissions warmed up"
    }

    // MARK: - Conversation Generation

    private func generateConversationPrompts(count: Int, startId: Int) async -> [GeneratedPrompt] {
        guard let provider else { return [] }

        let sequenceCount = max(3, count / 15)
        let batchSize = useExternalPrompts ? 10 : 3
        var all: [GeneratedPrompt] = []
        var nextId = startId
        var convId = 0

        for batchStart in stride(from: 0, to: sequenceCount, by: batchSize) {
            guard !Task.isCancelled else { break }
            let thisBatch = min(batchSize, sequenceCount - batchStart)

            let prompt = """
            Generate exactly \(thisBatch) conversation sequences for testing a voice assistant called iClaw. \
            Each sequence should be 2-4 turns that a real user would say in order.
            \(Self.toolCategories)
            Conversation patterns to include:
            - Follow-ups using pronouns: "those", "that", "it", "the last one"
            - Implicit context: "tomorrow?", "in euros?", "now french?"
            - Corrections: "no I meant chicago", "actually make it 10"
            - Drill-downs: "more details", "why?", "explain that"
            - Pivots: "ok now what about stocks", "and the weather there?"
            - Frustration: "that's not what I asked", "try again"
            Format: category|followup|prompt text
            Separate sequences with --- on its own line.
            The first turn of each sequence uses a difficulty like easy/medium/hard.
            Follow-up turns use "followup" as the difficulty.
            Example:
            weather|easy|what's the weather in london
            weather|followup|what about tomorrow
            weather|followup|and paris?
            ---
            stocks|medium|how's apple doing
            stocks|followup|compare to microsoft
            ---
            \(thisBatch) sequences, nothing else:
            """

            do {
                let response = try await provider.generateText(prompt)
                tokenTracker.record(response)
                let sequences = Self.parseConversationOutput(response.text, startId: nextId, startConvId: convId)
                for seq in sequences {
                    all.append(contentsOf: seq)
                }
                nextId = (all.last?.id ?? nextId) + 1
                convId += sequences.count

                currentItem = "Conversations: \(all.count) turns in \(convId) sequences"
            } catch {
                log.error("Conversation gen: \(error.localizedDescription)")
            }
        }

        return all
    }

    private static func parseConversationOutput(_ raw: String, startId: Int, startConvId: Int) -> [[GeneratedPrompt]] {
        var sequences: [[GeneratedPrompt]] = []
        var currentSeq: [GeneratedPrompt] = []
        var id = startId
        var convId = startConvId
        var turnIndex = 0

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !currentSeq.isEmpty {
                    sequences.append(currentSeq)
                    currentSeq = []
                    convId += 1
                    turnIndex = 0
                }
                continue
            }

            let parts = trimmed.split(separator: "|", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let category = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
            let difficulty = String(parts[1]).trimmingCharacters(in: .whitespaces).lowercased()
            let text = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            currentSeq.append(GeneratedPrompt(
                id: id, text: text, category: category, difficulty: difficulty,
                conversationId: convId, turnIndex: turnIndex
            ))
            id += 1
            turnIndex += 1
        }

        if !currentSeq.isEmpty {
            sequences.append(currentSeq)
        }

        return sequences
    }

    // MARK: - Conversation Execution

    private func executeConversationSequences(_ prompts: [GeneratedPrompt]) async -> [PromptResult] {
        var results: [PromptResult] = []
        let (safeCore, safeFM) = Self.buildSafeToolLists()

        // Group by conversationId
        let grouped = Dictionary(grouping: prompts, by: { $0.conversationId ?? 0 })
        let sortedKeys = grouped.keys.sorted()

        for convId in sortedKeys {
            guard !Task.isCancelled else { break }
            guard let sequence = grouped[convId]?.sorted(by: { $0.turnIndex ?? 0 < $1.turnIndex ?? 0 }) else { continue }

            // Fresh engine per conversation sequence
            let engine = ExecutionEngine(
                preprocessor: InputPreprocessor(),
                router: ToolRouter(availableTools: safeCore, fmTools: safeFM),
                conversationManager: ConversationManager(),
                finalizer: OutputFinalizer(),
                planner: ExecutionPlanner()
            )

            currentItem = "Conversation \(convId + 1): \(sequence.first?.text.prefix(40) ?? "")"

            for prompt in sequence {
                guard !Task.isCancelled else { break }

                let start = DispatchTime.now()

                var text: String
                var widget: String?
                var isError: Bool
                var timedOut = false

                do {
                    let result = try await withThrowingTaskGroup(of: EngineResult.self) { group in
                        group.addTask {
                            let r = await engine.run(input: prompt.text)
                            return EngineResult(text: r.text, widgetType: r.widgetType, isError: r.isError)
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: Self.promptTimeoutSeconds * 1_000_000_000)
                            throw TimeoutError()
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                    text = result.text
                    widget = result.widgetType
                    isError = result.isError
                } catch is TimeoutError {
                    text = "[TIMEOUT after \(Self.promptTimeoutSeconds)s]"
                    widget = nil
                    isError = true
                    timedOut = true
                } catch {
                    text = "[ERROR: \(error.localizedDescription)]"
                    widget = nil
                    isError = true
                }

                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

                results.append(PromptResult(
                    index: results.count + completedCount, prompt: prompt, responseText: text,
                    widgetType: widget, isError: isError, timedOut: timedOut,
                    durationMs: elapsed, judgement: nil
                ))
            }

            completedCount += sequence.count
            progress = Double(completedCount) / Double(totalTarget + prompts.count)
        }

        return results
    }

    // MARK: - Conversation Judging

    private func judgeConversationResults(_ results: [PromptResult]) async -> [PromptResult] {
        var judged = results
        guard let provider else { return judged }

        // Group conversation results by conversationId
        let convResults = results.enumerated().filter { $0.element.prompt.conversationId != nil }
        let grouped = Dictionary(grouping: convResults, by: { $0.element.prompt.conversationId! })

        for (convId, indexedItems) in grouped {
            guard !Task.isCancelled else { break }
            // Already judged in regular pass? Skip.
            if indexedItems.allSatisfy({ judged[$0.offset].judgement != nil }) { continue }

            var lines = ""
            for (_, r) in indexedItems {
                let turn = r.prompt.turnIndex ?? 0
                let truncated = String(r.responseText.prefix(150))
                lines += "Turn \(turn): \(r.prompt.text)\nResponse: \(truncated)\n\n"
            }

            let judgePrompt = """
            Rate this conversation sequence (ID: \(convId)). Focus on CONTEXT RETENTION — \
            does each follow-up correctly use context from prior turns?
            \(lines)
            For each turn, rate:
            - routing (1-5): Right tool/intent?
            - clarity (1-5): Clear, helpful, uses context?
            - overall (1-5): Overall quality including context retention
            - issues: Brief problems (or "none")
            Format: #N|routing:X|clarity:X|overall:X|issues:text
            \(indexedItems.count) lines:
            """

            do {
                let response = try await provider.generateText(judgePrompt)
                tokenTracker.record(response)
                let pattern = try? NSRegularExpression(pattern: #"^#\d+\|"#)
                let judgements = Self.parseJudgements(response.text, count: indexedItems.count, pattern: pattern)

                for (j, judgement) in judgements.enumerated() {
                    if j < indexedItems.count {
                        let idx = indexedItems[j].offset
                        judged[idx].judgement = judgement
                    }
                }
            } catch {
                log.error("Conversation judge \(convId): \(error.localizedDescription)")
            }

            judgedCount = judged.filter { $0.judgement != nil }.count
            currentItem = "Judged conversation \(convId + 1)"
        }

        return judged
    }

    // MARK: - Phase 2: Execute

    private func executePrompts(_ prompts: [GeneratedPrompt]) async -> [PromptResult] {
        var results: [PromptResult] = []
        let (safeCore, safeFM) = Self.buildSafeToolLists()

        let engine = ExecutionEngine(
            preprocessor: InputPreprocessor(),
            router: ToolRouter(availableTools: safeCore, fmTools: safeFM),
            conversationManager: ConversationManager(),
            finalizer: OutputFinalizer(),
            planner: ExecutionPlanner()
        )

        for (i, prompt) in prompts.enumerated() {
            guard !Task.isCancelled else { break }

            let start = DispatchTime.now()
            currentItem = prompt.text

            var text: String
            var widget: String?
            var isError: Bool
            var timedOut = false

            do {
                let result = try await withThrowingTaskGroup(of: EngineResult.self) { group in
                    group.addTask {
                        let r = await engine.run(input: prompt.text)
                        return EngineResult(text: r.text, widgetType: r.widgetType, isError: r.isError)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: Self.promptTimeoutSeconds * 1_000_000_000)
                        throw TimeoutError()
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                text = result.text
                widget = result.widgetType
                isError = result.isError
            } catch is TimeoutError {
                text = "[TIMEOUT after \(Self.promptTimeoutSeconds)s]"
                widget = nil
                isError = true
                timedOut = true
            } catch {
                text = "[ERROR: \(error.localizedDescription)]"
                widget = nil
                isError = true
            }

            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

            let category = ErrorCategory.categorize(text, timedOut: timedOut, isError: isError)
            let entry = PromptResult(
                index: i, prompt: prompt, responseText: text,
                widgetType: widget, isError: isError, timedOut: timedOut,
                durationMs: elapsed, judgement: nil, errorCategory: category
            )
            results.append(entry)
            appendToStreamLog(entry)

            // Update live stats
            completedCount = results.count
            if isError { errorCount = results.filter(\.isError).count }
            if timedOut { timeoutCount = results.filter(\.timedOut).count }
            avgDurationMs = results.map(\.durationMs).reduce(0, +) / results.count
            progress = Double(results.count) / Double(prompts.count)

            // Checkpoint every 25
            if results.count % 25 == 0 {
                writeJSON(results, to: "results_checkpoint_\(results.count).json")
            }
        }

        return results
    }

    // MARK: - Phase 3: Judge

    private func judgeResults(_ results: [PromptResult]) async -> [PromptResult] {
        var judged = results
        guard let provider else { return judged }
        let pattern = try? NSRegularExpression(pattern: #"^#\d+\|"#)

        for batchStart in stride(from: 0, to: results.count, by: Self.judgingBatchSize) {
            guard !Task.isCancelled else { break }

            let batchEnd = min(batchStart + Self.judgingBatchSize, results.count)
            let batch = Array(results[batchStart..<batchEnd])

            var lines = ""
            for (j, r) in batch.enumerated() {
                let truncated = String(r.responseText.prefix(150))
                lines += "---\n#\(j + 1)\nPrompt: \(r.prompt.text)\nExpected: \(r.prompt.category)\nResponse: \(truncated)\nWidget: \(r.widgetType ?? "none")\nError: \(r.isError)\n"
            }

            let judgePrompt = """
Rate each AI response:
- routing (1-5): Right tool? 5=perfect, 1=wrong tool
- clarity (1-5): Clear and helpful? 5=excellent, 1=unusable
- overall (1-5): Overall quality
- issues: Brief problems (or "none")
\(lines)
Format: #N|routing:X|clarity:X|overall:X|issues:text
\(batch.count) lines:
"""

            do {
                let response = try await provider.generateText(judgePrompt)
                tokenTracker.record(response)
                let judgements = Self.parseJudgements(response.text, count: batch.count, pattern: pattern)

                for (j, judgement) in judgements.enumerated() {
                    let idx = batchStart + j
                    if idx < judged.count {
                        judged[idx].judgement = judgement
                    }
                }
            } catch {
                log.error("Judge batch \(batchStart)-\(batchEnd): \(error.localizedDescription)")
            }

            judgedCount = judged.filter { $0.judgement != nil }.count
            progress = Double(batchEnd) / Double(results.count)
            currentItem = "Judged \(batchEnd)/\(results.count)"
        }

        return judged
    }

    private static func parseJudgements(_ raw: String, count: Int, pattern: NSRegularExpression?) -> [Judgement] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let pattern else { return line.hasPrefix("#") }
                let range = NSRange(line.startIndex..., in: line)
                return pattern.firstMatch(in: line, range: range) != nil
            }
            .prefix(count)
            .map { line -> Judgement in
                var routing = 3, clarity = 3, overall = 3
                var issues: [String] = []

                for part in line.split(separator: "|") {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("routing:") {
                        routing = Int(t.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if t.hasPrefix("clarity:") {
                        clarity = Int(t.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if t.hasPrefix("overall:") {
                        overall = Int(t.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if t.hasPrefix("issues:") {
                        let s = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                        if s.lowercased() != "none" && !s.isEmpty {
                            issues = s.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
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

    // MARK: - Phase 4: Synthesize

    private func synthesizeReport(_ results: [PromptResult], totalElapsedSeconds: Int) async -> StressReport {
        let judged = results.filter { $0.judgement != nil }
        let durations = results.map(\.durationMs)

        let grouped = Dictionary(grouping: results, by: { $0.prompt.category })
        let categoryStats: [CategoryStats] = grouped.map { _, items in
            let j = items.compactMap(\.judgement)
            return CategoryStats(
                category: items[0].prompt.category,
                count: items.count,
                avgRouting: j.isEmpty ? 0 : Double(j.map(\.routingScore).reduce(0, +)) / Double(j.count),
                avgClarity: j.isEmpty ? 0 : Double(j.map(\.clarityScore).reduce(0, +)) / Double(j.count),
                avgOverall: j.isEmpty ? 0 : Double(j.map(\.overallScore).reduce(0, +)) / Double(j.count),
                errorCount: items.filter(\.isError).count
            )
        }.sorted { $0.avgOverall < $1.avgOverall }

        var issueFreq: [String: Int] = [:]
        for r in results {
            for issue in r.judgement?.issues ?? [] { issueFreq[issue, default: 0] += 1 }
        }

        let worst = Array(results.filter { $0.judgement != nil }
            .sorted { ($0.judgement?.overallScore ?? 5) < ($1.judgement?.overallScore ?? 5) }
            .prefix(20))

        // Compact synthesis prompt
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
            let sc = r.judgement.map { "R:\($0.routingScore) C:\($0.clarityScore)" } ?? "?"
            worstLines += "- \"\(r.prompt.text.prefix(60))\" -> \"\(r.responseText.prefix(60))\" \(sc)\n"
        }

        let synthesisPrompt = """
Analyze stress test results for iClaw AI assistant. Be specific and actionable.
\(results.count) prompts, \(results.filter(\.isError).count) errors, \(results.filter(\.timedOut).count) timeouts.
Categories (worst first):
\(catLines)
Top issues:
\(issueLines)
Worst results:
\(worstLines)
Provide: 1) Top 5 gaps 2) Routing additions needed 3) Tools needing work 4) Training data gaps 5) Failure patterns
"""

        var synthesis = "LLM synthesis unavailable."
        if let provider {
            do {
                let response = try await provider.generateText(synthesisPrompt)
                tokenTracker.record(response)
                synthesis = response.text
            } catch {
                log.error("Synthesis: \(error.localizedDescription)")
            }
        }

        let scores = judged.compactMap(\.judgement)

        // Conversation stats
        let convResults = results.filter { $0.prompt.conversationId != nil }
        let convIds = Set(convResults.compactMap(\.prompt.conversationId))
        let convScores = convResults.compactMap(\.judgement)
        let convAvgOverall = convScores.isEmpty ? 0.0
            : Double(convScores.map(\.overallScore).reduce(0, +)) / Double(convScores.count)

        // Latency percentiles
        let sortedDurations = durations.sorted()
        let p50 = Self.percentile(sortedDurations, p: 0.50)
        let p95 = Self.percentile(sortedDurations, p: 0.95)
        let p99 = Self.percentile(sortedDurations, p: 0.99)

        // Error category breakdown
        let errorCategories = results.compactMap(\.errorCategory)
        let errorBreakdown: [String: Int]? = errorCategories.isEmpty ? nil : {
            var counts: [String: Int] = [:]
            for cat in errorCategories { counts[cat.rawValue, default: 0] += 1 }
            return counts
        }()

        return StressReport(
            date: ISO8601DateFormatter().string(from: Date()),
            totalPrompts: results.count,
            totalErrors: results.filter(\.isError).count,
            totalTimeouts: results.filter(\.timedOut).count,
            totalElapsedSeconds: totalElapsedSeconds,
            avgDurationMs: durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count,
            maxDurationMs: durations.max() ?? 0,
            avgRoutingScore: scores.isEmpty ? 0 : Double(scores.map(\.routingScore).reduce(0, +)) / Double(scores.count),
            avgClarityScore: scores.isEmpty ? 0 : Double(scores.map(\.clarityScore).reduce(0, +)) / Double(scores.count),
            avgOverallScore: scores.isEmpty ? 0 : Double(scores.map(\.overallScore).reduce(0, +)) / Double(scores.count),
            unjudgedCount: results.count - judged.count,
            categoryBreakdown: categoryStats,
            worstResults: worst,
            issueFrequency: issueFreq,
            llmSynthesis: synthesis,
            conversationCount: convIds.count,
            conversationAvgOverall: convAvgOverall,
            p50DurationMs: p50,
            p95DurationMs: p95,
            p99DurationMs: p99,
            followUpMetrics: computeFollowUpMetrics(results: results),
            errorCategoryBreakdown: errorBreakdown
        )
    }

    /// Computes follow-up detection metrics from conversation results.
    /// Evaluates whether consecutive turns in the same conversation were
    /// correctly handled (follow-ups routed to same tool, pivots routed differently).
    private func computeFollowUpMetrics(results: [PromptResult]) -> FollowUpMetrics? {
        let convResults = results.filter { $0.prompt.conversationId != nil }
        guard convResults.count >= 2 else { return nil }

        let grouped = Dictionary(grouping: convResults, by: { $0.prompt.conversationId! })
        var totalPairs = 0
        var correctFollowUps = 0
        var correctPivots = 0

        for (_, sequence) in grouped {
            let sorted = sequence.sorted { ($0.prompt.turnIndex ?? 0) < ($1.prompt.turnIndex ?? 0) }
            for i in 1..<sorted.count {
                let prior = sorted[i - 1]
                let current = sorted[i]
                totalPairs += 1

                let sameCategory = prior.prompt.category == current.prompt.category
                let priorWidget = prior.widgetType?.lowercased() ?? ""
                let currentWidget = current.widgetType?.lowercased() ?? ""
                let sameWidget = !priorWidget.isEmpty && priorWidget == currentWidget

                if sameCategory {
                    // Follow-up — should route to same tool category
                    if sameWidget || !current.isError {
                        correctFollowUps += 1
                    }
                } else {
                    // Pivot — should route to a different tool
                    if !sameWidget || currentWidget.isEmpty {
                        correctPivots += 1
                    }
                }
            }
        }

        let accuracy = totalPairs > 0 ? Double(correctFollowUps + correctPivots) / Double(totalPairs) : 0
        return FollowUpMetrics(
            totalTurnPairs: totalPairs,
            correctFollowUps: correctFollowUps,
            correctPivots: correctPivots,
            accuracy: accuracy
        )
    }

    private static func percentile(_ sorted: [Int], p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }

    // MARK: - Markdown

    private func renderMarkdown(_ report: StressReport, results: [PromptResult]) -> String {
        var md = ""
        md += "# iClaw Live Generative Stress Test Report\n"
        md += "**Date**: \(report.date)\n"
        md += "**Prompts**: \(report.totalPrompts) | **Errors**: \(report.totalErrors) | **Timeouts**: \(report.totalTimeouts)\n"
        md += "**Total time**: \(report.totalElapsedSeconds)s | **Avg**: \(report.avgDurationMs)ms | **Max**: \(report.maxDurationMs)ms\n"
        md += "**Unjudged**: \(report.unjudgedCount)\n\n"
        md += "## Scores (1-5)\n| Metric | Score |\n|--------|-------|\n"
        md += "| Routing | \(String(format: "%.2f", report.avgRoutingScore)) |\n"
        md += "| Clarity | \(String(format: "%.2f", report.avgClarityScore)) |\n"
        md += "| Overall | \(String(format: "%.2f", report.avgOverallScore)) |\n\n"
        if report.conversationCount > 0 {
            md += "## Conversation Sequences\n"
            md += "| Metric | Value |\n|--------|-------|\n"
            md += "| Sequences | \(report.conversationCount) |\n"
            md += "| Avg Overall | \(String(format: "%.2f", report.conversationAvgOverall)) |\n\n"
        }
        md += "## Latency Percentiles\n| Percentile | Duration |\n|------------|----------|\n"
        md += "| p50 | \(report.p50DurationMs)ms |\n"
        md += "| p95 | \(report.p95DurationMs)ms |\n"
        md += "| p99 | \(report.p99DurationMs)ms |\n\n"
        if let followUp = report.followUpMetrics {
            md += "## Follow-Up Detection\n| Metric | Value |\n|--------|-------|\n"
            md += "| Total Turn Pairs | \(followUp.totalTurnPairs) |\n"
            md += "| Correct Follow-Ups | \(followUp.correctFollowUps) |\n"
            md += "| Correct Pivots | \(followUp.correctPivots) |\n"
            md += "| Accuracy | \(String(format: "%.1f", followUp.accuracy * 100))% |\n\n"
        }

        md += "## Categories (worst first)\n| Category | N | Routing | Clarity | Overall | Errors |\n|----------|---|---------|---------|---------|--------|\n"
        for s in report.categoryBreakdown {
            md += "| \(s.category) | \(s.count) | \(String(format: "%.1f", s.avgRouting)) | \(String(format: "%.1f", s.avgClarity)) | \(String(format: "%.1f", s.avgOverall)) | \(s.errorCount) |\n"
        }
        if let errorBreakdown = report.errorCategoryBreakdown, !errorBreakdown.isEmpty {
            md += "\n## Error Categories\n| Category | Count |\n|----------|-------|\n"
            for (cat, count) in errorBreakdown.sorted(by: { $0.value > $1.value }) {
                md += "| \(cat) | \(count) |\n"
            }
            md += "\n"
        }

        let slowest = results.sorted(by: { $0.durationMs > $1.durationMs }).prefix(10)
        if !slowest.isEmpty {
            md += "## Slowest 10 Prompts\n| # | Duration | Category | Error? | Prompt |\n|---|----------|----------|--------|--------|\n"
            for r in slowest {
                let errLabel = r.errorCategory?.rawValue ?? (r.isError ? "error" : "-")
                md += "| \(r.index) | \(r.durationMs)ms | \(r.prompt.category) | \(errLabel) | \(r.prompt.text.prefix(60)) |\n"
            }
            md += "\n"
        }

        md += "## Top Issues\n"
        for (issue, count) in report.issueFrequency.sorted(by: { $0.value > $1.value }).prefix(20) {
            md += "- **[\(count)x]** \(issue)\n"
        }
        md += "\n## Worst 20\n"
        for r in report.worstResults {
            let sc = r.judgement.map { "R:\($0.routingScore) C:\($0.clarityScore) O:\($0.overallScore)" } ?? "unjudged"
            md += "### #\(r.index) [\(sc)]\n"
            md += "- **Prompt**: \(r.prompt.text.prefix(120))\n"
            md += "- **Response**: \(r.responseText.prefix(200))\n"
            md += "- **Issues**: \(r.judgement?.issues.joined(separator: "; ") ?? "none")\n\n"
        }
        md += "## LLM Gap Analysis\n\(report.llmSynthesis)\n"
        md += "\n---\n## Full Log\n<details><summary>\(results.count) entries</summary>\n\n"
        for r in results {
            let j = r.judgement
            md += "**[\(r.index)] \(r.prompt.category)/\(r.prompt.difficulty)**\n"
            md += "Prompt: \(r.prompt.text)\nResponse: \(r.responseText.prefix(300))\n"
            md += "Widget: \(r.widgetType ?? "none") | Err: \(r.isError) | TO: \(r.timedOut) | \(r.durationMs)ms\n"
            md += "R:\(j?.routingScore ?? 0) C:\(j?.clarityScore ?? 0) O:\(j?.overallScore ?? 0) | \(j?.issues.joined(separator: "; ") ?? "none")\n---\n\n"
        }
        md += "</details>\n*Generated by iClaw Stress Test*\n"
        return md
    }

    // MARK: - Helpers

    private struct EngineResult: Sendable {
        let text: String
        let widgetType: String?
        let isError: Bool
    }

    private struct TimeoutError: Error {}

    private func writeJSON<T: Encodable>(_ value: T, to filename: String) {
        writeJSONFile(value, to: filename, in: outputDir)
    }

    private static func buildSafeToolLists() -> (core: [any CoreTool], fm: [any FMToolDescriptor]) {
        var core: [any CoreTool] = ToolRegistry.coreTools.filter {
            !sideEffectCoreToolNames.contains($0.name)
        }
        for name in sideEffectCoreToolNames {
            let orig = ToolRegistry.coreTools.first { $0.name == name }
            core.append(StressSpyTool(
                name: name,
                schema: orig?.schema ?? "\(name) tool.",
                category: orig?.category ?? .offline
            ))
        }
        let fm = ToolRegistry.fmTools.filter { !sideEffectFMToolNames.contains($0.name) }
        return (core, fm)
    }

    // MARK: - Generation Data

    private static let toolCategories = """
Core tools: Weather, Calculator, Convert (units/currency), Time, Timer, Maps, \
Translate, Stocks, News, Dictionary, Random (coin/dice), Email, ReadEmail, \
WebFetch, Podcast, Research, Create (images), Game (2048/Wordle/Sokoban/Sudoku), \
SystemInfo, Calendar, Read, Write, Rewrite, Transcribe, Today, Feedback.
FM tools: Calendar Events, Contacts, Notes, Reminders, Messages, Shortcuts, \
Spotlight, Wikipedia.
"""

    private static let categoryFocuses = [
        "Mix of weather, time, and calculator prompts",
        "Mix of stocks, news, and web fetch prompts",
        "Mix of translate, convert, and dictionary prompts",
        "Mix of maps, email, and calendar prompts",
        "Edge cases: confusable tools (convert vs calculator, time vs timer, read vs reademail)",
        "Adversarial: typos, fragments, mixed languages, emoji, nonsense",
        "Multi-intent: prompts asking for two things at once",
        "Conversational: greetings, opinions, jokes (no tool needed)",
        "Mix of create, game, research, and podcast prompts",
        "Mix of system info, reminders, contacts, notes, messages, shortcuts",
    ]

    private static let externalCategoryFocuses = [
        "Typo-heavy weather, time, and calculator prompts with autocorrect fails",
        "Fragment-style stocks, news, web fetch — no full sentences",
        "Multi-intent run-ons mixing translate, convert, and dictionary",
        "ALL CAPS frustrated requests for maps, email, and calendar",
        "Emoji-laden and mixed-language requests across all tools",
        "Self-corrections and mid-sentence pivots between tools",
        "Extremely vague requests that could match any tool",
        "Sarcastic, rhetorical, and stream-of-consciousness inputs",
        "Confusable pairs: convert vs calculator, time vs timer, stocks vs convert",
        "Filler-word heavy casual requests for create, game, research, podcast",
    ]

    private static let difficultyMixes = [
        "8 easy, 5 medium, 2 hard",
        "5 easy, 5 medium, 3 hard, 2 adversarial",
        "3 easy, 5 medium, 5 hard, 2 adversarial",
        "0 easy, 5 medium, 5 hard, 5 adversarial",
        "10 easy, 3 medium, 2 hard",
    ]

    // MARK: - Retraining Export

    private static let categoryToLabel: [String: String] = [
        "weather": "Weather", "calculator": "Calculator", "convert": "Convert",
        "time": "Time", "timer": "Timer", "maps": "maps", "translate": "Translate",
        "stocks": "stocks", "news": "news", "dictionary": "Dictionary",
        "random": "Random", "email": "Email", "reademail": "ReadEmail",
        "webfetch": "WebFetch", "podcast": "Podcast", "research": "Research",
        "create": "Create", "systeminfo": "SystemInfo", "calendar": "Calendar",
        "read": "Read", "write": "Write", "rewrite": "Rewrite",
        "today": "Today", "feedback": "Feedback",
        "contacts": "contacts", "reminders": "reminders", "messages": "messages",
        "notes": "notes", "shortcuts": "shortcuts", "spotlight": "spotlight",
        "wikipedia": "wikipedia", "general": "general",
    ]

    private struct TrainingEntry: Codable {
        let text: String
        let label: String
    }

    private struct MisrouteEntry: Codable {
        let text: String
        let expected_label: String
        let actual_label: String
        let routing_score: Int
    }

    private func exportForRetraining(_ results: [PromptResult]) {
        var misroutes: [MisrouteEntry] = []
        var validated: [TrainingEntry] = []

        for r in results {
            guard let j = r.judgement else { continue }
            let expectedLabel = Self.categoryToLabel[r.prompt.category.lowercased()] ?? r.prompt.category

            if j.routingScore <= 2 {
                let actualLabel = r.widgetType ?? "unknown"
                misroutes.append(MisrouteEntry(
                    text: r.prompt.text,
                    expected_label: expectedLabel,
                    actual_label: actualLabel,
                    routing_score: j.routingScore
                ))
            }

            if j.routingScore >= 4 {
                validated.append(TrainingEntry(text: r.prompt.text, label: expectedLabel))
            }
        }

        writeJSON(misroutes, to: "misroutes.json")
        writeJSON(validated, to: "validated_prompts.json")
        log.info("Retraining export: \(misroutes.count) misroutes, \(validated.count) validated")
    }
}
