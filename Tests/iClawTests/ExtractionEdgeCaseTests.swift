import XCTest
@testable import iClawCore

/// Tests for ToolArgumentExtractor edge cases: malformed LLM output,
/// code fence stripping, schema file validity.
final class ExtractionEdgeCaseTests: XCTestCase {

    // MARK: - Code Fence Stripping

    func testStripPlainJSON() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            {"location": "San Francisco"}
            """
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather in SF", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertEqual(result?.location, "San Francisco")
    }

    func testStripLowercaseCodeFence() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            ```json
            {"location": "Paris"}
            ```
            """
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather in Paris", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertEqual(result?.location, "Paris")
    }

    func testStripUppercaseCodeFence() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            ```JSON
            {"location": "Tokyo"}
            ```
            """
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather in Tokyo", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertEqual(result?.location, "Tokyo")
    }

    func testStripLeadingProse() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            Here are the extracted parameters:
            {"location": "London"}
            """
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather in London", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertEqual(result?.location, "London")
    }

    func testStripBareCodeFence() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            ```
            {"location": "Berlin"}
            ```
            """
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather in Berlin", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertEqual(result?.location, "Berlin")
    }

    // MARK: - Failure Cases

    func testMalformedJSONReturnsNil() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return "I'm sorry, I couldn't extract the parameters."
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertNil(result)
    }

    func testEmptyResponseReturnsNil() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return ""
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertNil(result)
    }

    func testExtraFieldsIgnored() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            {"location": "NYC", "confidence": 0.95, "extra": true}
            """
        })

        struct Args: ToolArguments { let location: String }
        let result = await extractor.extract(input: "weather NYC", schema: "{}", toolName: "Weather", as: Args.self)
        XCTAssertEqual(result?.location, "NYC")
    }

    // MARK: - Schema File Validation

    func testAllSchemaFilesAreValidJSON() {
        // Enumerate ToolSchemas directory and validate every file
        let bundle = Bundle.iClawCore
        let possiblePaths = [
            bundle.resourceURL?.appendingPathComponent("Config/ToolSchemas"),
            bundle.url(forResource: "Config/ToolSchemas", withExtension: nil),
        ].compactMap { $0 }

        for dir in possiblePaths {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }

            for file in files where file.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: file)
                    let str = String(data: data, encoding: .utf8)
                    XCTAssertNotNil(str, "Schema \(file.lastPathComponent) is not valid UTF-8")
                    XCTAssertFalse(str?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                        "Schema \(file.lastPathComponent) is empty")
                } catch {
                    XCTFail("Failed to read schema \(file.lastPathComponent): \(error)")
                }
            }
        }
    }
}
