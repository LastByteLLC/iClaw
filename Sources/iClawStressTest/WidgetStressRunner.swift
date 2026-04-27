import Foundation
import iClawCore
import OSLog

/// Stress test for LLM-generated dynamic widgets.
///
/// Pipeline:
/// 1. **Generate** — LLM creates prompts designed to elicit rich, structured widget layouts
/// 2. **Execute** — Runs each prompt through the real ExecutionEngine (with WidgetLayoutGenerator active)
/// 3. **Judge** — LLM rates each widget's layout quality, data completeness, and visual appropriateness
/// 4. **Report** — Aggregated metrics + gallery data for on-screen rendering
@Observable
@MainActor
final class WidgetStressRunner: @unchecked Sendable {

    // MARK: - Data Types

    struct WidgetResult: Codable, Sendable, Identifiable {
        var id: Int { index }
        let index: Int
        let prompt: String
        let category: String
        let responseText: String
        let widgetType: String?
        /// Encoded DynamicWidgetData (Codable) — decoded by the view for rendering.
        let widgetDataJSON: Data?
        let isError: Bool
        let timedOut: Bool
        let durationMs: Int
        var judgement: WidgetJudgement?
    }

    struct WidgetJudgement: Codable, Sendable {
        let layoutScore: Int     // 1-5: block diversity, visual hierarchy
        let dataScore: Int       // 1-5: data completeness, accuracy
        let relevanceScore: Int  // 1-5: does the widget match the query?
        let overallScore: Int    // 1-5: overall quality
        let issues: [String]
    }

    struct WidgetReport: Codable, Sendable {
        let date: String
        let totalPrompts: Int
        let widgetsGenerated: Int
        let widgetRate: Double
        let avgLayoutScore: Double
        let avgDataScore: Double
        let avgRelevanceScore: Double
        let avgOverallScore: Double
        let avgDurationMs: Int
        let categoryBreakdown: [CategoryWidgetStats]
        let llmSynthesis: String
    }

    struct CategoryWidgetStats: Codable, Sendable, Identifiable {
        var id: String { category }
        let category: String
        let count: Int
        let widgetCount: Int
        let avgOverall: Double
    }

    // MARK: - State

    var phase: Phase = .idle
    var isRunning = false
    var progress: Double = 0
    var currentItem: String = ""
    var statusMessage: String = "Configure and press Run."

    var totalTarget: Int = 0
    var generatedCount: Int = 0
    var completedCount: Int = 0
    var judgedCount: Int = 0
    var elapsedSeconds: Int = 0

    var results: [WidgetResult] = []
    var report: WidgetReport?

    let tokenTracker = TokenTracker()

    enum Phase: String, CaseIterable {
        case idle = "Ready"
        case generating = "Generating Prompts"
        case executing = "Executing Pipeline"
        case judging = "Judging Widgets"
        case synthesizing = "Synthesizing Report"
        case done = "Complete"
        case failed = "Failed"
    }

    // Config
    private static let promptTimeoutSeconds: UInt64 = 45  // longer — layout gen adds a second LLM call
    private static let judgingBatchSize = 5
    private static let maxConsecutiveFailures = 8

    private var runTask: Task<Void, Never>?
    private var provider: (any LLMProvider)?
    private let log = Logger(subsystem: "com.geticlaw.iClaw.stress", category: "widget")
    private let outputDir: String

    init() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        self.outputDir = "/tmp/iclaw_widget_stress/\(timestamp)"
    }

    // MARK: - Control

    func start(promptCount: Int, provider: any LLMProvider, modelOption: ModelOption) {
        guard !isRunning else { return }
        self.provider = provider
        isRunning = true
        totalTarget = promptCount
        tokenTracker.reset()
        tokenTracker.inputPricePer1M = modelOption.inputPricePer1M
        tokenTracker.outputPricePer1M = modelOption.outputPricePer1M
        phase = .generating
        progress = 0
        generatedCount = 0
        completedCount = 0
        judgedCount = 0
        elapsedSeconds = 0
        results = []
        report = nil
        currentItem = ""
        statusMessage = "Starting..."

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
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        } catch {
            phase = .failed
            statusMessage = "Failed to create output dir: \(error.localizedDescription)"
            return
        }

        await ScratchpadCache.shared.reset()

        // Phase 1: Generate widget-eliciting prompts
        phase = .generating
        statusMessage = "Generating widget-eliciting prompts..."
        let prompts = await generatePrompts(count: promptCount)
        if Task.isCancelled { return }

        if prompts.isEmpty {
            phase = .failed
            statusMessage = "Failed to generate prompts."
            return
        }
        generatedCount = prompts.count

        // Phase 2: Execute
        phase = .executing
        statusMessage = "Running prompts through pipeline..."
        var currentResults = await executePrompts(prompts)
        if Task.isCancelled { return }

        results = currentResults
        writeJSON(currentResults, to: "results_raw.json")

        // Phase 3: Judge widgets
        phase = .judging
        statusMessage = "Judging widget quality..."
        currentResults = await judgeResults(currentResults)
        if Task.isCancelled { return }

        results = currentResults
        writeJSON(currentResults, to: "results_judged.json")

        // Phase 4: Synthesize
        phase = .synthesizing
        statusMessage = "Synthesizing report..."
        let finalReport = await synthesizeReport(currentResults)
        report = finalReport
        writeJSON(finalReport, to: "report.json")

        phase = .done
        statusMessage = "Complete. \(currentResults.filter { $0.widgetType == "DynamicWidget" }.count)/\(currentResults.count) prompts produced widgets."
    }

    // MARK: - Phase 1: Generate

    private struct GeneratedWidgetPrompt: Sendable {
        let text: String
        let category: String
    }

    private func generatePrompts(count: Int) async -> [GeneratedWidgetPrompt] {
        guard let provider else { return Self.builtInPrompts }
        var all: [GeneratedWidgetPrompt] = []
        var failures = 0
        let batchSize = provider is AppleFoundationProvider ? 8 : 30

        while all.count < count && !Task.isCancelled {
            let remaining = count - all.count
            let thisBatch = min(batchSize, remaining)
            let focus = Self.categoryFocuses[all.count / max(batchSize, 1) % Self.categoryFocuses.count]

            let prompt = """
            Generate exactly \(thisBatch) prompts that a user would ask a voice assistant, where the answer \
            is BEST shown as a structured card/widget — not just plain text.
            Focus: \(focus)
            Each prompt should elicit data suitable for: stats, key-value pairs, lists, tables, or comparison grids.
            Categories: person, country, science, car, company, food, sport, comparison, history, technology, health, finance, animal, city
            Format — one per line: category|prompt text
            Examples:
            person|Tell me about Marie Curie
            country|What's the population of Japan?
            car|Compare Tesla Model 3 and BMW i4
            company|Key facts about Apple Inc
            science|What is photosynthesis?
            city|Tell me about Barcelona
            comparison|iPhone 16 vs Samsung S25 specs
            \(thisBatch) lines, nothing else:
            """

            do {
                let response = try await provider.generateText(prompt)
                tokenTracker.record(response)
                let parsed = Self.parseWidgetPrompts(response.text)

                if parsed.isEmpty {
                    failures += 1
                    if failures >= Self.maxConsecutiveFailures { break }
                    continue
                }

                failures = 0
                all.append(contentsOf: parsed)
                generatedCount = all.count
                progress = Double(all.count) / Double(count)
                currentItem = "Generated \(all.count)/\(count)"
            } catch {
                failures += 1
                log.error("Generation: \(error.localizedDescription)")
                if failures >= Self.maxConsecutiveFailures { break }
            }
        }

        // Pad with built-in prompts if needed
        if all.count < count {
            let needed = count - all.count
            all.append(contentsOf: Self.builtInPrompts.prefix(needed))
        }

        return Array(all.prefix(count))
    }

    private static func parseWidgetPrompts(_ raw: String) -> [GeneratedWidgetPrompt] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.split(separator: "|", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let category = String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let text = String(parts[1]).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return GeneratedWidgetPrompt(text: text, category: category)
            }
    }

    // MARK: - Phase 2: Execute

    private struct EngineResult: Sendable {
        let text: String
        let widgetType: String?
        let widgetData: (any Sendable)?
        let isError: Bool
    }

    private struct TimeoutError: Error {}

    private func executePrompts(_ prompts: [GeneratedWidgetPrompt]) async -> [WidgetResult] {
        var results: [WidgetResult] = []

        // Auto-approve consent so tools don't hang waiting for UI confirmation
        ConsentManager.shared.autoApproveActions = true

        // Use real tools but spy out side-effect tools
        let sideEffectNames: Set<String> = ["Email", "Create"]
        var safeCore: [any CoreTool] = ToolRegistry.coreTools.filter { !sideEffectNames.contains($0.name) }
        for name in sideEffectNames {
            let orig = ToolRegistry.coreTools.first { $0.name == name }
            safeCore.append(WidgetSpyTool(name: name, schema: orig?.schema ?? "\(name) tool.", category: orig?.category ?? .offline))
        }

        let engine = ExecutionEngine(
            preprocessor: InputPreprocessor(),
            router: ToolRouter(availableTools: safeCore, fmTools: ToolRegistry.fmTools),
            conversationManager: ConversationManager(),
            finalizer: OutputFinalizer(),
            planner: ExecutionPlanner()
        )

        for (i, prompt) in prompts.enumerated() {
            guard !Task.isCancelled else { break }

            let start = DispatchTime.now()
            currentItem = prompt.text

            var text: String
            var widgetType: String?
            var widgetData: (any Sendable)?
            var isError: Bool
            var timedOut = false

            do {
                let result = try await withThrowingTaskGroup(of: EngineResult.self) { group in
                    group.addTask {
                        let r = await engine.run(input: prompt.text)
                        return EngineResult(text: r.text, widgetType: r.widgetType, widgetData: r.widgetData, isError: r.isError)
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
                widgetType = result.widgetType
                widgetData = result.widgetData
                isError = result.isError
            } catch is TimeoutError {
                text = "[TIMEOUT after \(Self.promptTimeoutSeconds)s]"
                widgetType = nil
                widgetData = nil
                isError = true
                timedOut = true
            } catch {
                text = "[ERROR: \(error.localizedDescription)]"
                widgetType = nil
                widgetData = nil
                isError = true
            }

            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

            // Encode DynamicWidgetData to JSON for Codable storage + view rendering
            var widgetDataJSON: Data?
            if let dw = widgetData as? DynamicWidgetData {
                widgetDataJSON = try? JSONEncoder().encode(dw)
            }

            results.append(WidgetResult(
                index: i,
                prompt: prompt.text,
                category: prompt.category,
                responseText: text,
                widgetType: widgetType,
                widgetDataJSON: widgetDataJSON,
                isError: isError,
                timedOut: timedOut,
                durationMs: elapsed
            ))

            completedCount = results.count
            progress = Double(results.count) / Double(prompts.count)

            // Reset engine between prompts so each gets a fresh context
            await engine.reset()
        }

        return results
    }

    // MARK: - Phase 3: Judge

    private func judgeResults(_ results: [WidgetResult]) async -> [WidgetResult] {
        var judged = results
        guard let provider else { return judged }

        // Only judge results that produced a DynamicWidget
        let widgetIndices = results.enumerated()
            .filter { $0.element.widgetType == "DynamicWidget" && $0.element.widgetDataJSON != nil }
            .map(\.offset)

        for batchStart in stride(from: 0, to: widgetIndices.count, by: Self.judgingBatchSize) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + Self.judgingBatchSize, widgetIndices.count)
            let batchIdxs = Array(widgetIndices[batchStart..<batchEnd])

            var lines = ""
            for (j, idx) in batchIdxs.enumerated() {
                let r = results[idx]
                // Describe the widget blocks for the judge
                let blockDesc: String
                if let data = r.widgetDataJSON,
                   let dw = try? JSONDecoder().decode(DynamicWidgetData.self, from: data) {
                    blockDesc = dw.blocks.map { describeBlock($0) }.joined(separator: ", ")
                } else {
                    blockDesc = "unknown"
                }
                lines += "---\n#\(j + 1)\nPrompt: \(r.prompt)\nResponse: \(String(r.responseText.prefix(150)))\nWidget blocks: \(blockDesc)\n"
            }

            let judgePrompt = """
            Rate each dynamic widget generated by an AI assistant. \
            Widgets are composed of blocks (header, stat, keyValue, itemList, table, image, etc.).
            \(lines)
            For each widget rate:
            - layout (1-5): Visual hierarchy, block diversity, appropriate types chosen
            - data (1-5): Data completeness, accuracy, well-labeled
            - relevance (1-5): Does the widget match the user's query?
            - overall (1-5): Overall quality
            - issues: Brief problems (or "none")
            Format: #N|layout:X|data:X|relevance:X|overall:X|issues:text
            \(batchIdxs.count) lines:
            """

            do {
                let response = try await provider.generateText(judgePrompt)
                tokenTracker.record(response)
                let judgements = Self.parseWidgetJudgements(response.text, count: batchIdxs.count)

                for (j, judgement) in judgements.enumerated() {
                    if j < batchIdxs.count {
                        judged[batchIdxs[j]].judgement = judgement
                    }
                }
            } catch {
                log.error("Widget judge batch: \(error.localizedDescription)")
            }

            judgedCount = judged.filter { $0.judgement != nil }.count
            currentItem = "Judged \(judgedCount)/\(widgetIndices.count) widgets"
        }

        return judged
    }

    private func describeBlock(_ block: WidgetBlock) -> String {
        switch block {
        case .header(let h): return "header(\(h.title))"
        case .image: return "image"
        case .stat(let s): return "stat(\(s.value))"
        case .statRow(let sr): return "statRow(\(sr.items.count))"
        case .keyValue(let kv): return "keyValue(\(kv.pairs.count) pairs)"
        case .itemList(let l): return "itemList(\(l.items.count) items)"
        case .chipRow(let c): return "chipRow(\(c.chips.count))"
        case .text(let t): return "text(\(t.style))"
        case .divider: return "divider"
        case .table(let tb): return "table(\(tb.headers.count)x\(tb.rows.count))"
        case .progress(let p): return "progress(\(p.value))"
        }
    }

    private static func parseWidgetJudgements(_ raw: String, count: Int) -> [WidgetJudgement] {
        let pattern = try? NSRegularExpression(pattern: #"^#\d+\|"#)
        return raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let pattern else { return line.hasPrefix("#") }
                let range = NSRange(line.startIndex..., in: line)
                return pattern.firstMatch(in: line, range: range) != nil
            }
            .prefix(count)
            .map { line -> WidgetJudgement in
                var layout = 3, data = 3, relevance = 3, overall = 3
                var issues: [String] = []

                for part in line.split(separator: "|") {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("layout:") {
                        layout = Int(t.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if t.hasPrefix("data:") {
                        data = Int(t.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if t.hasPrefix("relevance:") {
                        relevance = Int(t.dropFirst(10).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if t.hasPrefix("overall:") {
                        overall = Int(t.dropFirst(8).trimmingCharacters(in: .whitespaces)) ?? 3
                    } else if t.hasPrefix("issues:") {
                        let s = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                        if s.lowercased() != "none" && !s.isEmpty {
                            issues = s.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
                        }
                    }
                }

                return WidgetJudgement(
                    layoutScore: max(1, min(5, layout)),
                    dataScore: max(1, min(5, data)),
                    relevanceScore: max(1, min(5, relevance)),
                    overallScore: max(1, min(5, overall)),
                    issues: issues
                )
            }
    }

    // MARK: - Phase 4: Synthesize

    private func synthesizeReport(_ results: [WidgetResult]) async -> WidgetReport {
        let widgets = results.filter { $0.widgetType == "DynamicWidget" }
        let judged = widgets.filter { $0.judgement != nil }
        let widgetRate = results.isEmpty ? 0 : Double(widgets.count) / Double(results.count)

        let grouped = Dictionary(grouping: results, by: { $0.category })
        let categoryStats: [CategoryWidgetStats] = grouped.map { cat, items in
            let wCount = items.filter { $0.widgetType == "DynamicWidget" }.count
            let j = items.compactMap(\.judgement)
            let avgOverall = j.isEmpty ? 0.0 : Double(j.map(\.overallScore).reduce(0, +)) / Double(j.count)
            return CategoryWidgetStats(category: cat, count: items.count, widgetCount: wCount, avgOverall: avgOverall)
        }.sorted { $0.avgOverall < $1.avgOverall }

        // Synthesis prompt
        var catLines = ""
        for s in categoryStats {
            catLines += "\(s.category): n=\(s.count) widgets=\(s.widgetCount) avg=\(String(format: "%.1f", s.avgOverall))\n"
        }

        var synthesisText = "LLM synthesis unavailable."
        if let provider {
            let synthesisPrompt = """
            Analyze widget stress test results for iClaw AI assistant.
            \(results.count) prompts, \(widgets.count) produced dynamic widgets (\(String(format: "%.0f", widgetRate * 100))%).
            Categories:
            \(catLines)
            Provide: 1) Which categories produce best/worst widgets 2) Common layout issues 3) Data quality patterns 4) Suggestions to improve widget generation
            """
            do {
                let response = try await provider.generateText(synthesisPrompt)
                tokenTracker.record(response)
                synthesisText = response.text
            } catch {
                log.error("Synthesis: \(error.localizedDescription)")
            }
        }

        let scores = judged.compactMap(\.judgement)
        return WidgetReport(
            date: ISO8601DateFormatter().string(from: Date()),
            totalPrompts: results.count,
            widgetsGenerated: widgets.count,
            widgetRate: widgetRate,
            avgLayoutScore: scores.isEmpty ? 0 : Double(scores.map(\.layoutScore).reduce(0, +)) / Double(scores.count),
            avgDataScore: scores.isEmpty ? 0 : Double(scores.map(\.dataScore).reduce(0, +)) / Double(scores.count),
            avgRelevanceScore: scores.isEmpty ? 0 : Double(scores.map(\.relevanceScore).reduce(0, +)) / Double(scores.count),
            avgOverallScore: scores.isEmpty ? 0 : Double(scores.map(\.overallScore).reduce(0, +)) / Double(scores.count),
            avgDurationMs: results.isEmpty ? 0 : results.map(\.durationMs).reduce(0, +) / results.count,
            categoryBreakdown: categoryStats,
            llmSynthesis: synthesisText
        )
    }

    // MARK: - Helpers

    private func writeJSON<T: Encodable>(_ value: T, to filename: String) {
        writeJSONFile(value, to: filename, in: outputDir)
    }

    // MARK: - Built-in Prompts

    private static let builtInPrompts: [GeneratedWidgetPrompt] = [
        // Person / athlete / actor (6)
        .init(text: "Tell me about Keanu Reeves", category: "person"),
        .init(text: "Who was Nikola Tesla?", category: "person"),
        .init(text: "Tell me about Marie Curie", category: "person"),
        .init(text: "Show career stats of LeBron James", category: "athlete"),
        .init(text: "List Olympic medals won by Usain Bolt", category: "athlete"),
        .init(text: "Key facts about Meryl Streep", category: "actor"),
        // Country (3)
        .init(text: "What's the population of Brazil?", category: "country"),
        .init(text: "Tell me about Japan", category: "country"),
        .init(text: "Key facts about Germany: capital, population, GDP", category: "country"),
        // City (3)
        .init(text: "Tell me about Barcelona", category: "city"),
        .init(text: "Top tourist attractions in Paris", category: "city"),
        .init(text: "Key statistics for Tokyo", category: "city"),
        // Car (3)
        .init(text: "Compare Tesla Model 3 and BMW i4 specs", category: "car"),
        .init(text: "Porsche Taycan horsepower, range, and price", category: "car"),
        .init(text: "Ford Mustang Mach-E vs Volkswagen ID.4 specs", category: "car"),
        // Company (3)
        .init(text: "Key facts about Apple Inc", category: "company"),
        .init(text: "Profile of Microsoft: CEO, revenue, founding year", category: "company"),
        .init(text: "Compare revenue of Coca-Cola and PepsiCo", category: "company"),
        // Science (3)
        .init(text: "What is photosynthesis?", category: "science"),
        .init(text: "Properties of the element Oxygen", category: "science"),
        .init(text: "How does nuclear fusion work?", category: "science"),
        // Comparison / technology (3)
        .init(text: "iPhone 16 vs Samsung S25 specs", category: "comparison"),
        .init(text: "Compare Python and JavaScript", category: "comparison"),
        .init(text: "PlayStation 5 vs Xbox Series X features", category: "technology"),
        // Food (3)
        .init(text: "Nutrition facts for avocado", category: "food"),
        .init(text: "Compare calories of chicken breast vs salmon", category: "food"),
        .init(text: "Nutritional breakdown of a banana", category: "food"),
        // Health (3)
        .init(text: "What are the symptoms of diabetes?", category: "health"),
        .init(text: "BMI categories and their ranges", category: "health"),
        .init(text: "Common symptoms and treatments for flu", category: "health"),
        // Finance (3)
        .init(text: "Tell me about the S&P 500", category: "finance"),
        .init(text: "Key financial ratios of Apple Inc", category: "finance"),
        .init(text: "Compare market cap of top 5 tech companies", category: "finance"),
        // Sport (3)
        .init(text: "NBA standings this season", category: "sport"),
        .init(text: "FIFA World Cup winners list", category: "sport"),
        .init(text: "Top 10 all-time scoring leaders in the Premier League", category: "sport"),
        // Animal (3)
        .init(text: "Facts about blue whales", category: "animal"),
        .init(text: "Compare lifespan and weight of lions and tigers", category: "animal"),
        .init(text: "Key facts about African elephants", category: "animal"),
        // History (3)
        .init(text: "History of the Roman Empire", category: "history"),
        .init(text: "Timeline of major events in World War II", category: "history"),
        .init(text: "List US presidents with their terms", category: "history"),
    ]

    private static let categoryFocuses = [
        "People: actors, scientists, athletes, historical figures — elicit bio cards with stats",
        "Countries — population, GDP, language, capital stats, comparisons between nations",
        "Cities — population, landmarks, key statistics, cost of living",
        "Car comparisons — spec tables with range, horsepower, price (max 2 per batch)",
        "Company profiles — key-value facts about revenue, CEO, founding, market cap",
        "Science topics — properties, processes, explanatory cards with key metrics",
        "Health and nutrition — symptoms, treatments, nutrient breakdowns, food comparisons",
        "Sports and athletes — career stats, rankings, medal counts, league tables",
        "Finance and economics — market data, financial ratios, economic indicators",
        "Animals and nature — species facts, comparisons, habitat data",
        "History — timelines, key events, figure bios, era summaries",
        "Technology — device specs, feature comparisons, how-it-works cards",
    ]
}

// MARK: - Spy Tool

private final class WidgetSpyTool: CoreTool, @unchecked Sendable {
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
