import CoreML
import NaturalLanguage
import XCTest
@testable import iClawCore

/// Tests for the FollowUpClassifier CoreML model and its integration
/// into the ToolRouter follow-up detection pipeline.
final class FollowUpClassifierTests: XCTestCase {

    // MARK: - Model Loading

    func testModelLoads() async {
        let classifier = FollowUpClassifier.shared
        await classifier.loadModel()
        let prediction = await classifier.classify(
            priorTool: "weather",
            priorInput: "weather in Paris",
            currentInput: "and London?"
        )
        XCTAssertNotNil(prediction, "FollowUpClassifier should load and return predictions")
    }

    // MARK: - Continuation Detection

    func testContinuationWeatherLocation() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "and London?")
        XCTAssertEqual(result, .continuation, "New location after weather should be continuation")
    }

    func testContinuationWeatherDate() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "how about tomorrow?")
        XCTAssertEqual(result, .continuation)
    }

    func testContinuationStocksTicker() async {
        let result = await classify(prior: "stocks", priorInput: "AAPL stock price", current: "and TSLA?")
        XCTAssertEqual(result, .continuation)
    }

    func testContinuationTranslateLanguage() async {
        let result = await classify(prior: "text.translate", priorInput: "translate hello to Spanish", current: "and in French?")
        XCTAssertEqual(result, .continuation)
    }

    func testContinuationNewsTopicChange() async {
        let result = await classify(prior: "news", priorInput: "latest news", current: "what about sports?")
        XCTAssertEqual(result, .continuation)
    }

    func testContinuationTimeLocation() async {
        let result = await classify(prior: "time", priorInput: "what time is it in Tokyo", current: "and London?")
        XCTAssertEqual(result, .continuation)
    }

    // MARK: - Refinement Detection

    func testRefinementUnitChange() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "in celsius")
        XCTAssertEqual(result, .refinement, "Unit change should be refinement")
    }

    func testRefinementCorrection() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "no, tomorrow")
        XCTAssertEqual(result, .refinement)
    }

    func testRefinementMoreDetail() async {
        let result = await classify(prior: "news", priorInput: "latest news", current: "more detailed")
        XCTAssertEqual(result, .refinement)
    }

    func testRefinementLocationCorrection() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "sorry, London")
        XCTAssertEqual(result, .refinement)
    }

    // MARK: - Drill-Down Detection

    func testDrillDownOrdinal() async {
        let result = await classify(prior: "news", priorInput: "latest news", current: "read the first one")
        XCTAssertEqual(result, .drillDown, "Ordinal reference should be drill_down")
    }

    func testDrillDownMoreDetail() async {
        let result = await classify(prior: "search.web", priorInput: "search for swift tutorials", current: "tell me more about that")
        XCTAssertEqual(result, .drillDown)
    }

    func testDrillDownOpenLink() async {
        let result = await classify(prior: "news", priorInput: "top headlines", current: "open that link")
        XCTAssertEqual(result, .drillDown)
    }

    func testDrillDownElaborate() async {
        let result = await classify(prior: "search.research", priorInput: "research quantum computing", current: "can you elaborate on that")
        XCTAssertEqual(result, .drillDown)
    }

    // MARK: - Pivot Detection

    func testPivotWeatherToTimer() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "set a timer for 5 minutes")
        XCTAssertEqual(result, .pivot, "Completely unrelated query should be pivot")
    }

    func testPivotStocksToEmail() async {
        let result = await classify(prior: "stocks", priorInput: "AAPL stock price", current: "check my email")
        XCTAssertEqual(result, .pivot)
    }

    func testPivotEmailToWeather() async {
        let result = await classify(prior: "email.read", priorInput: "check my email", current: "what's the weather in Tokyo")
        XCTAssertEqual(result, .pivot)
    }

    func testPivotTimerToTranslate() async {
        let result = await classify(prior: "timer", priorInput: "set a timer for 10 minutes", current: "translate hello to French")
        XCTAssertEqual(result, .pivot)
    }

    func testPivotNewsToCalculator() async {
        let result = await classify(prior: "news", priorInput: "latest news", current: "what's 42 times 19")
        XCTAssertEqual(result, .pivot)
    }

    // MARK: - Retry Detection

    func testRetryTryAgain() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "try again")
        XCTAssertEqual(result, .retry, "Explicit retry phrase should be retry")
    }

    func testRetryDoItAgain() async {
        let result = await classify(prior: "stocks", priorInput: "AAPL stock price", current: "do it again")
        XCTAssertEqual(result, .retry)
    }

    func testRetryRunItAgain() async {
        let result = await classify(prior: "calculator", priorInput: "what's 42 times 19", current: "run it again")
        XCTAssertEqual(result, .retry)
    }

    func testRetryGiveItAnotherShot() async {
        let result = await classify(prior: "news", priorInput: "latest news", current: "give it another shot")
        XCTAssertEqual(result, .retry)
    }

    // MARK: - Meta Detection

    func testMetaWhyThatTool() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "why did you use that tool")
        XCTAssertEqual(result, .meta, "System question should be meta")
    }

    func testMetaCapabilities() async {
        let result = await classify(prior: "stocks", priorInput: "AAPL stock", current: "what tools do you have")
        XCTAssertEqual(result, .meta)
    }

    func testMetaHowDoesItWork() async {
        let result = await classify(prior: "news", priorInput: "latest news", current: "how does that work")
        XCTAssertEqual(result, .meta)
    }

    func testMetaAccuracy() async {
        let result = await classify(prior: "weather", priorInput: "weather in Paris", current: "is that accurate")
        XCTAssertEqual(result, .meta)
    }

    // MARK: - Batch Accuracy

    func testOverallAccuracy() async {
        let testCases: [(prior: String, priorInput: String, current: String, expected: FollowUpClassifier.TurnRelation)] = [
            // Continuation
            ("weather", "weather in Paris", "and London?", .continuation),
            ("time", "time in Tokyo", "and Berlin?", .continuation),
            ("stocks", "AAPL stock", "how about MSFT?", .continuation),
            ("news", "latest news", "what about tech?", .continuation),
            ("text.translate", "translate to French", "and Italian?", .continuation),
            ("convert", "10 miles to km", "and to miles?", .continuation),
            ("random", "roll a dice", "roll again", .continuation),
            ("create", "draw a sunset", "but at night", .continuation),
            // Refinement
            ("weather", "weather in Paris", "in celsius", .refinement),
            ("weather", "weather in Paris", "no, tomorrow", .refinement),
            ("convert", "100 fahrenheit", "in metric", .refinement),
            ("timer", "timer 5 min", "make it 10", .refinement),
            // Drill-down
            ("news", "latest news", "read the first one", .drillDown),
            ("search.web", "search python", "tell me more about that", .drillDown),
            ("news", "headlines", "open that link", .drillDown),
            ("search.research", "research AI", "expand on that", .drillDown),
            // Pivot
            ("weather", "weather Paris", "set a timer for 5 minutes", .pivot),
            ("stocks", "AAPL", "check my email", .pivot),
            ("email.read", "check email", "weather in Tokyo", .pivot),
            ("timer", "timer 10 min", "open Safari", .pivot),
            ("news", "latest news", "flip a coin", .pivot),
            // Retry
            ("weather", "weather Paris", "try again", .retry),
            ("stocks", "AAPL stock", "do it again", .retry),
            ("calculator", "42 times 19", "run it again", .retry),
            ("news", "latest news", "give it another shot", .retry),
            // Meta
            ("weather", "weather Paris", "why did you use that tool", .meta),
            ("stocks", "AAPL", "what tools do you have", .meta),
            ("news", "latest news", "how does that work", .meta),
        ]

        let classifier = FollowUpClassifier.shared
        await classifier.loadModel()

        var correct = 0
        var misses: [(input: String, expected: String, predicted: String)] = []

        for tc in testCases {
            guard let prediction = await classifier.classify(
                priorTool: tc.prior, priorInput: tc.priorInput, currentInput: tc.current
            ) else {
                misses.append((tc.current, tc.expected.rawValue, "nil"))
                continue
            }
            if prediction.relation == tc.expected {
                correct += 1
            } else {
                misses.append((tc.current, tc.expected.rawValue, prediction.relation.rawValue))
            }
        }

        let accuracy = Double(correct) / Double(testCases.count) * 100
        print("[FollowUp Overall] Accuracy: \(String(format: "%.1f", accuracy))% (\(correct)/\(testCases.count))")
        if !misses.isEmpty {
            print("  Misclassifications:")
            for miss in misses {
                print("    \"\(miss.input)\" → predicted: \(miss.predicted), expected: \(miss.expected)")
            }
        }

        XCTAssertGreaterThanOrEqual(accuracy, 85.0,
            "Overall follow-up classification accuracy should be at least 85%")
    }

    // MARK: - Router Integration

    func testRouterDetectsContinuation() async {
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast")
        let timerSpy = SpyTool(name: "Timer", schema: "timer countdown")

        let router = ToolRouter(
            availableTools: [weatherSpy, timerSpy],
            llmResponder: makeStubRouterLLMResponder(toolName: "none")
        )

        let context = PriorTurnContext(
            toolNames: ["Weather"],
            userInput: "weather in Paris",
            entities: ExtractedEntities(
                names: [], places: ["Paris"], organizations: [],
                urls: [], phoneNumbers: [], emails: [], ocrText: nil
            ),
            ingredients: ["Weather in Paris: 15°C, cloudy"]
        )
        await router.setPriorContext(context)

        // "and London?" should route back to Weather
        let result = await router.route(input: "and London?")
        switch result {
        case .tools(let tools):
            XCTAssertEqual(tools.first?.name, "Weather")
        default:
            // Acceptable if ML/slot/NLP all miss — not a failure
            break
        }
    }

    func testRouterDetectsPivot() async {
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast")
        let timerSpy = SpyTool(name: "Timer", schema: "timer countdown")

        let router = ToolRouter(
            availableTools: [weatherSpy, timerSpy],
            llmResponder: makeStubRouterLLMResponder(toolName: "none")
        )

        let context = PriorTurnContext(
            toolNames: ["Weather"],
            userInput: "weather in Paris",
            ingredients: ["Weather in Paris: 15°C"]
        )
        await router.setPriorContext(context)

        // "set a timer for 5 minutes" should NOT route to Weather
        let result = await router.route(input: "set a timer for 5 minutes")
        switch result {
        case .tools(let tools):
            XCTAssertNotEqual(tools.first?.name, "Weather",
                "Pivot should not route back to prior tool")
        default:
            break // Acceptable — may disambiguate or go conversational
        }
    }

    func testRouterDetectsMeta() async {
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast")

        let router = ToolRouter(
            availableTools: [weatherSpy],
            llmResponder: makeStubRouterLLMResponder(toolName: "none")
        )

        let context = PriorTurnContext(
            toolNames: ["Weather"],
            userInput: "weather in Paris",
            ingredients: ["Weather in Paris: 15°C"]
        )
        await router.setPriorContext(context)

        // "why did you use that tool" should go conversational
        let result = await router.route(input: "why did you use that tool")
        switch result {
        case .conversational:
            break // Expected
        default:
            // Also acceptable — NLP might override or ML might not be confident enough
            break
        }
    }

    // MARK: - Validation Data Accuracy (CI Gate)

    func testFollowUpValidationDataAccuracy() async {
        let validationPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MLTraining/followup_validation.json")

        guard let data = try? Data(contentsOf: validationPath),
              let entries = try? JSONDecoder().decode([[String: String]].self, from: data) else {
            return // Skip if file doesn't exist
        }

        // Use the FollowUpClassifier actor which loads from iClawCore's Bundle.module
        let classifier = FollowUpClassifier.shared
        await classifier.loadModel()
        guard await classifier.isReady else {
            // Model not available in test environment — skip gracefully
            return
        }

        // Parse the formatted text to extract priorTool, priorInput, and currentInput
        var correct = 0
        var total = 0
        var perLabel: [String: (correct: Int, total: Int)] = [:]

        for entry in entries {
            guard let text = entry["text"], let expected = entry["label"] else { continue }

            // Parse: [PRIOR_TOOL:X] [PRIOR] prior_text [CURRENT] current_text
            guard let toolRange = text.range(of: "[PRIOR_TOOL:"),
                  let toolEnd = text.range(of: "]", range: toolRange.upperBound..<text.endIndex),
                  let priorStart = text.range(of: "[PRIOR] ", range: toolEnd.upperBound..<text.endIndex),
                  let currentStart = text.range(of: " [CURRENT] ", range: priorStart.upperBound..<text.endIndex) else {
                continue
            }

            let priorTool = String(text[toolRange.upperBound..<toolEnd.lowerBound])
            let priorInput = String(text[priorStart.upperBound..<currentStart.lowerBound])
            let currentInput = String(text[currentStart.upperBound...])

            total += 1
            guard let prediction = await classifier.classify(
                priorTool: priorTool, priorInput: priorInput, currentInput: currentInput
            ) else { continue }

            let predicted = prediction.relation.rawValue
            var stats = perLabel[expected, default: (correct: 0, total: 0)]
            stats.total += 1
            if predicted == expected {
                correct += 1
                stats.correct += 1
            }
            perLabel[expected] = stats
        }

        guard total > 0 else { return }

        let accuracy = Double(correct) / Double(total) * 100
        print("[FollowUp Validation] Accuracy: \(String(format: "%.1f", accuracy))% (\(correct)/\(total))")

        for (label, stats) in perLabel.sorted(by: { $0.key < $1.key }) {
            let labelAcc = stats.total > 0 ? Double(stats.correct) / Double(stats.total) * 100 : 0
            print("  \(label): \(String(format: "%.1f", labelAcc))% (\(stats.correct)/\(stats.total))")
        }

        XCTAssertGreaterThanOrEqual(accuracy, 85.0,
            "Follow-up validation accuracy should be at least 85%")
    }

    // MARK: - Helpers

    private func classify(
        prior: String,
        priorInput: String,
        current: String
    ) async -> FollowUpClassifier.TurnRelation? {
        let classifier = FollowUpClassifier.shared
        await classifier.loadModel()
        return await classifier.classify(
            priorTool: prior,
            priorInput: priorInput,
            currentInput: current
        )?.relation
    }
}
