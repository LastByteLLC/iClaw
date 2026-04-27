import XCTest
import Foundation
import os
@testable import iClawCore

// MARK: - Mad Libs Stress Test

/// Generates hundreds of novel prompts programmatically and runs them through the pipeline.
/// Uses template-based "mad libs" generation — combining templates, locations,
/// tools, and perturbations to test routing robustness.
///
/// Designed to uncover:
/// - Routing confusion between similar tools under varied phrasing
/// - Edge cases in synonym expansion and ML classification
/// - Multi-turn state corruption under rapid sequential queries
/// - Cache key collisions across tool/input combinations
/// - Input sanitization gaps with generated adversarial patterns
/// Deterministic pseudo-random number generator for reproducible test prompt generation.
/// Uses the SplitMix64 algorithm — fast, simple, and produces good statistical distribution.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

final class MadLibsStressTest: XCTestCase {

    /// Fixed seed for reproducible prompt sets across runs.
    private static let defaultSeed: UInt64 = 0xCAFE_BABE_DEAD_BEEF

    // MARK: - Prompt Generators

    static let locations = [
        "London", "Tokyo", "New York", "Paris", "Berlin", "Sydney", "Mumbai",
        "São Paulo", "Cairo", "Singapore", "Toronto", "Dubai", "Seoul",
        "Mexico City", "Istanbul", "Bangkok", "Nairobi", "Oslo", "Reykjavik",
        "Buenos Aires", "Kyoto", "Marrakech", "Zurich", "Hanoi", "Lima"
    ]

    static let weatherTemplates = [
        "weather in {LOC}", "what's the weather in {LOC}", "how's the weather in {LOC}",
        "temperature in {LOC}", "is it raining in {LOC}", "will it rain in {LOC}",
        "humidity in {LOC}", "wind speed in {LOC}", "forecast for {LOC}",
        "uv index in {LOC}", "weather {LOC}", "{LOC} weather",
        "how cold is it in {LOC}", "is it warm in {LOC}", "cloud cover in {LOC}",
        "moon phase in {LOC}", "sunrise in {LOC}", "sunset in {LOC}",
    ]

    static let calcTemplates = [
        "what's {A} + {B}", "calculate {A} * {B}", "{A} divided by {B}",
        "{A} - {B}", "what is {A} percent of {B}", "square root of {A}",
        "{A}^2", "{A} mod {B}", "{A} times {B}", "{A} plus {B}",
    ]

    static let convertTemplates = [
        "{A} miles to kilometers", "{A} kg to pounds", "{A} celsius to fahrenheit",
        "{A} usd to eur", "{A} liters to gallons", "{A} feet to meters",
        "{A} btc to usd", "{A} ounces to grams", "{A} cups to ml",
    ]

    static let timeTemplates = [
        "time in {LOC}", "what time is it in {LOC}", "current time in {LOC}",
        "{LOC} time", "time zone of {LOC}",
    ]

    static let mapsTemplates = [
        "directions to {LOC}", "how far is {LOC}", "restaurants near {LOC}",
        "distance to {LOC}", "navigate to {LOC}", "eta to {LOC}",
        "coffee shops near {LOC}", "distance from {LOC} to {LOC2}",
    ]

    static let translateTemplates = [
        "translate hello to {LANG}", "how do you say goodbye in {LANG}",
        "translate 'thank you' to {LANG}", "say good morning in {LANG}",
    ]

    static let languages = [
        "Spanish", "French", "German", "Japanese", "Korean", "Italian",
        "Portuguese", "Mandarin", "Arabic", "Hindi", "Russian", "Turkish"
    ]

    nonisolated(unsafe) static let perturbations: [(String) -> String] = [
        { $0.uppercased() },                              // ALL CAPS
        { "   " + $0 + "   " },                           // Extra whitespace
        { $0 + "???" },                                    // Extra punctuation
        { $0 + " please" },                                // Polite suffix
        { "hey claw, " + $0 },                             // Trigger prefix
        { $0.replacingOccurrences(of: " ", with: "  ") },  // Double spaces
        { "can you " + $0 },                               // Question prefix
        { $0 + "!" },                                      // Exclamation
    ]

    struct GeneratedPrompt {
        let input: String
        let expectedTool: String
        let category: String
    }

    static func generatePrompts(count: Int, seed: UInt64 = defaultSeed) -> [GeneratedPrompt] {
        var prompts: [GeneratedPrompt] = []
        var rng = SeededRNG(seed: seed)

        func randLoc() -> String { locations.randomElement(using: &rng)! }
        func randNum() -> Int { Int.random(in: 1...999, using: &rng) }
        func randLang() -> String { languages.randomElement(using: &rng)! }
        func maybePerturb(_ s: String) -> String {
            if Bool.random(using: &rng) {
                return perturbations.randomElement(using: &rng)!(s)
            }
            return s
        }

        while prompts.count < count {
            let category = Int.random(in: 0..<6, using: &rng)

            switch category {
            case 0: // Weather
                let template = weatherTemplates.randomElement(using: &rng)!
                let filled = template.replacingOccurrences(of: "{LOC}", with: randLoc())
                prompts.append(GeneratedPrompt(input: maybePerturb(filled), expectedTool: "Weather", category: "weather"))

            case 1: // Calculator
                let template = calcTemplates.randomElement(using: &rng)!
                let filled = template
                    .replacingOccurrences(of: "{A}", with: "\(randNum())")
                    .replacingOccurrences(of: "{B}", with: "\(randNum())")
                prompts.append(GeneratedPrompt(input: maybePerturb(filled), expectedTool: "Calculator", category: "calculator"))

            case 2: // Convert
                let template = convertTemplates.randomElement(using: &rng)!
                let filled = template.replacingOccurrences(of: "{A}", with: "\(randNum())")
                prompts.append(GeneratedPrompt(input: maybePerturb(filled), expectedTool: "Convert", category: "convert"))

            case 3: // Time
                let template = timeTemplates.randomElement(using: &rng)!
                let filled = template.replacingOccurrences(of: "{LOC}", with: randLoc())
                prompts.append(GeneratedPrompt(input: maybePerturb(filled), expectedTool: "Time", category: "time"))

            case 4: // Maps
                let template = mapsTemplates.randomElement(using: &rng)!
                let loc1 = randLoc()
                var loc2 = randLoc()
                while loc2 == loc1 { loc2 = randLoc() }
                let filled = template
                    .replacingOccurrences(of: "{LOC2}", with: loc2)
                    .replacingOccurrences(of: "{LOC}", with: loc1)
                prompts.append(GeneratedPrompt(input: maybePerturb(filled), expectedTool: "Maps", category: "maps"))

            case 5: // Translate
                let template = translateTemplates.randomElement(using: &rng)!
                let filled = template.replacingOccurrences(of: "{LANG}", with: randLang())
                prompts.append(GeneratedPrompt(input: maybePerturb(filled), expectedTool: "Translate", category: "translate"))

            default:
                break
            }
        }
        return prompts
    }

    // MARK: - Spy Registry

    static func makeFullSpyRegistry() -> [String: SpyTool] {
        [
            "Weather": SpyTool(name: "Weather", schema: "Get the current weather: 'weather in London', 'temperature in Tokyo'.", category: .online),
            "Calculator": SpyTool(name: "Calculator", schema: "Perform simple math calculations.", category: .offline),
            "Convert": SpyTool(name: "Convert", schema: "Convert units or currency.", category: .online),
            "Time": SpyTool(name: "Time", schema: "Get the current time for a specific location or set a timer.", category: .offline),
            "Maps": SpyTool(name: "Maps", schema: "Directions, distance, ETA, nearby restaurants.", category: .online),
            "Translate": SpyTool(name: "Translate", schema: "Translate text between languages.", category: .offline),
            "Timer": SpyTool(name: "Timer", schema: "Set a countdown timer.", category: .offline),
            "Random": SpyTool(name: "Random", schema: "Random: flip coin, roll dice, random number.", category: .offline),
            "Stocks": SpyTool(name: "Stocks", schema: "Stock price and quotes.", category: .online),
            "WebFetch": SpyTool(name: "WebFetch", schema: "Fetch URL content.", category: .online),
            "Podcast": SpyTool(name: "Podcast", schema: "Search and play podcasts.", category: .online),
            "Dictionary": SpyTool(name: "Dictionary", schema: "Dictionary definition lookup.", category: .offline),
            "ReadEmail": SpyTool(name: "ReadEmail", schema: "Read or search emails.", category: .offline),
            "Email": SpyTool(name: "Email", schema: "Send an email.", category: .offline),
            "News": SpyTool(name: "News", schema: "Latest news headlines.", category: .online),
            "Research": SpyTool(name: "Research", schema: "Research a topic.", category: .online),
            "Create": SpyTool(name: "Create", schema: "Create an image.", category: .async),
            "SystemInfo": SpyTool(name: "SystemInfo", schema: "System info battery wifi disk CPU.", category: .offline),
            "Calendar": SpyTool(name: "Calendar", schema: "Date calculations.", category: .offline),
            "Transcribe": SpyTool(name: "Transcribe", schema: "Transcribe audio.", category: .offline),
            "Today": SpyTool(name: "Today", schema: "Today's date and summary.", category: .offline),
            "Feedback": SpyTool(name: "Feedback", schema: "Give feedback.", category: .offline),
        ]
    }

    // MARK: - Shared Test Runner

    /// Runs a batch of generated prompts and returns (passed, failed, errors, maxDuration).
    private func runBatch(_ prompts: [GeneratedPrompt]) async -> (passed: Int, failed: Int, errors: Int, maxDurationMs: Int, misroutes: [(input: String, expected: String, actual: String?)]) {
        var passed = 0, failed = 0, errors = 0, maxDuration = 0
        var misroutes: [(input: String, expected: String, actual: String?)] = []

        for prompt in prompts {
            let registry = Self.makeFullSpyRegistry()
            let spies = Array(registry.values)

            let routerLLM: RouterLLMResponder = { _, _ in prompt.expectedTool }
            let planner = ExecutionPlanner(llmResponder: { _ in "\(prompt.expectedTool): \(prompt.input)" })
            let router = ToolRouter(availableTools: spies, llmResponder: routerLLM)
            let engine = ExecutionEngine(
                router: router,
                conversationManager: ConversationManager(),
                planner: planner,
                llmResponder: makeStubLLMResponder()
            )

            let start = DispatchTime.now()
            let result = await engine.run(input: prompt.input)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            maxDuration = max(maxDuration, elapsed)

            if result.isError { errors += 1 }

            let invokedSpy = spies.first { $0.invocations.count > 0 }
            let actualTool = invokedSpy?.name

            if actualTool == prompt.expectedTool {
                passed += 1
            } else {
                failed += 1
                misroutes.append((input: prompt.input, expected: prompt.expectedTool, actual: actualTool))
            }
        }
        return (passed, failed, errors, maxDuration, misroutes)
    }

    private static func generateForCategory(_ category: Int, count: Int, seed: UInt64 = defaultSeed) -> [GeneratedPrompt] {
        var prompts: [GeneratedPrompt] = []
        var rng = SeededRNG(seed: seed &+ UInt64(category))
        func randLoc() -> String { locations.randomElement(using: &rng)! }
        func randNum() -> Int { Int.random(in: 1...999, using: &rng) }
        func randLang() -> String { languages.randomElement(using: &rng)! }
        func maybePerturb(_ s: String) -> String {
            Bool.random(using: &rng) ? perturbations.randomElement(using: &rng)!(s) : s
        }

        while prompts.count < count {
            switch category {
            case 0:
                let t = weatherTemplates.randomElement(using: &rng)!
                let f = t.replacingOccurrences(of: "{LOC}", with: randLoc())
                prompts.append(GeneratedPrompt(input: maybePerturb(f), expectedTool: "Weather", category: "weather"))
            case 1:
                let t = calcTemplates.randomElement(using: &rng)!
                let f = t.replacingOccurrences(of: "{A}", with: "\(randNum())").replacingOccurrences(of: "{B}", with: "\(randNum())")
                prompts.append(GeneratedPrompt(input: maybePerturb(f), expectedTool: "Calculator", category: "calculator"))
            case 2:
                let t = convertTemplates.randomElement(using: &rng)!
                let f = t.replacingOccurrences(of: "{A}", with: "\(randNum())")
                prompts.append(GeneratedPrompt(input: maybePerturb(f), expectedTool: "Convert", category: "convert"))
            case 3:
                let t = timeTemplates.randomElement(using: &rng)!
                let f = t.replacingOccurrences(of: "{LOC}", with: randLoc())
                prompts.append(GeneratedPrompt(input: maybePerturb(f), expectedTool: "Time", category: "time"))
            case 4:
                let t = mapsTemplates.randomElement(using: &rng)!
                let l1 = randLoc(); var l2 = randLoc(); while l2 == l1 { l2 = randLoc() }
                let f = t.replacingOccurrences(of: "{LOC2}", with: l2).replacingOccurrences(of: "{LOC}", with: l1)
                prompts.append(GeneratedPrompt(input: maybePerturb(f), expectedTool: "Maps", category: "maps"))
            case 5:
                let t = translateTemplates.randomElement(using: &rng)!
                let f = t.replacingOccurrences(of: "{LANG}", with: randLang())
                prompts.append(GeneratedPrompt(input: maybePerturb(f), expectedTool: "Translate", category: "translate"))
            default: break
            }
        }
        return prompts
    }

    // MARK: - Per-Category Tests (50 each, fast isolation)

    func testGenerativeWeather50() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()
        let r = await runBatch(Self.generateForCategory(0, count: 50))
        let rate = Double(r.passed) / 50.0 * 100
        XCTAssertGreaterThan(rate, 90.0, "Weather pass rate: \(rate)%")
        XCTAssertLessThan(r.maxDurationMs, 5000, "Slowest weather prompt: \(r.maxDurationMs)ms")
    }

    func testGenerativeCalculator50() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()
        let r = await runBatch(Self.generateForCategory(1, count: 50))
        let rate = Double(r.passed) / 50.0 * 100
        XCTAssertGreaterThan(rate, 90.0, "Calculator pass rate: \(rate)%")
        XCTAssertLessThan(r.maxDurationMs, 5000, "Slowest calc prompt: \(r.maxDurationMs)ms")
    }

    func testGenerativeConvert50() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()
        let r = await runBatch(Self.generateForCategory(2, count: 50))
        let rate = Double(r.passed) / 50.0 * 100
        XCTAssertGreaterThan(rate, 90.0, "Convert pass rate: \(rate)%")
        XCTAssertLessThan(r.maxDurationMs, 5000, "Slowest convert prompt: \(r.maxDurationMs)ms")
    }

    func testGenerativeTime50() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()
        let r = await runBatch(Self.generateForCategory(3, count: 50))
        let rate = Double(r.passed) / 50.0 * 100
        XCTAssertGreaterThan(rate, 90.0, "Time pass rate: \(rate)%")
        XCTAssertLessThan(r.maxDurationMs, 5000, "Slowest time prompt: \(r.maxDurationMs)ms")
    }

    func testGenerativeMaps50() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()
        let r = await runBatch(Self.generateForCategory(4, count: 50))
        let rate = Double(r.passed) / 90.0 * 100
        XCTAssertGreaterThan(rate, 85.0, "Maps pass rate: \(rate)%")
        XCTAssertLessThan(r.maxDurationMs, 5000, "Slowest maps prompt: \(r.maxDurationMs)ms")
    }

    func testGenerativeTranslate50() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()
        let r = await runBatch(Self.generateForCategory(5, count: 50))
        let rate = Double(r.passed) / 50.0 * 100
        XCTAssertGreaterThan(rate, 90.0, "Translate pass rate: \(rate)%")
        XCTAssertLessThan(r.maxDurationMs, 5000, "Slowest translate prompt: \(r.maxDurationMs)ms")
    }

    // MARK: - Combined Stress Test (smaller, with report)

    func testGenerative200Combined() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()
        let prompts = Self.generatePrompts(count: 200)
        let r = await runBatch(prompts)

        let passRate = Double(r.passed) / Double(prompts.count) * 100

        // Report misroutes
        if !r.misroutes.isEmpty {
            let grouped = Dictionary(grouping: r.misroutes, by: { $0.expected })
            for (expected, items) in grouped.sorted(by: { $0.key < $1.key }) {
                print("Misroutes for \(expected): \(items.count)")
                for item in items.prefix(5) {
                    print("  \"\(item.input.prefix(60))\" → \(item.actual ?? "none")")
                }
            }
        }

        XCTAssertEqual(r.errors, 0, "No errors expected")
        XCTAssertGreaterThan(passRate, 90.0, "Pass rate: \(String(format: "%.1f", passRate))%")
        XCTAssertLessThan(r.maxDurationMs, 5000, "Slowest prompt: \(r.maxDurationMs)ms")
    }

    // MARK: - Rapid-Fire Multi-Turn Test (100 turns, single engine)

    func testRapidFire100Turns() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()

        let registry = Self.makeFullSpyRegistry()
        let spies = Array(registry.values)

        let conversationManager = ConversationManager()
        let router = ToolRouter(availableTools: spies, llmResponder: makeStubRouterLLMResponder())
        let planner = ExecutionPlanner(llmResponder: { _ in "none: passthrough" })
        let engine = ExecutionEngine(
            router: router,
            conversationManager: conversationManager,
            planner: planner,
            llmResponder: makeStubLLMResponder()
        )

        // Rapidly alternate between different tool types
        let chips = ["#weather London", "#time Tokyo", "#calculator 2+2", "#convert 100 usd to eur",
                     "#timer 5 min", "#news tech", "#random coin", "#weather Paris",
                     "#time Berlin", "#calculator 100/3"]

        for i in 0..<100 {
            let input = chips[i % chips.count]
            let result = await engine.run(input: input)
            XCTAssertFalse(result.text.isEmpty, "Turn \(i) produced empty response for '\(input)'")
        }

        // Verify state didn't corrupt
        let state = await conversationManager.state
        XCTAssertEqual(state.turnCount, 100, "Should have 100 turns")
        XCTAssertEqual(state.topics.count, 3, "Topics should be capped at 3")
        XCTAssertLessThanOrEqual(state.activeEntities.count, 10, "Entities should be capped at 10")

        // Verify state serializes within budget
        let json = state.serialize()
        let tokens = AppConfig.estimateTokens(for: json)
        XCTAssertLessThan(tokens, AppConfig.conversationStateBlob,
                          "State should fit within budget after 100 turns (\(tokens) tokens)")
    }

    // MARK: - Cache Collision Sweep

    func testCacheCollisionSweep() async throws {
        await ScratchpadCache.shared.reset()

        // Generate pairs of inputs that SHOULD produce different cache keys
        let distinctPairs: [(String, String, String)] = [
            ("Convert", "100 USD to EUR", "100 EUR to USD"),
            ("Translate", "translate hello to Spanish", "translate Spanish to hello"),
            ("Convert", "50 miles to km", "50 km to miles"),
            ("Convert", "1 btc to usd", "1 usd to btc"),
        ]

        for (tool, input1, input2) in distinctPairs {
            let key1 = ScratchpadCache.makeKey(toolName: tool, input: input1)
            let key2 = ScratchpadCache.makeKey(toolName: tool, input: input2)
            XCTAssertNotEqual(key1, key2, "Cache collision for \(tool): '\(input1)' vs '\(input2)'")
        }

        // Generate pairs that SHOULD produce the same cache key (word reordering for non-directional tools)
        let equivalentPairs: [(String, String, String)] = [
            ("Weather", "weather in London", "London weather"),
            ("Weather", "how's the weather in Tokyo", "Tokyo weather how's the"),
            ("News", "latest tech news", "tech news latest"),
            ("Dictionary", "define serendipity", "serendipity define"),
        ]

        for (tool, input1, input2) in equivalentPairs {
            let key1 = ScratchpadCache.makeKey(toolName: tool, input: input1)
            let key2 = ScratchpadCache.makeKey(toolName: tool, input: input2)
            XCTAssertEqual(key1, key2, "Expected cache equivalence for \(tool): '\(input1)' vs '\(input2)'")
        }
    }
}
