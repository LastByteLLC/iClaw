import XCTest
@testable import iClawCore

final class TickerLookupTests: XCTestCase {

    // MARK: - Basic Lookup

    func testLookupKnownSymbol() {
        let result = TickerLookup.lookup(symbol: "AAPL")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.symbol, "AAPL")
        XCTAssertTrue(result!.name.contains("Apple"))
    }

    func testLookupCaseInsensitive() {
        let result = TickerLookup.lookup(symbol: "aapl")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.symbol, "AAPL")
    }

    func testLookupUnknownSymbol() {
        let result = TickerLookup.lookup(symbol: "ZZZZZ")
        XCTAssertNil(result)
    }

    // MARK: - Prefix Search

    func testSearchSingleLetter() {
        let results = TickerLookup.search(prefix: "A")
        XCTAssertFalse(results.isEmpty, "Should find tickers starting with A")
        XCTAssertLessThanOrEqual(results.count, 8, "Should return at most 8 results")
        for entry in results {
            XCTAssertTrue(entry.symbol.hasPrefix("A"), "All results should start with A, got \(entry.symbol)")
        }
    }

    func testSearchMultiLetter() {
        let results = TickerLookup.search(prefix: "MS")
        XCTAssertFalse(results.isEmpty)
        for entry in results {
            XCTAssertTrue(entry.symbol.hasPrefix("MS"), "Expected MS prefix, got \(entry.symbol)")
        }
    }

    func testSearchCaseInsensitive() {
        let upper = TickerLookup.search(prefix: "META")
        let lower = TickerLookup.search(prefix: "meta")
        XCTAssertEqual(upper.map(\.symbol), lower.map(\.symbol))
    }

    func testSearchReturnsMax8() {
        // "A" should have many matches but cap at 8
        let results = TickerLookup.search(prefix: "A")
        XCTAssertLessThanOrEqual(results.count, 8)
    }

    func testSearchEmptyPrefix() {
        // Empty prefix returns nothing (need at least 1 letter)
        let results = TickerLookup.search(prefix: "")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchNoMatch() {
        let results = TickerLookup.search(prefix: "ZZZZZ")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Data Quality

    func testNoNumericOnlySymbols() {
        for entry in TickerLookup.allTickers {
            let isNumericOnly = entry.symbol.allSatisfy { $0.isNumber || $0 == "." }
            XCTAssertFalse(isNumericOnly, "Found numeric-only symbol: \(entry.symbol)")
        }
    }

    func testNoDuplicateSymbols() {
        let symbols = TickerLookup.allTickers.map(\.symbol)
        let unique = Set(symbols)
        XCTAssertEqual(symbols.count, unique.count, "Found duplicate symbols")
    }

    func testAllTickersSorted() {
        let symbols = TickerLookup.allTickers.map(\.symbol)
        let sorted = symbols.sorted()
        XCTAssertEqual(symbols, sorted, "Tickers should be sorted alphabetically")
    }

    func testWellKnownTickersPresent() {
        let mustHave = ["AAPL", "MSFT", "GOOGL", "AMZN", "META", "NVDA", "TSLA", "JPM", "V", "MA",
                        "TSM", "ASML", "NVO", "SAP", "SHEL", "BHP", "BABA"]
        for symbol in mustHave {
            XCTAssertNotNil(TickerLookup.lookup(symbol: symbol), "Missing well-known ticker: \(symbol)")
        }
    }

    func testMinimumTickerCount() {
        XCTAssertGreaterThan(TickerLookup.allTickers.count, 500, "Should have at least 500 tickers")
    }

    // MARK: - InputParsingUtilities Integration

    func testExtractTickerSymbols() {
        let symbols = InputParsingUtilities.extractTickerSymbols(from: "Check $META and $AAPL prices")
        XCTAssertEqual(symbols, ["META", "AAPL"])
    }

    func testExtractTickerSymbolsSingle() {
        let symbols = InputParsingUtilities.extractTickerSymbols(from: "$TSLA")
        XCTAssertEqual(symbols, ["TSLA"])
    }

    func testExtractTickerSymbolsNone() {
        let symbols = InputParsingUtilities.extractTickerSymbols(from: "What's the weather?")
        XCTAssertTrue(symbols.isEmpty)
    }

    func testExtractTickerIgnoresDollarAmounts() {
        // "$50" should not be treated as a ticker (max 5 alpha chars)
        let symbols = InputParsingUtilities.extractTickerSymbols(from: "I have $50")
        XCTAssertTrue(symbols.isEmpty, "Dollar amounts should not match as tickers")
    }

    func testStripTickerSymbols() {
        let result = InputParsingUtilities.stripTickerSymbols(from: "$META stock price")
        XCTAssertEqual(result, "META stock price")
    }

    func testStripTickerSymbolsMultiple() {
        let result = InputParsingUtilities.stripTickerSymbols(from: "Compare $AAPL and $MSFT")
        XCTAssertEqual(result, "Compare AAPL and MSFT")
    }
}

// MARK: - Ticker Routing E2E

final class TickerRoutingE2ETests: XCTestCase {

    override func setUp() async throws { await ScratchpadCache.shared.reset() }

    func testDollarSymbolRoutesToStockTool() async throws {
        let spy = SpyTool(
            name: "Stocks",
            schema: "Stock quotes",
            result: ToolIO(text: "META $500", status: .ok, outputWidget: "StockWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "$META")
        XCTAssertEqual(spy.invocations.count, 1, "StockTool should be called for $META")
        XCTAssertTrue(spy.invocations.first!.input.contains("META"), "Input should contain META")
        XCTAssertFalse(spy.invocations.first!.input.contains("$"), "Dollar sign should be stripped")
    }

    func testDollarSymbolWithTextRoutesToStockTool() async throws {
        let spy = SpyTool(
            name: "Stocks",
            schema: "Stock quotes",
            result: ToolIO(text: "AAPL $150", status: .ok, outputWidget: "StockWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "What's $AAPL trading at?")
        XCTAssertEqual(spy.invocations.count, 1, "StockTool should be called for $AAPL in sentence")
    }

    func testHashStocksChipStillWorks() async throws {
        let spy = SpyTool(
            name: "Stocks",
            schema: "Stock quotes",
            result: ToolIO(text: "NVDA $800", status: .ok, outputWidget: "StockWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#stocks NVDA")
        XCTAssertEqual(spy.invocations.count, 1, "#stocks chip should still work")
    }

    func testUnknownTickerDoesNotRoute() async throws {
        let spy = SpyTool(
            name: "Stocks",
            schema: "Stock quotes",
            result: ToolIO(text: "result", status: .ok)
        )
        let engine = makeTestEngine(tools: [spy])

        // ZZZZZ is not in TickerLookup, should not auto-route to stocks
        _ = await engine.run(input: "$ZZZZZ")
        XCTAssertEqual(spy.invocations.count, 0, "Unknown ticker should not route to StockTool")
    }

    func testMultipleTickerPrompts() async throws {
        let prompts = [
            "$TSLA",
            "$GOOGL price",
            "show me $AMZN",
            "$MSFT stock",
            "$JPM quote",
        ]

        for prompt in prompts {
            let spy = SpyTool(
                name: "Stocks",
                schema: "Stock quotes",
                result: ToolIO(text: "result", status: .ok, outputWidget: "StockWidget")
            )
            let engine = makeTestEngine(tools: [spy])
            _ = await engine.run(input: prompt)
            XCTAssertEqual(spy.invocations.count, 1, "'\(prompt)' should route to StockTool")
        }
    }

    func testTickerDoesNotConflictWithToolChips() async throws {
        // #weather should route to weather, not stocks, even if $ appears elsewhere
        let weatherSpy = SpyTool(name: "Weather", schema: "Weather forecasts")
        let stockSpy = SpyTool(name: "Stocks", schema: "Stock quotes")
        let engine = makeTestEngine(tools: [weatherSpy, stockSpy])

        _ = await engine.run(input: "#weather London")
        XCTAssertEqual(weatherSpy.invocations.count, 1, "#weather should route to WeatherTool")
        XCTAssertEqual(stockSpy.invocations.count, 0, "StockTool should not be called")
    }

    func testStockWidgetOutput() async throws {
        let widgetData = StockWidgetData(
            symbol: "META", name: "Meta Platforms", currentPrice: 500.0,
            changeAmount: 5.0, changePercent: 1.0, recommendations: ["AAPL"]
        )
        let spy = SpyTool(
            name: "Stocks",
            schema: "Stock quotes",
            result: ToolIO(text: "META $500", status: .ok, outputWidget: "StockWidget", widgetData: widgetData)
        )
        let engine = makeTestEngine(tools: [spy])

        let result = await engine.run(input: "$META")
        XCTAssertEqual(result.widgetType, "StockWidget")
    }
}
