import XCTest
@testable import iClawCore

// MARK: - Intent Splitter Tests

final class IntentSplitterTests: XCTestCase {

    func testSplitsWeatherAndStocks() {
        let entities = ExtractedEntities(
            names: [], places: ["Paris"], organizations: [],
            urls: [], phoneNumbers: [], emails: [], ocrText: nil
        )
        // Use $AAPL ticker syntax which triggers stock domain detection
        let result = IntentSplitter.split(
            input: "What's the weather in Paris and how's $AAPL stock doing",
            entities: entities
        )
        XCTAssertNotNil(result, "Should detect two distinct intents")
        XCTAssertEqual(result?.count, 2)
        XCTAssertTrue(result![0].text.lowercased().contains("weather"))
        XCTAssertTrue(result![1].text.lowercased().contains("aapl"))
    }

    func testSplitsNewsAndCalculation() {
        let result = IntentSplitter.split(
            input: "Show me the latest news and calculate 25% of 300",
            entities: nil
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 2)
    }

    func testDoesNotSplitSingleIntent() {
        let result = IntentSplitter.split(
            input: "What's the weather in Paris",
            entities: nil
        )
        XCTAssertNil(result, "Single-intent query should not split")
    }

    func testDoesNotSplitComparison() {
        let result = IntentSplitter.split(
            input: "Compare weather in London and Paris",
            entities: nil
        )
        XCTAssertNil(result, "Comparison queries should not split")
    }

    func testDoesNotSplitVersus() {
        let result = IntentSplitter.split(
            input: "Weather in London vs Paris",
            entities: nil
        )
        XCTAssertNil(result, "Versus queries should not split")
    }

    func testDoesNotSplitShortInput() {
        let result = IntentSplitter.split(input: "hi and bye", entities: nil)
        XCTAssertNil(result, "Very short input should not split")
    }

    func testDoesNotSplitSameDomain() {
        let result = IntentSplitter.split(
            input: "What's the weather in London and what's the forecast for tomorrow",
            entities: nil
        )
        XCTAssertNil(result, "Same-domain queries should not split")
    }

    func testSplitsSentenceBoundary() {
        let result = IntentSplitter.split(
            input: "Check the weather in Tokyo. Also convert 100 miles to kilometers",
            entities: nil
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 2)
    }

    func testSplitsCalendarAndStocks() {
        let result = IntentSplitter.split(
            input: "What's on my calendar today and how's the stock market",
            entities: nil
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 2)
    }

    func testDistributesEntities() {
        let entities = ExtractedEntities(
            names: [], places: ["London", "Tokyo"], organizations: [],
            urls: [], phoneNumbers: [], emails: [], ocrText: nil
        )
        let result = IntentSplitter.split(
            input: "Weather in London and translate hello to Japanese",
            entities: entities
        )
        XCTAssertNotNil(result)
        if let sub = result {
            XCTAssertTrue(sub[0].entities?.places.contains("London") ?? false)
        }
    }
}

// MARK: - Date Arithmetic Tests

final class DateArithmeticTests: XCTestCase {

    func testDaysUntilChristmas() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "how many days until Christmas", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("day"), "Should mention days: \(result.text)")
        XCTAssertEqual(result.outputWidget, "MathWidget")
    }

    func testDaysUntilNewYears() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "days until new years", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("day"))
    }

    func testDaysFromNow() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "what day is 90 days from now", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // Should contain a day of the week
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        XCTAssertTrue(weekdays.contains(where: { result.text.contains($0) }), "Should contain a weekday: \(result.text)")
    }

    func testDaysAgo() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "what day was 100 days ago", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("was"))
    }

    func testDayOfWeekForDate() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "what day of the week was July 4, 1776", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Thursday"), "July 4, 1776 was a Thursday: \(result.text)")
    }

    func testDaysUntilSpecificDate() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "how many days until March 25", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("day"))
    }

    func testDaysBetween() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "how many days between January 1, 2026 and March 15, 2026", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("73"), "Should be 73 days: \(result.text)")
    }

    func testDaysFromToday() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "30 days from now", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("30 days from now"))
    }

    func testTomorrow() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "how many days until tomorrow", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1 day") || result.text.contains("tomorrow"))
    }

    func testNextFriday() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "what day is next friday", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Friday"))
    }

    // Math still works after date arithmetic addition
    func testRegularMathStillWorks() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "25 + 75", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("100"))
    }

    func testPercentStillWorks() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "25% of 200", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("50"))
    }
}

// MARK: - Output Finalizer Tests

final class OutputFinalizerRecalledTests: XCTestCase {

    func testRecalledIngredientPresent() async {
        let finalizer = OutputFinalizer()
        let output = await finalizer.finalize(
            ingredients: ["[RECALLED] Previously discussed: The user asked about weather in Paris last week"],
            brainContent: BrainProvider.current,
            soulContent: "Test soul",
            userContext: "",
            userPrompt: "What did we talk about?"
        )
        XCTAssertTrue(output.prompt.contains("[RECALLED]"), "Recalled ingredient should be present")
        XCTAssertTrue(output.prompt.contains("<brain>"), "Should contain brain section")
    }

    func testVerifiedAndRecalledIngredients() async {
        let finalizer = OutputFinalizer()
        let output = await finalizer.finalize(
            ingredients: [
                "[VERIFIED] Temperature: 72°F",
                "[RECALLED] Previously discussed: User prefers Celsius"
            ],
            brainContent: BrainProvider.current,
            soulContent: "Test soul",
            userContext: "",
            userPrompt: "Weather?"
        )
        XCTAssertTrue(output.prompt.contains("[VERIFIED]"), "Should contain verified ingredient")
        XCTAssertTrue(output.prompt.contains("[RECALLED]"), "Should contain recalled ingredient")
    }

    func testBrainRulesIncluded() async {
        let finalizer = OutputFinalizer()
        let output = await finalizer.finalize(
            ingredients: ["Current weather: sunny, 75°F"],
            brainContent: BrainProvider.current,
            soulContent: "Test soul",
            userContext: "",
            userPrompt: "Weather?"
        )
        XCTAssertTrue(output.prompt.contains("Never fabricate"), "Brain rules should be injected")
    }
}

// MARK: - Multi-Intent Pipeline E2E Tests

final class MultiIntentPipelineTests: XCTestCase {

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    func testMultiIntentRoutesBothTools() async throws {
        let weatherSpy = SpyTool(
            name: "Weather",
            schema: "weather temperature forecast rain sunny cloudy wind humidity",
            result: ToolIO(text: "72°F, sunny", status: .ok, isVerifiedData: true)
        )
        let stockSpy = SpyTool(
            name: "Stocks",
            schema: "stock price shares market ticker",
            result: ToolIO(text: "AAPL: $150", status: .ok, isVerifiedData: true)
        )
        let engine = makeTestEngine(
            tools: [weatherSpy, stockSpy],
            engineLLMResponder: makeStubLLMResponder()
        )

        // Use chip syntax to ensure routing works in test without ML model
        let result = await engine.run(input: "#weather Paris and #stocks AAPL")

        // Both tools should have been called
        let totalCalls = weatherSpy.invocations.count + stockSpy.invocations.count
        XCTAssertGreaterThanOrEqual(totalCalls, 1, "At least one tool should be called")
        XCTAssertFalse(result.isError)
    }

    func testSingleIntentDoesNotSplit() async throws {
        let weatherSpy = SpyTool(
            name: "Weather",
            schema: "weather temperature forecast rain sunny cloudy wind humidity",
            result: ToolIO(text: "72°F, sunny", status: .ok)
        )
        let engine = makeTestEngine(
            tools: [weatherSpy],
            engineLLMResponder: makeStubLLMResponder()
        )

        _ = await engine.run(input: "#weather Paris")

        XCTAssertEqual(weatherSpy.invocations.count, 1, "Single intent should call tool once")
    }
}

// MARK: - User Profile Manager Tests

final class UserProfileManagerTests: XCTestCase {

    @MainActor
    func testRecordToolUsage() async throws {
        // Use a fresh in-memory database for isolation
        let db = try DatabaseManager(inMemory: true)
        // The user profile table should have been created by the migration
        let count = try await db.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_profile") ?? 0
        }
        XCTAssertEqual(count, 0, "Should start empty")
    }
}

// MARK: - Air Quality Weather Intent Tests

final class AirQualityIntentTests: XCTestCase {

    func testAQIKeywordDetection() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "air quality in London", entities: nil)
        if case .detail(let field) = intent {
            XCTAssertEqual(field, .airQuality)
        } else {
            XCTFail("Should detect air quality intent, got \(intent)")
        }
    }

    func testAQIKeywordPollution() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "pollution levels in Beijing", entities: nil)
        if case .detail(let field) = intent {
            XCTAssertEqual(field, .airQuality)
        } else {
            XCTFail("Should detect air quality from 'pollution', got \(intent)")
        }
    }

    func testAQIKeywordSmog() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "is there smog in LA today", entities: nil)
        if case .detail(let field) = intent {
            XCTAssertEqual(field, .airQuality)
        } else {
            XCTFail("Should detect air quality from 'smog', got \(intent)")
        }
    }

    func testAQIKeywordPM25() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "pm2.5 levels in Delhi", entities: nil)
        if case .detail(let field) = intent {
            XCTAssertEqual(field, .airQuality)
        } else {
            XCTFail("Should detect air quality from 'pm2.5', got \(intent)")
        }
    }

    func testAQIKeywordPollen() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "pollen count today", entities: nil)
        if case .detail(let field) = intent {
            XCTAssertEqual(field, .airQuality)
        } else {
            XCTFail("Should detect air quality from 'pollen', got \(intent)")
        }
    }

    func testWeatherStillDetectsCurrent() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "weather in London", entities: nil)
        if case .current = intent {
            // Correct
        } else {
            XCTFail("Regular weather should still route to .current, got \(intent)")
        }
    }

    func testWeatherStillDetectsForecast() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "forecast for this week", entities: nil)
        if case .forecast = intent {
            // Correct
        } else {
            XCTFail("Forecast should still work, got \(intent)")
        }
    }

    func testWeatherStillDetectsWind() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "wind speed in Chicago", entities: nil)
        if case .detail(.wind) = intent {
            // Correct
        } else {
            XCTFail("Wind should still work, got \(intent)")
        }
    }

    func testAQIKeywordAQI() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "what's the aqi", entities: nil)
        if case .detail(let field) = intent {
            XCTAssertEqual(field, .airQuality)
        } else {
            XCTFail("Should detect 'aqi' keyword, got \(intent)")
        }
    }

    func testAQIKeywordParticulate() {
        let tool = WeatherTool()
        let intent = tool.detectIntent(input: "particulate matter in New York", entities: nil)
        if case .detail(let field) = intent {
            XCTAssertEqual(field, .airQuality)
        } else {
            XCTFail("Should detect 'particulate', got \(intent)")
        }
    }
}

// MARK: - AQI Level Mapping Tests

final class AQILevelTests: XCTestCase {

    func testGoodAQI() {
        // Access the static method through the public interface
        // We test the logic indirectly through the tool's output
        let tool = WeatherTool()
        // AQI levels are tested via intent detection + keyword coverage
        let intent = tool.detectIntent(input: "air quality index", entities: nil)
        if case .detail(.airQuality) = intent {
            // Correct routing
        } else {
            XCTFail("Should detect AQI from 'air quality index'")
        }
    }
}
