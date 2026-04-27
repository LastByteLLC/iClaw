import Foundation
import FoundationModels
import Vision
import PDFKit
import UniformTypeIdentifiers

@Generable
struct ReadFileInput: ConvertibleFromGeneratedContent {
    @Guide(description: "The absolute path or tilde-path (e.g. '~/Desktop/file.txt')")
    var path: String
}

struct ReadFileTool: Tool {
    typealias Arguments = ReadFileInput
    typealias Output = String

    let name = "read_file"
    let description = "Get a smart summary of a local file or directory. Uses metadata, Neural Engine analysis (for images), and content snippets."
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: ReadFileInput) async throws -> String {
        let expandedPath = (input.path as NSString).expandingTildeInPath
        // Resolve symlinks to prevent path traversal via symlink chains
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath()
        let resolvedPath = url.path

        // Block access outside the user's home directory and /tmp
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let allowedPrefixes = [home, "/tmp", "/var/folders"]
        guard allowedPrefixes.contains(where: { resolvedPath.hasPrefix($0) }) else {
            return "Error: Access restricted to files within your home directory."
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
            return "Error: File or directory not found at \(input.path)."
        }

        if isDir.boolValue {
            return try await summarizeDirectory(at: url)
        }

        var report = "--- Smart File Report ---\n"
        report += "Name: \(url.lastPathComponent)\n"

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let size = attributes[.size] as? Int64 ?? 0
            report += "Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))\n"
            if let date = attributes[.creationDate] as? Date {
                report += "Created: \(date.formatted())\n"
            }
        }

        let xattrs = listXattrs(at: url.path)
        if !xattrs.isEmpty {
            report += "Tags/Xattrs: \(xattrs.joined(separator: ", "))\n"
        }

        #if os(macOS)
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            let interestingKeys: [CFString] = [
                kMDItemWhereFroms, kMDItemTitle, kMDItemDescription,
                kMDItemAuthors, kMDItemComment, kMDItemKeywords,
                kMDItemCreator, kMDItemVersion
            ]
            for key in interestingKeys {
                if let val = MDItemCopyAttribute(item, key) {
                    let formattedVal = formatMDValue(val)
                    let keyName = key as String
                    report += "\(keyName): \(formattedVal)\n"
                }
            }
        }
        #endif

        let type = UTType(filenameExtension: url.pathExtension) ?? .data

        if type.conforms(to: .image) {
            report += "Type: Image\n"
            let imageAnalysis = await analyzeImage(at: url)
            report += "Visual Analysis: \(imageAnalysis)\n"
        } else if type.conforms(to: .pdf) {
            report += "Type: PDF Document\n"
            if let pdf = PDFDocument(url: url) {
                report += "Pages: \(pdf.pageCount)\n"
                if let firstPage = pdf.page(at: 0)?.string {
                    report += "Snippet: \(firstPage.prefix(1500))\n"
                }
            }
        } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) || url.pathExtension == "md" {
            report += "Type: Text/Source\n"
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                report += "Snippet: \(content.prefix(2000))\n"
            }
        } else {
            report += "Type: \(type.description)\n"
        }

        let finalSummary = await SummarizationManager.shared.summarize(text: report)
        return "Analysis for \(url.lastPathComponent):\n\(finalSummary)"
    }

    private func summarizeDirectory(at url: URL) async throws -> String {
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.nameKey, .fileSizeKey], options: .skipsHiddenFiles)
        let fileList = contents.prefix(20).map { $0.lastPathComponent }.joined(separator: ", ")
        let report = "Directory: \(url.lastPathComponent)\nContains \(contents.count) items. \nFirst few: \(fileList)"
        return await SummarizationManager.shared.summarize(text: report)
    }

    private func listXattrs(at path: String) -> [String] {
        let size = listxattr(path, nil, 0, 0)
        if size <= 0 { return [] }
        var data = Data(count: size)
        data.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            _ = listxattr(path, ptr.baseAddress, size, 0)
        }
        let names = String(data: data, encoding: .utf8)?.split(separator: "\0").map(String.init) ?? []
        return names.filter { !$0.starts(with: "com.apple.lastuseddate") && !$0.starts(with: "com.apple.quarantine") }
    }

    #if os(macOS)
    private func formatMDValue(_ value: CFTypeRef) -> String {
        if let str = value as? String { return str }
        if let arr = value as? [String] { return arr.joined(separator: ", ") }
        if let date = value as? Date { return date.formatted() }
        if let num = value as? NSNumber { return num.stringValue }
        return "\(value)"
    }
    #endif

    private func analyzeImage(at url: URL) async -> String {
        guard let data = try? Data(contentsOf: url) else { return "Could not read image data." }
        let requestHandler = VNImageRequestHandler(data: data)

        let classifyRequest = VNClassifyImageRequest()
        let ocrRequest = VNRecognizeTextRequest()
        ocrRequest.recognitionLevel = .accurate

        do {
            try requestHandler.perform([classifyRequest, ocrRequest])

            var results: [String] = []

            if let observations = classifyRequest.results {
                let labels = observations.prefix(3)
                    .filter { $0.confidence > 0.8 }
                    .map { $0.identifier }
                if !labels.isEmpty {
                    results.append("Objects: \(labels.joined(separator: ", "))")
                }
            }

            if let ocrResults = ocrRequest.results {
                let topOCR = ocrResults.prefix(15)
                    .compactMap { $0.topCandidates(1).first?.string }
                if !topOCR.isEmpty {
                    results.append("Text found: \(topOCR.joined(separator: " ").prefix(300))")
                }
            }

            return results.isEmpty ? "No high-confidence visual data." : results.joined(separator: " | ")
        } catch {
            return "Vision analysis failed: \(error.localizedDescription)"
        }
    }
}
