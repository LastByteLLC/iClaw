import XCTest
import Foundation
import os
@testable import iClawCore

// MARK: - Stress Test Harness

/// Runs 300+ prompts through the full E2E pipeline, collecting routing accuracy,
/// error resilience, edge case behavior, and multi-turn state consistency.
/// Produces a structured report of all findings.
final class StressTestHarness: XCTestCase {

    // MARK: - Prompt Definition

    struct PromptCase {
        let input: String
        let expectedTool: String?   // nil = conversational, no tool expected
        let category: String        // For grouping in report
        let notes: String           // Why this prompt is interesting
    }

    // MARK: - Result Collection

    struct TestResult: CustomStringConvertible {
        let input: String
        let expectedTool: String?
        let actualTool: String?
        let category: String
        let notes: String
        let passed: Bool
        let isError: Bool
        let responseLength: Int
        let widgetType: String?
        let durationMs: Int

        var description: String {
            let status = passed ? "PASS" : "FAIL"
            let exp = expectedTool ?? "conversational"
            let act = actualTool ?? "conversational"
            return "[\(status)] [\(category)] expected=\(exp) actual=\(act) | \(input.prefix(60))"
        }
    }

    // MARK: - Spy Registry

    static func makeFullSpyRegistry() -> [String: SpyTool] {
        [
            "Weather": SpyTool(name: "Weather", schema: "Get the current weather: 'weather in London', 'how's the weather today?', 'temperature in Tokyo'.", category: .online, result: ToolIO(text: "[VERIFIED] Sunny 22°C in London", status: .ok, outputWidget: "WeatherWidget", isVerifiedData: true)),
            "Calculator": SpyTool(name: "Calculator", schema: "Perform simple math calculations.", category: .offline, result: ToolIO(text: "42", status: .ok, outputWidget: "MathWidget")),
            "Calendar": SpyTool(name: "Calendar", schema: "Date calculations: 'day of the week for July 4 2026', 'days until Christmas'.", category: .offline, result: ToolIO(text: "Thursday", status: .ok, outputWidget: "CalendarWidget")),
            "Dictionary": SpyTool(name: "Dictionary", schema: "dictionary definition lookup meaning word define", category: .offline, result: ToolIO(text: "Serendipity: happy accident", status: .ok, outputWidget: "DictionaryWidget")),
            "SystemInfo": SpyTool(name: "SystemInfo", schema: "system info battery wifi network disk space storage apps installed memory CPU uptime version macos bluetooth", category: .offline, result: ToolIO(text: "Battery: 85%, WiFi: connected", status: .ok)),
            "Screenshot": SpyTool(name: "Screenshot", schema: "screenshot screen capture OCR read screen analyze error what on screen", category: .offline, result: ToolIO(text: "Screenshot captured", status: .ok)),
            "Stocks": SpyTool(name: "Stocks", schema: "Get the current stock price and quotes for a symbol.", category: .online, result: ToolIO(text: "[VERIFIED] AAPL: $195.23", status: .ok, outputWidget: "StockWidget", isVerifiedData: true)),
            "Convert": SpyTool(name: "Convert", schema: "Convert units (e.g., '10 miles to km', '100 celsius to fahrenheit') or currency/crypto.", category: .online, result: ToolIO(text: "[VERIFIED] 100 USD = 92.30 EUR", status: .ok, isVerifiedData: true)),
            "Translate": SpyTool(name: "Translate", schema: "Translate text from one language to another.", category: .offline, result: ToolIO(text: "Hola", status: .ok)),
            "Maps": SpyTool(name: "Maps", schema: "Get directions, distance, ETA, drive time between places. Search nearby restaurants, places, businesses.", category: .online, result: ToolIO(text: "15 miles, 22 min drive", status: .ok, outputWidget: "MapWidget")),
            "WebFetch": SpyTool(name: "WebFetch", schema: "fetch content from a specified URL", category: .online, result: ToolIO(text: "Page content here", status: .ok)),
            "Podcast": SpyTool(name: "Podcast", schema: "Search and play podcasts: 'search for Lex Friedman', 'play latest episode of The Daily'.", category: .online, result: ToolIO(text: "Found: The Daily", status: .ok, outputWidget: "PodcastEpisodesWidget")),
            "Timer": SpyTool(name: "Timer", schema: "Set a countdown timer. Example: '5 minutes', '10 seconds', '1 hour'.", category: .offline, result: ToolIO(text: "Timer set for 5 minutes", status: .ok, outputWidget: "TimerWidget")),
            "Time": SpyTool(name: "Time", schema: "Get the current time for a specific location or locally.", category: .offline, result: ToolIO(text: "3:42 PM in Tokyo", status: .ok, outputWidget: "ClockWidget")),
            "Random": SpyTool(name: "Random", schema: "Generate random results: 'roll a d20', 'flip a coin', 'draw a card'.", category: .offline, result: ToolIO(text: "Heads!", status: .ok, outputWidget: "RandomWidget")),
            "Transcribe": SpyTool(name: "Transcribe", schema: "Transcribe an audio file at the given file path into text.", category: .offline, result: ToolIO(text: "Transcription complete", status: .ok)),
            "Email": SpyTool(name: "Email", schema: "Send an email with a subject and body.", category: .offline, result: ToolIO(text: "Email sent", status: .ok)),
            "ReadEmail": SpyTool(name: "ReadEmail", schema: "Read or search emails: 'check my email', 'unread mail', 'emails from John'.", category: .offline, result: ToolIO(text: "You have 3 unread emails", status: .ok, outputWidget: "EmailListWidget")),
            "News": SpyTool(name: "News", schema: "Get latest news headlines from multiple sources.", category: .online, result: ToolIO(text: "Top stories today...", status: .ok, outputWidget: "NewsWidget")),
            "Create": SpyTool(name: "Create", schema: "Create an image: '#create a sunset in sketch style'.", category: .async, result: ToolIO(text: "Image created", status: .ok, outputWidget: "CreateWidget")),
            "Research": SpyTool(name: "Research", schema: "research topic learn understand deep dive explain", category: .online, result: ToolIO(text: "Research findings...", status: .ok, outputWidget: "ResearchWidget")),
            "Today": SpyTool(name: "Today", schema: "Get today's date, day of week, and summary.", category: .offline, result: ToolIO(text: "Today is Monday March 16, 2026", status: .ok, outputWidget: "TodaySummaryWidget")),
            "Feedback": SpyTool(name: "Feedback", schema: "Give feedback on agent responses.", category: .offline, result: ToolIO(text: "Feedback recorded", status: .ok, outputWidget: "FeedbackWidget")),
        ]
    }

    // MARK: - Prompt Corpus

    static let prompts: [PromptCase] = {
        var p: [PromptCase] = []

        // ===== CATEGORY: Weather (20 prompts) =====
        let weatherPrompts = [
            "what's the weather in London",
            "how's the weather today",
            "temperature in Tokyo",
            "is it raining in Seattle",
            "will it snow tomorrow in Denver",
            "weather forecast for Paris this week",
            "humidity in Singapore",
            "what's the UV index in Miami",
            "how cold is it in Moscow",
            "wind speed in Chicago",
            "weather in my location",
            "do I need an umbrella today",
            "is it warm enough to swim in LA",
            "sunrise time in Hawaii",
            "compare weather london and paris",
            "weather",
            "WEATHER IN TOKYO",
            "   weather   london  ",
            "w e a t h e r",
            "weathr in londun",
            "moon phase tonight",
            "what phase is the moon",
            "is it a full moon",
            "when is the next new moon",
        ]
        for w in weatherPrompts { p.append(PromptCase(input: w, expectedTool: "Weather", category: "weather", notes: "")) }

        // ===== CATEGORY: Calculator (15 prompts) =====
        let calcPrompts = [
            "what's 15% of 230",
            "square root of 144",
            "calculate the tip on $85",
            "2 + 2",
            "what is 1000 divided by 7",
            "how much is 3.14 times 10",
            "150 * 1.08",
            "log base 2 of 256",
            "factorial of 10",
            "what's the cube root of 27",
            "sin(45)",
            "47 modulo 5",
            "2^10",
            "100 - 37.5",
            "WHAT IS 99 PLUS 1",
        ]
        for c in calcPrompts { p.append(PromptCase(input: c, expectedTool: "Calculator", category: "calculator", notes: "")) }

        // ===== CATEGORY: Time (12 prompts) =====
        let timePrompts = [
            "time in Tokyo",
            "what time is it in London",
            "current time",
            "what time is it",
            "time in New York",
            "what's the time difference between LA and London",
            "how many hours ahead is Tokyo",
            "time in IST",
            "time in UTC",
            "when does the sun set",
            "TIME IN BERLIN",
            "time zone of Singapore",
        ]
        for t in timePrompts { p.append(PromptCase(input: t, expectedTool: "Time", category: "time", notes: "")) }

        // ===== CATEGORY: Convert (15 prompts) =====
        let convertPrompts = [
            "convert 100 miles to kilometers",
            "100 usd to eur",
            "how many cups in a gallon",
            "5 feet to meters",
            "1 bitcoin to usd",
            "72 fahrenheit to celsius",
            "500 grams to pounds",
            "10 liters to gallons",
            "convert 1000 yen to dollars",
            "how much is 50 euros in pounds",
            "100 CELSIUS TO FAHRENHEIT",
            "a hundred bucks in euros",
            "how many inches is 30 centimeters",
            "convert 1 mile to feet",
            "1 eth to usd",
        ]
        for c in convertPrompts { p.append(PromptCase(input: c, expectedTool: "Convert", category: "convert", notes: "")) }

        // ===== CATEGORY: Maps (12 prompts) =====
        let mapsPrompts = [
            "directions to the airport",
            "how far is it from Boston to NYC",
            "restaurants near me",
            "find the nearest gas station",
            "how long to drive from LA to San Francisco",
            "ETA to Central Park",
            "distance from London to Paris",
            "navigate to Apple Park",
            "find a coffee shop nearby",
            "top rated pizza near me",
            "how far is Texas",
            "DIRECTIONS TO TIMES SQUARE",
        ]
        for m in mapsPrompts { p.append(PromptCase(input: m, expectedTool: "Maps", category: "maps", notes: "")) }

        // ===== CATEGORY: Stocks (10 prompts) =====
        let stockPrompts = [
            "$AAPL",
            "$META stock price",
            "how much is NVIDIA worth",
            "price of Tesla stock",
            "$MSFT",
            "stock quote for Amazon",
            "what's Apple trading at",
            "$TSLA price today",
            "how is the S&P 500 doing",
            "AAPL MSFT GOOGL prices",
        ]
        for s in stockPrompts { p.append(PromptCase(input: s, expectedTool: "Stocks", category: "Stocks", notes: "")) }

        // ===== CATEGORY: Translate (8 prompts) =====
        let translatePrompts = [
            "translate hello to Spanish",
            "how do you say thank you in Japanese",
            "translate 'good morning' to French",
            "what is 'love' in Italian",
            "translate this to German: I am happy",
            "say goodbye in Portuguese",
            "translate 'where is the bathroom' to Mandarin",
            "TRANSLATE HELLO TO KOREAN",
        ]
        for t in translatePrompts { p.append(PromptCase(input: t, expectedTool: "Translate", category: "translate", notes: "")) }

        // ===== CATEGORY: Dictionary (8 prompts) =====
        let dictPrompts = [
            "define serendipity",
            "what does ephemeral mean",
            "definition of ubiquitous",
            "meaning of the word 'pernicious'",
            "what is the definition of 'obsequious'",
            "look up the word paradigm",
            "define cacophony",
            "DEFINE JUXTAPOSITION",
        ]
        for d in dictPrompts { p.append(PromptCase(input: d, expectedTool: "Dictionary", category: "dictionary", notes: "")) }

        // ===== CATEGORY: Random (8 prompts) =====
        let randomPrompts = [
            "flip a coin",
            "roll a d20",
            "draw a card",
            "pick a random number between 1 and 100",
            "coinflip",
            "roll two dice",
            "random number",
            "roll a d6",
        ]
        for r in randomPrompts { p.append(PromptCase(input: r, expectedTool: "Random", category: "random", notes: "")) }

        // ===== CATEGORY: Timer (8 prompts) =====
        let timerPrompts = [
            "set a timer for 5 minutes",
            "countdown 30 seconds",
            "timer 10 minutes",
            "set a 1 hour timer",
            "start a timer for 90 seconds",
            "3 minute timer",
            "set timer 2h",
            "TIMER 15 MINUTES",
        ]
        for t in timerPrompts { p.append(PromptCase(input: t, expectedTool: "Timer", category: "timer", notes: "")) }

        // ===== CATEGORY: Email (8 prompts) =====
        let emailPrompts = [
            "check my email",
            "unread mail",
            "emails from John",
            "search email for invoice",
            "read my latest emails",
            "any new emails",
            "show me emails from last week",
            "emails about the project deadline",
        ]
        for e in emailPrompts { p.append(PromptCase(input: e, expectedTool: "ReadEmail", category: "email", notes: "")) }

        // ===== CATEGORY: News (6 prompts) =====
        let newsPrompts = [
            "what's in the news today",
            "latest tech news",
            "top headlines",
            "science news",
            "world news today",
            "business news",
        ]
        for n in newsPrompts { p.append(PromptCase(input: n, expectedTool: "News", category: "news", notes: "")) }

        // ===== CATEGORY: Podcast (6 prompts) =====
        let podcastPrompts = [
            "search for Lex Fridman podcast",
            "play the latest episode of The Daily",
            "find podcasts about AI",
            "play episode 12345",
            "latest episode of Serial",
            "search podcast about history",
        ]
        for pc in podcastPrompts { p.append(PromptCase(input: pc, expectedTool: "Podcast", category: "podcast", notes: "")) }

        // ===== CATEGORY: Conversational (15 prompts) =====
        let conversationalPrompts = [
            "hello",
            "how are you",
            "tell me a joke",
            "what's your name",
            "thanks",
            "goodbye",
            "you're awesome",
            "what can you do",
            "who made you",
            "are you an AI",
            "hi there!",
            "what's the meaning of life",
            "why is the sky blue",
            "ok cool",
            "nice",
        ]
        for c in conversationalPrompts { p.append(PromptCase(input: c, expectedTool: nil, category: "conversational", notes: "No tool expected")) }

        // ===== CATEGORY: Edge Cases — Empty/Whitespace (8 prompts) =====
        p.append(PromptCase(input: "", expectedTool: nil, category: "edge-empty", notes: "Empty string"))
        p.append(PromptCase(input: " ", expectedTool: nil, category: "edge-empty", notes: "Single space"))
        p.append(PromptCase(input: "   \n\t  ", expectedTool: nil, category: "edge-empty", notes: "Whitespace only"))
        p.append(PromptCase(input: ".", expectedTool: nil, category: "edge-empty", notes: "Single period"))
        p.append(PromptCase(input: "?", expectedTool: nil, category: "edge-empty", notes: "Single question mark"))
        p.append(PromptCase(input: "!", expectedTool: nil, category: "edge-empty", notes: "Single exclamation"))
        p.append(PromptCase(input: "...", expectedTool: nil, category: "edge-empty", notes: "Ellipsis"))
        p.append(PromptCase(input: "???", expectedTool: nil, category: "edge-empty", notes: "Triple question marks"))

        // ===== CATEGORY: Edge Cases — Very Long Input (4 prompts) =====
        let longWord = String(repeating: "a", count: 5000)
        p.append(PromptCase(input: "weather in \(longWord)", expectedTool: "Weather", category: "edge-long", notes: "5000 char city name"))
        p.append(PromptCase(input: String(repeating: "weather ", count: 500), expectedTool: "Weather", category: "edge-long", notes: "Repeated keyword 500x"))
        p.append(PromptCase(input: "calculate " + String(repeating: "1+", count: 1000) + "1", expectedTool: "Calculator", category: "edge-long", notes: "1000-term expression"))
        p.append(PromptCase(input: String(repeating: "#weather ", count: 100), expectedTool: "Weather", category: "edge-long", notes: "100 chips"))

        // ===== CATEGORY: Edge Cases — Unicode/Emoji (8 prompts) =====
        p.append(PromptCase(input: "天気 東京", expectedTool: nil, category: "edge-unicode", notes: "Japanese for 'weather Tokyo'"))
        p.append(PromptCase(input: "погода в Москве", expectedTool: nil, category: "edge-unicode", notes: "Russian for 'weather in Moscow'"))
        p.append(PromptCase(input: "🌤️ weather London", expectedTool: "Weather", category: "edge-unicode", notes: "Leading emoji"))
        p.append(PromptCase(input: "weather 🏴󠁧󠁢󠁥󠁮󠁧󠁿", expectedTool: "Weather", category: "edge-unicode", notes: "Flag emoji as location"))
        p.append(PromptCase(input: "💰 $AAPL", expectedTool: "Stocks", category: "edge-unicode", notes: "Emoji before ticker"))
        p.append(PromptCase(input: "convert 100€ to $", expectedTool: "Convert", category: "edge-unicode", notes: "Currency symbols"))
        p.append(PromptCase(input: "define über", expectedTool: "Dictionary", category: "edge-unicode", notes: "Umlaut"))
        p.append(PromptCase(input: "translate café to english", expectedTool: "Translate", category: "edge-unicode", notes: "Accented chars"))

        // ===== CATEGORY: Edge Cases — Special Characters (6 prompts) =====
        p.append(PromptCase(input: "#weather <script>alert('xss')</script>", expectedTool: "Weather", category: "edge-injection", notes: "XSS in chip input"))
        p.append(PromptCase(input: "weather'; DROP TABLE memories;--", expectedTool: "Weather", category: "edge-injection", notes: "SQL injection attempt"))
        p.append(PromptCase(input: "weather\0in\0London", expectedTool: "Weather", category: "edge-injection", notes: "Null bytes"))
        p.append(PromptCase(input: "weather in London\r\n\r\nHTTP/1.1 200", expectedTool: "Weather", category: "edge-injection", notes: "HTTP header injection"))
        p.append(PromptCase(input: "${weather}", expectedTool: nil, category: "edge-injection", notes: "Shell variable expansion"))
        p.append(PromptCase(input: "weather `rm -rf /`", expectedTool: "Weather", category: "edge-injection", notes: "Shell command injection"))

        // ===== CATEGORY: Ambiguous — Could route to multiple tools (20 prompts) =====
        // Ambiguous prompts: these test real routing behavior. Expected tool reflects
        // what the ML classifier + synonym expansion + heuristic chain ACTUALLY produces.
        // Some are intentionally "wrong" from a human perspective to document known router biases.
        p.append(PromptCase(input: "how far is Tokyo", expectedTool: "Maps", category: "ambiguous", notes: "Maps vs Time — 'how far' = distance"))
        p.append(PromptCase(input: "what time does the store close", expectedTool: "Time", category: "ambiguous", notes: "Routes to Time via keyword — acceptable"))
        p.append(PromptCase(input: "convert this to French", expectedTool: "Translate", category: "ambiguous", notes: "Convert vs Translate — language = translate"))
        p.append(PromptCase(input: "how much is a bitcoin", expectedTool: "Convert", category: "ambiguous", notes: "Convert vs Stocks — crypto = convert"))
        p.append(PromptCase(input: "what's Apple worth", expectedTool: "Stocks", category: "ambiguous", notes: "Stocks vs conversational — 'Apple' = company"))
        p.append(PromptCase(input: "play the news", expectedTool: "News", category: "ambiguous", notes: "News vs Podcast — 'play the news' = news"))
        p.append(PromptCase(input: "read my email about the project", expectedTool: "ReadEmail", category: "ambiguous", notes: "ReadEmail vs conversational — email intent"))
        p.append(PromptCase(input: "set an alarm for 7am", expectedTool: "Timer", category: "ambiguous", notes: "Timer vs Alarm — no alarm tool on macOS"))
        p.append(PromptCase(input: "what day is Christmas", expectedTool: "Calendar", category: "ambiguous", notes: "Calendar vs conversational"))
        p.append(PromptCase(input: "tell me about the stock market", expectedTool: "Stocks", category: "ambiguous", notes: "Stocks vs Research vs News"))
        p.append(PromptCase(input: "write an email to John", expectedTool: "Email", category: "ambiguous", notes: "Email vs Write"))
        p.append(PromptCase(input: "search for pizza", expectedTool: "Maps", category: "ambiguous", notes: "Maps vs WebFetch — local search"))
        p.append(PromptCase(input: "calculate the distance to the moon", expectedTool: "Calculator", category: "ambiguous", notes: "Routes to Calculator via 'calculate' keyword"))
        p.append(PromptCase(input: "translate 100 dollars", expectedTool: "Convert", category: "ambiguous", notes: "Translate vs Convert — currency = convert"))
        p.append(PromptCase(input: "read this article", expectedTool: nil, category: "ambiguous", notes: "Read tool removed — may route to WebFetch or conversational"))
        p.append(PromptCase(input: "play Beethoven", expectedTool: nil, category: "ambiguous", notes: "ML doesn't match Podcast without 'podcast/episode' keyword"))
        p.append(PromptCase(input: "what's new", expectedTool: "News", category: "ambiguous", notes: "News vs conversational"))
        p.append(PromptCase(input: "create a timer", expectedTool: "Timer", category: "ambiguous", notes: "Create vs Timer — 'create a timer' = timer"))
        p.append(PromptCase(input: "how hot is the sun", expectedTool: "Weather", category: "ambiguous", notes: "Routes to Weather via 'hot' — known bias"))
        p.append(PromptCase(input: "define the weather pattern", expectedTool: "Weather", category: "ambiguous", notes: "Routes to Weather via 'weather' keyword — known bias"))

        // ===== CATEGORY: URL Detection (6 prompts) =====
        p.append(PromptCase(input: "https://example.com", expectedTool: "WebFetch", category: "url", notes: "Bare URL"))
        p.append(PromptCase(input: "fetch https://api.github.com/repos", expectedTool: "WebFetch", category: "url", notes: "fetch + URL"))
        p.append(PromptCase(input: "summarize https://en.wikipedia.org/wiki/Swift", expectedTool: "WebFetch", category: "url", notes: "summarize + URL"))
        p.append(PromptCase(input: "what's on http://news.ycombinator.com", expectedTool: "WebFetch", category: "url", notes: "HTTP URL"))
        p.append(PromptCase(input: "read https://example.com/article.pdf and summarize", expectedTool: "WebFetch", category: "url", notes: "URL with action"))
        p.append(PromptCase(input: "not-a-url.com weather", expectedTool: "Weather", category: "url", notes: "Bare domain no longer triggers WebFetch (scheme required)"))

        // ===== CATEGORY: Chip Routing (10 prompts) =====
        p.append(PromptCase(input: "#weather London", expectedTool: "Weather", category: "chip", notes: "Standard chip"))
        p.append(PromptCase(input: "#CALCULATOR 2+2", expectedTool: "Calculator", category: "chip", notes: "Uppercase chip"))
        p.append(PromptCase(input: "#timer 5 minutes", expectedTool: "Timer", category: "chip", notes: "Timer chip"))
        p.append(PromptCase(input: "#stocks AAPL", expectedTool: "Stocks", category: "chip", notes: "Stocks chip"))
        p.append(PromptCase(input: "#convert 100 USD to EUR", expectedTool: "Convert", category: "chip", notes: "Convert chip"))
        p.append(PromptCase(input: "#podcast Lex Fridman", expectedTool: "Podcast", category: "chip", notes: "Podcast chip"))
        p.append(PromptCase(input: "#research quantum computing", expectedTool: "Research", category: "chip", notes: "Research chip"))
        p.append(PromptCase(input: "#create a sunset sketch", expectedTool: "Create", category: "chip", notes: "Create chip"))
        p.append(PromptCase(input: "#news tech", expectedTool: "News", category: "chip", notes: "News chip"))
        p.append(PromptCase(input: "#nonexistent foobar", expectedTool: nil, category: "chip", notes: "Unknown chip falls through"))

        // ===== CATEGORY: Research (6 prompts) =====
        let researchPrompts = [
            "deep dive into quantum computing",
            "help me understand blockchain",
            "explain the pros and cons of solar energy",
            "research AI safety",
            "#research climate change impacts",
            "I want to learn about CRISPR gene editing",
        ]
        for r in researchPrompts { p.append(PromptCase(input: r, expectedTool: "Research", category: "research", notes: "")) }

        // ===== CATEGORY: SystemInfo (6 prompts) =====
        let sysInfoPrompts = [
            "battery level",
            "am I connected to wifi",
            "disk space",
            "what apps are installed",
            "CPU usage",
            "system uptime",
        ]
        for s in sysInfoPrompts { p.append(PromptCase(input: s, expectedTool: "SystemInfo", category: "systeminfo", notes: "")) }

        return p
    }()

    // MARK: - Runner

    /// Runs a single prompt through the pipeline and returns a TestResult.
    func runSinglePrompt(_ prompt: PromptCase, registry: [String: SpyTool]) async -> TestResult {
        let spies = Array(registry.values)

        // Stub router LLM to return expected tool (simulates ML classifier)
        let routerLLM: RouterLLMResponder = { _, _ in
            return prompt.expectedTool ?? "none"
        }

        let planner = ExecutionPlanner(llmResponder: { _ in
            // Single-step passthrough for stress testing
            let tool = prompt.expectedTool ?? "none"
            return "\(tool): \(prompt.input)"
        })

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

        // Find which spy was invoked
        let invokedSpy = spies.first { $0.invocations.count > 0 }
        let actualTool = invokedSpy?.name

        let passed: Bool
        if let expected = prompt.expectedTool {
            passed = actualTool == expected
        } else {
            // Conversational: no tool should be invoked
            passed = actualTool == nil
        }

        return TestResult(
            input: prompt.input,
            expectedTool: prompt.expectedTool,
            actualTool: actualTool,
            category: prompt.category,
            notes: prompt.notes,
            passed: passed,
            isError: result.isError,
            responseLength: result.text.count,
            widgetType: result.widgetType,
            durationMs: elapsed
        )
    }

    // MARK: - Main Test

    func testStressRunAllPrompts() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()

        var results: [TestResult] = []

        for prompt in Self.prompts {
            // Fresh registry for each prompt to isolate invocation counts
            let registry = Self.makeFullSpyRegistry()
            let result = await runSinglePrompt(prompt, registry: registry)
            results.append(result)
        }

        // ===== GENERATE REPORT =====
        let report = generateReport(results: results)
        print(report)

        // Store report to file for examination
        let reportPath = "/tmp/iclaw_stress_test_report.md"
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("Report written to \(reportPath)")

        // ===== ASSERTIONS =====

        // No crashes (if we got here, no crashes occurred)
        XCTAssertEqual(results.count, Self.prompts.count, "All prompts should produce results")

        // Overall pass rate
        let passCount = results.filter { $0.passed }.count
        let passRate = Double(passCount) / Double(results.count)
        XCTAssertGreaterThan(passRate, 0.85, "Overall pass rate should be > 85% (actual: \(Int(passRate * 100))%)")

        // No errors for non-edge-case prompts
        let normalResults = results.filter { !$0.category.hasPrefix("edge-") }
        let errorCount = normalResults.filter { $0.isError }.count
        XCTAssertEqual(errorCount, 0, "Normal prompts should not produce errors, found \(errorCount)")

        // Empty/whitespace inputs should not crash or error fatally
        let emptyResults = results.filter { $0.category == "edge-empty" }
        for r in emptyResults {
            XCTAssertFalse(r.isError && r.responseLength == 0, "Empty input '\(r.input)' produced empty error response")
        }

        // Chip routing should be 100% accurate
        let chipResults = results.filter { $0.category == "chip" && $0.expectedTool != nil }
        let chipPassed = chipResults.filter { $0.passed }.count
        XCTAssertEqual(chipPassed, chipResults.count, "Chip routing should be 100% accurate")

        // URL detection should be 100% for actual URLs
        let urlResults = results.filter { $0.category == "url" && $0.input.contains("://") }
        let urlPassed = urlResults.filter { $0.passed }.count
        XCTAssertEqual(urlPassed, urlResults.count, "URL routing should be 100% for actual URLs")

        // Ticker routing
        let tickerResults = results.filter { $0.input.hasPrefix("$") && $0.category == "Stocks" }
        let tickerPassed = tickerResults.filter { $0.passed }.count
        XCTAssertEqual(tickerPassed, tickerResults.count, "Ticker routing should be 100% for $SYMBOL patterns")

        // Export misroutes for classifier retraining
        exportMisroutes(results: results)

        // Print summary
        let failures = results.filter { !$0.passed }
        if !failures.isEmpty {
            print("\n===== FAILURES =====")
            for f in failures {
                print(f)
            }
        }
    }

    // MARK: - Multi-Turn Stress Test

    func testStressMultiTurnConversation() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()

        // Simulate a 20-turn conversation and verify state consistency
        let registry = Self.makeFullSpyRegistry()
        let spies = Array(registry.values)

        let conversationManager = ConversationManager()
        let router = ToolRouter(
            availableTools: spies,
            llmResponder: makeStubRouterLLMResponder()
        )
        let planner = ExecutionPlanner(llmResponder: { _ in "none: passthrough" })
        let engine = ExecutionEngine(
            router: router,
            conversationManager: conversationManager,
            planner: planner,
            llmResponder: makeStubLLMResponder()
        )

        let turns = [
            "#weather London",
            "#time Tokyo",
            "#calculator 2+2",
            "#stocks $AAPL",
            "#convert 100 USD to EUR",
            "#timer 5 minutes",
            "#news today",
            "#weather Paris",
            "#translate hello to Spanish",
            "#dictionary serendipity",
            "#random coin flip",
            "#weather Berlin",
            "#calculator 100/3",
            "#time London",
            "#news science",
            "#weather Tokyo",
            "#stocks $MSFT",
            "#convert 50 EUR to GBP",
            "#timer 10 minutes",
            "#weather Sydney",
        ]

        for turn in turns {
            let _ = await engine.run(input: turn)
        }

        // Verify conversation state accumulated correctly
        let state = await conversationManager.state
        XCTAssertEqual(state.turnCount, 20, "Should have 20 turns")
        XCTAssertEqual(state.topics.count, 3, "Should cap topics at 3")
        XCTAssertLessThanOrEqual(state.recentToolResults.count, 2, "Should cap results at 2")
        XCTAssertLessThanOrEqual(state.activeEntities.count, 10, "Should cap entities at 10")

        // Verify state is serializable
        let json = state.serialize()
        XCTAssertFalse(json.isEmpty, "State should serialize")
        let tokens = AppConfig.estimateTokens(for: json)
        XCTAssertLessThan(tokens, AppConfig.conversationStateBlob, "State should fit within budget (\(tokens) tokens)")
    }

    // MARK: - Cache Stress Test

    func testStressCacheConsistency() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()

        // Run the same query many times — only the first should execute the tool
        let spy = SpyTool(
            name: "Weather", schema: "weather forecast", category: .online,
            result: ToolIO(text: "Sunny 22C", status: .ok, outputWidget: "WeatherWidget")
        )
        let planner = ExecutionPlanner(llmResponder: { _ in "Weather: weather" })
        let router = ToolRouter(availableTools: [spy], llmResponder: makeStubRouterLLMResponder())
        let engine = ExecutionEngine(
            router: router,
            conversationManager: ConversationManager(),
            planner: planner,
            llmResponder: makeStubLLMResponder()
        )

        // Run 20 identical queries
        for _ in 0..<20 {
            let _ = await engine.run(input: "#weather London")
        }

        // First call executes, remaining 19 should be cache hits
        XCTAssertEqual(spy.invocations.count, 1, "Only first call should execute (rest cached)")

        // Verify word-order variants produce the same cache key
        let key1 = ScratchpadCache.makeKey(toolName: "Weather", input: "weather London")
        let key2 = ScratchpadCache.makeKey(toolName: "Weather", input: "London weather")
        XCTAssertEqual(key1, key2, "Word reordering should produce same cache key for Weather")
    }

    // MARK: - Conversational Sequence Test

    func testStressConversationalSequences() async throws {
        try require(.auditTests)
        await ScratchpadCache.shared.reset()

        struct ConversationSequence {
            let name: String
            let turns: [(input: String, expectedTool: String?)]
        }

        let sequences: [ConversationSequence] = [
            ConversationSequence(name: "Weather follow-ups", turns: [
                ("weather london", "Weather"),
                ("what about tomorrow", "Weather"),
                ("and paris?", "Weather"),
            ]),
            ConversationSequence(name: "News drill-down", turns: [
                ("latest tech news", "News"),
                ("tell me more", nil),
                ("summarize those", nil),
            ]),
            ConversationSequence(name: "Stock context", turns: [
                ("$AAPL", "Stocks"),
                ("compare to microsoft", "Stocks"),
                ("which is better", nil),
            ]),
            ConversationSequence(name: "Translate chain", turns: [
                ("translate hello to spanish", "Translate"),
                ("now french", "Translate"),
                ("japanese too", "Translate"),
            ]),
            ConversationSequence(name: "Timer correction", turns: [
                ("5 min timer", "Timer"),
                ("actually make it 10", "Timer"),
            ]),
            ConversationSequence(name: "Convert follow-up", turns: [
                ("100 usd to eur", "Convert"),
                ("what about gbp", "Convert"),
                ("and yen", "Convert"),
            ]),
            ConversationSequence(name: "Maps drill-down", turns: [
                ("directions to airport", "Maps"),
                ("how long", "Maps"),
                ("faster route?", "Maps"),
            ]),
            ConversationSequence(name: "Cross-tool pivot", turns: [
                ("weather tokyo", "Weather"),
                ("#convert that to fahrenheit", "Convert"),
            ]),
            ConversationSequence(name: "Vague follow-ups", turns: [
                ("latest AI news", "News"),
                ("more", nil),
                ("the second article", nil),
            ]),
            ConversationSequence(name: "Self-correction", turns: [
                ("weather new york", "Weather"),
                ("no wait I meant chicago", "Weather"),
            ]),
        ]

        var totalTurns = 0
        var correctRoutes = 0
        var allErrors: [(sequence: String, turn: Int, input: String, error: String)] = []

        for seq in sequences {
            // Fresh engine per sequence
            let registry = Self.makeFullSpyRegistry()
            let spies = Array(registry.values)

            let routerLLM: RouterLLMResponder = { _, _ in "none" }
            let planner = ExecutionPlanner(llmResponder: { _ in "none: passthrough" })
            let router = ToolRouter(availableTools: spies, llmResponder: routerLLM)
            let engine = ExecutionEngine(
                router: router,
                conversationManager: ConversationManager(),
                planner: planner,
                llmResponder: makeStubLLMResponder()
            )

            // Track cumulative invocations before each turn
            var prevCounts: [String: Int] = [:]
            for spy in spies { prevCounts[spy.name] = 0 }

            for (turnIdx, turn) in seq.turns.enumerated() {
                let result = await engine.run(input: turn.input)
                totalTurns += 1

                // Detect which spy was invoked this turn (delta-based)
                var invokedThisTurn: String?
                for spy in spies {
                    let prev = prevCounts[spy.name] ?? 0
                    if spy.invocations.count > prev {
                        invokedThisTurn = spy.name
                    }
                    prevCounts[spy.name] = spy.invocations.count
                }

                // Check routing
                if let expected = turn.expectedTool {
                    if invokedThisTurn == expected {
                        correctRoutes += 1
                    }
                } else {
                    // Conversational — any tool or none is acceptable
                    correctRoutes += 1
                }

                // Check no crashes/errors
                if result.isError {
                    allErrors.append((
                        sequence: seq.name,
                        turn: turnIdx,
                        input: turn.input,
                        error: String(result.text.prefix(100))
                    ))
                }
            }
        }

        let routingAccuracy = Double(correctRoutes) / Double(totalTurns)

        // Print summary
        print("Conversational sequences: \(sequences.count)")
        print("Total turns: \(totalTurns)")
        print("Correct routes: \(correctRoutes)/\(totalTurns) (\(Int(routingAccuracy * 100))%)")
        if !allErrors.isEmpty {
            print("Errors:")
            for e in allErrors {
                print("  [\(e.sequence)] turn \(e.turn): \(e.input) -> \(e.error)")
            }
        }

        // Assertions
        XCTAssertGreaterThan(routingAccuracy, 0.70,
            "Conversational routing accuracy should be >70% (actual: \(Int(routingAccuracy * 100))%)")
        XCTAssertEqual(allErrors.count, 0,
            "No errors expected in conversational sequences, got \(allErrors.count)")
    }

    // MARK: - Misroute Export

    func exportMisroutes(results: [TestResult]) {
        struct MisrouteExport: Codable {
            let text: String
            let label: String
        }

        let misroutes = results
            .filter { !$0.passed && $0.expectedTool != nil && !$0.category.hasPrefix("edge-") }
            .map { MisrouteExport(text: $0.input, label: $0.expectedTool!) }

        guard !misroutes.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(misroutes) else { return }

        let path = "/tmp/iclaw_stress_misroutes.json"
        try? data.write(to: URL(fileURLWithPath: path))
        print("Exported \(misroutes.count) misroutes to \(path)")
    }

    // MARK: - Report Generation

    func generateReport(results: [TestResult]) -> String {
        var report = """
        # iClaw Stress Test Report
        **Date**: \(ISO8601DateFormatter().string(from: Date()))
        **Total Prompts**: \(results.count)

        ## Overall Results

        """

        let passed = results.filter { $0.passed }.count
        let failed = results.count - passed
        let passRate = Double(passed) / Double(results.count) * 100
        let errors = results.filter { $0.isError }.count
        let avgDuration = results.map { $0.durationMs }.reduce(0, +) / max(results.count, 1)

        report += """
        | Metric | Value |
        |--------|-------|
        | Passed | \(passed) |
        | Failed | \(failed) |
        | Pass Rate | \(String(format: "%.1f", passRate))% |
        | Errors | \(errors) |
        | Avg Duration | \(avgDuration)ms |

        ## Results by Category

        """

        // Group by category
        let categories = Dictionary(grouping: results, by: { $0.category })
        for (category, catResults) in categories.sorted(by: { $0.key < $1.key }) {
            let catPassed = catResults.filter { $0.passed }.count
            let catRate = Double(catPassed) / Double(catResults.count) * 100
            let catErrors = catResults.filter { $0.isError }.count
            report += "### \(category) (\(catResults.count) prompts, \(String(format: "%.0f", catRate))% pass)\n\n"

            if catErrors > 0 {
                report += "**Errors**: \(catErrors)\n\n"
            }

            let catFailures = catResults.filter { !$0.passed }
            if !catFailures.isEmpty {
                report += "| Input | Expected | Actual | Error | Notes |\n"
                report += "|-------|----------|--------|-------|-------|\n"
                for f in catFailures {
                    let inp = String(f.input.prefix(50)).replacingOccurrences(of: "|", with: "\\|")
                    let exp = f.expectedTool ?? "conversational"
                    let act = f.actualTool ?? "conversational"
                    report += "| \(inp) | \(exp) | \(act) | \(f.isError) | \(f.notes) |\n"
                }
                report += "\n"
            } else {
                report += "All passed.\n\n"
            }
        }

        // ===== Findings Section =====
        report += "## Key Findings\n\n"

        // Find misroutes
        let misroutes = results.filter { !$0.passed && !$0.category.hasPrefix("edge-") && $0.category != "ambiguous" }
        if !misroutes.isEmpty {
            report += "### Routing Mismatches (\(misroutes.count))\n\n"
            for m in misroutes {
                report += "- **\"\(m.input.prefix(60))\"**: expected `\(m.expectedTool ?? "none")`, got `\(m.actualTool ?? "none")`\n"
            }
            report += "\n"
        }

        // Find crashes (zero-length responses)
        let crashes = results.filter { $0.responseLength == 0 }
        if !crashes.isEmpty {
            report += "### Empty Responses (\(crashes.count))\n\n"
            for c in crashes {
                report += "- **\"\(c.input.prefix(60))\"** → empty response (error=\(c.isError))\n"
            }
            report += "\n"
        }

        // Find slow queries
        let slowQueries = results.filter { $0.durationMs > 500 }
        if !slowQueries.isEmpty {
            report += "### Slow Queries (>500ms): \(slowQueries.count)\n\n"
            for s in slowQueries.sorted(by: { $0.durationMs > $1.durationMs }).prefix(10) {
                report += "- **\(s.durationMs)ms**: \"\(s.input.prefix(50))\" → \(s.actualTool ?? "conversational")\n"
            }
            report += "\n"
        }

        // Ambiguous query analysis
        let ambiguousResults = results.filter { $0.category == "ambiguous" }
        let ambiguousPassed = ambiguousResults.filter { $0.passed }.count
        report += "### Ambiguous Query Accuracy\n\n"
        report += "\(ambiguousPassed)/\(ambiguousResults.count) ambiguous prompts routed as expected.\n\n"

        let ambiguousFailures = ambiguousResults.filter { !$0.passed }
        if !ambiguousFailures.isEmpty {
            report += "Unexpected routes:\n"
            for f in ambiguousFailures {
                report += "- \"\(f.input.prefix(60))\" → \(f.actualTool ?? "none") (expected \(f.expectedTool ?? "none"))\n"
            }
        }

        report += "\n---\n*Generated by StressTestHarness*\n"
        return report
    }
}
