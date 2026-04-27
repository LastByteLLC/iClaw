import SwiftUI

// MARK: - Widget Data

public struct AutomationWidgetData: Sendable {
    public enum Mode: Sendable {
        case confirmation(query: String, interval: String, intervalSeconds: Int, nextRun: Date)
        case list(automations: [AutomationSummary])
    }
    public let mode: Mode
}

public struct AutomationSummary: Sendable {
    public let id: Int64
    public let label: String
    public let interval: String
    public let isActive: Bool
    public let lastResult: String?
    public let nextRun: Date
}

// MARK: - Widget View

public struct AutomationWidgetView: View {
    public let data: AutomationWidgetData
    @Environment(\.dismissWidget) var dismissWidget

    public var body: some View {
        switch data.mode {
        case .confirmation(let query, let interval, let intervalSeconds, let nextRun):
            confirmationView(query: query, interval: interval, intervalSeconds: intervalSeconds, nextRun: nextRun)
        case .list(let automations):
            listView(automations: automations)
        }
    }

    // MARK: - Confirmation

    @ViewBuilder
    private func confirmationView(query: String, interval: String, intervalSeconds: Int, nextRun: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("New Automation", systemImage: "arrow.clockwise.circle")
                .font(.headline)

            Divider()

            HStack {
                Text("Query:")
                    .foregroundStyle(.secondary)
                Text(query)
                    .fontWeight(.medium)
            }
            .font(.subheadline)

            HStack {
                Text("Interval:")
                    .foregroundStyle(.secondary)
                Text(interval)
                    .fontWeight(.medium)
            }
            .font(.subheadline)

            HStack {
                Text("First run:")
                    .foregroundStyle(.secondary)
                Text(nextRun, style: .relative)
                    .fontWeight(.medium)
            }
            .font(.subheadline)

            Divider()

            HStack {
                Button("Confirm") {
                    Task {
                        await confirmAutomation(query: query, intervalSeconds: intervalSeconds, nextRun: nextRun, interval: interval)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel") {
                    dismissWidget?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    private func confirmAutomation(query: String, intervalSeconds: Int, nextRun: Date, interval: String) async {
        let scheduled = ScheduledQuery(
            query: query,
            intervalSeconds: intervalSeconds,
            nextRunDate: nextRun,
            label: "\(query) \(interval)"
        )
        do {
            _ = try await ScheduledQueryStore.shared.create(scheduled)
        } catch {
            Log.engine.error("Failed to save automation: \(error)")
        }
        dismissWidget?()
    }

    // MARK: - List

    @ViewBuilder
    private func listView(automations: [AutomationSummary]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Automations (\(automations.count))", systemImage: "arrow.clockwise.circle")
                .font(.headline)

            Divider()

            ForEach(automations, id: \.id) { auto in
                HStack {
                    Circle()
                        .fill(auto.isActive ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(auto.label)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(auto.interval)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let result = auto.lastResult {
                        Text(result.prefix(40))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Button("Manage in Settings") {
                #if os(macOS)
                SettingsNavigation.shared.openTab(.automations)
                #endif
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(12)
    }
}
