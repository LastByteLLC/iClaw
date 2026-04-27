import SwiftUI

struct EnergyBenchView: View {
    @Bindable var runner: BenchmarkRunner
    @State private var iterations: Int = 10
    @State private var warmup: Int = 2

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Text("Energy Benchmark")
                .font(.title)

            // Status
            HStack {
                if runner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(runner.statusMessage)
                    .foregroundStyle(.secondary)
            }

            if runner.isRunning {
                ProgressView(value: runner.progress)
                    .padding(.horizontal)
            }

            // Controls
            if !runner.isRunning {
                HStack(spacing: 20) {
                    LabeledContent("Iterations per prompt") {
                        Stepper("\(iterations)", value: $iterations, in: 1...100)
                            .frame(width: 100)
                    }
                    LabeledContent("Warmup") {
                        Stepper("\(warmup)", value: $warmup, in: 0...10)
                            .frame(width: 80)
                    }
                    Button("Run Benchmark") {
                        runner.start(iterations: iterations, warmupCount: warmup)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
            }

            Divider()

            // Results
            if let report = runner.report {
                reportView(report)
            } else if !runner.results.isEmpty {
                liveResultsView
            } else {
                ContentUnavailableView(
                    "No Results Yet",
                    systemImage: "bolt.fill",
                    description: Text("Run the benchmark to measure on-device LLM energy consumption.")
                )
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Live Results

    private var liveResultsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Results (\(runner.results.count) measurements)")
                .font(.headline)

            Table(runner.results.suffix(20)) {
                TableColumn("Prompt") { m in
                    Text(m.promptText.prefix(40) + "...")
                        .lineLimit(1)
                }
                TableColumn("Energy (mJ)") { m in
                    Text(String(format: "%.2f", m.totalEnergyMJ))
                        .monospacedDigit()
                }
                .width(90)
                TableColumn("mJ/tok") { m in
                    Text(String(format: "%.4f", m.mjPerToken))
                        .monospacedDigit()
                }
                .width(80)
                TableColumn("tok/s") { m in
                    Text(String(format: "%.1f", m.tokensPerSecond))
                        .monospacedDigit()
                }
                .width(70)
                TableColumn("Latency") { m in
                    Text(String(format: "%.0f ms", m.durationMs))
                        .monospacedDigit()
                }
                .width(80)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Report View

    private func reportView(_ report: BenchmarkReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Device info
                GroupBox("Device") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Chip", value: report.device.chip)
                        LabeledContent("Memory", value: "\(report.device.memoryGB) GB")
                        LabeledContent("OS", value: report.device.osVersion)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                // Aggregate
                GroupBox("Aggregate") {
                    let a = report.aggregate
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Total inferences", value: "\(a.totalInferences)")
                        LabeledContent("Mean energy/query", value: String(format: "%.2f mJ", a.meanEnergyMJ))
                        LabeledContent("Mean energy/token", value: String(format: "%.4f mJ", a.meanMJPerToken))
                        LabeledContent("Mean throughput", value: String(format: "%.1f tok/s", a.meanTokensPerSec))
                        LabeledContent("Mean latency", value: String(format: "%.0f ms", a.meanDurationMs))
                        LabeledContent("Mean power draw", value: String(format: "%.3f W", a.meanWatts))
                        LabeledContent("Efficiency", value: String(format: "%.2f Wh/M tokens", a.whPerMillionTokens))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                // Cloud comparison
                GroupBox("Cloud Comparison") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Model").fontWeight(.semibold).frame(width: 200, alignment: .leading)
                            Text("Wh/M tok").fontWeight(.semibold).frame(width: 80, alignment: .trailing)
                            Text("Ratio").fontWeight(.semibold).frame(width: 60, alignment: .trailing)
                        }
                        Divider()
                        HStack {
                            Text("Apple FM (on-device)").frame(width: 200, alignment: .leading)
                            Text(String(format: "%.2f", report.aggregate.whPerMillionTokens))
                                .monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text("1.00x").monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                        .foregroundStyle(.green)
                        ForEach(report.cloudComparison, id: \.model) { c in
                            HStack {
                                Text(c.model).frame(width: 200, alignment: .leading)
                                Text(String(format: "%.0f", c.estimatedWhPerMillionTokens))
                                    .monospacedDigit().frame(width: 80, alignment: .trailing)
                                Text(c.ratio > 0 ? String(format: "%.2fx", c.ratio) : "N/A")
                                    .monospacedDigit().frame(width: 60, alignment: .trailing)
                            }
                        }
                        Divider()
                        Text("Ratio < 1.0 = on-device is more efficient")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                // Category breakdown
                GroupBox("By Category") {
                    ForEach(report.categorySummaries, id: \.category) { cat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cat.category.replacingOccurrences(of: "_", with: " ").capitalized)
                                .fontWeight(.medium)
                            HStack(spacing: 16) {
                                Text(String(format: "%.2f ± %.2f mJ", cat.meanEnergyMJ, cat.stddevEnergyMJ))
                                Text(String(format: "%.4f mJ/tok", cat.meanMJPerToken))
                                Text(String(format: "%.1f tok/s", cat.meanTokensPerSec))
                                Text(String(format: "%.0f ms", cat.meanDurationMs))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Table conformance

extension PromptMeasurement: Identifiable {
    var id: String { "\(promptText)-\(iteration)" }
}
