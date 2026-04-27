import SwiftUI

// MARK: - Automations Settings

struct AutomationsSettingsView: View {
    @State private var automations: [ScheduledQuery] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Automations", bundle: .iClawCore)
                    .font(.title2)
                    .fontWeight(.bold)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if automations.isEmpty {
                    emptyState
                } else {
                    automationList
                }

                Divider()

                Text("Minimum interval: 5 minutes. Maximum: \(AppConfig.maxActiveAutomations) active automations.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .task {
            await loadAutomations()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.largeTitle) // SF Symbol sizing
                .foregroundStyle(.secondary)
            Text("No automations yet", bundle: .iClawCore)
                .font(.headline)
            Text("Try saying \"Check AAPL every hour\" or \"Weather report every morning at 8am\" to create one.", bundle: .iClawCore)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var automationList: some View {
        VStack(spacing: 8) {
            ForEach(automations, id: \.id) { automation in
                automationRow(automation)
            }
        }
    }

    @ViewBuilder
    private func automationRow(_ automation: ScheduledQuery) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor(for: automation))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(automation.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(IntervalParser.formatSeconds(automation.intervalSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let result = automation.lastResult {
                        Text(result.prefix(50))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text(statusLabel(for: automation))
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor(for: automation).opacity(0.15))
                .clipShape(Capsule())

            Button {
                Task {
                    if let id = automation.id {
                        do { try await ScheduledQueryStore.shared.toggleActive(id: id) }
                        catch { Log.engine.debug("Automation toggle failed: \(error)") }
                        await loadAutomations()
                    }
                }
            } label: {
                Image(systemName: automation.isActive ? "pause.circle" : "play.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help(automation.isActive ? String(localized: "Pause", bundle: .iClawCore) : String(localized: "Resume", bundle: .iClawCore))
            .accessibilityLabel(Text(automation.isActive ? "Pause automation" : "Resume automation", bundle: .iClawCore))

            Button(role: .destructive) {
                Task {
                    if let id = automation.id {
                        do { try await ScheduledQueryStore.shared.delete(id: id) }
                        catch { Log.engine.debug("Automation delete failed: \(error)") }
                        await loadAutomations()
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help(String(localized: "Delete", bundle: .iClawCore))
            .accessibilityLabel(Text("Delete automation", bundle: .iClawCore))
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusColor(for automation: ScheduledQuery) -> Color {
        if automation.failureCount >= AppConfig.automationMaxConsecutiveFailures { return .red }
        return automation.isActive ? .green : .gray
    }

    private func statusLabel(for automation: ScheduledQuery) -> String {
        if automation.failureCount >= AppConfig.automationMaxConsecutiveFailures { return String(localized: "Failed", bundle: .iClawCore) }
        return automation.isActive ? String(localized: "Active", bundle: .iClawCore) : String(localized: "Paused", bundle: .iClawCore)
    }

    private func loadAutomations() async {
        do {
            automations = try await ScheduledQueryStore.shared.fetchAll()
        } catch {
            automations = []
        }
        isLoading = false
    }
}
