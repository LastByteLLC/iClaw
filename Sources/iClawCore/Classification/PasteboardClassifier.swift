import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import CryptoKit

/// Classifies pasteboard content and creates temporary files for attachment.
public struct PasteboardClassifier: Sendable {

    /// Result of inspecting the pasteboard.
    public enum PasteResult: Sendable {
        /// Short plain text — insert inline, don't create an attachment.
        case inline(String)
        /// Content that should become a file attachment.
        case attachment(data: Data, category: FileAttachment.FileCategory, ext: String)
        /// Nothing useful on the pasteboard.
        case empty
    }

    // MARK: - Code Indicators

    private static let codeIndicators: [String] = [
        "func ", "class ", "struct ", "import ", "enum ", "protocol ",
        "def ", "var ", "let ", "const ", "return ", "if ", "for ",
        "=>", "->", "async ", "await ", "{}", "};", "();"
    ]

    /// Threshold below which plain text is inserted inline rather than attached.
    private static let inlineCharLimit = 200

    // MARK: - Public API

    /// Inspects the system pasteboard and returns a classification.
    @MainActor
    public static func classify() -> PasteResult {
        #if canImport(AppKit)
        let pb = NSPasteboard.general

        // 1. File URL
        if let fileURL = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ])?.first as? URL {
            // Delegate to FileAttachment — return the URL path as data
            let pathData = Data(fileURL.path.utf8)
            let category = FileAttachment.FileCategory.classify(url: fileURL)
            let ext = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension
            return .attachment(data: pathData, category: category, ext: ext)
        }

        // 2. Image (TIFF or PNG)
        // macOS pasteboard often provides TIFF data even for PNG sources.
        // Normalize to PNG so the file extension matches the actual content,
        // which is required for Vision framework image analysis.
        if let tiffData = pb.data(forType: .tiff) {
            let pngData = Self.convertTIFFtoPNG(tiffData) ?? tiffData
            let ext = pngData == tiffData ? "tiff" : "png"
            return .attachment(data: pngData, category: .image, ext: ext)
        }
        if let pngData = pb.data(forType: .png) {
            return .attachment(data: pngData, category: .image, ext: "png")
        }

        // 3. PDF
        if let pdfData = pb.data(forType: .pdf) {
            return .attachment(data: pdfData, category: .pdf, ext: "pdf")
        }

        // 4. String
        if let string = pb.string(forType: .string) {
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .empty
            }

            // Short plain text without code indicators → inline
            if string.count < inlineCharLimit && !looksLikeCode(string) {
                return .inline(string)
            }

            let data = Data(string.utf8)
            let category: FileAttachment.FileCategory = looksLikeCode(string) ? .code : .text
            return .attachment(data: data, category: category, ext: "txt")
        }

        return .empty
        #else // UIKit
        let pb = UIPasteboard.general

        // 1. Image
        if let image = pb.image, let data = image.pngData() {
            return .attachment(data: data, category: .image, ext: "png")
        }

        // 2. String
        if let string = pb.string {
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .empty
            }
            if string.count < inlineCharLimit && !looksLikeCode(string) {
                return .inline(string)
            }
            let data = Data(string.utf8)
            let category: FileAttachment.FileCategory = looksLikeCode(string) ? .code : .text
            return .attachment(data: data, category: category, ext: "txt")
        }

        return .empty
        #endif
    }

    #if canImport(AppKit)
    /// Converts TIFF image data to PNG format so the extension matches the content.
    /// Returns nil if conversion fails, allowing the caller to fall back to raw TIFF.
    private static func convertTIFFtoPNG(_ tiffData: Data) -> Data? {
        guard let imageRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return imageRep.representation(using: .png, properties: [:])
    }
    #endif

    /// Returns a SHA256 hash of the first 4KB of data, for duplicate detection.
    public static func hashPrefix(_ data: Data) -> String {
        let prefix = data.prefix(4096)
        let digest = SHA256.hash(data: prefix)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private

    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let indicatorCount = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return codeIndicators.contains { trimmed.hasPrefix($0) || trimmed.contains($0) }
        }.count
        // At least 2 code-like lines
        return indicatorCount >= 2
    }
}
