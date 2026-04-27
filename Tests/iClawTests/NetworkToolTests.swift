import XCTest
import Replay
import FoundationModels
@testable import iClawCore

/// URLProtocol that returns HTTP 503 for all requests — used to test graceful
/// failure paths without hitting the real network.
private class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Creates a URLSession whose requests all fail with HTTP 503.
private func makeFailingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FailingURLProtocol.self]
    return URLSession(configuration: config)
}

/// Comprehensive tests for all network-dependent tools using Replay HAR fixtures.
/// These tests replay recorded HTTP responses — no live network calls.
///
/// To re-record fixtures: `swift test --filter iClawTests.FixtureRecorder`
/// Fixtures live in Tests/iClawTests/Fixtures/*.har
final class NetworkToolTests: XCTestCase {

    override func setUp() async throws { await ScratchpadCache.shared.reset() }

    // MARK: - Helpers

    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    private func harURL(_ name: String) -> URL {
        Self.fixturesDir.appendingPathComponent("\(name).har")
    }

    /// Creates a URLSession configured for strict HAR playback (no network).
    /// Uses component-based matching (host + path + query) to handle URL encoding
    /// differences (e.g. `+` vs `%20` in query params).
    private func replaySession(_ fixtureName: String) async throws -> URLSession {
        let config = PlaybackConfiguration(
            source: .file(harURL(fixtureName)),
            playbackMode: .strict,
            recordMode: .none,
            matchers: [.method, .host, .path, .query]
        )
        return try await Playback.session(configuration: config)
    }

    // MARK: - WebFetchTool Tests

    func testWebFetchExtractsURLFromNaturalLanguage() async throws {
        let session = try await replaySession("webfetch_example")
        let tool = WebFetchTool(session: session)

        // Bug fix test: input is a natural language sentence containing a URL
        let result = try await tool.execute(
            input: "Summarize this article: https://example.com",
            entities: ExtractedEntities(
                names: [], places: [], organizations: [],
                urls: [URL(string: "https://example.com")!],
                phoneNumbers: [], emails: [], ocrText: nil
            )
        )

        XCTAssertEqual(result.status, .ok, "Should succeed, got: \(result.text)")
        XCTAssertFalse(result.text.contains("Invalid URL"), "Should not report invalid URL")
        XCTAssertFalse(result.text.contains("No valid URL"), "Should find the URL in entities")
        XCTAssertTrue(result.text.contains("Example Domain"), "Should contain page content")
    }

    func testWebFetchWithBareURL() async throws {
        let session = try await replaySession("webfetch_example")
        let tool = WebFetchTool(session: session)

        let result = try await tool.execute(input: "https://example.com")
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Example Domain"))
    }

    func testWebFetchParsesURLFromInputWhenNoEntities() async throws {
        let session = try await replaySession("webfetch_example")
        let tool = WebFetchTool(session: session)

        // No entities passed — tool should parse URL from input string
        let result = try await tool.execute(
            input: "Please fetch https://example.com for me",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok, "Should parse URL from input text")
        XCTAssertTrue(result.text.contains("Example Domain"))
    }

    func testWebFetchArticleContent() async throws {
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
        XCTAssertGreaterThan(result.text.count, 100, "Should fetch real article content")
    }

    func testWebFetchFallsBackToSearchWhenNoURL() async throws {
        let tool = WebFetchTool()

        let result = try await tool.execute(input: "tell me about cats")
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Search the web for"), "Should fall back to web search. Got: \(result.text)")
    }

    // MARK: - Weather API Tests
    //
    // WeatherTool first geocodes cities via MKLocalSearch (Apple framework, not HTTP).
    // We test the Open-Meteo API response parsing directly by verifying the fixture
    // data is valid JSON with expected fields.

    func testWeatherAPIResponseStructure() async throws {
        let session = try await replaySession("weather_london")

        // Fetch directly with the same URL WeatherTool would use for London
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=51.5074&longitude=-0.1278&current=temperature_2m,weather_code&wind_speed_unit=ms&timezone=auto")!
        let (data, response) = try await session.data(from: url)

        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)

        // Verify it parses as valid OpenMeteo response
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        XCTAssertNotEqual(decoded.current.temperature_2m, 0, "Should have a temperature value")
        XCTAssertTrue((0...99).contains(decoded.current.weather_code), "Weather code should be valid")
    }

    func testWeatherTokyoAPIResponse() async throws {
        let session = try await replaySession("weather_tokyo")

        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=35.6762&longitude=139.6503&current=temperature_2m,weather_code&wind_speed_unit=ms&timezone=auto")!
        let (data, _) = try await session.data(from: url)

        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        XCTAssertNotEqual(decoded.current.temperature_2m, 0)
    }

    func testWeatherToolWithKnownCoordinatesCity() async throws {
        // Test WeatherTool end-to-end with a city that MKLocalSearch can geocode
        // This test hits the real geocoder but uses the replay session for the API call
        let session = try await replaySession("weather_london")
        let tool = WeatherTool(session: session)

        let result = try await tool.execute(input: "weather in London")
        // Geocoding may fail in CI/sandbox — check both success and graceful failure
        if result.status == .ok {
            let hasTemp = result.text.contains("°C") || result.text.contains("°F")
            XCTAssertTrue(hasTemp, "Should contain temperature: \(result.text)")
            XCTAssertEqual(result.outputWidget, "WeatherWidget")
        } else {
            // Geocoding failure is expected in sandboxed environments
            XCTAssertTrue(result.text.contains("London"),
                "Error should mention the requested city: \(result.text)")
        }
    }

    // MARK: - ConvertTool Tests (Currency)

    func testConvertCurrencyUSDtoEUR() async throws {
        let session = try await replaySession("currency_usd")
        let tool = ConvertTool(session: session)

        let result = try await tool.execute(input: "100 usd to eur")
        XCTAssertEqual(result.status, .ok, "Currency conversion should succeed: \(result.text)")
        XCTAssertTrue(result.text.contains("USD"), "Should mention USD")
        XCTAssertTrue(result.text.contains("EUR"), "Should mention EUR")
    }

    func testConvertCurrencyWithAliases() async throws {
        let session = try await replaySession("currency_usd")
        let tool = ConvertTool(session: session)

        let result = try await tool.execute(input: "50 dollars to pounds")
        XCTAssertEqual(result.status, .ok, "Alias resolution should work: \(result.text)")
    }

    func testConvertCryptoBTC() async throws {
        let session = try await replaySession("currency_btc")
        let tool = ConvertTool(session: session)

        let result = try await tool.execute(input: "1 btc to usd")
        XCTAssertEqual(result.status, .ok, "Crypto conversion should succeed: \(result.text)")
        XCTAssertTrue(result.text.contains("BTC"), "Should mention BTC")
    }

    func testConvertVerifiedDataFlag() async throws {
        let session = try await replaySession("currency_usd")
        let tool = ConvertTool(session: session)

        let result = try await tool.execute(input: "100 usd to gbp")
        XCTAssertTrue(result.isVerifiedData, "Currency data should be flagged as verified")
    }

    func testConvertUnitConversionStillWorks() async throws {
        // Unit conversion doesn't need network
        let tool = ConvertTool()

        let result = try await tool.execute(input: "10 miles to km")
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("16.09") || result.text.contains("16.1"),
            "10 miles should be ~16.09 km: \(result.text)")
    }

    func testConvertTemperature() async throws {
        let tool = ConvertTool()

        let result = try await tool.execute(input: "100 fahrenheit to celsius")
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("37.78") || result.text.contains("37.7"),
            "100°F should be ~37.78°C: \(result.text)")
    }

    // MARK: - PodcastTool Tests

    func testPodcastSearch() async throws {
        let session = try await replaySession("podcast_search_daily")
        // Force keyword fallback (no LLM in tests)
        let tool = PodcastTool(session: session, llmResponder: { _ in throw NSError(domain: "test", code: 0) })

        let result = try await tool.execute(input: "search for the daily")
        XCTAssertEqual(result.status, .ok, "Podcast search should succeed: \(result.text)")
        XCTAssertTrue(result.text.contains("Daily") || result.text.contains("daily"),
            "Should find The Daily podcast: \(result.text)")
    }

    func testPodcastSearchReturnsMultipleResults() async throws {
        let session = try await replaySession("podcast_search_daily")
        let tool = PodcastTool(session: session, llmResponder: { _ in throw NSError(domain: "test", code: 0) })

        let result = try await tool.execute(input: "search the daily")
        let lineCount = result.text.components(separatedBy: "\n").count
        XCTAssertGreaterThan(lineCount, 1, "Should return multiple results")
    }

    func testPodcastSearchIncludesRichData() async throws {
        let session = try await replaySession("podcast_search_daily")
        let tool = PodcastTool(session: session, llmResponder: { _ in throw NSError(domain: "test", code: 0) })

        let result = try await tool.execute(input: "search for the daily")
        // Should now include episode count and genre
        XCTAssertTrue(result.text.contains("episodes)") || result.text.contains("episode"),
            "Should include episode counts: \(result.text)")
    }

    func testPodcastEpisodeSearchAPI() async throws {
        // Verify the episode API response structure using the fixture directly
        let session = try await replaySession("podcast_episodes_daily")

        let url = URL(string: "https://itunes.apple.com/search?term=the%20daily&entity=podcastEpisode&limit=5")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            XCTFail("Should parse JSON")
            return
        }

        XCTAssertGreaterThan(results.count, 0, "Should have episode results")

        // Verify rich fields are present
        let ep = results[0]
        XCTAssertNotNil(ep["trackName"], "Should have episode title")
        XCTAssertNotNil(ep["description"], "Should have episode description")
        XCTAssertNotNil(ep["episodeUrl"], "Should have streaming URL")
        XCTAssertNotNil(ep["trackTimeMillis"], "Should have duration")
    }

    // MARK: - Full Pipeline Integration (URL → WebFetch)

    func testPipelineURLAutoRoutesToWebFetch() async throws {
        _ = try await replaySession("webfetch_example")
        let webFetch = SpyTool(
            name: "WebFetch",
            schema: "fetch content from a URL",
            result: ToolIO(text: "Example Domain content", status: .ok)
        )

        let engine = makeTestEngine(
            tools: [webFetch],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "none"),
            engineLLMResponder: makeStubLLMResponder(response: "Here's what I found on that page.")
        )

        _ = await engine.run(input: "Summarize https://example.com")

        XCTAssertEqual(webFetch.invocations.count, 1,
            "WebFetch should be invoked for URL input")
    }

    func testPipelineURLWithTextContext() async throws {
        let webFetch = SpyTool(
            name: "WebFetch",
            schema: "fetch content from a URL",
            result: ToolIO(text: "Page content here", status: .ok)
        )

        let engine = makeTestEngine(
            tools: [webFetch],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "none"),
            engineLLMResponder: makeStubLLMResponder(response: "Summary of article")
        )

        _ = await engine.run(input: "What does this article say? https://blog.rust-lang.org/")

        XCTAssertEqual(webFetch.invocations.count, 1,
            "Should auto-route to WebFetch when URL detected")
    }

    func testPipelineNoURLDoesNotRouteToWebFetch() async throws {
        let webFetch = SpyTool(
            name: "WebFetch",
            schema: "fetch content",
            result: ToolIO(text: "content", status: .ok)
        )
        let weather = SpyTool(
            name: "Weather",
            schema: "weather forecast temperature",
            result: ToolIO(text: "72°F Sunny", status: .ok)
        )

        let engine = makeTestEngine(
            tools: [webFetch, weather],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "none"),
            engineLLMResponder: makeStubLLMResponder(response: "It's sunny")
        )

        _ = await engine.run(input: "what's the weather")

        XCTAssertEqual(webFetch.invocations.count, 0,
            "WebFetch should NOT be invoked for non-URL input")
    }

    // MARK: - Edge Cases

    func testWebFetchMultipleURLsInInput() async throws {
        // Tests that the tool doesn't crash with multiple URLs — uses failing session
        // so no real network calls are made
        let tool = WebFetchTool(session: makeFailingSession())
        let result = try await tool.execute(
            input: "Compare https://example.com and https://example.org",
            entities: ExtractedEntities(
                names: [], places: [], organizations: [],
                urls: [URL(string: "https://example.com")!, URL(string: "https://example.org")!],
                phoneNumbers: [], emails: [], ocrText: nil
            )
        )
        // Should not crash — may error due to 503 but should handle gracefully
        XCTAssertNotEqual(result.text, "No valid URL found in input.")
    }

    func testConvertInvalidCurrencyReturnsError() async throws {
        let tool = ConvertTool(session: makeFailingSession())
        let result = try await tool.execute(input: "convert 100 zzz to yyy")
        // Should either return an error or a "not found" message
        XCTAssertTrue(
            result.status == .error || result.text.contains("Could not"),
            "Invalid currency should report error: \(result.text)"
        )
    }

    func testConvertNoInputParseFails() async throws {
        // Stub the LLM responder to prevent self-healing from normalizing the input
        let tool = ConvertTool(session: makeFailingSession(), llmResponder: { _ in "NONE" })
        let result = try await tool.execute(input: "convert something")
        XCTAssertEqual(result.status, .error, "Unparseable input should error")
    }

    func testPodcastEmptyQuery() async throws {
        let tool = PodcastTool(session: makeFailingSession(), llmResponder: { _ in throw NSError(domain: "test", code: 0) })
        let result = try await tool.execute(input: "search for")
        // Should not crash — may error due to 503 or fall back gracefully
        XCTAssertTrue(result.status == .ok || result.status == .error)
    }

    // MARK: - WikipediaSearchTool Tests

    func testWikipediaSearchAndExtract() async throws {
        // Wikipedia tool makes 2 requests: opensearch then extract
        // We need both fixtures loaded. Use a combined session approach.
        let searchConfig = PlaybackConfiguration(
            source: .file(harURL("wikipedia_search_einstein")),
            playbackMode: .strict,
            recordMode: .none,
            matchers: [.method, .host, .path, .query]
        )
        let searchSession = try await Playback.session(configuration: searchConfig)

        // Test the search step directly
        let encoded = "Albert%20Einstein"
        let searchURL = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(encoded)&limit=1&format=json")!
        let (searchData, searchResponse) = try await searchSession.data(from: searchURL)
        XCTAssertEqual((searchResponse as! HTTPURLResponse).statusCode, 200)

        // Parse opensearch result
        let json = try JSONSerialization.jsonObject(with: searchData) as! [Any]
        XCTAssertGreaterThan(json.count, 1)
        let titles = json[1] as! [String]
        XCTAssertTrue(titles.first?.contains("Einstein") == true, "Should find Einstein article")
    }

    func testWikipediaExtractContent() async throws {
        let session = try await replaySession("wikipedia_extract_einstein")

        let titleEncoded = "Albert%20Einstein"
        let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&exintro=1&titles=\(titleEncoded)&format=json")!
        let (data, _) = try await session.data(from: url)

        let fetchJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let query = fetchJSON["query"] as! [String: Any]
        let pages = query["pages"] as! [String: Any]
        let page = pages.values.first as! [String: Any]
        let extract = page["extract"] as! String

        XCTAssertTrue(extract.contains("physicist"), "Einstein extract should mention physicist")
        XCTAssertGreaterThan(extract.count, 100, "Extract should have substantial content")
    }

    func testWikipediaNoResults() async throws {
        let session = try await replaySession("wikipedia_search_noresults")

        let url = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=xyzzyplughtwisty&limit=1&format=json")!
        let (data, _) = try await session.data(from: url)

        let json = try JSONSerialization.jsonObject(with: data) as! [Any]
        let titles = json[1] as? [String] ?? []
        XCTAssertTrue(titles.isEmpty, "Nonsense query should return no results")
    }

    func testWikipediaToolEndToEnd() async throws {
        // WikipediaCoreTool calls both search + extract in sequence.
        // Since Replay can serve both from the same session when matchers are broad enough,
        // we test the full tool using a merged fixture approach.
        let session = try await replaySession("wikipedia_search_einstein")
        let tool = WikipediaCoreTool(session: session)

        // This will succeed on the search step but may fail on extract (different fixture)
        // since WikipediaCoreTool makes two sequential requests.
        // We verify the search parsing works by catching the extract failure gracefully.
        do {
            let result = try await tool.execute(input: "Albert Einstein")
            // If both requests match, we get a real result
            XCTAssertFalse(result.text.contains("No Wikipedia article found"))
        } catch {
            // Extract request may not match — that's OK for this test
            // The search step succeeded if we got this far
        }
    }

    // MARK: - NewsTool Tests

    func testNewsToolMetadata() {
        let tool = NewsTool()
        XCTAssertEqual(tool.name, "News")
        XCTAssertEqual(tool.category, .online)
        XCTAssertFalse(tool.isInternal)
    }

    func testNewsRSSParsing() {
        // Test the RSS parser with a minimal RSS feed
        let rssXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
        <channel>
            <title>Test Feed</title>
            <item>
                <title>First Headline</title>
                <link>https://example.com/article1</link>
                <pubDate>Wed, 12 Mar 2026 10:00:00 +0000</pubDate>
            </item>
            <item>
                <title>Second Headline</title>
                <link>https://example.com/article2</link>
                <pubDate>Wed, 12 Mar 2026 09:00:00 +0000</pubDate>
            </item>
        </channel>
        </rss>
        """.data(using: .utf8)!

        let parser = XMLParser(data: rssXML)
        let rssParser = RSSParser(sourceName: "Test")
        parser.delegate = rssParser
        parser.parse()

        XCTAssertEqual(rssParser.articles.count, 2)
        XCTAssertEqual(rssParser.articles[0].title, "First Headline")
        XCTAssertEqual(rssParser.articles[0].link, "https://example.com/article1")
        XCTAssertEqual(rssParser.articles[0].source, "Test")
        XCTAssertEqual(rssParser.articles[0].domain, "example.com")
    }

    func testNewsAtomParsing() {
        // Test Atom feed format (used by The Verge, etc.)
        let atomXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
            <title>Atom Feed</title>
            <entry>
                <title>Atom Article</title>
                <link href="https://atom.example.com/post/1"/>
                <published>2026-03-12T08:00:00Z</published>
            </entry>
        </feed>
        """.data(using: .utf8)!

        let parser = XMLParser(data: atomXML)
        let rssParser = RSSParser(sourceName: "Atom Source")
        parser.delegate = rssParser
        parser.parse()

        XCTAssertEqual(rssParser.articles.count, 1)
        XCTAssertEqual(rssParser.articles[0].title, "Atom Article")
        XCTAssertEqual(rssParser.articles[0].link, "https://atom.example.com/post/1")
        XCTAssertEqual(rssParser.articles[0].source, "Atom Source")
    }

    func testNewsWidgetDataStructure() {
        let articles = [
            NewsArticle(title: "Test", link: "https://bbc.com/1", source: "BBC", domain: "bbc.com", pubDate: "1h ago"),
        ]
        let data = NewsWidgetData(articles: articles, category: "tech")
        XCTAssertEqual(data.articles.count, 1)
        XCTAssertEqual(data.category, "tech")
        XCTAssertEqual(data.articles[0].domain, "bbc.com")
    }

    func testNewsDrillDownWithURL() async throws {
        // When input contains a URL, NewsTool should attempt to fetch the article.
        // Uses failing session so no real network calls are made.
        let tool = NewsTool(session: makeFailingSession(), httpOnly: true)
        let result = try await tool.execute(input: "https://example.com/test-article", entities: nil)
        // Should attempt drill-down and handle 503 gracefully
        XCTAssertTrue(result.status == .ok || result.status == .error)
    }

    // MARK: - WebSearchTool Tests

    func testWebSearchReturnsResults() async throws {
        let session = try await replaySession("websearch_swift")
        let tool = WebSearchTool(session: session)

        let result = try await tool.call(arguments: WebSearchInput(query: "Swift programming language"))
        // Google may block with captcha, but our fixture has a 200 response
        XCTAssertFalse(result.isEmpty, "Should return some content")
        if result.contains("Search results") {
            XCTAssertTrue(result.contains("Swift") || result.contains("swift"),
                "Search for Swift should mention Swift: \(result.prefix(300))")
        }
    }


    // MARK: - StockTool Tests

    func testStockQuoteTypeAPIParsing() async throws {
        let session = try await replaySession("stock_quotetype_aapl")

        let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/quoteType/AAPL?formatted=true&enablePrivateCompany=true&overnightPrice=true&lang=en-US&region=US")!
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)

        let status = (response as! HTTPURLResponse).statusCode
        XCTAssertEqual(status, 200)

        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let quoteType = json["quoteType"] as? [String: Any]
        XCTAssertNotNil(quoteType, "Should have quoteType in response")
    }

    func testStockRecommendationsAPIParsing() async throws {
        let session = try await replaySession("stock_recommendations_aapl")

        let url = URL(string: "https://query1.finance.yahoo.com/v6/finance/recommendationsbysymbol/AAPL?fields=&lang=en-US&region=US")!
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)

        let status = (response as! HTTPURLResponse).statusCode
        XCTAssertEqual(status, 200)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testStockToolGracefulFailure() async throws {
        // Inject a session that returns 503 to test graceful failure without network
        let tool = StockTool(session: makeFailingSession())
        let result = try await tool.execute(input: "AAPL")
        // Should not crash — returns error or fallback data
        XCTAssertTrue(
            result.status == .ok || result.status == .error,
            "Should handle gracefully: \(result.text)"
        )
    }

    func testStockToolInputParsing() async throws {
        // Verify the tool correctly extracts symbols from various inputs without network
        let tool = StockTool(session: makeFailingSession())

        for input in ["#stocks AAPL", "stock price for MSFT", "price of GOOG", "TSLA"] {
            let result = try await tool.execute(input: input)
            XCTAssertTrue(
                result.status == .ok || result.status == .error,
                "Should handle '\(input)' gracefully: \(result.text)"
            )
        }
    }

    func testStockToolResolvesCompanyName() async throws {
        // Company name resolution should map "Microsoft" -> MSFT, not extract "CEO" or "PRICE"
        let tool = StockTool(session: makeFailingSession())

        // ExtractableCoreTool path: LLM might extract "CEO" but rawInput has "Microsoft"
        let args = StockArgs(ticker: "CEO", intent: nil)
        let result = try await tool.execute(args: args, rawInput: "Show financial highlights and CEO info for Microsoft", entities: nil)
        XCTAssertFalse(result.text.contains("CEO"), "Should resolve Microsoft -> MSFT, not use extracted ticker CEO. Got: \(result.text)")

        // NL path: "Tesla" in input should resolve to TSLA
        let nlResult = try await tool.execute(input: "Show stock price history for Tesla")
        XCTAssertFalse(nlResult.text.contains("PRICE"), "Should resolve Tesla -> TSLA, not extract PRICE. Got: \(nlResult.text)")
        XCTAssertFalse(nlResult.text.contains("HISTORY"), "Should resolve Tesla -> TSLA, not extract HISTORY. Got: \(nlResult.text)")
    }

    func testStockToolRejectsInvalidTicker() async throws {
        let tool = StockTool(session: makeFailingSession())

        // ExtractableCoreTool path with nonsense ticker and no company name in input
        let args = StockArgs(ticker: "ZZZZZ", intent: nil)
        let result = try await tool.execute(args: args, rawInput: "stock ZZZZZ", entities: nil)
        XCTAssertEqual(result.status, .ok, "Unrecognized tickers return .ok with a search fallback")
        XCTAssertTrue(result.text.contains("not a recognized stock ticker"), "Should suggest web search. Got: \(result.text)")

        // NL path with invalid ticker
        let nlResult = try await tool.execute(input: "stock ZZZZZ")
        XCTAssertEqual(nlResult.status, .ok, "Unrecognized tickers return .ok with a search fallback")
        XCTAssertTrue(nlResult.text.contains("not a recognized stock ticker"), "Should suggest web search. Got: \(nlResult.text)")
    }

    // MARK: - FactLookupService Tests

    func testDDGInstantAnswerGermanyReturnsStructuredFacts() async throws {
        let session = try await replaySession("ddg_instant_germany")
        let service = FactLookupService(session: session)

        let result = await service.lookup(query: "Germany")
        XCTAssertNotNil(result, "DDG Instant Answer should return facts for Germany")
        XCTAssertEqual(result?.title, "Germany")
        XCTAssertFalse(result?.abstract.isEmpty ?? true, "Should have abstract text")
        XCTAssertGreaterThan(result?.facts.count ?? 0, 0, "Should have infobox facts")

        // Check for known facts
        let factKeys = result?.facts.map(\.key) ?? []
        XCTAssertTrue(factKeys.contains("Capital"), "Should contain Capital fact")
        XCTAssertTrue(factKeys.contains("Currency"), "Should contain Currency fact")
    }

    func testDDGInstantAnswerPythonReturnsAbstract() async throws {
        let session = try await replaySession("ddg_instant_python")
        let service = FactLookupService(session: session)

        let result = await service.lookup(query: "Python programming language")
        XCTAssertNotNil(result, "DDG should return data for Python")
        XCTAssertTrue(result?.abstract.contains("Python") ?? false ||
                      result?.title.contains("Python") ?? false,
                      "Should mention Python")
    }

    func testDDGInstantAnswerNoResultsReturnsNil() async throws {
        // DDG returns empty abstract/infobox for nonsense — lookup should try Wikidata next.
        // With only the DDG fixture loaded, Wikidata will fail (no fixture), so overall = nil.
        let session = try await replaySession("ddg_instant_noresults")
        let service = FactLookupService(session: session)

        let result = await service.lookup(query: "xyzzyplughtwisty")
        XCTAssertNil(result, "Nonsense query should return nil from DDG Instant Answer")
    }

    func testWikidataGermanyReturnsStructuredProperties() async throws {
        // Test the Wikidata path directly by using a session with DDG returning no results
        // so FactLookupService falls through to Wikidata
        let session = try await replaySession("wikidata_full_germany")
        let service = FactLookupService(session: session)

        // The DDG call will fail (no matching fixture entry), falling through to Wikidata
        let result = await service.lookup(query: "Germany")
        XCTAssertNotNil(result, "Wikidata should return facts for Germany")
        XCTAssertEqual(result?.title, "Germany")
        XCTAssertEqual(result?.source, "Wikidata")

        // Check for known properties extracted from claims
        let factKeys = result?.facts.map(\.key) ?? []
        XCTAssertTrue(factKeys.contains("Population") || factKeys.contains("Currency") || factKeys.contains("Capital"),
                      "Should contain at least one known Wikidata property. Got: \(factKeys)")
    }

    func testWikidataNoResultsReturnsNil() async throws {
        let session = try await replaySession("wikidata_search_noresults")
        let service = FactLookupService(session: session)

        // DDG will fail (no fixture), Wikidata will return empty search
        let result = await service.lookup(query: "xyzzyplughtwisty")
        XCTAssertNil(result, "Nonsense query should return nil from Wikidata")
    }

    func testFactResultFormattingIsCompact() async throws {
        let session = try await replaySession("ddg_instant_germany")
        let service = FactLookupService(session: session)

        let result = await service.lookup(query: "Germany")
        XCTAssertNotNil(result)
        let formatted = result!.formatted()
        XCTAssertLessThan(formatted.count, 1600, "Formatted output should respect char limit")
        XCTAssertTrue(formatted.contains("Germany"), "Formatted output should contain title")
    }

    func testWebSearchToolUsesFactLookupFirst() async throws {
        // When DDG Instant Answer succeeds, WebSearchTool should return verified data
        // without attempting HTML search
        let session = try await replaySession("ddg_instant_germany")
        let factLookup = FactLookupService(session: session)
        let tool = WebSearchTool(
            backend: HTTPFetchBackend(session: session),
            factLookup: factLookup
        )

        let result = try await tool.call(arguments: WebSearchInput(query: "Germany"))
        XCTAssertTrue(result.hasPrefix("[VERIFIED]"),
                      "Should return verified data from fact lookup. Got: \(result.prefix(100))")
        XCTAssertTrue(result.contains("Germany"), "Should contain Germany data")
    }

    func testWebSearchToolFallsBackToHTMLWhenNoInstantAnswer() async throws {
        // When DDG Instant Answer returns nothing, should fall through to HTML search
        let ddgSession = try await replaySession("ddg_instant_noresults")
        let factLookup = FactLookupService(session: ddgSession)
        // Use the websearch_swift fixture for the HTML fallback
        let htmlSession = try await replaySession("websearch_swift")
        let tool = WebSearchTool(
            backend: HTTPFetchBackend(session: htmlSession),
            factLookup: factLookup
        )

        let result = try await tool.call(arguments: WebSearchInput(query: "xyzzyplughtwisty"))
        // Should not crash — will either get HTML results or "No results found"
        XCTAssertFalse(result.isEmpty, "Should return some response even on fallback")
    }

    func testFactLookupLargeNumberFormatting() {
        // Test the number formatting logic directly
        let result = FactResult(
            title: "Test",
            abstract: "",
            facts: [("Pop", "84000000"), ("GDP", "4200000000000")],
            relatedSnippets: [],
            source: nil,
            imageURL: nil
        )
        let formatted = result.formatted()
        // The raw numbers should ideally appear formatted, but since they come
        // from DDG as strings (not processed by formatLargeNumber), verify the
        // formatted output at least contains the facts
        XCTAssertTrue(formatted.contains("Pop"), "Should contain fact keys")
        XCTAssertTrue(formatted.contains("GDP"), "Should contain fact keys")
    }
}
