import Foundation
import UniformTypeIdentifiers

/// Represents a file attached to a chat prompt via the paperclip button.
public struct FileAttachment: Sendable, Identifiable {
    public let id = UUID()
    public let url: URL
    public let fileName: String
    public let fileCategory: FileCategory
    /// SHA256 hash of pasted data prefix, used for per-prompt dedup. Nil for file-picker attachments.
    public let pasteHash: String?

    public init(url: URL) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.fileCategory = FileCategory.classify(url: url)
        self.pasteHash = nil
    }

    /// Creates a file attachment from pasted data, writing to a temp directory.
    /// - Parameters:
    ///   - pastedData: Raw data from the pasteboard.
    ///   - category: Classified category of the pasted content.
    ///   - sequence: Incrementing counter for unique filenames.
    ///   - ext: File extension to use.
    public init?(pastedData: Data, category: FileCategory, sequence: Int, ext: String, hash: String? = nil) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iClaw-Paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName = "pasted-content-\(sequence).\(ext)"
        let fileURL = dir.appendingPathComponent(fileName)

        // For file URLs pasted from Finder, the data is the path itself
        if category != .image && category != .pdf,
           let pathString = String(data: pastedData, encoding: .utf8),
           FileManager.default.fileExists(atPath: pathString) {
            self.url = URL(fileURLWithPath: pathString)
            self.fileName = self.url.lastPathComponent
            self.fileCategory = FileCategory.classify(url: self.url)
            self.pasteHash = hash
            return
        }

        do {
            try pastedData.write(to: fileURL)
        } catch {
            return nil
        }

        self.url = fileURL
        self.fileName = fileName
        self.fileCategory = category
        self.pasteHash = hash
    }

    /// Broad categories for attached files, used to drive suggestion chips and routing hints.
    public enum FileCategory: String, Sendable {
        case text
        case pdf
        case audio
        case image
        case code
        case binary
        case folder
    }
}

// MARK: - Classification

extension FileAttachment.FileCategory {

    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "java", "go", "rs", "c", "cpp", "h", "rb", "sh"
    ]

    private static let textExtensions: Set<String> = [
        "md", "csv", "docx", "txt", "rtf", "log", "json", "xml", "yaml", "yml", "toml"
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "mp4", "m4a", "wav", "aac", "ogg", "flac"
    ]

    /// Classifies a file URL into a `FileCategory` using UTType conformance and extension fallback.
    static func classify(url: URL) -> FileAttachment.FileCategory {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return .folder
        }

        let ext = url.pathExtension.lowercased()

        // PDF check first — must precede UTType .text conformance
        if ext == "pdf" { return .pdf }

        // Extension-based checks first for precision
        if codeExtensions.contains(ext) { return .code }
        if textExtensions.contains(ext) { return .text }
        if audioExtensions.contains(ext) { return .audio }

        // UTType conformance
        if let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .pdf) { return .pdf }
            if utType.conforms(to: .sourceCode) { return .code }
            if utType.conforms(to: .text) { return .text }
            if utType.conforms(to: .audio) || utType.conforms(to: .movie) { return .audio }
            if utType.conforms(to: .image) { return .image }
        }

        return .binary
    }
}

// MARK: - Content Profile

extension FileAttachment {

    /// Fine-grained content profile for driving context-specific suggestion pills.
    public enum ContentProfile: String, Sendable {
        // Code profiles
        case swiftSource, pythonSource, jstsSource, goSource, rustSource, cppSource, rubySource, shellScript
        case unitTest
        case buildConfig
        case ciConfig
        case dockerConfig
        case infraConfig

        // Data/Config profiles
        case jsonData, yamlConfig, xmlData, tomlConfig
        case csvSpreadsheet, tsvData
        case envFile
        case sqlQuery

        // Text profiles
        case markdownDocument, plainText, richList
        case logFile
        case errorStackTrace
        case apiResponse

        // Web
        case htmlPage, cssStylesheet
        case regexPattern, crontab

        // Image profiles
        case photo           // JPEG/HEIC photos from camera
        case screenshot      // PNG screenshots (detected by name/dimensions)
        case diagram         // SVG, vector diagrams, flowcharts
        case gif             // Animated GIF

        // Audio/Video profiles
        case voiceMemo       // Short voice recording
        case musicTrack      // Music file with ID3/metadata
        case videoClip       // Video file (mp4, mov, etc.)
        case meetingRecording // Long audio, meeting patterns in name

        // Document profiles
        case pdfDocument     // Generic PDF (no further classification)
        case invoice         // PDF/image with monetary patterns
        case receipt         // Short PDF/image with totals
        case contract        // PDF with legal language
        case academicPaper   // PDF with abstract/references
        case form            // PDF with form fields
        case presentation    // Keynote, PowerPoint, Google Slides
        case spreadsheet     // Excel, Numbers, Google Sheets
        case wordDocument    // Word, Pages

        // Calendar/Contact profiles
        case calendarEvent   // .ics calendar event files
        case contactCard     // .vcf vCard contact files

        // Archive profiles
        case archive         // ZIP, tar, gz, rar, 7z, dmg
    }

    /// Analyzes file content to determine a fine-grained content profile.
    /// Uses extension + first 100 lines for pattern matching. Sync and fast.
    public static func analyzeContent(url: URL, category: FileCategory) -> ContentProfile? {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent.lowercased()

        // Extension fast-paths for calendar/contact files
        switch ext {
        case "ics":
            return .calendarEvent
        case "vcf", "vcard":
            return .contactCard
        default:
            break
        }

        // Category-level fast paths for non-text types
        switch category {
        case .image:
            return detectImageProfile(ext: ext, fileName: fileName)
        case .audio:
            return detectAudioProfile(ext: ext, fileName: fileName, url: url)
        case .pdf:
            return detectPDFProfile(url: url)
        case .binary:
            return detectBinaryProfile(ext: ext)
        default:
            break
        }

        // Read first 100 lines for text-based pattern detection
        let headContent: String
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
           let text = String(data: data, encoding: .utf8) {
            let lines = text.components(separatedBy: .newlines)
            headContent = lines.prefix(100).joined(separator: "\n")
        } else {
            headContent = ""
        }

        let firstLine = headContent.components(separatedBy: .newlines).first ?? ""

        // Extension-based narrowing for code/text
        switch ext {
        case "swift":
            return hasTestPatterns(headContent) ? .unitTest : .swiftSource
        case "py":
            return hasTestPatterns(headContent) ? .unitTest : .pythonSource
        case "js", "ts", "tsx", "jsx":
            return hasTestPatterns(headContent) ? .unitTest : .jstsSource
        case "go":
            return hasTestPatterns(headContent) ? .unitTest : .goSource
        case "rs":
            return hasTestPatterns(headContent) ? .unitTest : .rustSource
        case "c", "cpp", "cc", "cxx", "h", "hpp":
            return hasTestPatterns(headContent) ? .unitTest : .cppSource
        case "rb":
            return hasTestPatterns(headContent) ? .unitTest : .rubySource
        case "sh", "bash", "zsh", "fish":
            return .shellScript
        case "json":
            return detectJSONProfile(headContent)
        case "yaml", "yml":
            return detectYAMLProfile(headContent)
        case "xml":
            return .xmlData
        case "toml":
            return .tomlConfig
        case "csv":
            return .csvSpreadsheet
        case "tsv":
            return .tsvData
        case "env":
            return .envFile
        case "sql":
            return .sqlQuery
        case "md", "markdown":
            return .markdownDocument
        case "log":
            return .logFile
        case "html", "htm":
            return .htmlPage
        case "css", "scss", "sass":
            return .cssStylesheet
        case "dockerfile":
            return .dockerConfig
        // Office document extensions
        case "docx", "doc", "pages", "odt":
            return .wordDocument
        case "xlsx", "xls", "numbers", "ods":
            return .spreadsheet
        case "pptx", "ppt", "key", "odp":
            return .presentation
        default:
            break
        }

        // Filename-based detection
        if fileName == "makefile" || fileName == "cmakelists.txt" || fileName == "build.gradle" || fileName == "build.gradle.kts" {
            return .buildConfig
        }
        if fileName == "package.swift" { return .buildConfig }
        if fileName == "dockerfile" || fileName == "docker-compose.yml" || fileName == "docker-compose.yaml" {
            return .dockerConfig
        }
        if fileName == "jenkinsfile" || fileName == ".gitlab-ci.yml" {
            return .ciConfig
        }
        if fileName.hasPrefix(".env") { return .envFile }
        if fileName == "crontab" { return .crontab }

        // Content-based detection for unknown extensions
        if !headContent.isEmpty {
            return detectFromContent(headContent, firstLine: firstLine)
        }

        return nil
    }

    // MARK: - Pattern Helpers

    private static func hasTestPatterns(_ content: String) -> Bool {
        let testKeywords = ["@Test", "func test", "describe(", "it(", "expect(", "assert",
                            "XCTest", "unittest", "pytest", "#[test]", "testing.T"]
        return testKeywords.contains { content.contains($0) }
    }

    private static func detectJSONProfile(_ content: String) -> ContentProfile {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\"status\"") && (trimmed.contains("\"data\"") || trimmed.contains("\"error\"") || trimmed.contains("\"message\"")) {
            return .apiResponse
        }
        return .jsonData
    }

    private static func detectYAMLProfile(_ content: String) -> ContentProfile {
        if content.contains("jobs:") && (content.contains("runs-on:") || content.contains("steps:")) {
            return .ciConfig
        }
        if content.contains("apiVersion:") && content.contains("kind:") {
            return .infraConfig
        }
        return .yamlConfig
    }

    private static func detectFromContent(_ content: String, firstLine: String) -> ContentProfile? {
        // Shebang detection
        if firstLine.hasPrefix("#!/") {
            if firstLine.contains("python") { return .pythonSource }
            if firstLine.contains("bash") || firstLine.contains("sh") || firstLine.contains("zsh") { return .shellScript }
            if firstLine.contains("ruby") { return .rubySource }
            if firstLine.contains("node") { return .jstsSource }
        }

        // Stack trace patterns
        let stackTracePatterns = ["at ", "Traceback", "Exception in thread", "Fatal error:", "panic:"]
        if stackTracePatterns.contains(where: { content.contains($0) }) &&
           (content.contains(".swift:") || content.contains(".py:") || content.contains(".java:") || content.contains(".js:") || content.contains(".go:")) {
            return .errorStackTrace
        }

        // Log file patterns (timestamps + log levels)
        let logLevels = ["[INFO]", "[WARN]", "[ERROR]", "[DEBUG]", " INFO ", " WARN ", " ERROR ", " DEBUG "]
        let hasLogLevel = logLevels.contains { content.contains($0) }
        let hasTimestamp = content.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
        if hasLogLevel && hasTimestamp { return .logFile }

        // SQL patterns
        let sqlKeywords = ["SELECT ", "INSERT ", "UPDATE ", "DELETE ", "CREATE TABLE", "ALTER TABLE"]
        if sqlKeywords.contains(where: { content.uppercased().contains($0) }) { return .sqlQuery }

        // Env file patterns
        if content.components(separatedBy: .newlines).prefix(10).allSatisfy({
            $0.isEmpty || $0.hasPrefix("#") || $0.contains("=")
        }) && content.contains("=") {
            return .envFile
        }

        return nil
    }

    // MARK: - Non-Text Profile Detection

    private static func detectImageProfile(ext: String, fileName: String) -> ContentProfile {
        if ext == "gif" { return .gif }
        if ext == "svg" { return .diagram }

        // Screenshot detection by common naming patterns
        let screenshotPatterns = ["screenshot", "screen shot", "screen_shot", "capture", "snip"]
        if screenshotPatterns.contains(where: { fileName.contains($0) }) {
            return .screenshot
        }
        // macOS screenshot naming: "Screenshot 2024-..."
        if fileName.hasPrefix("screenshot") { return .screenshot }
        // iOS screenshot: "IMG_" + PNG is often a screenshot
        if fileName.hasPrefix("img_") && ext == "png" { return .screenshot }

        return .photo
    }

    private static func detectAudioProfile(ext: String, fileName: String, url: URL) -> ContentProfile {
        // Video formats
        let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "wmv", "m4v"]
        if videoExtensions.contains(ext) { return .videoClip }

        // Meeting recording patterns
        let meetingPatterns = ["meeting", "call", "recording", "zoom", "teams", "interview", "standup"]
        if meetingPatterns.contains(where: { fileName.contains($0) }) {
            return .meetingRecording
        }

        // Voice memo patterns
        let memoPatterns = ["voice", "memo", "note", "dictation"]
        if memoPatterns.contains(where: { fileName.contains($0) }) {
            return .voiceMemo
        }

        // Detect by file size heuristic — very large audio files are likely meetings
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            // >50MB likely a meeting recording; <2MB likely a voice memo
            if size > 50_000_000 { return .meetingRecording }
            if size < 2_000_000 && ["m4a", "wav", "caf"].contains(ext) { return .voiceMemo }
        }

        return .musicTrack
    }

    private static func detectPDFProfile(url: URL) -> ContentProfile {
        // Read first ~4KB of the PDF for text-based heuristics
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .pdfDocument
        }

        // Extract visible text from the raw PDF data (rough heuristic)
        let previewSize = min(data.count, 8192)
        let preview = String(data: data.prefix(previewSize), encoding: .ascii) ?? ""

        // Invoice patterns
        let invoicePatterns = ["invoice", "bill to", "amount due", "payment due", "invoice number", "inv #", "invoice date"]
        if invoicePatterns.contains(where: { preview.lowercased().contains($0) }) {
            return .invoice
        }

        // Receipt patterns
        let receiptPatterns = ["receipt", "total", "subtotal", "tax", "thank you for your purchase", "order #"]
        let receiptCount = receiptPatterns.filter { preview.lowercased().contains($0) }.count
        if receiptCount >= 2 { return .receipt }

        // Contract/legal patterns
        let legalPatterns = ["hereby", "whereas", "agreement", "terms and conditions", "party", "governing law", "indemnif"]
        let legalCount = legalPatterns.filter { preview.lowercased().contains($0) }.count
        if legalCount >= 2 { return .contract }

        // Academic paper patterns
        let academicPatterns = ["abstract", "references", "doi:", "introduction", "methodology", "et al"]
        let academicCount = academicPatterns.filter { preview.lowercased().contains($0) }.count
        if academicCount >= 2 { return .academicPaper }

        // Form patterns
        let formPatterns = ["/AcroForm", "/Widget", "fill in", "please complete", "signature"]
        if formPatterns.contains(where: { preview.contains($0) || preview.lowercased().contains($0) }) {
            return .form
        }

        return .pdfDocument
    }

    private static func detectBinaryProfile(ext: String) -> ContentProfile? {
        let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z", "dmg", "iso", "pkg"]
        if archiveExtensions.contains(ext) { return .archive }

        // Office formats that UTType might not catch
        let presentationExts: Set<String> = ["pptx", "ppt", "key", "odp"]
        if presentationExts.contains(ext) { return .presentation }

        let spreadsheetExts: Set<String> = ["xlsx", "xls", "numbers", "ods"]
        if spreadsheetExts.contains(ext) { return .spreadsheet }

        let wordExts: Set<String> = ["docx", "doc", "pages", "odt"]
        if wordExts.contains(ext) { return .wordDocument }

        return nil
    }
}

// MARK: - Content-Aware Suggestions

extension FileAttachment {

    /// Returns contextual action suggestions based on content profile analysis.
    /// Falls back to category-based suggestions when no profile is detected.
    public static func suggestions(for category: FileCategory, profile: ContentProfile? = nil) -> [(label: String, prompt: String)] {
        if let profile {
            return profileSuggestions(for: profile)
        }
        return categorySuggestions(for: category)
    }

    private static func profileSuggestions(for profile: ContentProfile) -> [(label: String, prompt: String)] {
        switch profile {
        // Code profiles
        case .swiftSource, .pythonSource, .jstsSource, .goSource, .rustSource, .cppSource, .rubySource:
            return [
                ("Explain", "Explain this code"),
                ("Find bugs", "Find bugs in this code"),
                ("Refactor", "Refactor this code"),
                ("Add tests", "Write tests for this code"),
            ]
        case .shellScript:
            return [
                ("Explain", "Explain this script"),
                ("Find issues", "Find issues in this script"),
                ("Improve", "Improve this script"),
            ]
        case .unitTest:
            return [
                ("Review tests", "Review these tests"),
                ("Find missing coverage", "Find missing test coverage"),
                ("Explain test logic", "Explain the test logic"),
            ]
        case .buildConfig:
            return [
                ("Explain build config", "Explain this build configuration"),
                ("Check for issues", "Check this build config for issues"),
                ("Simplify", "Simplify this build configuration"),
            ]
        case .ciConfig:
            return [
                ("Explain pipeline", "Explain this CI/CD pipeline"),
                ("Find issues", "Find issues in this CI config"),
                ("Optimize", "Optimize this CI/CD pipeline"),
            ]
        case .dockerConfig:
            return [
                ("Explain", "Explain this Docker configuration"),
                ("Optimize layers", "Optimize the Docker layers"),
                ("Security check", "Check this Dockerfile for security issues"),
            ]
        case .infraConfig:
            return [
                ("Explain infrastructure", "Explain this infrastructure config"),
                ("Find issues", "Find issues in this infrastructure config"),
                ("Security review", "Review this config for security issues"),
            ]

        // Data/Config profiles
        case .jsonData:
            return [
                ("Format & validate", "Format and validate this JSON"),
                ("Explain structure", "Explain the structure of this JSON"),
                ("Convert to YAML", "Convert this JSON to YAML"),
            ]
        case .yamlConfig:
            return [
                ("Explain", "Explain this YAML configuration"),
                ("Validate", "Validate this YAML"),
                ("Convert to JSON", "Convert this YAML to JSON"),
            ]
        case .xmlData:
            return [
                ("Explain structure", "Explain the structure of this XML"),
                ("Validate", "Validate this XML"),
                ("Convert to JSON", "Convert this XML to JSON"),
            ]
        case .tomlConfig:
            return [
                ("Explain", "Explain this TOML configuration"),
                ("Validate", "Validate this TOML"),
            ]
        case .csvSpreadsheet:
            return [
                ("Summarize data", "Summarize this data"),
                ("Find patterns", "Find patterns in this data"),
                ("Convert to table", "Convert this CSV to a formatted table"),
            ]
        case .tsvData:
            return [
                ("Summarize data", "Summarize this data"),
                ("Find patterns", "Find patterns in this data"),
            ]
        case .envFile:
            return [
                ("Explain variables", "Explain the environment variables"),
                ("Check for issues", "Check for missing or problematic env vars"),
            ]
        case .sqlQuery:
            return [
                ("Explain query", "Explain this SQL query"),
                ("Optimize", "Optimize this SQL query"),
                ("Find issues", "Find issues in this SQL"),
            ]

        // Text profiles
        case .markdownDocument:
            return [
                ("Summarize", "Summarize this document"),
                ("Edit", "Edit this document"),
                ("Fix formatting", "Fix the formatting in this Markdown"),
            ]
        case .plainText, .richList:
            return [
                ("Summarize", "Summarize this file"),
                ("Edit", "Edit this file"),
                ("Look for typos", "Look for typos in this file"),
            ]
        case .logFile:
            return [
                ("Summarize events", "Summarize the events in this log"),
                ("Find errors", "Find errors in this log"),
                ("Timeline", "Create a timeline of events from this log"),
            ]
        case .errorStackTrace:
            return [
                ("Diagnose error", "Diagnose this error"),
                ("Find root cause", "Find the root cause of this error"),
                ("Suggest fix", "Suggest a fix for this error"),
            ]
        case .apiResponse:
            return [
                ("Explain response", "Explain this API response"),
                ("Validate schema", "Validate the schema of this response"),
                ("Extract data", "Extract the key data from this response"),
            ]

        // Web
        case .htmlPage:
            return [
                ("Explain page", "Explain this HTML page"),
                ("Find issues", "Find issues in this HTML"),
                ("Extract content", "Extract the main content from this HTML"),
            ]
        case .cssStylesheet:
            return [
                ("Explain styles", "Explain these CSS styles"),
                ("Find issues", "Find issues in this CSS"),
                ("Simplify", "Simplify this CSS"),
            ]
        case .regexPattern:
            return [
                ("Explain pattern", "Explain this regex pattern"),
                ("Test cases", "Generate test cases for this regex"),
            ]
        case .crontab:
            return [
                ("Explain schedule", "Explain this cron schedule"),
                ("Check syntax", "Check the crontab syntax"),
            ]

        // Image profiles
        case .photo:
            return [
                ("Describe", "Describe this photo"),
                ("Extract text (OCR)", "Extract text from this image"),
                ("Edit", "Suggest edits for this photo"),
                ("Reimagine", "Create an image based on this"),
            ]
        case .screenshot:
            return [
                ("Extract text (OCR)", "Extract text from this screenshot"),
                ("Describe", "Describe what's shown in this screenshot"),
                ("Explain UI", "Explain the interface shown"),
            ]
        case .diagram:
            return [
                ("Explain diagram", "Explain this diagram"),
                ("Extract text", "Extract text from this diagram"),
                ("Recreate", "Describe this diagram in detail"),
            ]
        case .gif:
            return [
                ("Describe", "Describe this GIF"),
                ("Extract text", "Extract any text from this image"),
            ]

        // Audio/Video profiles
        case .voiceMemo:
            return [
                ("Transcribe", "Transcribe this voice memo"),
                ("Summarize", "Summarize what's said"),
                ("Action items", "Extract action items from this memo"),
            ]
        case .musicTrack:
            return [
                ("Identify", "What song is this?"),
                ("Transcribe lyrics", "Transcribe the lyrics"),
            ]
        case .videoClip:
            return [
                ("Describe", "Describe what happens in this video"),
                ("Transcribe", "Transcribe the audio from this video"),
                ("Summarize", "Summarize this video"),
            ]
        case .meetingRecording:
            return [
                ("Transcribe", "Transcribe this meeting"),
                ("Summarize", "Summarize the key points"),
                ("Action items", "Extract action items and decisions"),
                ("Minutes", "Generate meeting minutes"),
            ]

        // Document profiles
        case .pdfDocument:
            return [
                ("Summarize", "Summarize this document"),
                ("Extract text", "Extract the text from this file"),
                ("Search for...", "Search this file for "),
            ]
        case .invoice:
            return [
                ("Extract details", "Extract the invoice details (amount, date, vendor)"),
                ("Summarize", "Summarize this invoice"),
                ("Verify", "Check this invoice for errors"),
            ]
        case .receipt:
            return [
                ("Extract total", "Extract the total, date, and merchant from this receipt"),
                ("Categorize", "Categorize this expense"),
            ]
        case .contract:
            return [
                ("Summarize", "Summarize the key terms of this contract"),
                ("Key clauses", "Highlight the most important clauses"),
                ("Risks", "Identify potential risks or concerns"),
            ]
        case .academicPaper:
            return [
                ("Summarize", "Summarize this paper"),
                ("Key findings", "What are the key findings?"),
                ("Explain", "Explain this paper in simple terms"),
            ]
        case .form:
            return [
                ("Extract fields", "Extract the form fields and their values"),
                ("Explain", "Explain what this form is for"),
            ]
        case .presentation:
            return [
                ("Summarize", "Summarize this presentation"),
                ("Key points", "Extract the key points"),
                ("Critique", "Suggest improvements to this presentation"),
            ]
        case .spreadsheet:
            return [
                ("Summarize data", "Summarize the data in this spreadsheet"),
                ("Find patterns", "Find patterns or trends"),
                ("Charts", "Suggest charts for this data"),
            ]
        case .wordDocument:
            return [
                ("Summarize", "Summarize this document"),
                ("Edit", "Suggest edits to this document"),
                ("Look for typos", "Look for typos and grammar issues"),
            ]

        // Calendar/Contact profiles
        case .calendarEvent:
            return [
                ("Add to Calendar", "Add this event to my calendar"),
                ("Show details", "Show the event details"),
            ]
        case .contactCard:
            return [
                ("Add to Contacts", "Add this contact"),
                ("Show details", "Show the contact details"),
            ]

        // Archive profiles
        case .archive:
            return [
                ("List contents", "List the contents of this archive"),
                ("What is this?", "What does this archive contain?"),
            ]
        }
    }

    /// Fallback: original category-based suggestions.
    private static func categorySuggestions(for category: FileCategory) -> [(label: String, prompt: String)] {
        switch category {
        case .text:
            return [
                ("Summarize", "Summarize this file"),
                ("Edit", "Edit this file"),
                ("Look for typos", "Look for typos in this file"),
                ("Search for...", "Search this file for "),
            ]
        case .pdf:
            return [
                ("Summarize", "Summarize this file"),
                ("Extract text", "Extract the text from this file"),
                ("Search for...", "Search this file for "),
            ]
        case .audio:
            return [
                ("Transcribe", "Transcribe this file"),
                ("Summarize", "Summarize this audio"),
                ("Search for moment...", "Search this audio for "),
            ]
        case .image:
            return [
                ("Describe", "Describe this image"),
                ("Extract text (OCR)", "Extract text from this image"),
                ("Analyze", "Analyze this image"),
                ("Reimagine", "Create an image based on this"),
            ]
        case .code:
            return [
                ("Explain", "Explain this code"),
                ("Find bugs", "Find bugs in this code"),
                ("Refactor", "Refactor this code"),
            ]
        case .binary:
            return [
                ("Inspect metadata", "Inspect the metadata of this file"),
                ("What is this file?", "What is this file?"),
            ]
        case .folder:
            return [
                ("List contents", "List the contents of this folder"),
                ("Summarize structure", "Summarize the structure of this folder"),
                ("Find files matching...", "Find files matching "),
            ]
        }
    }

    /// Returns an SF Symbol name appropriate for the file category.
    public static func icon(for category: FileCategory) -> String {
        switch category {
        case .text: return "doc.text"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .image: return "photo"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .binary: return "doc.zipper"
        case .folder: return "folder"
        }
    }
}
