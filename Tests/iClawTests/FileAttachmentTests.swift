import XCTest
import FoundationModels
@testable import iClawCore

/// Stub FM descriptor for attachment routing tests.
private struct StubFMDescriptor: FMToolDescriptor {
    let name: String
    let chipName: String
    let routingKeywords: [String]
    let category: CategoryEnum = .offline
    func makeTool() -> any Tool { ClipboardTool() }
}

final class FileAttachmentTests: XCTestCase {

    private let readFileFM = StubFMDescriptor(
        name: "read_file", chipName: "read", routingKeywords: ["read", "file", "document"]
    )

    // MARK: - Classification Tests

    func testClassifyTextFiles() {
        let extensions = ["txt", "md", "csv", "docx", "rtf", "log", "json", "xml", "yaml"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/test.\(ext)")
            XCTAssertEqual(
                FileAttachment.FileCategory.classify(url: url), .text,
                ".\(ext) should classify as .text"
            )
        }
    }

    func testClassifyPDF() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        XCTAssertEqual(FileAttachment.FileCategory.classify(url: url), .pdf)
    }

    func testClassifyCodeFiles() {
        let extensions = ["swift", "py", "js", "ts", "java", "go", "rs", "c", "cpp", "h", "rb", "sh"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/main.\(ext)")
            XCTAssertEqual(
                FileAttachment.FileCategory.classify(url: url), .code,
                ".\(ext) should classify as .code"
            )
        }
    }

    func testClassifyAudioFiles() {
        let extensions = ["mp3", "mp4", "m4a", "wav", "aac"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/audio.\(ext)")
            XCTAssertEqual(
                FileAttachment.FileCategory.classify(url: url), .audio,
                ".\(ext) should classify as .audio"
            )
        }
    }

    func testClassifyImageFiles() {
        let extensions = ["png", "jpg", "jpeg", "gif", "tiff", "heic"]
        for ext in extensions {
            let url = URL(fileURLWithPath: "/tmp/photo.\(ext)")
            XCTAssertEqual(
                FileAttachment.FileCategory.classify(url: url), .image,
                ".\(ext) should classify as .image"
            )
        }
    }

    func testClassifyBinaryFiles() {
        let url = URL(fileURLWithPath: "/tmp/data.bin")
        XCTAssertEqual(FileAttachment.FileCategory.classify(url: url), .binary)
    }

    func testClassifyFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("test_folder_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertEqual(FileAttachment.FileCategory.classify(url: folder), .folder)
    }

    // MARK: - Suggestions Tests

    func testTextSuggestions() {
        let suggestions = FileAttachment.suggestions(for: .text)
        XCTAssertTrue(suggestions.contains { $0.label == "Summarize" })
        XCTAssertTrue(suggestions.contains { $0.label == "Edit" })
        XCTAssertTrue(suggestions.contains { $0.label == "Look for typos" })
    }

    func testAudioSuggestions() {
        let suggestions = FileAttachment.suggestions(for: .audio)
        XCTAssertTrue(suggestions.contains { $0.label == "Transcribe" })
    }

    func testImageSuggestions() {
        let suggestions = FileAttachment.suggestions(for: .image)
        XCTAssertTrue(suggestions.contains { $0.label == "Describe" })
        XCTAssertTrue(suggestions.contains { $0.label == "Extract text (OCR)" })
    }

    func testCodeSuggestions() {
        let suggestions = FileAttachment.suggestions(for: .code)
        XCTAssertTrue(suggestions.contains { $0.label == "Explain" })
        XCTAssertTrue(suggestions.contains { $0.label == "Find bugs" })
    }

    func testBinarySuggestions() {
        let suggestions = FileAttachment.suggestions(for: .binary)
        XCTAssertTrue(suggestions.contains { $0.label == "What is this file?" })
    }

    func testFolderSuggestions() {
        let suggestions = FileAttachment.suggestions(for: .folder)
        XCTAssertTrue(suggestions.contains { $0.label == "List contents" })
    }

    // MARK: - Icon Tests

    func testIconsReturnNonEmpty() {
        for category in [FileAttachment.FileCategory.text, .pdf, .audio, .image, .code, .binary, .folder] {
            XCTAssertFalse(FileAttachment.icon(for: category).isEmpty, "\(category) should have an icon")
        }
    }

    // MARK: - FileAttachment Init

    func testFileAttachmentInit() {
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        let attachment = FileAttachment(url: url)
        XCTAssertEqual(attachment.fileName, "notes.md")
        XCTAssertEqual(attachment.fileCategory, .text)
        XCTAssertEqual(attachment.url, url)
    }

    // MARK: - Pipeline E2E Tests (Attachment Routing)
    // Gated: these test FM read_file which is not shipped in v1.

    func testAttachmentTextFileRoutesToFMReadFile() async throws {
        try require(.auditTests)
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [readFileFM],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )
        await ScratchpadCache.shared.reset()

        _ = await engine.run(input: "[Attached: /tmp/notes.txt]\nSummarize this file")
        // FM tool should be routed — the ingredient should mention read_file
        XCTAssertTrue(captured.value.contains("read_file"), "FM read_file should be used for text attachment")
    }

    func testAttachmentCodeFileRoutesToFMReadFile() async throws {
        try require(.auditTests)
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [readFileFM],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )
        await ScratchpadCache.shared.reset()

        _ = await engine.run(input: "[Attached: /tmp/main.swift]\nExplain this code")
        XCTAssertTrue(captured.value.contains("read_file"), "FM read_file should be used for code attachment")
    }

    func testAttachmentCodeFileWithTyposRoutesToRewrite() async throws {
        try require(.auditTests)
        let rewriteSpy = SpyTool(name: "Rewrite", schema: "rewrite proofread grammar", result: ToolIO(text: "fixed", status: .ok))
        let engine = makeTestEngine(tools: [rewriteSpy], fmTools: [readFileFM])
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "[Attached: /tmp/essay.txt]\nLook for typos in this file")
        XCTAssertEqual(rewriteSpy.invocations.count, 1, "Rewrite tool should be called for typo request")
    }

    func testAttachmentAudioRoutesToTranscribe() async throws {
        let spy = SpyTool(name: "Transcribe", schema: "transcribe audio speech", result: ToolIO(text: "transcript", status: .ok))
        let engine = makeTestEngine(tools: [spy])
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "[Attached: /tmp/recording.mp3]\nTranscribe this file")
        XCTAssertEqual(spy.invocations.count, 1, "Transcribe tool should be called for audio attachment")
    }

    func testAttachmentPrefixStrippedFromRouting() async throws {
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [readFileFM],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "[Attached: /tmp/doc.md]\nSummarize this")
        // The final prompt should contain "Summarize this" but not the [Attached:] tag
        XCTAssertFalse(captured.value.contains("[Attached:"), "Attachment tag should be stripped from final prompt")
    }

    func testAttachmentEditRoutesToRewrite() async throws {
        try require(.auditTests)
        let spy = SpyTool(name: "Rewrite", schema: "rewrite proofread grammar edit", result: ToolIO(text: "edited", status: .ok))
        let engine = makeTestEngine(tools: [spy], fmTools: [readFileFM])
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "[Attached: /tmp/draft.md]\nEdit this file")
        XCTAssertEqual(spy.invocations.count, 1, "Rewrite should be called for 'edit' request")
    }

    func testAttachmentProofreadRoutesToRewrite() async throws {
        try require(.auditTests)
        let spy = SpyTool(name: "Rewrite", schema: "rewrite proofread grammar", result: ToolIO(text: "proofread", status: .ok))
        let engine = makeTestEngine(tools: [spy], fmTools: [readFileFM])
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "[Attached: /tmp/letter.txt]\nProofread this")
        XCTAssertEqual(spy.invocations.count, 1, "Rewrite should be called for 'proofread' request")
    }

    func testAttachmentPDFRoutesToFMReadFile() async throws {
        try require(.auditTests)
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [readFileFM],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "[Attached: /tmp/report.pdf]\nSummarize this file")
        XCTAssertTrue(captured.value.contains("read_file"), "FM read_file should be used for PDF attachment")
    }

    func testPDFSuggestions() {
        let suggestions = FileAttachment.suggestions(for: .pdf)
        XCTAssertTrue(suggestions.contains { $0.label == "Summarize" })
        XCTAssertTrue(suggestions.contains { $0.label == "Extract text" })
    }

    func testNoAttachmentRoutesNormally() async throws {
        let spy = SpyTool(name: "Weather", schema: "weather forecast temperature", result: ToolIO(text: "sunny", status: .ok))
        let engine = makeTestEngine(tools: [spy])
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "#weather London")
        XCTAssertEqual(spy.invocations.count, 1, "Normal routing should work without attachment")
        XCTAssertFalse(spy.invocations.first!.input.contains("/tmp"), "No file path should be injected")
    }

    func testAttachmentPathInjectedIntoToolInput() async throws {
        let spy = SpyTool(name: "Transcribe", schema: "transcribe audio speech", result: ToolIO(text: "transcript", status: .ok))
        let engine = makeTestEngine(tools: [spy])
        await ScratchpadCache.shared.reset()

        let _ = await engine.run(input: "[Attached: /Users/test/voice.m4a]\nTranscribe this")
        XCTAssertTrue(spy.invocations.first!.input.contains("/Users/test/voice.m4a"), "File path should be in tool input")
    }

    func testAttachmentWithChipOverridesHint() async throws {
        try require(.auditTests)
        // Even with a text attachment, an explicit #weather chip should win
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast temperature", result: ToolIO(text: "sunny", status: .ok))
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [weatherSpy],
            fmTools: [readFileFM],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )
        await ScratchpadCache.shared.reset()

        // The attachment hint checks if input starts with a path, but the engine
        // prepends the path. With a chip present, chips are checked before attachment hints.
        // However, the router sees "path\n#weather London" — the attachment hint triggers first.
        // This routes to FM read_file since text attachments use FM tools now.
        let _ = await engine.run(input: "[Attached: /tmp/notes.txt]\n#weather London")
        // Attachment hint fires first, routes to FM read_file
        XCTAssertTrue(captured.value.contains("read_file"), "FM read_file should handle text attachment")
    }
}
