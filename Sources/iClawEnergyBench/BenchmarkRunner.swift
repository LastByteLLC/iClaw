import Foundation
import FoundationModels
import os

// MARK: - Data Types

struct BenchmarkPrompt: Sendable {
    let text: String
    let category: String
    let expectedOutputLength: String // "short", "medium", "long"
}

struct PromptMeasurement: Codable, Sendable {
    let promptText: String
    let category: String
    let iteration: Int
    let outputLength: Int
    let estimatedTokens: Int
    let cpuEnergyMJ: Double
    let gpuEnergyMJ: Double
    let totalEnergyMJ: Double
    let durationMs: Double
    let tokensPerSecond: Double
    let mjPerToken: Double
    let wattsAverage: Double
}

struct CategorySummary: Codable, Sendable {
    let category: String
    let promptCount: Int
    let totalIterations: Int
    let meanEnergyMJ: Double
    let medianEnergyMJ: Double
    let stddevEnergyMJ: Double
    let meanMJPerToken: Double
    let meanTokensPerSec: Double
    let meanDurationMs: Double
    let meanWatts: Double
}

struct BenchmarkReport: Codable, Sendable {
    let device: DeviceInfo
    let config: RunConfig
    let measurements: [PromptMeasurement]
    let categorySummaries: [CategorySummary]
    let aggregate: AggregateSummary
    let cloudComparison: [CloudComparison]
}

struct DeviceInfo: Codable, Sendable {
    let chip: String
    let memoryGB: Int
    let osVersion: String
    let modelName: String
}

struct RunConfig: Codable, Sendable {
    let iterationsPerPrompt: Int
    let warmupIterations: Int
    let promptCount: Int
    let timestamp: String
}

struct AggregateSummary: Codable, Sendable {
    let totalInferences: Int
    let meanEnergyMJ: Double
    let medianEnergyMJ: Double
    let p95EnergyMJ: Double
    let meanMJPerToken: Double
    let meanTokensPerSec: Double
    let meanDurationMs: Double
    let meanWatts: Double
    let totalEnergyWh: Double
    let whPerMillionTokens: Double
}

struct CloudComparison: Codable, Sendable {
    let model: String
    let estimatedWhPerMillionTokens: Double
    let ratio: Double // local / cloud
    let note: String
}

// MARK: - Runner

@Observable
@MainActor
final class BenchmarkRunner {
    var isRunning = false
    var statusMessage = "Ready"
    var progress: Double = 0
    var results: [PromptMeasurement] = []
    var report: BenchmarkReport?

    private let meter = EnergyMeter()
    private let logger = Logger(subsystem: "com.geticlaw.EnergyBench", category: "runner")

    static let standardPrompts: [BenchmarkPrompt] = [
        // Short factual
        BenchmarkPrompt(text: "What is the capital of France?", category: "short_factual", expectedOutputLength: "short"),
        BenchmarkPrompt(text: "How many planets are in the solar system?", category: "short_factual", expectedOutputLength: "short"),
        BenchmarkPrompt(text: "What year did World War II end?", category: "short_factual", expectedOutputLength: "short"),

        // Medium conversational
        BenchmarkPrompt(text: "Explain photosynthesis in simple terms.", category: "medium_conversational", expectedOutputLength: "medium"),
        BenchmarkPrompt(text: "What are the main differences between Python and Swift?", category: "medium_conversational", expectedOutputLength: "medium"),
        BenchmarkPrompt(text: "Describe how a refrigerator works.", category: "medium_conversational", expectedOutputLength: "medium"),

        // Long generation
        BenchmarkPrompt(text: "Write a short story about a robot learning to paint.", category: "long_generation", expectedOutputLength: "long"),
        BenchmarkPrompt(text: "Explain the history of the internet from ARPANET to today.", category: "long_generation", expectedOutputLength: "long"),

        // Reasoning
        BenchmarkPrompt(text: "If a train leaves at 3pm going 60mph and another at 4pm going 80mph, when does the second catch up?", category: "reasoning", expectedOutputLength: "medium"),
        BenchmarkPrompt(text: "A farmer has chickens and cows. He counts 20 heads and 56 legs. How many of each?", category: "reasoning", expectedOutputLength: "medium"),
    ]

    func start(iterations: Int = 10, warmupCount: Int = 2) {
        guard !isRunning else { return }
        isRunning = true
        results = []
        report = nil
        progress = 0
        statusMessage = "Starting benchmark..."

        Task {
            await runBenchmark(iterations: iterations, warmupCount: warmupCount)
        }
    }

    private func runBenchmark(iterations: Int, warmupCount: Int) async {
        let prompts = Self.standardPrompts
        let totalWork = warmupCount + (prompts.count * iterations)
        var completedWork = 0

        // Warmup phase — prime the model, discard measurements
        statusMessage = "Warming up model (\(warmupCount) iterations)..."
        for i in 0..<warmupCount {
            logger.info("Warmup \(i + 1)/\(warmupCount)")
            do {
                let session = LanguageModelSession(model: .default)
                _ = try await session.respond(to: "Hello")
            } catch {
                logger.warning("Warmup failed: \(error.localizedDescription)")
            }
            completedWork += 1
            progress = Double(completedWork) / Double(totalWork)
        }

        // Measurement phase
        statusMessage = "Running measurements..."
        var measurements: [PromptMeasurement] = []

        for prompt in prompts {
            for iteration in 1...iterations {
                statusMessage = "[\(prompt.category)] iteration \(iteration)/\(iterations): \(prompt.text.prefix(40))..."
                logger.info("Measuring: \(prompt.category) iter \(iteration)")

                let measurement = await measureSingleInference(prompt: prompt, iteration: iteration)
                if let m = measurement {
                    measurements.append(m)
                    results = measurements
                }

                completedWork += 1
                progress = Double(completedWork) / Double(totalWork)
            }
        }

        // Generate report
        statusMessage = "Generating report..."
        let finalReport = buildReport(
            measurements: measurements,
            prompts: prompts,
            iterations: iterations,
            warmupCount: warmupCount
        )
        report = finalReport

        // Save to disk
        await saveReport(finalReport)

        statusMessage = "Complete — \(measurements.count) measurements"
        isRunning = false
    }

    private func measureSingleInference(prompt: BenchmarkPrompt, iteration: Int) async -> PromptMeasurement? {
        let before = meter.snapshot()

        let responseText: String
        do {
            let session = LanguageModelSession(model: .default)
            let response = try await session.respond(to: prompt.text)
            responseText = response.content
        } catch {
            logger.error("Inference failed: \(error.localizedDescription)")
            return nil
        }

        let after = meter.snapshot()
        let measurement = meter.measure(from: before, to: after)

        let estimatedTokens = max(1, responseText.count / 4)

        return PromptMeasurement(
            promptText: prompt.text,
            category: prompt.category,
            iteration: iteration,
            outputLength: responseText.count,
            estimatedTokens: estimatedTokens,
            cpuEnergyMJ: measurement.cpuEnergyMJ,
            gpuEnergyMJ: measurement.gpuEnergyMJ,
            totalEnergyMJ: measurement.totalEnergyMJ,
            durationMs: measurement.durationMs,
            tokensPerSecond: Double(estimatedTokens) / (measurement.durationMs / 1000.0),
            mjPerToken: measurement.energyPerToken(tokens: estimatedTokens),
            wattsAverage: measurement.wattsAverage
        )
    }

    // MARK: - Report Building

    private func buildReport(
        measurements: [PromptMeasurement],
        prompts: [BenchmarkPrompt],
        iterations: Int,
        warmupCount: Int
    ) -> BenchmarkReport {
        let categories = Set(measurements.map(\.category))
        let categorySummaries = categories.sorted().map { cat -> CategorySummary in
            let catMeasurements = measurements.filter { $0.category == cat }
            let energies = catMeasurements.map(\.totalEnergyMJ).sorted()
            let mean = energies.mean
            let median = energies.median
            let stddev = energies.stddev

            return CategorySummary(
                category: cat,
                promptCount: Set(catMeasurements.map(\.promptText)).count,
                totalIterations: catMeasurements.count,
                meanEnergyMJ: mean,
                medianEnergyMJ: median,
                stddevEnergyMJ: stddev,
                meanMJPerToken: catMeasurements.map(\.mjPerToken).mean,
                meanTokensPerSec: catMeasurements.map(\.tokensPerSecond).mean,
                meanDurationMs: catMeasurements.map(\.durationMs).mean,
                meanWatts: catMeasurements.map(\.wattsAverage).mean
            )
        }

        let allEnergies = measurements.map(\.totalEnergyMJ).sorted()
        let totalTokens = measurements.map(\.estimatedTokens).reduce(0, +)
        let totalEnergyMJ = measurements.map(\.totalEnergyMJ).reduce(0, +)
        let totalEnergyWh = totalEnergyMJ / 1_000.0 / 3600.0
        let whPerMillion = totalTokens > 0 ? (totalEnergyWh / Double(totalTokens)) * 1_000_000 : 0

        let aggregate = AggregateSummary(
            totalInferences: measurements.count,
            meanEnergyMJ: allEnergies.mean,
            medianEnergyMJ: allEnergies.median,
            p95EnergyMJ: allEnergies.percentile(95),
            meanMJPerToken: measurements.map(\.mjPerToken).mean,
            meanTokensPerSec: measurements.map(\.tokensPerSecond).mean,
            meanDurationMs: measurements.map(\.durationMs).mean,
            meanWatts: measurements.map(\.wattsAverage).mean,
            totalEnergyWh: totalEnergyWh,
            whPerMillionTokens: whPerMillion
        )

        // Published energy estimates for cloud LLMs (approximate)
        let cloudComparisons: [CloudComparison] = [
            CloudComparison(
                model: "GPT-4 (cloud)",
                estimatedWhPerMillionTokens: 4500,
                ratio: whPerMillion > 0 ? whPerMillion / 4500 : 0,
                note: "Estimated from published datacenter PUE + GPU power draw"
            ),
            CloudComparison(
                model: "GPT-4o (cloud)",
                estimatedWhPerMillionTokens: 1500,
                ratio: whPerMillion > 0 ? whPerMillion / 1500 : 0,
                note: "More efficient architecture, estimated from inference benchmarks"
            ),
            CloudComparison(
                model: "Claude 3.5 Sonnet (cloud)",
                estimatedWhPerMillionTokens: 2000,
                ratio: whPerMillion > 0 ? whPerMillion / 2000 : 0,
                note: "Estimated from Anthropic efficiency claims + datacenter overhead"
            ),
            CloudComparison(
                model: "Llama 3 8B (local GPU)",
                estimatedWhPerMillionTokens: 300,
                ratio: whPerMillion > 0 ? whPerMillion / 300 : 0,
                note: "RTX 4090 local inference, excludes system idle power"
            ),
        ]

        return BenchmarkReport(
            device: collectDeviceInfo(),
            config: RunConfig(
                iterationsPerPrompt: iterations,
                warmupIterations: warmupCount,
                promptCount: prompts.count,
                timestamp: ISO8601DateFormatter().string(from: Date())
            ),
            measurements: measurements,
            categorySummaries: categorySummaries,
            aggregate: aggregate,
            cloudComparison: cloudComparisons
        )
    }

    private func collectDeviceInfo() -> DeviceInfo {
        var chip = "Unknown"

        // Get chip name
        var chipBuf = [CChar](repeating: 0, count: 256)
        var chipLen = chipBuf.count
        if sysctlbyname("machdep.cpu.brand_string", &chipBuf, &chipLen, nil, 0) == 0 {
            chip = String(decoding: chipBuf.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
        }

        // Get RAM
        var memSize: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &len, nil, 0)
        let memGB = Int(memSize / (1024 * 1024 * 1024))

        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return DeviceInfo(
            chip: chip,
            memoryGB: memGB,
            osVersion: osVersion,
            modelName: "Apple Foundation Model (on-device)"
        )
    }

    // MARK: - Persistence

    private func saveReport(_ report: BenchmarkReport) async {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = "/tmp/iclaw_energy_bench/\(timestamp)"

        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)

            let reportPath = "\(dir)/report.json"
            try data.write(to: URL(fileURLWithPath: reportPath))

            // Also write a human-readable summary
            let summary = formatSummary(report)
            let summaryPath = "\(dir)/summary.txt"
            try summary.write(toFile: summaryPath, atomically: true, encoding: .utf8)

            logger.info("Report saved to \(dir)")
            statusMessage = "Complete — saved to \(dir)"
        } catch {
            logger.error("Failed to save report: \(error.localizedDescription)")
        }
    }

    private func formatSummary(_ report: BenchmarkReport) -> String {
        var lines: [String] = []
        lines.append("═══════════════════════════════════════════════════════")
        lines.append("  iClaw Energy Benchmark Report")
        lines.append("═══════════════════════════════════════════════════════")
        lines.append("")
        lines.append("Device: \(report.device.chip)")
        lines.append("Memory: \(report.device.memoryGB) GB")
        lines.append("OS:     \(report.device.osVersion)")
        lines.append("Model:  \(report.device.modelName)")
        lines.append("Date:   \(report.config.timestamp)")
        lines.append("")
        lines.append("Config: \(report.config.promptCount) prompts × \(report.config.iterationsPerPrompt) iterations")
        lines.append("        \(report.config.warmupIterations) warmup iterations")
        lines.append("")

        lines.append("── Aggregate ──────────────────────────────────────────")
        let a = report.aggregate
        lines.append(String(format: "  Total inferences:     %d", a.totalInferences))
        lines.append(String(format: "  Mean energy/query:    %.2f mJ", a.meanEnergyMJ))
        lines.append(String(format: "  Median energy/query:  %.2f mJ", a.medianEnergyMJ))
        lines.append(String(format: "  P95 energy/query:     %.2f mJ", a.p95EnergyMJ))
        lines.append(String(format: "  Mean energy/token:    %.4f mJ", a.meanMJPerToken))
        lines.append(String(format: "  Mean throughput:      %.1f tok/s", a.meanTokensPerSec))
        lines.append(String(format: "  Mean latency:         %.0f ms", a.meanDurationMs))
        lines.append(String(format: "  Mean power draw:      %.3f W", a.meanWatts))
        lines.append(String(format: "  Total energy:         %.6f Wh", a.totalEnergyWh))
        lines.append(String(format: "  Efficiency:           %.2f Wh/M tokens", a.whPerMillionTokens))
        lines.append("")

        lines.append("── By Category ────────────────────────────────────────")
        for cat in report.categorySummaries {
            lines.append(String(format: "  %@:", cat.category))
            lines.append(String(format: "    Energy:    %.2f ± %.2f mJ/query", cat.meanEnergyMJ, cat.stddevEnergyMJ))
            lines.append(String(format: "    Per-token: %.4f mJ/tok", cat.meanMJPerToken))
            lines.append(String(format: "    Speed:     %.1f tok/s", cat.meanTokensPerSec))
            lines.append(String(format: "    Latency:   %.0f ms", cat.meanDurationMs))
        }
        lines.append("")

        lines.append("── Cloud Comparison ───────────────────────────────────")
        lines.append("  \("Model".padding(toLength: 28, withPad: " ", startingAt: 0))  \("Wh/M tokens".padding(toLength: 12, withPad: " ", startingAt: 0))  \("Ratio".padding(toLength: 8, withPad: " ", startingAt: 0))")
        lines.append("  \("Apple FM (on-device)".padding(toLength: 28, withPad: " ", startingAt: 0))  \(String(format: "%12.2f", a.whPerMillionTokens))  \("1.00x".padding(toLength: 8, withPad: " ", startingAt: 0))")
        for c in report.cloudComparison {
            let ratioStr = c.ratio > 0 ? String(format: "%.2fx", c.ratio) : "N/A"
            lines.append("  \(c.model.padding(toLength: 28, withPad: " ", startingAt: 0))  \(String(format: "%12.0f", c.estimatedWhPerMillionTokens))  \(ratioStr.padding(toLength: 8, withPad: " ", startingAt: 0))")
        }
        lines.append("")
        lines.append("  Ratio < 1.0 = on-device is MORE efficient than cloud")
        lines.append("  Note: Cloud estimates include datacenter overhead (PUE ~1.2)")
        lines.append("")
        lines.append("═══════════════════════════════════════════════════════")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Statistics Helpers

private extension Array where Element == Double {
    var mean: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }

    var median: Double {
        guard !isEmpty else { return 0 }
        let s = sorted()
        if s.count % 2 == 0 {
            return (s[s.count / 2 - 1] + s[s.count / 2]) / 2.0
        }
        return s[s.count / 2]
    }

    var stddev: Double {
        guard count > 1 else { return 0 }
        let m = mean
        let variance = map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count - 1)
        return variance.squareRoot()
    }

    func percentile(_ p: Int) -> Double {
        guard !isEmpty else { return 0 }
        let s = sorted()
        let index = Double(p) / 100.0 * Double(s.count - 1)
        let lower = Int(index)
        let upper = Swift.min(lower + 1, s.count - 1)
        let weight = index - Double(lower)
        return s[lower] * (1 - weight) + s[upper] * weight
    }
}
