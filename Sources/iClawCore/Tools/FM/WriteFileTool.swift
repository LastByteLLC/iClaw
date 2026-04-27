import Foundation
import FoundationModels

@Generable
struct WriteFileInput: ConvertibleFromGeneratedContent {
    @Guide(description: "Filename to create, e.g. 'countries.csv' or 'notes.txt'")
    var filename: String

    @Guide(description: "The text content to write to the file")
    var content: String
}

struct WriteFileTool: Tool {
    typealias Arguments = WriteFileInput
    typealias Output = String

    let name = "write_file"
    let description = "Save text content to a file in the user's Downloads folder. Supports any text format: CSV, JSON, TXT, Markdown, etc. The filename determines the format."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: WriteFileInput) async throws -> String {
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        // Sanitize filename: remove path separators and dangerous characters
        let sanitized = input.filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else {
            return "Error: Invalid filename."
        }

        // Resolve collision: append timestamp if file exists
        var targetURL = downloadsURL.appendingPathComponent(sanitized)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            let name = (sanitized as NSString).deletingPathExtension
            let ext = (sanitized as NSString).pathExtension
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: " ", with: "")
            let datePart = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
                .replacingOccurrences(of: "/", with: "-")
            let newName = ext.isEmpty ? "\(name)_\(datePart)_\(timestamp)" : "\(name)_\(datePart)_\(timestamp).\(ext)"
            targetURL = downloadsURL.appendingPathComponent(newName)
        }

        do {
            try input.content.write(to: targetURL, atomically: true, encoding: .utf8)
            let size = (try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? Int64) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return "Saved \(targetURL.lastPathComponent) to Downloads (\(sizeStr))"
        } catch {
            return "Error saving file: \(error.localizedDescription)"
        }
    }
}
