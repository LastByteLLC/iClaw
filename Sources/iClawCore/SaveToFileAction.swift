import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers

/// A SwiftUI ViewModifier that adds a "Save to File..." context menu to chat messages.
/// Supports exporting to Markdown, Text, Word (docx), CSV, and Excel (via CSV).
@MainActor
struct SaveToFileAction: ViewModifier {
    let content: String

    private var hasTable: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Check for Markdown table: | header | \n | --- |
        let hasMarkdownTable = trimmed.contains("|") && trimmed.contains("---")
        // Check for HTML table
        let hasHTMLTable = trimmed.localizedCaseInsensitiveContains("<table>") || trimmed.localizedCaseInsensitiveContains("<table ")
        return hasMarkdownTable || hasHTMLTable
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Menu("Save to File...") {
                    Button {
                        save(as: .markdown)
                    } label: {
                        Label("Markdown (.md)", systemImage: "text.alignleft")
                    }

                    Button {
                        save(as: .text)
                    } label: {
                        Label("Text (.txt)", systemImage: "doc.text")
                    }

                    Button {
                        save(as: .docx)
                    } label: {
                        Label("Word (.docx)", systemImage: "doc.richtext")
                    }

                    if hasTable {
                        Divider()

                        Button {
                            save(as: .csv)
                        } label: {
                            Label("CSV (.csv)", systemImage: "tablecells")
                        }

                        Button {
                            save(as: .excel)
                        } label: {
                            Label("Excel (.xlsx)", systemImage: "tablecells.fill")
                        }
                    }
                }
            }
    }

    enum FileFormat {
        case markdown, text, docx, csv, excel

        var utType: UTType {
            switch self {
            case .markdown: return .plainText
            case .text: return .plainText
            case .docx: return UTType("org.openxmlformats.wordprocessingml.document") ?? .data
            case .csv: return .commaSeparatedText
            case .excel: return .spreadsheet
            }
        }

        var `extension`: String {
            switch self {
            case .markdown: return "md"
            case .text: return "txt"
            case .docx: return "docx"
            case .csv: return "csv"
            case .excel: return "xlsx"
            }
        }
    }

    private func save(as format: FileFormat) {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "iClaw_Export.\(format.`extension`)"
        panel.title = String(localized: "Save Message", bundle: .iClawCore)
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try prepareData(for: format)
                try data.write(to: url)
            } catch {
                Log.tools.error("Failed to save file: \(error)")
            }
        }
        #else
        // iOS: write to temp and present share sheet
        do {
            let data = try prepareData(for: format)
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("iClaw_Export.\(format.`extension`)")
            try data.write(to: tempURL)
            let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first?.rootViewController {
                root.present(activityVC, animated: true)
            }
        } catch {
            Log.tools.error("Failed to save file: \(error)")
        }
        #endif
    }

    private func prepareData(for format: FileFormat) throws -> Data {
        switch format {
        case .markdown, .text:
            return content.data(using: .utf8) ?? Data()
        case .docx:
            // officeOpenXML is for .docx
            let options: [NSAttributedString.DocumentAttributeKey: Any] = [
                .documentType: NSAttributedString.DocumentType.officeOpenXML
            ]
            let attrString = NSAttributedString(string: content)
            return try attrString.data(from: NSRange(location: 0, length: attrString.length), documentAttributes: options)
        case .csv, .excel:
            let csvString = markdownToCSV(content)
            return csvString.data(using: .utf8) ?? Data()
        }
    }

    private func markdownToCSV(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var csvLines: [String] = []

        for line in lines {
            if line.contains("|") {
                // Split by | and trim
                let parts = line.split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }

                var finalParts = parts
                if line.hasPrefix("|") && !finalParts.isEmpty && finalParts[0].isEmpty {
                    finalParts.removeFirst()
                }
                if line.hasSuffix("|") && !finalParts.isEmpty && finalParts.last?.isEmpty == true {
                    finalParts.removeLast()
                }

                // Skip the separator line |---|---|
                if finalParts.allSatisfy({ part in
                    let p = part.trimmingCharacters(in: .whitespaces)
                    return !p.isEmpty && p.allSatisfy({ $0 == "-" || $0 == ":" })
                }) && !finalParts.isEmpty {
                    continue
                }

                if !finalParts.isEmpty {
                    let escapedParts = finalParts.map { part in
                        let cleaned = part.trimmingCharacters(in: .whitespaces)
                        if cleaned.contains(",") || cleaned.contains("\"") || cleaned.contains("\n") {
                            return "\"\(cleaned.replacingOccurrences(of: "\"", with: "\"\""))\""
                        }
                        return cleaned
                    }
                    csvLines.append(escapedParts.joined(separator: ","))
                }
            }
        }
        return csvLines.joined(separator: "\n")
    }
}

extension View {
    /// Adds a context menu to save the content of a chat message to a file.
    func saveToFile(content: String) -> some View {
        modifier(SaveToFileAction(content: content))
    }
}
