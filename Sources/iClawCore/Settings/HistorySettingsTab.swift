import SwiftUI
import GRDB
import UniformTypeIdentifiers

// MARK: - Clear Age

enum ClearAge: String, CaseIterable, Identifiable {
    case week
    case month
    case threeMonths
    case sixMonths
    case forever

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week: return String(localized: "1 Week", bundle: .iClawCore)
        case .month: return String(localized: "1 Month", bundle: .iClawCore)
        case .threeMonths: return String(localized: "3 Months", bundle: .iClawCore)
        case .sixMonths: return String(localized: "6 Months", bundle: .iClawCore)
        case .forever: return String(localized: "Keep Forever", bundle: .iClawCore)
        }
    }

    var cutoffDate: Date? {
        let calendar = Calendar.current
        switch self {
        case .week: return calendar.date(byAdding: .weekOfYear, value: -1, to: Date())
        case .month: return calendar.date(byAdding: .month, value: -1, to: Date())
        case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: Date())
        case .sixMonths: return calendar.date(byAdding: .month, value: -6, to: Date())
        case .forever: return nil
        }
    }
}

// MARK: - History Settings

struct HistorySettingsView: View {
    @State private var memoryCount: Int = 0
    @State private var knowledgeCount: Int = 0
    @State private var diskSizeString: String = String(localized: "Calculating...", bundle: .iClawCore)
    @State private var showClearConfirmation = false
    @State private var showClearKnowledgeConfirmation = false
    @State private var clearAge: ClearAge = .week
    @State private var isExporting = false
    @AppStorage(AppConfig.knowledgeMemoryEnabledKey) private var knowledgeMemoryEnabled = true

    var body: some View {
        Form {
            Section(String(localized: "Knowledge Memory", bundle: .iClawCore)) {
                Toggle(String(localized: "Enable Knowledge Memory", bundle: .iClawCore), isOn: $knowledgeMemoryEnabled)

                if knowledgeMemoryEnabled {
                    LabeledContent(String(localized: "Learned facts", bundle: .iClawCore)) {
                        Text("\(knowledgeCount)")
                            .monospacedDigit()
                    }

                    if knowledgeCount > 0 {
                        Button(String(localized: "Clear Knowledge Memories", bundle: .iClawCore), role: .destructive) {
                            showClearKnowledgeConfirmation = true
                        }
                        .confirmationDialog(
                            String(localized: "Clear all knowledge memories?", bundle: .iClawCore),
                            isPresented: $showClearKnowledgeConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(String(localized: "Clear", bundle: .iClawCore), role: .destructive) {
                                Task {
                                    try? await KnowledgeMemoryManager.shared.clearAll()
                                    knowledgeCount = await KnowledgeMemoryManager.shared.count()
                                }
                            }
                            Button(String(localized: "Cancel", bundle: .iClawCore), role: .cancel) {}
                        } message: {
                            Text("This removes all learned preferences, facts, and relationships. This cannot be undone.", bundle: .iClawCore)
                        }
                    }
                }
            }

            Section(String(localized: "Conversation Memory", bundle: .iClawCore)) {
                LabeledContent(String(localized: "Stored memories", bundle: .iClawCore)) {
                    Text("\(memoryCount)")
                        .monospacedDigit()
                }

                LabeledContent(String(localized: "Database size", bundle: .iClawCore)) {
                    Text(diskSizeString)
                        .monospacedDigit()
                }
            }

            Section(String(localized: "Export", bundle: .iClawCore)) {
                Button {
                    Task { await exportHistory() }
                } label: {
                    Label(String(localized: "Export Conversation History", bundle: .iClawCore), systemImage: "doc.text")
                }
                .disabled(memoryCount == 0 || isExporting)

                Text("Exports all stored conversations as a Markdown file.", bundle: .iClawCore)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Clear History", bundle: .iClawCore)) {
                Picker(String(localized: "Clear memories older than", bundle: .iClawCore), selection: $clearAge) {
                    ForEach(ClearAge.allCases) { age in
                        Text(age.displayName).tag(age)
                    }
                }
                .pickerStyle(.menu)

                if clearAge != .forever {
                    Button(String(localized: "Clear Old Memories", bundle: .iClawCore), role: .destructive) {
                        showClearConfirmation = true
                    }
                    .confirmationDialog(
                        String(localized: "Clear memories older than \(clearAge.displayName.lowercased())?", bundle: .iClawCore),
                        isPresented: $showClearConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(String(localized: "Clear", bundle: .iClawCore), role: .destructive) {
                            Task { await clearOldMemories() }
                        }
                        Button(String(localized: "Cancel", bundle: .iClawCore), role: .cancel) {}
                    } message: {
                        Text("This cannot be undone. Important memories will be preserved.", bundle: .iClawCore)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            await loadStats()
        }
    }

    private func loadStats() async {
        // Count conversation memories
        let db = DatabaseManager.shared
        do {
            let count = try await db.dbQueue.read { db in
                try Memory.fetchCount(db)
            }
            memoryCount = count
        } catch {
            memoryCount = 0
        }

        // Count knowledge memories
        knowledgeCount = await KnowledgeMemoryManager.shared.count()

        // Database file size
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbURL = appSupportURL.appendingPathComponent("iClaw/db.sqlite")
        if let attrs = try? fileManager.attributesOfItem(atPath: dbURL.path),
           let size = attrs[.size] as? UInt64 {
            diskSizeString = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            diskSizeString = String(localized: "N/A", bundle: .iClawCore)
        }
    }

    @MainActor
    private func exportHistory() async {
        isExporting = true
        defer { isExporting = false }

        let memories: [Memory]
        do {
            memories = try await DatabaseManager.shared.dbQueue.read { db in
                try Memory.order(Column("created_at").asc).fetchAll(db)
            }
        } catch {
            Log.ui.debug("Export failed: \(error)")
            return
        }
        guard !memories.isEmpty else { return }

        // Build Markdown grouped by day
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .long
        let timeFmt = DateFormatter()
        timeFmt.timeStyle = .short

        var md = "# iClaw Conversation History\n\n"
        md += "Exported: \(dateFmt.string(from: Date())) — \(memories.count) memories\n\n---\n"

        var currentDay: String?
        for memory in memories {
            let day = dateFmt.string(from: memory.created_at)
            if day != currentDay {
                md += "\n## \(day)\n\n"
                currentDay = day
            }
            let time = timeFmt.string(from: memory.created_at)
            let label = memory.role == "user" ? "User" : "Agent"
            let star = memory.is_important ? " ⭐" : ""
            md += "**\(label)** (\(time))\(star):\n\(memory.content)\n\n"
        }

        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "iClaw_History_\(dateStr).md"
        panel.title = String(localized: "Export Conversation History", bundle: .iClawCore)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.ui.debug("Export write failed: \(error)")
        }
        #endif
    }

    private func clearOldMemories() async {
        guard let cutoffDate = clearAge.cutoffDate else { return }
        let db = DatabaseManager.shared
        do {
            try await db.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM memories WHERE created_at < ? AND is_important = 0",
                    arguments: [cutoffDate]
                )
            }
            // Reclaim disk space — VACUUM cannot run inside a transaction
            try await db.dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }
            await loadStats()
        } catch {
            Log.ui.debug("Failed to clear old memories: \(error)")
        }
    }
}
