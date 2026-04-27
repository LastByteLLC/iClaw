/// Run this script to record/update HAR fixtures for network-dependent tool tests.
/// Usage: swift test --filter iClawTests.FixtureRecorder
///
/// Set REPLAY_RECORD_MODE=rewrite to re-record all fixtures.
/// Fixtures are saved to Tests/iClawTests/Fixtures/*.har

import XCTest
import Replay
@testable import iClawCore

/// Records HAR fixtures from live network requests for deterministic test replay.
final class FixtureRecorder: XCTestCase {

    private static let fixturesDir: URL = {
        // Navigate from the test bundle to the fixtures directory in the source tree
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        return url
    }()

    private func harURL(_ name: String) -> URL {
        Self.fixturesDir.appendingPathComponent("\(name).har")
    }

    /// Record weather API fixture (Open-Meteo, London coordinates)
    func testRecordWeatherFixture() async throws {
        let harFile = harURL("weather_london")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        // London coordinates
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=51.5074&longitude=-0.1278&current=temperature_2m,weather_code&wind_speed_unit=ms&timezone=auto")!
        let (data, response) = try await session.data(from: url)
        let httpResponse = response as! HTTPURLResponse

        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertGreaterThan(data.count, 0)
        print("[Fixture] Weather London: \(data.count) bytes, status \(httpResponse.statusCode)")
    }

    /// Record weather API fixture (Tokyo)
    func testRecordWeatherTokyoFixture() async throws {
        let harFile = harURL("weather_tokyo")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=35.6762&longitude=139.6503&current=temperature_2m,weather_code&wind_speed_unit=ms&timezone=auto")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Weather Tokyo: \(data.count) bytes")
    }

    /// Record currency conversion fixture (USD to EUR)
    func testRecordCurrencyFixture() async throws {
        let harFile = harURL("currency_usd")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Currency USD: \(data.count) bytes")
    }

    /// Record currency conversion fixture (BTC)
    func testRecordCryptoCurrencyFixture() async throws {
        let harFile = harURL("currency_btc")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/btc.json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Currency BTC: \(data.count) bytes")
    }

    /// Record podcast search fixture (iTunes API)
    /// Uses the same URL encoding as PodcastTool (percent-encoding, not +)
    func testRecordPodcastSearchFixture() async throws {
        let harFile = harURL("podcast_search_daily")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        // Match PodcastTool's encoding: addingPercentEncoding produces %20 not +
        let encoded = "the daily".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "the%20daily"
        let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=podcast&limit=20")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Podcast search: \(data.count) bytes")
    }

    /// Record podcast episode search fixture
    func testRecordPodcastEpisodeFixture() async throws {
        let harFile = harURL("podcast_episodes_daily")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "the daily".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "the%20daily"
        let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=podcastEpisode&limit=5")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Podcast episodes: \(data.count) bytes")
    }

    /// Record a web page fetch fixture (uses browser UA for realistic response)
    func testRecordWebFetchFixture() async throws {
        let harFile = harURL("webfetch_example")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://example.com")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] WebFetch example.com: \(data.count) bytes")
    }

    // MARK: - Wikipedia Fixtures

    /// Record Wikipedia opensearch fixture (search step)
    func testRecordWikipediaSearchFixture() async throws {
        let harFile = harURL("wikipedia_search_einstein")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "Albert Einstein".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(encoded)&limit=1&format=json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Wikipedia search Einstein: \(data.count) bytes")
    }

    /// Record Wikipedia article extract fixture
    func testRecordWikipediaExtractFixture() async throws {
        let harFile = harURL("wikipedia_extract_einstein")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let titleEncoded = "Albert Einstein".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&exintro=1&titles=\(titleEncoded)&format=json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Wikipedia extract Einstein: \(data.count) bytes")
    }

    /// Record Wikipedia search for a topic with no results
    func testRecordWikipediaSearchNoResultsFixture() async throws {
        let harFile = harURL("wikipedia_search_noresults")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "xyzzyplughtwisty".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(encoded)&limit=1&format=json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Wikipedia no results: \(data.count) bytes")
    }

    // MARK: - News Fixtures

    /// Record news API fixture (all stories)
    func testRecordNewsAllFixture() async throws {
        let harFile = harURL("news_all")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://actually-relevant-api.onrender.com/api/stories")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] News all: \(data.count) bytes")
    }

    /// Record news API fixture (science-technology category)
    func testRecordNewsSciTechFixture() async throws {
        let harFile = harURL("news_scitech")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://actually-relevant-api.onrender.com/api/stories?slug=science-technology")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] News sci-tech: \(data.count) bytes")
    }

    // MARK: - WebSearch Fixtures

    /// Record Google search fixture (uses browser UA for proper HTML response)
    func testRecordWebSearchFixture() async throws {
        let harFile = harURL("websearch_swift")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "Swift programming language".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://www.google.com/search?q=\(encoded)")!
        var request = URLRequest(url: url)
        // Browser UA gets full HTML with search results (not JS-only response)
        request.addValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.addValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.addValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        // Google may return 200 or 429; record whatever we get
        XCTAssertTrue([200, 429].contains(status), "Unexpected status: \(status)")
        print("[Fixture] WebSearch Swift: \(data.count) bytes, status \(status)")
    }

    // MARK: - Stock Fixtures

    /// Record Yahoo Finance crumb fixture
    func testRecordStockCrumbFixture() async throws {
        let harFile = harURL("stock_crumb")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        // Step 1: yahoo.com for cookies
        let initialURL = URL(string: "https://www.yahoo.com/")!
        var req1 = URLRequest(url: initialURL)
        req1.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req1.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data1, _) = try await session.data(for: req1)
        print("[Fixture] Stock yahoo.com: \(data1.count) bytes")

        // Step 2: crumb
        let crumbURL = URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!
        var req2 = URLRequest(url: crumbURL)
        req2.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data2, response2) = try await session.data(for: req2)
        let status = (response2 as! HTTPURLResponse).statusCode
        print("[Fixture] Stock crumb: \(data2.count) bytes, status \(status)")
    }

    /// Record Yahoo Finance quote fixture for AAPL
    func testRecordStockQuoteFixture() async throws {
        let harFile = harURL("stock_quote_aapl")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://query2.finance.yahoo.com/v11/finance/quoteSummary/?symbols=AAPL&modules=price,summaryDetail,defaultKeyStatistics&crumb=test")!
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        print("[Fixture] Stock quote AAPL: \(data.count) bytes, status \(status)")
    }

    /// Record Yahoo Finance quoteType fixture for AAPL
    func testRecordStockQuoteTypeFixture() async throws {
        let harFile = harURL("stock_quotetype_aapl")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/quoteType/AAPL?formatted=true&enablePrivateCompany=true&overnightPrice=true&lang=en-US&region=US")!
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        print("[Fixture] Stock quoteType AAPL: \(data.count) bytes, status \(status)")
    }

    /// Record Yahoo Finance recommendations fixture for AAPL
    func testRecordStockRecommendationsFixture() async throws {
        let harFile = harURL("stock_recommendations_aapl")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://query1.finance.yahoo.com/v6/finance/recommendationsbysymbol/AAPL?fields=&lang=en-US&region=US")!
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as! HTTPURLResponse).statusCode
        print("[Fixture] Stock recommendations AAPL: \(data.count) bytes, status \(status)")
    }

    /// Record a real article fetch fixture (uses browser UA for realistic response)
    func testRecordWebFetchArticleFixture() async throws {
        let harFile = harURL("webfetch_article")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://blog.rust-lang.org/")!
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await session.data(for: request)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] WebFetch article: \(data.count) bytes")
    }

    // MARK: - DDG Instant Answer Fixtures

    /// Record DuckDuckGo Instant Answer API fixture (Germany — rich infobox)
    func testRecordDDGInstantAnswerGermany() async throws {
        let harFile = harURL("ddg_instant_germany")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "Germany".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] DDG Instant Answer Germany: \(data.count) bytes")
    }

    /// Record DuckDuckGo Instant Answer API fixture (Python — well-known topic)
    func testRecordDDGInstantAnswerPython() async throws {
        let harFile = harURL("ddg_instant_python")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "Python programming language".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] DDG Instant Answer Python: \(data.count) bytes")
    }

    /// Record DuckDuckGo Instant Answer API fixture (nonsense query — no results)
    func testRecordDDGInstantAnswerNoResults() async throws {
        let harFile = harURL("ddg_instant_noresults")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "xyzzyplughtwisty".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] DDG Instant Answer no results: \(data.count) bytes")
    }

    // MARK: - Wikidata Fixtures

    /// Record Wikidata entity search fixture (Germany)
    func testRecordWikidataSearchGermany() async throws {
        let harFile = harURL("wikidata_search_germany")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "Germany".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=\(encoded)&language=en&limit=1&format=json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Wikidata search Germany: \(data.count) bytes")
    }

    /// Record Wikidata entity claims fixture (Germany — Q183)
    func testRecordWikidataClaimsGermany() async throws {
        let harFile = harURL("wikidata_claims_germany")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=Q183&props=claims&format=json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Wikidata claims Germany: \(data.count) bytes")
    }

    /// Record Wikidata search for nonsense (no results)
    func testRecordWikidataSearchNoResults() async throws {
        let harFile = harURL("wikidata_search_noresults")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "xyzzyplughtwisty".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbsearchentities&search=\(encoded)&language=en&limit=1&format=json")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] Wikidata search no results: \(data.count) bytes")
    }

    /// Record DDG Instant Answer for Tesla (company entity with infobox)
    func testRecordDDGInstantAnswerTesla() async throws {
        let harFile = harURL("ddg_instant_tesla")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once
        )
        let session = try await Playback.session(configuration: config)

        let encoded = "Tesla Inc".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1")!
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as! HTTPURLResponse).statusCode, 200)
        print("[Fixture] DDG Instant Answer Tesla: \(data.count) bytes")
    }

    // MARK: - Feedback API Fixtures

    /// Record feedback submission (success case)
    func testRecordFeedbackFixture() async throws {
        let harFile = harURL("feedback_submit")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once,
            matchers: [.method, .host, .path]
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "\(AppConfig.apiBaseURL)\(AppConfig.feedbackEndpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "message": "Test feedback from fixture recorder",
            "category": "general",
            "app_version": "1.0"
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        print("[Fixture] Feedback submit: \(data.count) bytes, status \(http.statusCode)")
    }

    // MARK: - Crash Log API Fixtures

    /// Record crash log submission (success case)
    func testRecordCrashLogFixture() async throws {
        let harFile = harURL("crashlog_submit")
        let config = PlaybackConfiguration(
            source: .file(harFile),
            playbackMode: .passthrough,
            recordMode: .once,
            matchers: [.method, .host, .path]
        )
        let session = try await Playback.session(configuration: config)

        let url = URL(string: "\(AppConfig.apiBaseURL)\(AppConfig.crashLogEndpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "report": "Test crash from fixture recorder\nThread 0: test backtrace",
            "app_version": "1.0",
            "os_version": "macOS 26.0",
            "device": "Mac15,3"
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        print("[Fixture] Crash log submit: \(data.count) bytes, status \(http.statusCode)")
    }
}
