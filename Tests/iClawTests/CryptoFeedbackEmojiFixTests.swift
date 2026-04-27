import XCTest
@testable import iClawCore

// MARK: - Group 1: CryptoSymbolSet Validation

final class CryptoSymbolSanitizationTests: XCTestCase {

    func testSymbolSetLoadsFromJSON() {
        let symbols = CryptoSymbolSet.symbols
        XCTAssertFalse(symbols.isEmpty, "CryptoSymbolSet should load symbols from JSON")
        for expected in ["BTC", "ETH", "DOGE", "SOL", "XRP"] {
            XCTAssertTrue(symbols.contains(expected), "Missing expected symbol: \(expected)")
        }
    }

    func testRemovedEnglishWordsNotPresent() {
        let symbols = CryptoSymbolSet.symbols
        let removed = [
            "W", "NOT", "HOT", "HIGH", "SAFE", "PEOPLE", "MAGIC", "ACE",
            "PRIME", "SAND", "RUNE", "MANA", "FLOW", "NEAR", "MASK",
            "DOGS", "WAVES", "MEME", "ALT", "PIXEL"
        ]
        for word in removed {
            XCTAssertFalse(symbols.contains(word), "\(word) should have been removed (English word)")
        }
    }

    func testNoSingleOrTwoCharSymbols() {
        let short = CryptoSymbolSet.symbols.filter { $0.count <= 2 }
        XCTAssertTrue(short.isEmpty, "Found short symbols that should be removed: \(short)")
    }

    func testApproximateCount() {
        let count = CryptoSymbolSet.symbols.count
        XCTAssertGreaterThan(count, 120, "Too few symbols — check for accidental mass deletion")
        XCTAssertLessThan(count, 150, "Too many symbols — check for accidental re-addition of English words")
    }

    func testAllSymbolsUppercased() {
        for symbol in CryptoSymbolSet.symbols {
            // Skip symbols starting with digits (e.g. "1INCH")
            guard symbol.first?.isLetter == true else { continue }
            XCTAssertEqual(symbol, symbol.uppercased(), "\(symbol) should be uppercased")
        }
    }

    func testFallbackSymbolsAreSubset() {
        let fallback: Set<String> = ["BTC", "ETH", "DOGE", "SOL", "XRP", "AVAX", "SHIB", "LTC", "LINK"]
        let symbols = CryptoSymbolSet.symbols
        for s in fallback {
            XCTAssertTrue(symbols.contains(s), "Fallback symbol \(s) missing from loaded set")
        }
    }
}

// MARK: - Group 2: Crypto Routing (Stocks → Convert Override)

final class CryptoRoutingTests: XCTestCase {

    private func makeRouter() -> (stocks: SpyTool, convert: SpyTool, router: ToolRouter) {
        let stocks = SpyTool(name: "Stocks", schema: "stock prices ticker market cap")
        let convert = SpyTool(name: "Convert", schema: "convert currency crypto exchange rate")
        let router = ToolRouter(
            availableTools: [stocks, convert],
            llmResponder: makeStubRouterLLMResponder(toolName: "Stocks")
        )
        return (stocks, convert, router)
    }

    private func assertRoutesToConvert(_ input: String, file: StaticString = #filePath, line: UInt = #line) async {
        let (_, _, router) = makeRouter()
        let result = await router.route(input: input)
        if case .tools(let tools) = result {
            XCTAssertEqual(tools.first?.name, "Convert", "Expected Convert for: \(input)", file: file, line: line)
        } else {
            XCTFail("Expected .tools result for: \(input)", file: file, line: line)
        }
    }

    private func assertStaysStocks(_ input: String, file: StaticString = #filePath, line: UInt = #line) async {
        let (_, _, router) = makeRouter()
        let result = await router.route(input: input)
        if case .tools(let tools) = result {
            XCTAssertEqual(tools.first?.name, "Stocks", "Expected Stocks for: \(input)", file: file, line: line)
        } else {
            XCTFail("Expected .tools result for: \(input)", file: file, line: line)
        }
    }

    // Happy path: crypto symbols override to Convert

    func testBTCRoutesToConvert() async { await assertRoutesToConvert("What is the BTC stock price?") }
    func testETHRoutesToConvert() async { await assertRoutesToConvert("How much is ETH stock worth today?") }
    func testDOGERoutesToConvert() async { await assertRoutesToConvert("DOGE stock price today please") }
    func testSOLRoutesToConvert() async { await assertRoutesToConvert("Show me the SOL stock price") }
    func testAVAXRoutesToConvert() async { await assertRoutesToConvert("What is the current AVAX stock price?") }
    func testCryptoMidSentence() async { await assertRoutesToConvert("I want to check the ETH stock market today") }
    func testCryptoWithPunctuation() async { await assertRoutesToConvert("What's the BTC stock price worth?") }

    // Negative: removed English words should NOT trigger override

    func testHOTStaysStocks() async { await assertStaysStocks("HOT stocks market price today") }
    func testSAFEStaysStocks() async { await assertStaysStocks("Is SAFE a good stock to buy?") }
    func testMAGICStaysStocks() async { await assertStaysStocks("What is the MAGIC stock price?") }
    func testPRIMEStaysStocks() async { await assertStaysStocks("Show me the PRIME stock price") }
    func testSingleLetterWStaysStocks() async { await assertStaysStocks("What is the W stock price?") }

    // Edge cases

    func testNoCryptoStaysStocks() async { await assertStaysStocks("What is the Apple stock price?") }
    func testBITCOINNotInSymbolList() async { await assertStaysStocks("What is the BITCOIN stock price today?") }
}

// MARK: - Group 3: SkillWidgetParser Crypto Detection (Substring Fix)

final class SkillWidgetParserCryptoTests: XCTestCase {

    func testCryptoWidgetFromBTC() {
        let result = SkillWidgetParser.buildWidget(
            skillName: nil, toolNames: ["Convert"],
            ingredients: ["1 BTC = 87432.15 USD"], responseText: ""
        )
        XCTAssertEqual(result?.type, "CryptoWidget")
    }

    func testCryptoWidgetFromETH() {
        let result = SkillWidgetParser.buildWidget(
            skillName: nil, toolNames: ["Convert"],
            ingredients: ["1 ETH = 3200.50 USD"], responseText: ""
        )
        XCTAssertEqual(result?.type, "CryptoWidget")
    }

    func testSubstringFETCHDoesNotMatchFET() {
        let result = SkillWidgetParser.buildWidget(
            skillName: nil, toolNames: ["Convert"],
            ingredients: ["The FETCH protocol is interesting"], responseText: ""
        )
        XCTAssertNil(result, "FETCH should not match FET via substring")
    }

    func testSubstringLINKEDDoesNotMatchLINK() {
        let result = SkillWidgetParser.buildWidget(
            skillName: nil, toolNames: ["Convert"],
            ingredients: ["LINKED resources are available"], responseText: ""
        )
        XCTAssertNil(result, "LINKED should not match LINK via substring")
    }

    func testNonCryptoIngredients() {
        let result = SkillWidgetParser.buildWidget(
            skillName: nil, toolNames: ["Convert"],
            ingredients: ["Convert 100 USD to EUR"], responseText: ""
        )
        XCTAssertNil(result, "Plain currency conversion should not trigger crypto widget")
    }

    func testTokenSplitOnSpecialChars() {
        let result = SkillWidgetParser.buildWidget(
            skillName: nil, toolNames: ["Convert"],
            ingredients: ["Price: SOL=150.00 USD"], responseText: ""
        )
        XCTAssertEqual(result?.type, "CryptoWidget", "SOL should be extracted as a token despite adjacent punctuation")
    }

    func testOnlyConvertToolTriggers() {
        let result = SkillWidgetParser.buildWidget(
            skillName: nil, toolNames: ["WebFetch"],
            ingredients: ["1 BTC = 87000 USD"], responseText: ""
        )
        XCTAssertNil(result, "Non-Convert tools should not trigger crypto widget detection")
    }

    func testSkillNameOverrideStillWorks() {
        let result = SkillWidgetParser.buildWidget(
            skillName: "Crypto Price", toolNames: [],
            ingredients: ["1 BTC = 87000 USD"], responseText: ""
        )
        XCTAssertEqual(result?.type, "CryptoWidget")
    }
}

// MARK: - Group 4: FeedbackTool

final class FeedbackToolTests: XCTestCase {

    func testEmptyInputReturnsOKNotError() async throws {
        let tool = FeedbackTool()
        let result = try await tool.execute(input: "", entities: nil)
        XCTAssertEqual(result.status, .ok, "Empty input should return .ok, not .error")
        XCTAssertTrue(result.text.lowercased().contains("what's on your mind"),
                      "Should return a conversational prompt")
    }

    func testWhitespaceOnlyReturnsOK() async throws {
        let tool = FeedbackTool()
        let result = try await tool.execute(input: "   \n\t  ", entities: nil)
        XCTAssertEqual(result.status, .ok)
    }

    func testValidFeedbackReturnsWidget() async throws {
        let tool = FeedbackTool()
        let result = try await tool.execute(input: "The answer was wrong", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "FeedbackWidget")
        XCTAssertNotNil(result.widgetData as? FeedbackWidgetData)
    }

    func testChainPrefixParsed() async throws {
        let tool = FeedbackTool()
        let input = """
        [Feedback on: "hi"→"hello"] The tone was off
        """
        let result = try await tool.execute(input: input, entities: nil)
        let widgetData = result.widgetData as? FeedbackWidgetData
        XCTAssertNotNil(widgetData)
        XCTAssertTrue(widgetData?.summary.contains("Context:") == true)
        XCTAssertTrue(widgetData?.summary.contains("The tone was off") == true)
    }

    func testDefaultSuggestionsWhenNoLLM() async throws {
        let tool = FeedbackTool(llmResponder: { _, _ in "suggestion1\nsuggestion2\nsuggestion3" })
        let result = try await tool.execute(input: "Bad answer", entities: nil)
        let widgetData = result.widgetData as? FeedbackWidgetData
        XCTAssertEqual(widgetData?.suggestedQuestions.count, 3)
        for q in widgetData?.suggestedQuestions ?? [] {
            XCTAssertFalse(q.isEmpty, "Suggestions should not be empty strings")
        }
    }

    func testIsPositivePropertyRemoved() {
        let data = FeedbackWidgetData(phase: .review, summary: "test")
        let mirror = Mirror(reflecting: data)
        let labels = mirror.children.compactMap(\.label)
        XCTAssertFalse(labels.contains("isPositive"),
                       "isPositive was removed — FeedbackWidgetData should not have this property")
    }
}

// MARK: - Group 5: Emoji Widget Parser

final class EmojiWidgetParserTests: XCTestCase {

    private func parseEmoji(_ text: String) -> EmojiWidgetData? {
        guard let result = SkillWidgetParser.buildWidget(
            skillName: "Emoji", toolNames: [], ingredients: [], responseText: text
        ) else { return nil }
        return result.data as? EmojiWidgetData
    }

    func testRelatedEmojiHaveNonEmptyNames() {
        let data = parseEmoji("The Fire emoji 🔥 is popular. Related: 💥 🌋 ☀️")
        XCTAssertNotNil(data)
        XCTAssertFalse(data!.relatedEmoji.isEmpty, "Should have related emoji")
        for related in data!.relatedEmoji {
            XCTAssertFalse(related.name.isEmpty,
                           "Related emoji \(related.emoji) should have a non-empty Unicode name")
        }
    }

    func testMainEmojiExtracted() {
        let data = parseEmoji("🎉 Party Popper emoji is festive")
        XCTAssertEqual(data?.emoji, "🎉")
    }

    func testRelatedCappedAtThree() {
        let data = parseEmoji("🔥 Fire emoji. 💥 🌋 ☀️ 🌊 🪨")
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data!.relatedEmoji.count, 3)
    }

    func testNoRelatedWhenOnlyMain() {
        let data = parseEmoji("The 🎯 Target emoji")
        XCTAssertNotNil(data)
        XCTAssertTrue(data!.relatedEmoji.isEmpty)
    }

    func testMainExcludedFromRelated() {
        let data = parseEmoji("🔥 Fire 🔥 is great. Also: 💥")
        XCTAssertNotNil(data)
        let relatedEmojis = data!.relatedEmoji.map(\.emoji)
        XCTAssertFalse(relatedEmojis.contains("🔥"), "Main emoji should be excluded from related")
    }

    func testNoEmojiReturnsNil() {
        let data = parseEmoji("No emoji here at all")
        XCTAssertNil(data)
    }

    func testEmojiNameFromPattern() {
        let data = parseEmoji("The Smiling Face emoji 😊 is widely used")
        XCTAssertNotNil(data)
        XCTAssertTrue(data!.name.contains("Smiling Face"),
                      "Expected name containing 'Smiling Face', got: \(data!.name)")
    }

    func testEmojiOnlyFallbackName() {
        let data = parseEmoji("🤷")
        XCTAssertNotNil(data)
        // With only an emoji and no descriptive text, falls back to "Emoji"
        XCTAssertFalse(data!.name.isEmpty)
    }
}

// MARK: - Group 6: Full Pipeline E2E

final class CodeReviewFixesPipelineTests: XCTestCase {

    func testCryptoQueryE2E() async throws {
        let stocksSpy = SpyTool(name: "Stocks", schema: "stock prices ticker market cap")
        let convertSpy = SpyTool(name: "Convert", schema: "convert currency crypto",
                                 result: ToolIO(text: "1 BTC = 87000 USD", status: .ok))
        let engine = makeTestEngine(
            tools: [stocksSpy, convertSpy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Stocks")
        )
        _ = await engine.run(input: "What is the BTC stock price?")
        XCTAssertEqual(convertSpy.invocations.count, 1, "Convert should be invoked via crypto override")
        XCTAssertEqual(stocksSpy.invocations.count, 0, "Stocks should NOT be invoked")
    }

    func testEnglishWordNoCryptoOverrideE2E() async {
        let stocksSpy = SpyTool(name: "Stocks", schema: "stock prices ticker market cap")
        let convertSpy = SpyTool(name: "Convert", schema: "convert currency crypto")
        let engine = makeTestEngine(
            tools: [stocksSpy, convertSpy],
            routerLLMResponder: makeStubRouterLLMResponder(toolName: "Stocks")
        )
        _ = await engine.run(input: "HOT stocks this week")
        XCTAssertEqual(stocksSpy.invocations.count, 1, "Stocks should be invoked (HOT is not a crypto symbol)")
        XCTAssertEqual(convertSpy.invocations.count, 0, "Convert should NOT be invoked")
    }

    func testFeedbackEmptyInputE2E() async {
        let feedbackTool = FeedbackTool()
        let engine = makeTestEngine(tools: [feedbackTool])
        let result = await engine.run(input: "#feedback")
        XCTAssertFalse(result.isError, "Empty feedback should not be an error")
    }

    @MainActor
    func testEmojiSkillWidgetE2E() async throws {
        let engine = await makeTestEngineWithSkills(
            tools: [],
            engineLLMResponder: makeStubLLMResponder(response: "The Crab emoji 🦀 is officially called Crab. Related: 🦞 🦐 🦑")
        )
        let result = await engine.run(input: "#emoji 🦀")
        XCTAssertEqual(result.widgetType, "EmojiWidget", "Should produce EmojiWidget")
        if let emojiData = result.widgetData as? EmojiWidgetData {
            XCTAssertFalse(emojiData.relatedEmoji.isEmpty, "Should have related emoji")
            for related in emojiData.relatedEmoji {
                XCTAssertFalse(related.name.isEmpty,
                               "Related emoji \(related.emoji) should have a populated name")
            }
        }
    }
}
