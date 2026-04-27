import SwiftUI
import iClawCore

enum StressTestMode: String, CaseIterable, Identifiable {
    case routing = "Routing"
    case followUp = "Follow-Up"
    case widget = "Widget"
    var id: String { rawValue }
}

struct StressTestView: View {
    @Bindable var runner: StressTestRunner
    @State var followUpRunner = FollowUpStressRunner()
    @State var widgetRunner = WidgetStressRunner()
    @State private var promptCount: Int = 100
    @State private var showingExport = false
    @State private var testMode: StressTestMode = .routing

    // Provider config
    @State private var selectedProvider: ProviderKind = .appleFoundation
    @State private var selectedModelId: String = "default"
    @State private var apiKey: String = ""
    @State private var isValidatingKey: Bool = false
    @State private var keyValidationResult: KeyValidationResult?

    private let promptOptions = [50, 100, 250, 500, 1000]
    private let conversationOptions = [8, 20, 50, 100]
    private let widgetOptions = [10, 20, 50, 100]

    private enum KeyValidationResult {
        case valid
        case invalid(String)
    }

    private var selectedModel: ModelOption {
        selectedProvider.models.first { $0.id == selectedModelId }
            ?? selectedProvider.models[0]
    }

    private var apiKeyFormatValid: Bool {
        if !selectedProvider.requiresAPIKey { return true }
        if apiKey.count < selectedProvider.keyMinLength { return false }
        if let prefix = selectedProvider.keyPrefix, !apiKey.hasPrefix(prefix) { return false }
        return true
    }

    private var canRun: Bool {
        if runner.isRunning || followUpRunner.isRunning || widgetRunner.isRunning { return false }
        if selectedProvider == .appleFoundation { return true }
        if case .valid = keyValidationResult { return true }
        return false
    }

    /// Whether either runner is idle (show config) or active (show progress).
    private var isIdle: Bool {
        switch testMode {
        case .followUp: return followUpRunner.phase == .idle
        case .widget: return widgetRunner.phase == .idle || widgetRunner.phase == .failed
        case .routing: return runner.phase == .idle || runner.phase == .failed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isIdle {
                        providerConfigSection
                    }

                    switch testMode {
                    case .followUp:
                        // Follow-Up mode UI
                        if followUpRunner.phase != .idle {
                            followUpProgressSection
                        }
                        if followUpRunner.phase == .done, let report = followUpRunner.report {
                            followUpReportSection(report)
                        }
                        if followUpRunner.phase == .failed {
                            Text("Follow-up stress test failed.")
                                .foregroundStyle(.red)
                        }

                    case .widget:
                        // Widget mode UI
                        if widgetRunner.phase != .idle {
                            widgetProgressSection
                        }
                        if widgetRunner.phase == .done, let report = widgetRunner.report {
                            widgetReportSection(report)
                        }
                        if widgetRunner.phase == .done {
                            widgetGallerySection
                        }
                        if widgetRunner.phase == .failed {
                            Text(widgetRunner.statusMessage)
                                .foregroundStyle(.red)
                        }

                    case .routing:
                        // Routing mode UI (existing)
                        if runner.phase != .idle {
                            progressSection
                            statsGrid
                        }
                        if runner.phase == .done, let report = runner.report {
                            reportSection(report)
                        }
                        if runner.phase == .failed {
                            failureSection
                        }
                        if !runner.results.isEmpty && runner.phase == .done {
                            worstResultsSection
                        }
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedProvider) {
            selectedModelId = selectedProvider.models[0].id
            apiKey = ""
            keyValidationResult = nil
        }
        .onChange(of: testMode) {
            // Reset count when switching modes to avoid invalid picker selection
            switch testMode {
            case .followUp:
                if !conversationOptions.contains(promptCount) { promptCount = conversationOptions[0] }
            case .widget:
                if !widgetOptions.contains(promptCount) { promptCount = widgetOptions[1] }
            case .routing:
                if !promptOptions.contains(promptCount) { promptCount = promptOptions[1] }
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("iClaw Stress Test")
                .font(.headline)

            Picker("Mode:", selection: $testMode) {
                ForEach(StressTestMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .disabled(runner.isRunning || followUpRunner.isRunning || widgetRunner.isRunning)

            Spacer()

            switch testMode {
            case .routing:
                Picker("Prompts:", selection: $promptCount) {
                    ForEach(promptOptions, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .disabled(runner.isRunning)
            case .followUp:
                Picker("Conversations:", selection: $promptCount) {
                    ForEach(conversationOptions, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                .disabled(followUpRunner.isRunning)
            case .widget:
                Picker("Prompts:", selection: $promptCount) {
                    ForEach(widgetOptions, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .disabled(widgetRunner.isRunning)
            }

            if runner.isRunning || followUpRunner.isRunning || widgetRunner.isRunning {
                Button("Stop") {
                    runner.stop()
                    widgetRunner.stop()
                }
                    .buttonStyle(.bordered)
                    .tint(.red)
            } else {
                Button("Run") { startRun() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
            }

            if runner.phase == .done {
                Button("Open Report") {
                    let url = URL(fileURLWithPath: "\(runner.outputDir)/report.md")
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)

                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: runner.outputDir)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Provider Config

    private var providerConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LLM Provider")
                .font(.headline)

            HStack(spacing: 16) {
                Picker("Provider:", selection: $selectedProvider) {
                    ForEach(ProviderKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)

                Picker("Model:", selection: $selectedModelId) {
                    ForEach(selectedProvider.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            if selectedProvider.requiresAPIKey {
                HStack(spacing: 8) {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                        .onChange(of: apiKey) { keyValidationResult = nil }

                    Button {
                        Task { await validateKey() }
                    } label: {
                        if isValidatingKey {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Validate")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!apiKeyFormatValid || isValidatingKey)

                    validationBadge
                }

                if !apiKeyFormatValid && !apiKey.isEmpty {
                    Text(selectedProvider.keyFormatHint)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle")
                        .foregroundStyle(.secondary)
                    Text("Pricing: $\(String(format: "%.3f", selectedModel.inputPricePer1M))/1M input, $\(String(format: "%.2f", selectedModel.outputPricePer1M))/1M output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var validationBadge: some View {
        switch keyValidationResult {
        case .valid:
            Label("Valid", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .invalid(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        case nil:
            EmptyView()
        }
    }

    // MARK: - Key Validation

    private func validateKey() async {
        isValidatingKey = true
        defer { isValidatingKey = false }

        let provider = buildProvider()
        do {
            try await provider.validateKey()
            keyValidationResult = .valid
        } catch {
            keyValidationResult = .invalid(error.localizedDescription)
        }
    }

    // MARK: - Follow-Up UI

    private var followUpProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(followUpRunner.phase.rawValue.capitalized)
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(followUpRunner.completedCount)/\(followUpRunner.totalTarget)")
                    .font(.system(.body, design: .monospaced))
            }

            if !followUpRunner.currentItem.isEmpty {
                Text(followUpRunner.currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: followUpRunner.totalTarget > 0
                ? Double(followUpRunner.completedCount) / Double(followUpRunner.totalTarget)
                : 0)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func followUpReportSection(_ report: FollowUpStressRunner.FollowUpReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow-Up Results")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Conversations").foregroundStyle(.secondary)
                    Text("\(report.totalConversations)").monospacedDigit()
                }
                GridRow {
                    Text("Total Turns").foregroundStyle(.secondary)
                    Text("\(report.totalTurns)").monospacedDigit()
                }
                GridRow {
                    Text("Overall Accuracy").foregroundStyle(.secondary)
                    Text(String(format: "%.1f%%", report.overallAccuracy * 100))
                        .monospacedDigit()
                        .foregroundStyle(report.overallAccuracy >= 0.85 ? .green : .red)
                }
                GridRow {
                    Text("Avg Duration").foregroundStyle(.secondary)
                    Text("\(report.avgDurationMs)ms").monospacedDigit()
                }
            }

            Divider()

            Text("Per-Relation Routing Accuracy")
                .font(.subheadline.weight(.medium))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Continuation").font(.caption)
                    Text(String(format: "%.1f%%", report.continuationRoutingAccuracy * 100))
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Refinement").font(.caption)
                    Text(String(format: "%.1f%%", report.refinementRoutingAccuracy * 100))
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Drill-Down").font(.caption)
                    Text(String(format: "%.1f%%", report.drillDownRoutingAccuracy * 100))
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Pivot").font(.caption)
                    Text(String(format: "%.1f%%", report.pivotRoutingAccuracy * 100))
                        .font(.system(.caption, design: .monospaced))
                }
                GridRow {
                    Text("Meta").font(.caption)
                    Text(String(format: "%.1f%%", report.metaRoutingAccuracy * 100))
                        .font(.system(.caption, design: .monospaced))
                }
            }

            Divider()

            // Show individual conversation results
            ForEach(report.conversations, id: \.id) { conv in
                let routePct = conv.totalTurns > 0 ? Double(conv.correctRouting) / Double(conv.totalTurns) * 100 : 0
                DisclosureGroup("Conversation \(conv.id) — routing \(String(format: "%.0f", routePct))%") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(conv.turns, id: \.turnIndex) { turn in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: turn.routedCorrectly ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(turn.routedCorrectly ? .green : .red)
                                    .font(.caption2)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(turn.input)
                                        .font(.caption)
                                        .lineLimit(2)
                                    Text("\(turn.expectedRelation) → \(turn.expectedTool)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.leading, 8)
                }
                .font(.caption)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Run

    private func startRun() {
        let provider = buildProvider()
        switch testMode {
        case .routing:
            runner.start(promptCount: promptCount, provider: provider, modelOption: selectedModel)
        case .followUp:
            followUpRunner.start(conversationCount: promptCount, provider: provider, modelOption: selectedModel)
        case .widget:
            widgetRunner.start(promptCount: promptCount, provider: provider, modelOption: selectedModel)
        }
    }

    private func buildProvider() -> any LLMProvider {
        switch selectedProvider {
        case .appleFoundation: AppleFoundationProvider()
        case .openAI: OpenAIProvider(apiKey: apiKey, model: selectedModelId)
        case .googleGemini: GeminiProvider(apiKey: apiKey, model: selectedModelId)
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                phaseIndicator(runner.phase)
                Spacer()

                if runner.tokenTracker.totalTokens > 0 {
                    HStack(spacing: 12) {
                        Label(runner.tokenTracker.formattedTokens, systemImage: "number")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if runner.tokenTracker.estimatedCostUSD > 0 {
                            Label(runner.tokenTracker.formattedCost, systemImage: "dollarsign.circle")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Text(formatElapsed(runner.elapsedSeconds))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: runner.progress, total: 1.0)
                .progressViewStyle(.linear)

            HStack {
                Text(runner.currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(Int(runner.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func phaseIndicator(_ phase: StressTestRunner.Phase) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(phaseColor(phase))
                .frame(width: 8, height: 8)
            Text(phase.rawValue)
                .font(.subheadline.weight(.medium))
        }
    }

    private func phaseColor(_ phase: StressTestRunner.Phase) -> Color {
        switch phase {
        case .idle: .gray
        case .warmingUp: .yellow
        case .generating: .blue
        case .executing: .orange
        case .judging: .purple
        case .synthesizing: .indigo
        case .done: .green
        case .failed: .red
        }
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                statCard("Generated", "\(runner.generatedCount)/\(runner.totalTarget)", .blue)
                statCard("Completed", "\(runner.completedCount)/\(runner.totalTarget)", .green)
                statCard("Errors", "\(runner.errorCount)", runner.errorCount > 0 ? .red : .green)
                statCard("Timeouts", "\(runner.timeoutCount)", runner.timeoutCount > 0 ? .orange : .green)
                statCard("Judged", "\(runner.judgedCount)", .purple)
                statCard("Avg Duration", "\(runner.avgDurationMs)ms", .secondary)

                if runner.phase == .done, let r = runner.report {
                    statCard("Routing", String(format: "%.1f", r.avgRoutingScore), scoreColor(r.avgRoutingScore))
                    statCard("Clarity", String(format: "%.1f", r.avgClarityScore), scoreColor(r.avgClarityScore))
                }
            }

            if runner.tokenTracker.totalTokens > 0 {
                HStack(spacing: 16) {
                    tokenStatItem("API Calls", "\(runner.tokenTracker.callCount)")
                    tokenStatItem("Prompt Tokens", "\(runner.tokenTracker.totalPromptTokens)")
                    tokenStatItem("Completion", "\(runner.tokenTracker.totalCompletionTokens)")
                    tokenStatItem("Total Tokens", runner.tokenTracker.formattedTokens)
                    if runner.tokenTracker.estimatedCostUSD > 0 {
                        tokenStatItem("Est. Cost", runner.tokenTracker.formattedCost)
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func tokenStatItem(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func statCard(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 4.0 { return .green }
        if score >= 3.0 { return .yellow }
        if score >= 2.0 { return .orange }
        return .red
    }

    // MARK: - Report

    private func reportSection(_ report: StressReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scores (1-5)")
                .font(.headline)

            HStack(spacing: 20) {
                scoreGauge("Routing", report.avgRoutingScore)
                scoreGauge("Clarity", report.avgClarityScore)
                scoreGauge("Overall", report.avgOverallScore)
            }
            .frame(maxWidth: .infinity)

            if !report.categoryBreakdown.isEmpty {
                Text("Category Breakdown")
                    .font(.headline)
                    .padding(.top, 8)

                categoryTable(report.categoryBreakdown)
            }

            if !report.issueFrequency.isEmpty {
                Text("Top Issues")
                    .font(.headline)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(
                        report.issueFrequency.sorted(by: { $0.value > $1.value }).prefix(10),
                        id: \.key
                    ) { issue, count in
                        HStack {
                            Text("[\(count)x]")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(issue)
                                .font(.caption)
                        }
                    }
                }
            }

            if !report.llmSynthesis.isEmpty && report.llmSynthesis != "LLM synthesis unavailable." {
                Text("LLM Gap Analysis")
                    .font(.headline)
                    .padding(.top, 8)

                Text(report.llmSynthesis)
                    .font(.caption)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func scoreGauge(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 4) {
            Gauge(value: value, in: 0...5) {
                EmptyView()
            } currentValueLabel: {
                Text(String(format: "%.1f", value))
                    .font(.system(.title3, design: .rounded, weight: .bold))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(scoreColor(value))

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func categoryTable(_ stats: [CategoryStats]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Category").frame(width: 120, alignment: .leading)
                Text("N").frame(width: 40)
                Text("Routing").frame(width: 60)
                Text("Clarity").frame(width: 60)
                Text("Overall").frame(width: 60)
                Text("Errors").frame(width: 50)
            }
            .font(.caption.weight(.semibold))
            .padding(.vertical, 4)
            .padding(.horizontal, 8)

            Divider()

            ForEach(stats) { s in
                HStack {
                    Text(s.category)
                        .lineLimit(1)
                        .frame(width: 120, alignment: .leading)
                    Text("\(s.count)").frame(width: 40)
                    Text(String(format: "%.1f", s.avgRouting))
                        .foregroundStyle(scoreColor(s.avgRouting))
                        .frame(width: 60)
                    Text(String(format: "%.1f", s.avgClarity))
                        .foregroundStyle(scoreColor(s.avgClarity))
                        .frame(width: 60)
                    Text(String(format: "%.1f", s.avgOverall))
                        .foregroundStyle(scoreColor(s.avgOverall))
                        .frame(width: 60)
                    Text("\(s.errorCount)")
                        .foregroundStyle(s.errorCount > 0 ? .red : .primary)
                        .frame(width: 50)
                }
                .font(.system(.caption, design: .monospaced))
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
            }
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Worst Results

    private var worstResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Worst Results")
                .font(.headline)

            ForEach(
                runner.results
                    .filter { $0.judgement != nil }
                    .sorted { ($0.judgement?.overallScore ?? 5) < ($1.judgement?.overallScore ?? 5) }
                    .prefix(10),
                id: \.index
            ) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("#\(r.index)")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                        Text(r.prompt.category)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                        if let j = r.judgement {
                            Spacer()
                            HStack(spacing: 8) {
                                scoreLabel("R", j.routingScore)
                                scoreLabel("C", j.clarityScore)
                                scoreLabel("O", j.overallScore)
                            }
                        }
                    }
                    Text(String(r.prompt.text.prefix(100)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(r.responseText.prefix(120)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let issues = r.judgement?.issues, !issues.isEmpty {
                        Text(issues.joined(separator: "; "))
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func scoreLabel(_ label: String, _ value: Int) -> some View {
        Text("\(label):\(value)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(scoreColor(Double(value)))
    }

    // MARK: - Widget Mode UI

    private var widgetProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(widgetPhaseColor(widgetRunner.phase))
                        .frame(width: 8, height: 8)
                    Text(widgetRunner.phase.rawValue)
                        .font(.subheadline.weight(.medium))
                }
                Spacer()

                if widgetRunner.tokenTracker.totalTokens > 0 {
                    HStack(spacing: 12) {
                        Label(widgetRunner.tokenTracker.formattedTokens, systemImage: "number")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if widgetRunner.tokenTracker.estimatedCostUSD > 0 {
                            Label(widgetRunner.tokenTracker.formattedCost, systemImage: "dollarsign.circle")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Text(formatElapsed(widgetRunner.elapsedSeconds))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: widgetRunner.progress, total: 1.0)
                .progressViewStyle(.linear)

            HStack {
                Text(widgetRunner.currentItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("\(widgetRunner.completedCount)/\(widgetRunner.totalTarget)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func widgetPhaseColor(_ phase: WidgetStressRunner.Phase) -> Color {
        switch phase {
        case .idle: .gray
        case .generating: .blue
        case .executing: .orange
        case .judging: .purple
        case .synthesizing: .indigo
        case .done: .green
        case .failed: .red
        }
    }

    private func widgetReportSection(_ report: WidgetStressRunner.WidgetReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Widget Generation Report")
                .font(.headline)

            // Top-level stats
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                statCard("Prompts", "\(report.totalPrompts)", .blue)
                statCard("Widgets", "\(report.widgetsGenerated)", .green)
                statCard("Rate", String(format: "%.0f%%", report.widgetRate * 100), report.widgetRate >= 0.5 ? .green : .orange)
                statCard("Avg Duration", "\(report.avgDurationMs)ms", .secondary)
            }

            // Score gauges
            HStack(spacing: 20) {
                scoreGauge("Layout", report.avgLayoutScore)
                scoreGauge("Data", report.avgDataScore)
                scoreGauge("Relevance", report.avgRelevanceScore)
                scoreGauge("Overall", report.avgOverallScore)
            }
            .frame(maxWidth: .infinity)

            // Category breakdown
            if !report.categoryBreakdown.isEmpty {
                Text("Category Breakdown")
                    .font(.headline)
                    .padding(.top, 8)

                VStack(spacing: 0) {
                    HStack {
                        Text("Category").frame(width: 120, alignment: .leading)
                        Text("N").frame(width: 40)
                        Text("Widgets").frame(width: 60)
                        Text("Overall").frame(width: 60)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)

                    Divider()

                    ForEach(report.categoryBreakdown) { s in
                        HStack {
                            Text(s.category)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            Text("\(s.count)").frame(width: 40)
                            Text("\(s.widgetCount)").frame(width: 60)
                            Text(String(format: "%.1f", s.avgOverall))
                                .foregroundStyle(scoreColor(s.avgOverall))
                                .frame(width: 60)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                    }
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            // LLM synthesis
            if !report.llmSynthesis.isEmpty && report.llmSynthesis != "LLM synthesis unavailable." {
                Text("LLM Analysis")
                    .font(.headline)
                    .padding(.top, 8)

                Text(report.llmSynthesis)
                    .font(.caption)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var widgetGallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            let widgetResults = widgetRunner.results.filter { $0.widgetType == "DynamicWidget" && $0.widgetDataJSON != nil }
            let plainResults = widgetRunner.results.filter { $0.widgetType != "DynamicWidget" || $0.widgetDataJSON == nil }

            Text("Widget Gallery (\(widgetResults.count) widgets)")
                .font(.headline)

            ForEach(widgetResults) { result in
                widgetCard(result)
            }

            if !plainResults.isEmpty {
                Divider()
                Text("No Widget Generated (\(plainResults.count))")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ForEach(plainResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("#\(result.index)")
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                            Text(result.category)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            Spacer()
                            Text(result.widgetType ?? "none")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(result.prompt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(result.responseText.prefix(150)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(6)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func widgetCard(_ result: WidgetStressRunner.WidgetResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: prompt + scores
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("#\(result.index)")
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                        Text(result.category)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                        Text("\(result.durationMs)ms")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(result.prompt)
                        .font(.callout)
                        .lineLimit(2)
                }

                Spacer()

                if let j = result.judgement {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            widgetScoreLabel("L", j.layoutScore)
                            widgetScoreLabel("D", j.dataScore)
                            widgetScoreLabel("R", j.relevanceScore)
                            widgetScoreLabel("O", j.overallScore)
                        }
                        if !j.issues.isEmpty {
                            Text(j.issues.joined(separator: "; "))
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Rendered widget
            if let data = result.widgetDataJSON,
               let widgetData = try? JSONDecoder().decode(DynamicWidgetData.self, from: data) {
                DynamicWidgetView(data: widgetData)
                    .frame(maxWidth: 400)
            }

            // Response text (collapsed)
            DisclosureGroup("Response text") {
                Text(result.responseText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
        .padding(10)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private func widgetScoreLabel(_ label: String, _ value: Int) -> some View {
        Text("\(label):\(value)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(scoreColor(Double(value)))
    }

    // MARK: - Failure

    private var failureSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(runner.statusMessage)
                .font(.body)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
