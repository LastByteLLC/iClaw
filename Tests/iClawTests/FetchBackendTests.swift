import XCTest
import Replay
@testable import iClawCore

/// Tests for FetchBackend implementations and the updated WebFetchTool/WebSearchTool.
/// Uses Replay HAR fixtures for deterministic network testing.
final class FetchBackendTests: XCTestCase {

    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    private func harURL(_ name: String) -> URL {
        Self.fixturesDir.appendingPathComponent("\(name).har")
    }

    private func replaySession(_ fixtureName: String) async throws -> URLSession {
        let config = PlaybackConfiguration(
            source: .file(harURL(fixtureName)),
            playbackMode: .strict,
            recordMode: .none,
            matchers: [.method, .host, .path, .query]
        )
        return try await Playback.session(configuration: config)
    }

    // MARK: - HTTPFetchBackend Tests

    func testHTTPFetchBackendExtractsText() async throws {
        let session = try await replaySession("webfetch_example")
        let backend = HTTPFetchBackend(session: session)

        let result = try await backend.fetch(url: URL(string: "https://example.com")!)
        XCTAssertTrue(result.text.contains("Example Domain"), "Should extract text from HTML")
        XCTAssertNotNil(result.title, "Should extract title")
        XCTAssertNotNil(result.html, "Should preserve raw HTML")
        XCTAssertEqual(result.statusCode, 200)
    }

    func testHTTPFetchBackendStripsScriptsAndNav() async throws {
        let session = try await replaySession("webfetch_article")
        let backend = HTTPFetchBackend(session: session)

        let result = try await backend.fetch(url: URL(string: "https://blog.rust-lang.org/")!)
        XCTAssertEqual(result.statusCode, 200)
        // Script tags should be removed from the text extraction
        XCTAssertFalse(result.text.contains("<script"), "Text should not contain script tags")
        XCTAssertFalse(result.text.contains("<style"), "Text should not contain style tags")
        // But raw HTML should still be available
        XCTAssertNotNil(result.html)
    }

    func testHTTPFetchBackendHandlesJSON() async throws {
        let session = try await replaySession("weather_london")
        let backend = HTTPFetchBackend(session: session)

        let result = try await backend.fetch(
            url: URL(string: "https://api.open-meteo.com/v1/forecast?latitude=51.5074&longitude=-0.1278&current=temperature_2m,weather_code&wind_speed_unit=ms&timezone=auto")!
        )
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertNil(result.html, "JSON response should not have html field")
        XCTAssertNil(result.title, "JSON response should not have title")
        XCTAssertTrue(result.text.contains("temperature"), "Should return raw JSON text")
    }

    // MARK: - WebFetchTool with HTTPFetchBackend

    func testWebFetchToolCompactsOutput() async throws {
        let session = try await replaySession("webfetch_article")
        let tool = WebFetchTool(session: session)

        let result = try await tool.execute(
            input: "https://blog.rust-lang.org/",
            entities: ExtractedEntities(
                names: [], places: [], organizations: [],
                urls: [URL(string: "https://blog.rust-lang.org/")!],
                phoneNumbers: [], emails: [], ocrText: nil
            )
        )
        XCTAssertEqual(result.status, .ok)
        // Output should be compacted — no excessive whitespace
        XCTAssertFalse(result.text.contains("   "), "Should not have triple spaces after compaction")
    }

    func testWebFetchToolPrependsTitle() async throws {
        let session = try await replaySession("webfetch_example")
        let tool = WebFetchTool(session: session)

        let result = try await tool.execute(input: "https://example.com")
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.hasPrefix("# "), "Should prepend title as markdown header")
    }

    func testWebFetchToolLimitsTruncation() async throws {
        let session = try await replaySession("webfetch_article")
        let tool = WebFetchTool(session: session)

        let result = try await tool.execute(input: "https://blog.rust-lang.org/")
        XCTAssertEqual(result.status, .ok)
        // Result should be within the token budget
        XCTAssertLessThanOrEqual(result.text.count, ContentCompactor.defaultLimit + 200,
            "Output should be within token budget (with some margin for title/separator)")
    }

    // MARK: - isKnownAPI heuristic

    func testIsKnownAPIDetectsAPISubdomains() {
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://api.example.com/data")!))
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://api.open-meteo.com/v1/forecast")!))
    }

    func testIsKnownAPIDetectsAPIPathSegments() {
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://example.com/api/users")!))
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://example.com/v2/data")!))
    }

    func testIsKnownAPIDetectsFileExtensions() {
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://example.com/feed.json")!))
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://example.com/feed.xml")!))
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://example.com/feed.rss")!))
    }

    func testIsKnownAPIDetectsKnownHosts() {
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://query1.finance.yahoo.com/v1/quote")!))
        XCTAssertTrue(WebFetchTool.isKnownAPI(URL(string: "https://itunes.apple.com/search?term=test")!))
    }

    func testIsKnownAPIRejectsRegularWebPages() {
        XCTAssertFalse(WebFetchTool.isKnownAPI(URL(string: "https://www.nytimes.com/article")!))
        XCTAssertFalse(WebFetchTool.isKnownAPI(URL(string: "https://en.wikipedia.org/wiki/Swift")!))
        XCTAssertFalse(WebFetchTool.isKnownAPI(URL(string: "https://github.com/apple/swift")!))
        XCTAssertFalse(WebFetchTool.isKnownAPI(URL(string: "https://blog.rust-lang.org/")!))
    }

    // MARK: - WebSearchTool parsing

    func testWebSearchToolParsesGoogleFixture() async throws {
        let session = try await replaySession("websearch_swift")
        let tool = WebSearchTool(session: session)

        let result = try await tool.call(arguments: WebSearchInput(query: "Swift programming language"))
        // The fixture may have degraded HTML (no h3s with old UA), but tool should handle gracefully
        XCTAssertFalse(result.isEmpty, "Should return some content")
    }

    func testWebSearchDDGParserHandlesEmptyHTML() throws {
        let results = try WebSearchTool.parseDuckDuckGoResults(html: "<html><body></body></html>")
        XCTAssertTrue(results.isEmpty, "Empty page should yield no results")
    }

    func testWebSearchBraveParserHandlesEmptyHTML() throws {
        let results = try WebSearchTool.parseBraveResults(html: "<html><body></body></html>")
        XCTAssertTrue(results.isEmpty, "Empty page should yield no results")
    }
}
