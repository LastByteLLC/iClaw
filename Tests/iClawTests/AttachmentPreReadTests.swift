import XCTest
import os
import FoundationModels
@testable import iClawCore

/// Tests for the attachment pre-read optimization: when a file is attached,
/// the engine reads it directly instead of relying on the LLM to call the
/// read_file FM tool (which fails unreliably on-device).
final class AttachmentPreReadTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iClaw-AttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Text File Pre-Read

    func testAttachmentTextFilePreRead() async throws {
        let filePath = tempDir.appendingPathComponent("notes.txt")
        try "Meeting notes from Q1 planning session.\nAction items: review budget, hire 2 engineers.".write(to: filePath, atomically: true, encoding: .utf8)

        let captured = CapturedPrompt()
        let capturedTools = CapturedTools()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [ReadFileFMDescriptor()],
            engineLLMResponder: makeToolCapturingLLMResponder(capture: captured, toolCapture: capturedTools)
        )

        let result = await engine.run(input: "[Attached: \(filePath.path)]\nwhat am I missing?")

        let prompt = captured.value
        // File content should appear in the final prompt as an ingredient
        XCTAssertTrue(prompt.contains("Meeting notes from Q1 planning"), "Final prompt should contain the file content")
        XCTAssertTrue(prompt.contains("[FILE: notes.txt]"), "Ingredient should be tagged with [FILE: filename]")
        // Should NOT attach the read_file FM tool (we pre-read instead)
        XCTAssertFalse(capturedTools.contains(toolNamed: ToolNames.readFile), "Should not defer to FM tool when pre-read succeeds")
        // Should have a non-empty response (not generic fallback)
        XCTAssertFalse(result.text.contains("I wasn't able to generate"), "Should not show generic fallback")
    }

    // MARK: - Code File Pre-Read

    func testAttachmentCodeFilePreRead() async throws {
        let filePath = tempDir.appendingPathComponent("example.swift")
        try "import Foundation\n\nfunc greet(name: String) -> String {\n    return \"Hello, \\(name)!\"\n}".write(to: filePath, atomically: true, encoding: .utf8)

        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [ReadFileFMDescriptor()],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "[Attached: \(filePath.path)]\nexplain this code")

        let prompt = captured.value
        XCTAssertTrue(prompt.contains("import Foundation"), "Final prompt should contain the Swift code")
        XCTAssertTrue(prompt.contains("func greet"), "Final prompt should contain function definition")
        XCTAssertTrue(prompt.contains("[FILE: example.swift]"), "Ingredient should identify the file")
    }

    // MARK: - Large File Truncation

    func testAttachmentLargeFileTruncation() async throws {
        let filePath = tempDir.appendingPathComponent("large.txt")
        // Create a file with 10K characters
        let largeContent = String(repeating: "Lorem ipsum dolor sit amet. ", count: 400)
        try largeContent.write(to: filePath, atomically: true, encoding: .utf8)

        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [ReadFileFMDescriptor()],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "[Attached: \(filePath.path)]\nsummarize")

        let prompt = captured.value
        // The ingredient should be present but truncated
        XCTAssertTrue(prompt.contains("[FILE: large.txt]"), "Should contain file ingredient")
        // Content should be truncated (4000 char default + prefix)
        XCTAssertTrue(prompt.contains("Lorem ipsum"), "Should contain beginning of file")

        // Extract the [FILE:...] ingredient and verify it's bounded
        if let fileRange = prompt.range(of: "[FILE: large.txt]") {
            let afterFile = String(prompt[fileRange.lowerBound...])
            // The ingredient + prefix should be well under 5000 chars
            XCTAssertLessThan(afterFile.count, 5000, "File ingredient should be truncated to ~4000 chars")
        }
    }

    // MARK: - Missing File Graceful Fallback

    func testAttachmentMissingFileGracefulFallback() async throws {
        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [ReadFileFMDescriptor()],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "[Attached: /tmp/nonexistent-file-\(UUID()).txt]\nread this")

        let prompt = captured.value
        // Should contain an error ingredient about file not found
        XCTAssertTrue(prompt.contains("File not found") || prompt.contains("[FILE:"), "Should contain file-not-found error or file ingredient")
        // Should NOT show generic fallback (the error message is a substantive ingredient)
        XCTAssertFalse(prompt.isEmpty, "Should have a non-empty prompt")
    }

    // MARK: - Path Extraction

    func testAttachmentPathExtraction() async throws {
        let filePath = tempDir.appendingPathComponent("test.txt")
        try "test content".write(to: filePath, atomically: true, encoding: .utf8)

        let captured = CapturedPrompt()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [ReadFileFMDescriptor()],
            engineLLMResponder: makeStubLLMResponder(capture: captured)
        )

        _ = await engine.run(input: "[Attached: \(filePath.path)]\nwhat is this?")

        let prompt = captured.value
        // The [Attached: ...] tag should be stripped from the user prompt
        XCTAssertFalse(prompt.contains("[Attached:"), "The [Attached:] tag should be stripped from the prompt")
        // The user's question should still be present
        XCTAssertTrue(prompt.contains("what is this?"), "User question should remain in prompt")
    }

    // MARK: - Non-Attachment FM Tools Unchanged

    func testNonAttachmentFMToolsUnchanged() async throws {
        // Use a non-read_file FM tool descriptor with no attachment
        let stub = StubFMTool(name: "web_search", chipName: "search", routingKeywords: ["search"])
        let capturedTools = CapturedTools()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [stub],
            engineLLMResponder: makeToolCapturingLLMResponder(toolCapture: capturedTools)
        )

        _ = await engine.run(input: "#search latest news")

        // Should use the normal FM tool path (not pre-read): FM tool attached.
        XCTAssertTrue(capturedTools.contains(toolNamed: "web_search"), "Non-attachment FM tools should be attached via tools parameter")
    }

    // MARK: - Security: Blocks Outside Home

    func testAttachmentSecurityBlocksOutsideHome() async throws {
        // Path outside home/tmp/var should be blocked by pre-read
        let capturedTools = CapturedTools()
        let engine = makeTestEngine(
            tools: [],
            fmTools: [ReadFileFMDescriptor()],
            engineLLMResponder: makeToolCapturingLLMResponder(toolCapture: capturedTools)
        )

        _ = await engine.run(input: "[Attached: /etc/passwd]\nshow me this")

        // Pre-read should fail for /etc/passwd, falling back to FM tool path,
        // which attaches read_file to the LLM generation call.
        XCTAssertTrue(
            capturedTools.contains(toolNamed: ToolNames.readFile),
            "Should fall back to FM tool path when pre-read is blocked"
        )
    }
}

// MARK: - Test Helpers

/// Stub Tool whose name matches the descriptor, so tests can verify which
/// FM tool reaches the LLM via the `tools:` parameter.
private struct StubFMToolImpl: Tool {
    typealias Arguments = ClipboardInput
    typealias Output = String

    let name: String
    var description: String { "stub tool \(name)" }
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments: ClipboardInput) async throws -> String { "stub" }
}

private struct StubFMTool: FMToolDescriptor {
    let name: String
    let chipName: String
    let routingKeywords: [String]
    let category: CategoryEnum = .offline
    func makeTool() -> any Tool { StubFMToolImpl(name: name) }
}
