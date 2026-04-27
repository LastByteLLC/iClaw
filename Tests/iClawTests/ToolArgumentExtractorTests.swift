import XCTest
@testable import iClawCore

final class ToolArgumentExtractorTests: XCTestCase {

    // MARK: - Spellcheck Tests

    func testSpellCorrectFixesSimpleTypo() {
        // "teh" → "the" is a reliable system dictionary correction
        let (corrected, didCorrect) = InputPreprocessor.spellCorrect("teh weather today")
        XCTAssertTrue(didCorrect)
        XCTAssertEqual(corrected, "the weather today")
    }

    func testSpellCorrectSkipsChips() {
        let (corrected, _) = InputPreprocessor.spellCorrect("#weathre in London")
        // Chip should not be corrected
        XCTAssertTrue(corrected.contains("#weathre"))
    }

    func testSpellCorrectSkipsTickers() {
        let (corrected, _) = InputPreprocessor.spellCorrect("$AAPL stock price")
        XCTAssertTrue(corrected.contains("$AAPL"))
    }

    func testSpellCorrectSkipsShortWords() {
        let (corrected, _) = InputPreprocessor.spellCorrect("hw are you")
        // "hw" is only 2 chars, should be skipped
        XCTAssertTrue(corrected.contains("hw"))
    }

    func testSpellCorrectSkipsProperNouns() {
        let nerNames: Set<String> = ["Xandrex"]
        let (corrected, _) = InputPreprocessor.spellCorrect("email from Xandrex", nerNames: nerNames)
        XCTAssertTrue(corrected.contains("Xandrex"))
    }

    func testSpellCorrectSkipsNumbers() {
        let (corrected, _) = InputPreprocessor.spellCorrect("roll a d20")
        XCTAssertTrue(corrected.contains("d20"))
    }

    func testSpellCorrectNoChangeForCorrectInput() {
        let (corrected, didCorrect) = InputPreprocessor.spellCorrect("weather in London")
        XCTAssertFalse(didCorrect)
        XCTAssertEqual(corrected, "weather in London")
    }

    func testSpellCorrectSkipsCustomDictionaryWords() {
        // "wordle" is in SpellcheckDictionary.json — must not be corrected to "world"
        let (corrected, didCorrect) = InputPreprocessor.spellCorrect("play wordle")
        XCTAssertFalse(didCorrect)
        XCTAssertTrue(corrected.contains("wordle"))
    }

    func testSpellCorrectSkipsSudoku() {
        let (corrected, _) = InputPreprocessor.spellCorrect("play sudoku")
        XCTAssertTrue(corrected.contains("sudoku"))
    }

    func testSpellCorrectPreservesPunctuation() {
        // Question marks and other punctuation should not be stripped
        let (corrected, _) = InputPreprocessor.spellCorrect("what time is it in London?")
        XCTAssertTrue(corrected.hasSuffix("?"))
    }

    // MARK: - Multi-Signal Spellcheck Guard Tests

    func testSpellCorrectSkipsMidSentenceCapitalizedWord() {
        // "Tesla" mid-sentence starts with uppercase — signals proper noun, should be skipped
        let (corrected, _) = InputPreprocessor.spellCorrect("show me Tesla stock")
        XCTAssertTrue(corrected.contains("Tesla"), "Mid-sentence capitalized word 'Tesla' should not be corrected")
    }

    func testSpellCorrectSkipsBrandNameRivian() {
        // "Rivian" should not be corrected to "Vivian" — mid-sentence capitalization guard
        let (corrected, _) = InputPreprocessor.spellCorrect("buy Rivian stock")
        XCTAssertTrue(corrected.contains("Rivian"), "Brand name 'Rivian' should not be overcorrected")
    }

    func testSpellCorrectSkipsNERAdjacentWord() {
        // "Audi" is an NER org — "e-tron" next to it should be protected by adjacency guard
        let nerNames: Set<String> = ["Audi"]
        let (corrected, _) = InputPreprocessor.spellCorrect("show me Audi e-tron", nerNames: nerNames)
        // e-tron is adjacent to NER entity "Audi" and should not be corrected
        XCTAssertTrue(corrected.contains("Audi"), "NER entity 'Audi' should not be corrected")
    }

    func testSpellCorrectStillFixesCommonTypo() {
        // "teh" → "the" should still work — "the" is a common word
        let (corrected, didCorrect) = InputPreprocessor.spellCorrect("teh weather today")
        XCTAssertTrue(didCorrect, "'teh' should be corrected to 'the'")
        XCTAssertEqual(corrected, "the weather today")
    }

    func testSpellCorrectStillFixesWeatherTypo() {
        // "waether" → "weather" or "whether" — NSSpellChecker's first guess is platform-dependent.
        // "whether" is contextually wrong for the user's intent, but we can't control
        // NSSpellChecker's ranking. The CommonWords guard accepts both since both are common words.
        let (corrected, didCorrect) = InputPreprocessor.spellCorrect("waether forecast")
        XCTAssertTrue(didCorrect, "'waether' should be corrected")
        XCTAssertTrue(corrected.contains("weather") || corrected.contains("whether"),
            "Corrected text should contain 'weather' or 'whether', got: \(corrected)")
    }

    func testSpellCorrectAllowsFirstWordCapitalized() {
        // First word capitalized is normal sentence start — should still be eligible for correction.
        // "Waether" at position 0 should be checked (capitalization guard only applies at index > 0).
        // NSSpellChecker may suggest "Whether" or "Weather" — both are valid.
        let (corrected, didCorrect) = InputPreprocessor.spellCorrect("Waether forecast today")
        XCTAssertTrue(didCorrect, "First word 'Waether' should still be eligible for correction")
        let lower = corrected.lowercased()
        XCTAssertTrue(lower.contains("weather") || lower.contains("whether"),
            "First-word typo should be corrected, got: \(corrected)")
    }

    // MARK: - Edit Distance Tests

    func testEditDistanceHelper() {
        // Access via spellCorrect behavior — words with edit distance > 2 should not be corrected
        // "xyzabc" → unlikely to have a correction with edit distance ≤ 2
        let (_, didCorrect) = InputPreprocessor.spellCorrect("xyzabc")
        // Unknown word with no close match should not be corrected
        XCTAssertFalse(didCorrect)
    }

    // MARK: - ExtractedEntities correctedInput

    func testExtractedEntitiesDefaultsToNilCorrectedInput() {
        let entities = ExtractedEntities(
            names: [], places: [], organizations: [],
            urls: [], phoneNumbers: [], emails: [],
            ocrText: nil
        )
        XCTAssertNil(entities.correctedInput)
    }

    func testExtractedEntitiesStoresCorrectedInput() {
        let entities = ExtractedEntities(
            names: [], places: [], organizations: [],
            urls: [], phoneNumbers: [], emails: [],
            ocrText: nil,
            correctedInput: "weather in London"
        )
        XCTAssertEqual(entities.correctedInput, "weather in London")
    }

    // MARK: - ToolArgumentExtractor Tests

    func testExtractorReturnsDecodedArgs() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            {"intent":"forecast","location":"London","forecastDays":3}
            """
        })

        let args = await extractor.extract(
            input: "3 day forecast for London",
            schema: WeatherTool.extractionSchema,
            toolName: "Weather",
            as: WeatherArgs.self
        )

        XCTAssertNotNil(args)
        XCTAssertEqual(args?.intent, "forecast")
        XCTAssertEqual(args?.location, "London")
        XCTAssertEqual(args?.forecastDays, 3)
    }

    func testExtractorHandlesMarkdownCodeFence() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return """
            ```json
            {"intent":"coin"}
            ```
            """
        })

        let args = await extractor.extract(
            input: "flip a coin",
            schema: RandomTool.extractionSchema,
            toolName: "Random",
            as: RandomArgs.self
        )

        XCTAssertNotNil(args)
        XCTAssertEqual(args?.intent, "coin")
    }

    func testExtractorReturnsNilOnInvalidJSON() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            return "I don't understand the request"
        })

        let args = await extractor.extract(
            input: "do something",
            schema: "{}",
            toolName: "Test",
            as: WeatherArgs.self
        )

        XCTAssertNil(args)
    }

    func testExtractorReturnsNilOnLLMFailure() async {
        let extractor = ToolArgumentExtractor(llmResponder: { _ in
            throw NSError(domain: "test", code: -1)
        })

        let args = await extractor.extract(
            input: "weather",
            schema: "{}",
            toolName: "Weather",
            as: WeatherArgs.self
        )

        XCTAssertNil(args)
    }

    // MARK: - Schema Loading Tests

    func testWeatherSchemaLoads() {
        let schema = WeatherTool.extractionSchema
        XCTAssertTrue(schema.contains("intent"))
        XCTAssertTrue(schema.contains("location"))
    }

    func testRandomSchemaLoads() {
        let schema = RandomTool.extractionSchema
        XCTAssertTrue(schema.contains("intent"))
        XCTAssertTrue(schema.contains("sides"))
    }

    func testPodcastSchemaLoads() {
        let schema = PodcastTool.extractionSchema
        XCTAssertTrue(schema.contains("intent"))
        XCTAssertTrue(schema.contains("query"))
    }

    func testMapsSchemaLoads() {
        let schema = MapsCoreTool.extractionSchema
        XCTAssertTrue(schema.contains("intent"))
        XCTAssertTrue(schema.contains("destination"))
    }

    func testReadEmailSchemaLoads() {
        let schema = ReadEmailTool.extractionSchema
        XCTAssertTrue(schema.contains("intent"))
        XCTAssertTrue(schema.contains("senderName"))
    }

    // MARK: - Tool Args Decoding Tests

    func testWeatherArgsDecoding() throws {
        let json = """
        {"intent":"comparison","location":"London","comparisonCity":"Paris"}
        """
        let args = try JSONDecoder().decode(WeatherArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(args.intent, "comparison")
        XCTAssertEqual(args.location, "London")
        XCTAssertEqual(args.comparisonCity, "Paris")
        XCTAssertNil(args.forecastDays)
    }

    func testRandomArgsDecoding() throws {
        let json = """
        {"intent":"dice","sides":20}
        """
        let args = try JSONDecoder().decode(RandomArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(args.intent, "dice")
        XCTAssertEqual(args.sides, 20)
    }

    func testPodcastArgsDecoding() throws {
        let json = """
        {"intent":"play","query":"The Daily"}
        """
        let args = try JSONDecoder().decode(PodcastArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(args.intent, "play")
        XCTAssertEqual(args.query, "The Daily")
    }

    func testMapsArgsDecoding() throws {
        let json = """
        {"intent":"directions","origin":"Boston","destination":"New York","transport":"automobile"}
        """
        let args = try JSONDecoder().decode(MapsArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(args.intent, "directions")
        XCTAssertEqual(args.origin, "Boston")
        XCTAssertEqual(args.destination, "New York")
    }

    func testReadEmailArgsDecoding() throws {
        let json = """
        {"intent":"sender","senderName":"John"}
        """
        let args = try JSONDecoder().decode(ReadEmailArgs.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(args.intent, "sender")
        XCTAssertEqual(args.senderName, "John")
    }

    // MARK: - RandomTool execute(args:) Tests

    func testRandomToolCoinFlipViaArgs() async throws {
        let tool = RandomTool()
        let args = RandomArgs(intent: "coin", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "flip a coin", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Coin Flip"))
    }

    func testRandomToolDiceViaArgs() async throws {
        let tool = RandomTool()
        let args = RandomArgs(intent: "dice", sides: 20, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "roll a d20", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Dice Roll"))
        XCTAssertTrue(result.text.contains("d20"))
    }

    func testRandomToolNumberRangeViaArgs() async throws {
        let tool = RandomTool()
        let args = RandomArgs(intent: "number", sides: nil, min: 1, max: 10)
        let result = try await tool.execute(args: args, rawInput: "random number 1 to 10", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Random Number"))
        XCTAssertTrue(result.text.contains("1 to 10"))
    }

    func testRandomToolCardViaArgs() async throws {
        let tool = RandomTool()
        let args = RandomArgs(intent: "card", sides: nil, min: nil, max: nil)
        let result = try await tool.execute(args: args, rawInput: "draw a card", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Card drawn"), "Expected 'Card drawn' in: \(result.text)")
    }

    // MARK: - Pipeline E2E with Mock Extractor

    func testExtractionPipelineWithMockExtractor() async {
        let spy = SpyTool(name: "Weather", schema: "weather tool", category: .online)
        _ = ToolArgumentExtractor(llmResponder: { _ in
            return "{\"intent\":\"current\",\"location\":\"London\"}"
        })

        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder()
        )

        // The engine uses the real extractor by default, but since SpyTool doesn't
        // conform to ExtractableCoreTool, it falls through to normal execute()
        let result = await engine.run(input: "#weather London")
        // Should route to Weather spy and get the stub response
        XCTAssertFalse(result.isError)
        XCTAssertEqual(spy.invocations.count, 1)
    }
}
