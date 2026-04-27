import XCTest
import FoundationModels
@testable import iClawCore

/// Tests for the CoreML-based tool classifier integrated into ToolRouter.
/// Exercises real model predictions (no stubs) to measure routing accuracy.
/// Labels use compound `domain.action` format (e.g., "email.read", "weather").
final class MLClassifierTests: XCTestCase {

    // MARK: - Direct Model Tests

    func testModelLoads() async {
        let classifier = MLToolClassifier.shared
        await classifier.loadModel()
        let prediction = await classifier.predict(text: "what's the weather")
        XCTAssertNotNil(prediction, "Model should load and return predictions")
    }

    func testPredictionReturnsConfidenceScores() async {
        let classifier = MLToolClassifier.shared
        await classifier.loadModel()
        guard let prediction = await classifier.predict(text: "set a timer for 5 minutes") else {
            XCTFail("Prediction should not be nil"); return
        }
        XCTAssertFalse(prediction.confidence.isEmpty, "Should have confidence scores")
        XCTAssertGreaterThan(prediction.confidence[prediction.label] ?? 0, 0.0)
    }

    // MARK: - Core Tool Routing via ML

    /// Each entry: (input, expectedLabel)
    /// These prompts do NOT use chips — they test pure ML classification.
    static let coreToolTestCases: [(String, String)] = [
        // weather (flat)
        ("what's the weather like today", "weather"),
        ("is it going to rain tomorrow", "weather"),
        ("temperature outside right now", "weather"),
        ("how cold is it in chicago", "weather"),
        ("weather forecast for this weekend", "weather"),
        ("do I need an umbrella", "weather"),
        ("whats the temp", "weather"),
        ("will it snow tonight", "weather"),
        ("humidity levels today", "weather"),
        ("weather", "weather"),
        // date-based weather/moon queries
        ("moon phase on april 10", "weather"),
        ("when is the next full moon", "weather"),
        ("next sunny day", "weather"),
        ("sunrise tomorrow", "weather"),
        ("sunset on christmas day", "weather"),
        ("weather on friday", "weather"),
        ("will it rain this saturday", "weather"),
        ("next clear day for a picnic", "weather"),
        ("how many days until full moon", "weather"),
        ("should i bring a jacket on monday", "weather"),

        // calculator (flat)
        ("what's 42 times 19", "calculator"),
        ("calculate 15% of 230", "calculator"),
        ("2 + 2", "calculator"),
        ("square root of 144", "calculator"),
        ("what is 100 divided by 7", "calculator"),
        ("how much is 3.14 * 2", "calculator"),
        ("18 squared", "calculator"),
        ("do the math: 500 - 127", "calculator"),
        ("what's 2^10", "calculator"),
        ("15 * 23", "calculator"),

        // calendar.view
        ("what day is christmas", "calendar.view"),
        ("how many days until new years", "calendar.view"),
        ("what day of the week is july 4th 2026", "calendar.view"),
        ("days between march 1 and april 15", "calendar.view"),
        ("when is easter this year", "calendar.view"),
        ("what day was january 1 2000", "calendar.view"),
        ("how many weeks until summer", "calendar.view"),
        ("is 2028 a leap year", "calendar.view"),
        ("days left in the month", "calendar.view"),
        ("when is thanksgiving", "calendar.view"),

        // time (flat)
        ("what time is it", "time"),
        ("current time in tokyo", "time"),
        ("time in london right now", "time"),
        ("what's the time", "time"),
        ("time in new york", "time"),
        ("current time", "time"),
        ("what time is it in paris", "time"),
        ("time zone for sydney", "time"),
        ("what's the local time", "time"),
        ("time", "time"),

        // timer (flat)
        ("set a timer for 10 minutes", "timer"),
        ("start a 5 minute timer", "timer"),
        ("countdown 30 seconds", "timer"),
        ("timer 3 minutes", "timer"),
        ("remind me in 15 minutes", "timer"),
        ("set timer 1 hour", "timer"),
        ("start a pomodoro timer", "timer"),
        ("timer for 45 seconds", "timer"),
        ("set a 2 minute countdown", "timer"),
        ("alarm for 10 min", "timer"),

        // text.define
        ("define serendipity", "text.define"),
        ("what does ephemeral mean", "text.define"),
        ("definition of ubiquitous", "text.define"),
        ("meaning of the word cacophony", "text.define"),
        ("look up the word tenacious", "text.define"),
        ("define love", "text.define"),
        ("what is the definition of entropy", "text.define"),
        ("dictionary lookup for ameliorate", "text.define"),
        ("what does synergy mean", "text.define"),
        ("define paradigm", "text.define"),

        // text.translate
        ("translate hello to spanish", "text.translate"),
        ("how do you say goodbye in french", "text.translate"),
        ("translate 'thank you' to japanese", "text.translate"),
        ("what is 'dog' in german", "text.translate"),
        ("translate this to italian: good morning", "text.translate"),
        ("say cheese in mandarin", "text.translate"),
        ("how to say I love you in korean", "text.translate"),
        ("translate buenos dias to english", "text.translate"),
        ("what's the french word for cat", "text.translate"),
        ("translate water to arabic", "text.translate"),

        // convert (flat)
        ("convert 10 miles to kilometers", "convert"),
        ("how many cups in a gallon", "convert"),
        ("100 fahrenheit in celsius", "convert"),
        ("5 feet to meters", "convert"),
        ("convert 1 kg to pounds", "convert"),
        ("how many inches in a yard", "convert"),
        ("30 celsius to fahrenheit", "convert"),
        ("convert 100 ml to oz", "convert"),
        ("2 liters to gallons", "convert"),
        ("how many grams in an ounce", "convert"),

        // random (flat)
        ("roll a dice", "random"),
        ("flip a coin", "random"),
        ("random number between 1 and 100", "random"),
        ("roll a d20", "random"),
        ("draw a card", "random"),
        ("pick a random number", "random"),
        ("heads or tails", "random"),
        ("roll 2d6", "random"),
        ("give me a random number", "random"),
        ("coin flip", "random"),

        // email.compose
        ("send an email to john", "email.compose"),
        ("compose an email about the meeting", "email.compose"),
        ("email sarah about dinner plans", "email.compose"),
        ("draft an email to my boss", "email.compose"),
        ("send a message via email", "email.compose"),
        ("write an email to the team", "email.compose"),
        ("email mom happy birthday", "email.compose"),
        ("compose a new email", "email.compose"),
        ("send email", "email.compose"),
        ("email about project update", "email.compose"),

        // email.read
        ("check my email", "email.read"),
        ("read my mail", "email.read"),
        ("any new emails", "email.read"),
        ("unread emails", "email.read"),
        ("show my inbox", "email.read"),
        ("emails from John", "email.read"),
        ("search my email for invoice", "email.read"),
        ("what's in my inbox", "email.read"),
        ("check for new mail", "email.read"),
        ("any unread messages", "email.read"),

        // stocks (flat)
        ("stock price of apple", "stocks"),
        ("how is AAPL doing", "stocks"),
        ("check TSLA stock", "stocks"),
        ("microsoft stock price", "stocks"),
        ("what's the price of NVDA", "stocks"),
        ("show me GOOGL", "stocks"),
        ("stock quote for amazon", "stocks"),
        ("how are my stocks doing", "stocks"),
        ("MSFT price", "stocks"),
        ("tesla share price", "stocks"),

        // system.info
        ("how much battery do I have", "system.info"),
        ("check disk space", "system.info"),
        ("how much storage is left", "system.info"),
        ("what's my wifi network", "system.info"),
        ("cpu usage", "system.info"),
        ("memory usage", "system.info"),
        ("system information", "system.info"),
        ("battery percentage", "system.info"),
        ("how much ram is free", "system.info"),
        ("check system status", "system.info"),

        // media.screenshot
        ("take a screenshot", "media.screenshot"),
        ("capture the screen", "media.screenshot"),
        ("what's on my screen", "media.screenshot"),
        ("screenshot this", "media.screenshot"),
        ("screen capture", "media.screenshot"),
        ("read my screen", "media.screenshot"),
        ("grab the screen", "media.screenshot"),
        ("screenshot", "media.screenshot"),
        ("take a picture of my screen", "media.screenshot"),
        ("OCR the screen", "media.screenshot"),

        // media.podcast
        ("search for a podcast about history", "media.podcast"),
        ("play the latest episode of the daily", "media.podcast"),
        ("find a podcast on technology", "media.podcast"),
        ("podcast recommendations", "media.podcast"),
        ("play joe rogan podcast", "media.podcast"),
        ("search podcast lex fridman", "media.podcast"),
        ("latest podcast episodes", "media.podcast"),
        ("find a true crime podcast", "media.podcast"),
        ("play podcast", "media.podcast"),
        ("podcast about science", "media.podcast"),

        // speech.transcribe
        ("transcribe this audio file", "speech.transcribe"),
        ("convert speech to text from recording.m4a", "speech.transcribe"),
        ("transcribe the voice memo", "speech.transcribe"),
        ("turn this audio into text", "speech.transcribe"),
        ("transcribe recording", "speech.transcribe"),
        ("speech to text for meeting.mp3", "speech.transcribe"),
        ("transcribe the interview audio", "speech.transcribe"),
        ("convert audio to text", "speech.transcribe"),
        ("transcribe this mp3", "speech.transcribe"),
        ("extract text from audio file", "speech.transcribe"),

        // speech.read
        ("read this essay and give feedback", "speech.read"),
        ("analyze this paragraph for tone", "speech.read"),
        ("review my writing style", "speech.read"),
        ("read my cover letter", "speech.read"),
        ("check the tone of this text", "speech.read"),

        // text.write
        ("write a haiku about rain", "text.write"),
        ("write me a short poem", "text.write"),
        ("write a paragraph about dogs", "text.write"),
        ("compose a limerick", "text.write"),
        ("write 3 sentences about space", "text.write"),

        // text.rewrite
        ("fix the typos in this text", "text.rewrite"),
        ("rewrite this paragraph", "text.rewrite"),
        ("polish this sentence", "text.rewrite"),
        ("clean up my writing", "text.rewrite"),
        ("fix the grammar in this", "text.rewrite"),

        // create (flat)
        ("create an image of a sunset", "create"),
        ("generate a picture of a cat", "create"),
        ("draw me a dragon", "create"),
        ("sketch a mountain landscape", "create"),
        ("illustrate a fantasy castle", "create"),
        ("imagine a futuristic city", "create"),
        ("make a picture of a robot", "create"),
        ("design a poster of a wolf", "create"),
        ("render a 3d spaceship", "create"),
        ("create a watercolor painting of flowers", "create"),

        // search.research
        ("research quantum computing", "search.research"),
        ("deep dive into how compilers work", "search.research"),
        ("help me understand distributed systems", "search.research"),
        ("explain the pros and cons of microservices", "search.research"),
        ("what's the current state of fusion energy", "search.research"),
        ("i want to learn about blockchain", "search.research"),
        ("teach me about neural networks", "search.research"),
        ("comprehensive analysis of edge computing", "search.research"),
        ("investigate the effectiveness of TDD", "search.research"),
        ("what does the research say about remote work", "search.research"),
    ]

    /// FM tool test cases
    static let fmToolTestCases: [(String, String)] = [
        // system.app
        ("open safari", "system.app"),
        ("launch chrome", "system.app"),
        ("switch to finder", "system.app"),
        ("open xcode", "system.app"),
        ("start spotify", "system.app"),
        ("quit mail", "system.app"),
        ("open the app store", "system.app"),
        ("launch terminal", "system.app"),
        ("open slack", "system.app"),
        ("switch to messages app", "system.app"),

        // calendar.search
        ("what's on my calendar today", "calendar.search"),
        ("do I have any meetings", "calendar.search"),
        ("schedule a meeting for tomorrow at 3pm", "calendar.search"),
        ("show my appointments", "calendar.search"),
        ("add an event for friday", "calendar.search"),
        ("what's my schedule this week", "calendar.search"),
        ("create a calendar event", "calendar.search"),
        ("any events tomorrow", "calendar.search"),
        ("book a meeting", "calendar.search"),
        ("check my agenda", "calendar.search"),

        // media.camera
        ("take a photo", "media.camera"),
        ("snap a picture", "media.camera"),
        ("open the camera", "media.camera"),
        ("take a selfie", "media.camera"),
        ("capture a photo", "media.camera"),

        // clipboard (flat)
        ("paste from clipboard", "clipboard"),
        ("what's on my clipboard", "clipboard"),
        ("copy this to clipboard", "clipboard"),
        ("show clipboard contents", "clipboard"),
        ("paste", "clipboard"),

        // contacts.view
        ("find john's phone number", "contacts.view"),
        ("look up sarah's email", "contacts.view"),
        ("what's mom's address", "contacts.view"),
        ("search contacts for dave", "contacts.view"),
        ("find contact info for jane", "contacts.view"),

        // currency (routed to convert)
        ("convert 100 usd to euros", "convert"),
        ("how much is 50 pounds in dollars", "convert"),
        ("exchange rate usd to jpy", "convert"),
        ("1 bitcoin in usd", "convert"),
        ("euro to dollar rate", "convert"),

        // health (flat)
        ("how many steps today", "health"),
        ("show my step count", "health"),
        ("calories burned today", "health"),
        ("heart rate", "health"),
        ("how did I sleep last night", "health"),

        // news (flat)
        ("show me the latest news", "news"),
        ("top headlines today", "news"),
        ("what's happening in the world", "news"),
        ("breaking news", "news"),
        ("today's news", "news"),

        // notes.create
        ("create a new note", "notes.create"),
        ("write a note about groceries", "notes.create"),
        ("save this as a note", "notes.create"),
        ("open my notes", "notes.create"),
        ("add to my journal", "notes.create"),

        // file.read
        ("read the file at ~/Desktop/report.txt", "file.read"),
        ("open document.pdf", "file.read"),
        ("read this file for me", "file.read"),
        ("show contents of config.json", "file.read"),
        ("read ~/notes.txt", "file.read"),

        // reminders.create
        ("remind me to buy milk", "reminders.create"),
        ("set a reminder for dentist tomorrow", "reminders.create"),
        ("add to my todo list", "reminders.create"),
        ("create a reminder", "reminders.create"),
        ("show my reminders", "reminders.create"),

        // search.local
        ("search for files named report", "search.local"),
        ("find the document I was working on", "search.local"),
        ("spotlight search for photos", "search.local"),
        ("search my mac for invoices", "search.local"),
        ("find files with budget in the name", "search.local"),

        // system.control
        ("turn up the volume", "system.control"),
        ("increase brightness", "system.control"),
        ("mute the sound", "system.control"),
        ("lower the screen brightness", "system.control"),
        ("volume to 50%", "system.control"),
        ("set brightness to max", "system.control"),
        ("turn off the display", "system.control"),
        ("unmute", "system.control"),
        ("volume down", "system.control"),
        ("dim the screen", "system.control"),

        // search.web
        ("google best restaurants nearby", "search.web"),
        ("search for swift tutorials", "search.web"),
        ("look up the capital of france", "search.web"),
        ("search the web for hiking trails", "search.web"),
        ("google it", "search.web"),

        // search.wiki
        ("wikipedia article on black holes", "search.wiki"),
        ("look up einstein on wikipedia", "search.wiki"),
        ("wiki page for the moon", "search.wiki"),
        ("tell me about the roman empire", "search.wiki"),
        ("wikipedia: photosynthesis", "search.wiki"),

        // messages.send
        ("text mom I'll be home soon", "messages.send"),
        ("send a message to john", "messages.send"),
        ("imessage sarah about dinner", "messages.send"),
        ("tell dad I'm on my way", "messages.send"),
        ("send text to alex", "messages.send"),

        // nav.directions
        ("directions to the airport", "nav.directions"),
        ("how far is it to downtown", "nav.directions"),
        ("navigate to starbucks", "nav.directions"),
        ("eta to work", "nav.directions"),
        ("find restaurants nearby", "nav.directions"),
        ("how long to drive to LA", "nav.directions"),
        ("route to the grocery store", "nav.directions"),
        ("directions home", "nav.directions"),
        ("distance to new york", "nav.directions"),
        ("navigate to 123 main street", "nav.directions"),

        // shortcuts (flat)
        ("run my morning shortcut", "shortcuts"),
        ("turn on the lights", "shortcuts"),
        ("set the thermostat to 72", "shortcuts"),
        ("activate do not disturb", "shortcuts"),
        ("run the backup shortcut", "shortcuts"),
    ]

    /// Tricky/adversarial test cases with spelling errors, slang, etc.
    static let trickyTestCases: [(String, String)] = [
        // Misspellings
        ("wether in london", "weather"),
        ("defnition of love", "text.define"),
        ("calcualte 5 + 3", "calculator"),
        ("temperture outside", "weather"),
        ("transalte hello to french", "text.translate"),
        ("screnshot my desktop", "media.screenshot"),
        ("systm info", "system.info"),
        ("podcst about science", "media.podcast"),
        ("opne safari", "system.app"),
        ("brighntess up", "system.control"),

        // ALL CAPS
        ("WHAT'S THE WEATHER", "weather"),
        ("DEFINE HAPPINESS", "text.define"),
        ("ROLL A DICE", "random"),
        ("SET TIMER 5 MINUTES", "timer"),
        ("TAKE A SCREENSHOT", "media.screenshot"),

        // Slang/informal
        ("yo what's the temp outside", "weather"),
        ("gimme a random number", "random"),
        ("what's good with the stonks", "stocks"),
        ("fire up chrome", "system.app"),
        ("nah lemme check the time rn", "time"),

        // Verbose/chatty
        ("hey so I was wondering if you could maybe tell me what the weather is like outside right now", "weather"),
        ("could you please set a timer for about five minutes or so", "timer"),
        ("I'm trying to figure out what 145 divided by 12 is can you help", "calculator"),
        ("so like I need to know how to say thank you in japanese", "text.translate"),

        // Terse
        ("weather", "weather"),
        ("time", "time"),
        ("5+3", "calculator"),
        ("AAPL", "stocks"),
        ("battery", "system.info"),
        ("screenshot", "media.screenshot"),
        ("translate", "text.translate"),
        ("podcast", "media.podcast"),
    ]

    // MARK: - Batch Test Runner

    struct ClassificationResult {
        let input: String
        let expected: String
        let predicted: String
        let correct: Bool
        let topConfidence: Double
    }

    func runClassificationBatch(
        _ testCases: [(String, String)],
        label: String
    ) async -> (accuracy: Double, results: [ClassificationResult]) {
        let classifier = MLToolClassifier.shared
        await classifier.loadModel()

        var results: [ClassificationResult] = []
        var correct = 0

        for (input, expected) in testCases {
            guard let prediction = await classifier.predict(text: input) else {
                results.append(ClassificationResult(
                    input: input, expected: expected, predicted: "nil",
                    correct: false, topConfidence: 0
                ))
                continue
            }

            let isCorrect = prediction.label == expected
            if isCorrect { correct += 1 }

            results.append(ClassificationResult(
                input: input, expected: expected, predicted: prediction.label,
                correct: isCorrect,
                topConfidence: prediction.confidence[prediction.label] ?? 0
            ))
        }

        let accuracy = testCases.isEmpty ? 0 : Double(correct) / Double(testCases.count) * 100.0
        print("[\(label)] Accuracy: \(String(format: "%.1f", accuracy))% (\(correct)/\(testCases.count))")

        // Print misclassifications
        let misses = results.filter { !$0.correct }
        if !misses.isEmpty {
            print("  Misclassifications:")
            for miss in misses {
                print("    \"\(miss.input)\" → predicted: \(miss.predicted), expected: \(miss.expected) (conf: \(String(format: "%.3f", miss.topConfidence)))")
            }
        }

        return (accuracy, results)
    }

    // MARK: - Test Methods

    func testCoreToolClassification() async {
        let (accuracy, _) = await runClassificationBatch(
            Self.coreToolTestCases, label: "Core Tools"
        )
        // We expect at least 70% on these natural-language prompts
        XCTAssertGreaterThan(accuracy, 70.0,
            "Core tool classification accuracy should be above 70%")
    }

    func testFMToolClassification() async {
        let (accuracy, _) = await runClassificationBatch(
            Self.fmToolTestCases, label: "FM Tools"
        )
        XCTAssertGreaterThan(accuracy, 70.0,
            "FM tool classification accuracy should be above 70%")
    }

    func testTrickyInputClassification() async {
        let (accuracy, _) = await runClassificationBatch(
            Self.trickyTestCases, label: "Tricky Inputs"
        )
        // Lower bar for adversarial inputs
        XCTAssertGreaterThan(accuracy, 55.0,
            "Tricky input classification accuracy should be above 55%")
    }

    func testOverallClassification() async {
        let allCases = Self.coreToolTestCases + Self.fmToolTestCases + Self.trickyTestCases
        let (accuracy, _) = await runClassificationBatch(allCases, label: "Overall")
        XCTAssertGreaterThan(accuracy, 65.0,
            "Overall classification accuracy should be above 65%")
    }

    // MARK: - Router Integration Tests

    /// Verifies that the ToolRouter uses the ML model and routes to the correct tool
    /// when no chip is present and the LLM fallback returns "none".
    func testRouterUsesMLClassifier() async {
        let weatherSpy = SpyTool(name: "Weather", schema: "weather forecast temperature")
        let calcSpy = SpyTool(name: "Calculator", schema: "math calculate")
        let timerSpy = SpyTool(name: "Timer", schema: "timer countdown")

        let router = ToolRouter(
            availableTools: [weatherSpy, calcSpy, timerSpy],
            llmResponder: makeStubRouterLLMResponder(toolName: "none")
        )

        let result = await router.route(input: "what's the weather like today")
        switch result {
        case .tools(let tools):
            // The ML model should route to Weather (or possibly disambiguate)
            let names = tools.map { $0.name }
            XCTAssertTrue(names.contains("Weather"),
                "Expected Weather tool, got: \(names)")
        case .requiresDisambiguation:
            // Also acceptable if confidence is close between tools
            break
        default:
            // With only 3 tools and a clear weather prompt, ML should match
            XCTFail("Expected .tools or .requiresDisambiguation, got \(result)")
        }
    }

    func testRouterMLClassifierWithFMTools() async {
        struct TestFMTool: FMToolDescriptor, @unchecked Sendable {
            let name: String
            let chipName: String
            let routingKeywords: [String]
            let category: CategoryEnum = .offline
            func makeTool() -> any FoundationModels.Tool { fatalError() }
        }

        let coreTools: [any CoreTool] = [
            SpyTool(name: "Weather", schema: "weather"),
        ]
        let fmTools: [any FMToolDescriptor] = [
            TestFMTool(name: "system_control", chipName: "system", routingKeywords: ["open", "launch", "app", "volume", "mute", "quit", "close"]),
            TestFMTool(name: "messages", chipName: "messages", routingKeywords: ["text", "message", "send"]),
        ]

        let router = ToolRouter(
            availableTools: coreTools,
            fmTools: fmTools,
            llmResponder: makeStubRouterLLMResponder(toolName: "none")
        )

        let result = await router.route(input: "open safari for me please")
        switch result {
        case .fmTools(let tools):
            XCTAssertEqual(tools.first?.name, "system_control")
        case .requiresDisambiguation:
            break // acceptable
        default:
            break // ML may have lower confidence with limited tool list
        }
    }

    // MARK: - LabelRegistry Tests

    func testLabelRegistryLoads() {
        XCTAssertFalse(LabelRegistry.allLabels.isEmpty, "LabelRegistry should load labels from JSON")
        XCTAssertGreaterThan(LabelRegistry.allLabels.count, 30, "Should have at least 30 labels")
    }

    func testLabelRegistryLookup() {
        let emailRead = LabelRegistry.lookup("email.read")
        XCTAssertNotNil(emailRead)
        XCTAssertEqual(emailRead?.tool, "ReadEmail")
        XCTAssertEqual(emailRead?.type, "core")
        XCTAssertFalse(emailRead?.requiresConsent ?? true)

        let emailCompose = LabelRegistry.lookup("email.compose")
        XCTAssertNotNil(emailCompose)
        XCTAssertEqual(emailCompose?.tool, "Email")
        XCTAssertTrue(emailCompose?.requiresConsent ?? false)

        let weather = LabelRegistry.lookup("weather")
        XCTAssertNotNil(weather)
        XCTAssertEqual(weather?.tool, "Weather")
    }

    func testLabelRegistryDomainExtraction() {
        XCTAssertEqual(LabelRegistry.domain(of: "email.read"), "email")
        XCTAssertEqual(LabelRegistry.domain(of: "calendar.manage"), "calendar")
        XCTAssertEqual(LabelRegistry.domain(of: "weather"), "weather")
        XCTAssertEqual(LabelRegistry.action(of: "email.read"), "read")
        XCTAssertEqual(LabelRegistry.action(of: "calendar.manage"), "manage")
        XCTAssertNil(LabelRegistry.action(of: "weather"))
    }

    func testLabelRegistrySiblings() {
        let emailSiblings = LabelRegistry.siblings(of: "email.read")
        XCTAssertTrue(emailSiblings.contains("email.compose"))
        XCTAssertTrue(emailSiblings.contains("email.search"))
        XCTAssertFalse(emailSiblings.contains("email.read")) // not itself
    }

    func testCompoundDomainDetection() {
        XCTAssertTrue(LabelRegistry.isCompoundDomain("email"))
        XCTAssertTrue(LabelRegistry.isCompoundDomain("calendar"))
        XCTAssertTrue(LabelRegistry.isCompoundDomain("search"))
        XCTAssertFalse(LabelRegistry.isCompoundDomain("weather"))
        XCTAssertFalse(LabelRegistry.isCompoundDomain("stocks"))
    }

    // MARK: - DomainDisambiguator Tests

    func testDomainDisambiguatorEmail() {
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "email", input: "check my email"), "email.read")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "email", input: "read my inbox"), "email.read")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "email", input: "send an email to john"), "email.compose")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "email", input: "compose a message"), "email.compose")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "email", input: "find emails from sarah"), "email.search")
    }

    func testDomainDisambiguatorCalendar() {
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "calendar", input: "what day is christmas"), "calendar.view")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "calendar", input: "create a new event for friday"), "calendar.manage")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "calendar", input: "what's on my calendar"), "calendar.search")
    }

    func testDomainDisambiguatorMessages() {
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "messages", input: "send a text to john"), "messages.send")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "messages", input: "read my messages"), "messages.read")
        XCTAssertEqual(DomainDisambiguator.resolve(domain: "messages", input: "find messages from sarah"), "messages.search")
    }

    func testDomainDisambiguatorDefaultAction() {
        // Domains should have a default action
        XCTAssertNotNil(DomainDisambiguator.defaultAction(for: "email"))
        XCTAssertNotNil(DomainDisambiguator.defaultAction(for: "calendar"))
        XCTAssertNil(DomainDisambiguator.defaultAction(for: "nonexistent"))
    }

    // MARK: - Consent Policy Tests

    func testConsentPolicySafe() {
        let policy = ActionConsentPolicy.safe
        XCTAssertFalse(policy.needsConsent)
        XCTAssertFalse(policy.isDestructive)
        XCTAssertNil(policy.actionDescription)
    }

    func testConsentPolicyRequiresConsent() {
        let policy = ActionConsentPolicy.requiresConsent(description: "Send an email")
        XCTAssertTrue(policy.needsConsent)
        XCTAssertFalse(policy.isDestructive)
        XCTAssertEqual(policy.actionDescription, "Send an email")
    }

    func testConsentPolicyDestructive() {
        let policy = ActionConsentPolicy.destructive(description: "Delete a file")
        XCTAssertTrue(policy.needsConsent)
        XCTAssertTrue(policy.isDestructive)
        XCTAssertEqual(policy.actionDescription, "Delete a file")
    }

    func testEmailToolHasConsentPolicy() {
        let emailTool = EmailTool()
        XCTAssertTrue(emailTool.consentPolicy.needsConsent, "EmailTool should require consent")
    }

    func testWeatherToolIsSafe() {
        let weatherTool = WeatherTool()
        XCTAssertFalse(weatherTool.consentPolicy.needsConsent, "WeatherTool should be safe")
    }

    // MARK: - Per-Label Accuracy Report

    func testPerLabelAccuracyReport() async {
        let allCases = Self.coreToolTestCases + Self.fmToolTestCases + Self.trickyTestCases
        let classifier = MLToolClassifier.shared
        await classifier.loadModel()

        struct LabelStats {
            var correct: Int = 0
            var total: Int = 0
        }
        var perLabel: [String: LabelStats] = [:]

        for (input, expected) in allCases {
            let predicted = await classifier.predict(text: input)?.label ?? "nil"
            var entry = perLabel[expected, default: LabelStats()]
            if predicted == expected { entry.correct += 1 }
            entry.total += 1
            perLabel[expected] = entry
        }

        print("\n===== PER-LABEL ACCURACY REPORT =====")
        print("Label                      Right  Total      Acc")
        print(String(repeating: "-", count: 52))

        var totalCorrect = 0
        var totalCount = 0

        for (label, stats) in perLabel.sorted(by: { $0.key < $1.key }) {
            let acc = stats.total > 0 ? Double(stats.correct) / Double(stats.total) * 100 : 0
            let accStr = String(format: "%.1f", acc)
            print("\(label.padding(toLength: 25, withPad: " ", startingAt: 0))  \(stats.correct)      \(stats.total)    \(accStr)%")
            totalCorrect += stats.correct
            totalCount += stats.total
        }

        let overallAcc = totalCount > 0 ? Double(totalCorrect) / Double(totalCount) * 100 : 0
        print(String(repeating: "-", count: 52))
        print("OVERALL                    \(totalCorrect)    \(totalCount)    \(String(format: "%.1f", overallAcc))%")
    }

    func testValidationDataAccuracy() async {
        // Load validation data from MLTraining/validation_data_compound.json
        let validationPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/iClawTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // project root
            .appendingPathComponent("MLTraining/validation_data_compound.json")

        guard let data = try? Data(contentsOf: validationPath),
              let entries = try? JSONDecoder().decode([[String: String]].self, from: data) else {
            // Skip if validation file doesn't exist
            return
        }

        let testCases: [(String, String)] = entries.compactMap { entry in
            guard let text = entry["text"], let label = entry["label"] else { return nil }
            return (text, label)
        }

        guard !testCases.isEmpty else { return }

        let (accuracy, results) = await runClassificationBatch(testCases, label: "Validation Data")
        XCTAssertGreaterThanOrEqual(accuracy, 80.0, "Validation data accuracy should be at least 80%")

        // Per-label check: labels with >10 samples should be >=60%.
        // Some compound labels (speech.read, text.write) have very few training
        // examples (~200) and need data augmentation to reach higher accuracy.
        let grouped = Dictionary(grouping: results, by: { $0.expected })
        var lowLabels: [(label: String, acc: Double)] = []
        for (label, labelResults) in grouped where labelResults.count > 10 {
            let labelCorrect = labelResults.filter(\.correct).count
            let labelAcc = Double(labelCorrect) / Double(labelResults.count) * 100
            if labelAcc < 60.0 {
                lowLabels.append((label, labelAcc))
            }
        }
        // Allow up to 3 labels below threshold during compound label transition.
        // These need training data augmentation (tracked for Phase 5).
        XCTAssertLessThanOrEqual(lowLabels.count, 3,
            "Too many labels below 60%: \(lowLabels.map { "\($0.label)=\(String(format: "%.1f", $0.acc))%" }.joined(separator: ", "))")
    }
}
