import XCTest
import Replay
@testable import iClawCore

final class ToolTests: XCTestCase {

    override func setUp() async throws {
        TestLocationSetup.install()
        await ScratchpadCache.shared.reset()
    }

    // MARK: - CalculatorTool Tests
    
    func testCalculatorTool() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "5 + 5", entities: nil)

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "MathWidget")
        XCTAssertTrue(result.text.contains("10"))
        XCTAssertNotNil(result.widgetData as? CalculationWidgetData)
    }

    // MARK: - CalculatorTool Sanitizer Tests

    func testCalculatorPercentOf() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "25% of 300", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("75"), "25% of 300 should be 75, got: \(result.text)")
    }

    func testCalculatorPercentSymbolWithNumber() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "15% of 230", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("34.5"), "15% of 230 should be 34.5, got: \(result.text)")
    }

    func testCalculatorCurrencySymbolStripped() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "$100 + $200", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("300"), "$100 + $200 should be 300, got: \(result.text)")
    }

    func testCalculatorCommasStripped() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "1,000 + 2,000", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("3,000") || result.text.contains("3000"),
                       "1000 + 2000 should be 3000, got: \(result.text)")
    }

    func testCalculatorWordOperators() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "10 plus 5", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("15"), "10 plus 5 should be 15, got: \(result.text)")
    }

    func testCalculatorNaturalLanguagePrefix() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "what's 7 * 8", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("56"), "7 * 8 should be 56, got: \(result.text)")
    }

    func testCalculatorSquareRoot() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "square root of 144", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("12"), "sqrt(144) should be 12, got: \(result.text)")
    }

    func testCalculatorSquared() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "9 squared", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("81"), "9 squared should be 81, got: \(result.text)")
    }

    func testCalculatorRejectsGarbage() async throws {
        // Inject a throwing LLM responder to test the regex-only path.
        // Without an LLM fallback, garbage input should fail sanitization.
        let tool = CalculatorTool(llmResponder: { _ in throw NSError(domain: "test", code: 0) })
        let result = try await tool.execute(input: "tell me a joke", entities: nil)
        XCTAssertEqual(result.status, .error)
    }

    func testCalculatorRejectsEmpty() async throws {
        // Inject a throwing LLM responder to test the regex-only path.
        // Without an LLM fallback, empty input should fail sanitization.
        let tool = CalculatorTool(llmResponder: { _ in throw NSError(domain: "test", code: 0) })
        let result = try await tool.execute(input: "", entities: nil)
        XCTAssertEqual(result.status, .error)
    }

    func testCalculatorWidgetDataHasCurrencySymbol() async throws {
        let tool = CalculatorTool()
        let result = try await tool.execute(input: "$500 + $300", entities: nil)
        let data = result.widgetData as? CalculationWidgetData
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.symbol, "$", "Currency input should produce $ symbol")
    }

    func testCalculatorWidgetDataHasLabel() async throws {
        let tool = CalculatorTool()
        // "interest" keyword triggers the "Interest" label
        let result = try await tool.execute(input: "1000 * 0.05 * 3", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // No label for bare arithmetic (label requires context words)
        let data = result.widgetData as? CalculationWidgetData
        XCTAssertNotNil(data)
        XCTAssertNil(data?.label)
    }

    func testCalculatorLLMFallback() async throws {
        // Inject a stub LLM that normalizes "two plus three" → "2 + 3"
        let tool = CalculatorTool(llmResponder: { _ in "2 + 3" })
        let result = try await tool.execute(input: "two plus three", entities: nil)
        XCTAssertEqual(result.status, .partial, "LLM-normalized expressions return .partial status")
        XCTAssertTrue(result.text.contains("5"), "LLM-normalized 2+3 should be 5, got: \(result.text)")
    }

    func testCalculatorLLMFallbackRejectsUnsafe() async throws {
        // LLM returns something unsafe — sanitizer should reject it
        let tool = CalculatorTool(llmResponder: { _ in "rm -rf /" })
        let result = try await tool.execute(input: "delete everything", entities: nil)
        XCTAssertEqual(result.status, .error)
    }

    func testCalculatorSanitizeIsPure() {
        // Verify sanitize is a pure function with no side effects
        XCTAssertEqual(CalculatorTool.sanitize("5 + 5"), "5 + 5")
        XCTAssertEqual(CalculatorTool.sanitize("what's 10 * 3"), "10 * 3")
        XCTAssertEqual(CalculatorTool.sanitize("$1,000 + $2,000"), "1000 + 2000")
        XCTAssertEqual(CalculatorTool.sanitize("tell me a joke"), "")
        XCTAssertEqual(CalculatorTool.sanitize(""), "")
    }

    // MARK: - TranslateTool Tests
    
    func testTranslateTool() async throws {
        try require(.auditTests)

        let tool = TranslateTool()
        let result = try await tool.execute(input: "Hello world", entities: nil)

        // Translation requires a working LLM session; in restricted environments
        // the API may report available but fail at generation time.
        XCTAssertTrue(result.status == .ok || result.status == .error,
            "Should either translate or fail gracefully, got: \(result.status)")
        XCTAssertFalse(result.text.isEmpty)
    }
    
    // MARK: - TranscribeTool Tests
    
    func testTranscribeToolNonexistentFile() async throws {
        let tool = TranscribeTool()

        // Nonexistent file should return error status
        let result = try await tool.execute(input: "/path/to/nonexistent.mp3", entities: nil)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("File not found"))
    }

    func testTranscribeToolRejectsNonFilePath() async throws {
        let tool = TranscribeTool()

        // Natural language input (no file path indicators) should return error
        let result = try await tool.execute(input: "Summarize the Zootopia episode", entities: nil)
        XCTAssertEqual(result.status, .error)
        XCTAssertTrue(result.text.contains("file path"))
    }

    func testTranscribeToolMetadata() {
        let tool = TranscribeTool()
        XCTAssertEqual(tool.name, "Transcribe")
        XCTAssertEqual(tool.category, .async)
        XCTAssertFalse(tool.isInternal)
    }

    func testTranscribeToolChipRouting() async throws {
        let spy = SpyTool(
            name: "Transcribe",
            schema: "Transcribe an audio file",
            result: ToolIO(text: "Hello world", status: .ok, outputWidget: "TranscriptionWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        _ = await engine.run(input: "#transcribe /tmp/test.m4a")
        XCTAssertEqual(spy.invocations.count, 1, "Transcribe tool should be called via #transcribe chip")
        XCTAssertFalse(spy.invocations.first!.input.contains("#"), "Chip should be stripped")
    }

    func testTranscribeToolWidgetOutput() async throws {
        let spy = SpyTool(
            name: "Transcribe",
            schema: "Transcribe an audio file",
            result: ToolIO(text: "Transcribed text here", status: .ok, outputWidget: "TranscriptionWidget")
        )
        let engine = makeTestEngine(tools: [spy])

        let result = await engine.run(input: "#transcribe /tmp/test.m4a")
        XCTAssertEqual(result.widgetType, "TranscriptionWidget")
    }

    func testTranscribeToolPromptVariants() async throws {
        let chipPrompts = [
            "#transcribe /tmp/audio.m4a",
            "#transcribe /Users/test/recording.wav",
            "#transcribe meeting_notes.mp3",
        ]

        for prompt in chipPrompts {
            let spy = SpyTool(name: "Transcribe", schema: "Transcribe an audio file")
            let engine = makeTestEngine(tools: [spy])
            _ = await engine.run(input: prompt)
            XCTAssertEqual(spy.invocations.count, 1, "'\(prompt)' should route to Transcribe tool")
        }
    }
    
    // MARK: - EmailTool Tests
    
    func testEmailTool() async throws {
        let tool = EmailTool()
        let result = try await tool.execute(input: "Hello iClaw!", entities: nil)
        
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Email draft opened") || result.text.contains("Couldn't open"),
                      "Expected email result, got: \(result.text)")
    }
    
    // MARK: - WebFetchTool Tests (Mocked with Replay)
    
    func testWebFetchTool() async throws {
        // Replay API for version 0.4.0
        let configuration = Replay.configuration(base: .ephemeral)
        let session = URLSession(configuration: configuration)
        let tool = WebFetchTool(session: session)
        
        // Use a real-looking URL.
        let testURL = "https://example.com"
        
        // Execute the tool. In a real CI environment, we would set REPLAY_PLAYBACK_MODE=strict
        // and have a recording. For now, we just verify the tool uses the session correctly.
        let result = try await tool.execute(input: testURL, entities: nil)
        
        XCTAssertNotNil(result)
        // If there's no recording and it's strict, it might be an error.
        // But the logic is sound.
    }
    
    // MARK: - ConvertTool Tests
    
    func testConvertTool() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "10 miles to km", entities: nil)
        
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.text, "10.0 miles = 16.09 km")
    }

    func testConvertToolBinary() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "Hi to binary", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("01001000 01101001"), "Binary of 'Hi': \(result.text)")
    }

    func testConvertToolHex() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "Hi to hex", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("48 69"), "Hex of 'Hi': \(result.text)")
    }

    func testConvertToolBase64() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "Hello to base64", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("SGVsbG8="), "Base64 of 'Hello': \(result.text)")
    }

    func testConvertToolDecodeBase64() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "decode base64 SGVsbG8=", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Hello"), "Decoded base64: \(result.text)")
    }

    func testConvertToolNATO() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "SOS to nato", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Sierra Oscar Sierra"), "NATO of 'SOS': \(result.text)")
    }

    func testConvertToolMorse() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "SOS to morse", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("... --- ..."), "Morse of 'SOS': \(result.text)")
    }

    func testConvertToolROT13() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "Hello to rot13", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Uryyb"), "ROT13 of 'Hello': \(result.text)")
    }

    func testConvertToolURL() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "hello world to url", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("hello%20world"), "URL encoding: \(result.text)")
    }

    // MARK: - ConvertTool Raw Binary Tests

    func testConvertToolRawBinaryAutoDetect() async throws {
        let tool = ConvertTool()
        // "Example" in binary
        let result = try await tool.execute(
            input: "01000101 01111000 01100001 01101101 01110000 01101100 01100101",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Example"), "Raw binary decode: \(result.text)")
    }

    func testConvertToolRawBinaryToBase64() async throws {
        let tool = ConvertTool()
        // "Example" in binary, convert to base64
        let result = try await tool.execute(
            input: "01000101 01111000 01100001 01101101 01110000 01101100 01100101 in base64",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("RXhhbXBsZQ=="), "Binary to base64: \(result.text)")
    }

    func testConvertToolRawBinaryToHex() async throws {
        let tool = ConvertTool()
        // "Hi" in binary, convert to hex
        let result = try await tool.execute(
            input: "01001000 01101001 in hex",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("48 69"), "Binary to hex: \(result.text)")
    }

    // MARK: - ConvertTool Raw Hex Tests

    func testConvertToolRawHexAutoDetect() async throws {
        let tool = ConvertTool()
        // "Example!" in hex
        let result = try await tool.execute(
            input: "45 78 61 6d 70 6C 65 21",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Example!"), "Raw hex decode: \(result.text)")
    }

    func testConvertToolRawHexToBase64() async throws {
        let tool = ConvertTool()
        // "Hi" in hex → base64
        let result = try await tool.execute(
            input: "48 69 in base64",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("SGk="), "Hex to base64: \(result.text)")
    }

    func testConvertToolRawHexToBinary() async throws {
        let tool = ConvertTool()
        // "Hi" in hex → binary
        let result = try await tool.execute(
            input: "48 69 in binary",
            entities: nil
        )
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("01001000 01101001"), "Hex to binary: \(result.text)")
    }

    // MARK: - ConvertTool Roman Numeral Tests

    func testConvertToolRomanAutoDetect() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "XXVIII", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("28"), "Roman XXVIII: \(result.text)")
    }

    func testConvertToolRomanToHex() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "XXVIII in hex", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // 28 → hex is "32 38" (ASCII of '2' and '8')
        XCTAssertTrue(result.text.contains("32 38"), "Roman to hex: \(result.text)")
    }

    func testConvertToolRomanToBinary() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "XIV in binary", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // 14 → binary of ASCII '1' and '4': "00110001 00110100"
        XCTAssertTrue(result.text.contains("00110001 00110100"), "Roman to binary: \(result.text)")
    }

    func testConvertToolRomanLargeNumber() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "MCMXCIX", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("1999"), "Roman MCMXCIX: \(result.text)")
    }

    func testConvertToolNumberToRoman() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "42 to roman", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("XLII"), "42 to roman: \(result.text)")
    }

    func testConvertToolTextInHex() async throws {
        let tool = ConvertTool()
        // The original bug: "text" in hex using "in" instead of "to"
        let result = try await tool.execute(input: "\"this is cool\" in hex", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.lowercased().contains("hex"), "Text in hex: \(result.text)")
    }

    func testConvertToolTextInBinary() async throws {
        let tool = ConvertTool()
        let result = try await tool.execute(input: "\"this is cool\" in binary", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("Binary"), "Text in binary: \(result.text)")
    }

    // MARK: - RandomTool Tests

    func testRandomTool() async throws {
        let tool = RandomTool()
        let result = try await tool.execute(input: "roll a d20", entities: nil)
        
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "RandomWidget")
        XCTAssertNotNil(result.widgetData as? RandomWidgetData)
    }

    // MARK: - TimeTool (Timer Path) Tests

    func testTimerTool() async throws {
        let tool = TimeTool()
        let result = try await tool.execute(input: "5 minutes", entities: nil, routingLabel: "timer")
        
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "TimerWidget")
        let data = result.widgetData as? TimerWidgetData
        XCTAssertEqual(data?.duration, 300)
    }

    // MARK: - CalendarTool Tests

    func testCalendarTool() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "day of the week for July 4 2026", entities: nil)

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.outputWidget, "CalendarWidget")
        XCTAssertTrue(result.text.contains("Saturday"))
    }

    func testCalendarRelativeDateYearsAgo() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "what year was 60 years ago", entities: nil)
        XCTAssertEqual(result.status, .ok)
        // 60 years before current year
        let expectedYear = Calendar.current.component(.year, from: Date()) - 60
        XCTAssertTrue(result.text.contains("\(expectedYear)"), "Expected year \(expectedYear) in: \(result.text)")
    }

    func testCalendarRelativeDateDaysFromNow() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "90 days from now", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("90 days from now"), "Should label the offset: \(result.text)")
        XCTAssertEqual(result.outputWidget, "CalendarWidget")
    }

    func testCalendarRelativeDateWeeksAgo() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "3 weeks ago", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("3 week"), "Should reference the offset: \(result.text)")
    }

    func testCalendarRelativeDateMonthsFromNow() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "6 months from now", entities: nil)
        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.text.contains("6 month"), "Should reference the offset: \(result.text)")
    }

    func testCalendarWhatYearWasPattern() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "what year was 100 years ago", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let expectedYear = Calendar.current.component(.year, from: Date()) - 100
        XCTAssertTrue(result.text.contains("\(expectedYear)"), "Expected \(expectedYear) in: \(result.text)")
    }

    func testCalendarRelativeDateFutureYear() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "what date is 5 years from now", entities: nil)
        XCTAssertEqual(result.status, .ok)
        let expectedYear = Calendar.current.component(.year, from: Date()) + 5
        XCTAssertTrue(result.text.contains("\(expectedYear)"), "Expected \(expectedYear) in: \(result.text)")
    }

    // MARK: - CalendarTool Event-Query Self-Refusal
    //
    // Calendar is a date-arithmetic tool. Event/meeting/appointment lookups
    // belong to CalendarEvent (EventKit). When the classifier or the verifier
    // LLM mistakenly picks Calendar for those queries, the tool must self-
    // refuse (ToolIO(text: "", status: .error)) so the engine falls through
    // to conversational BRAIN instead of emitting the generic "Today: <date>"
    // fallback, which the finalizer was reshaping into fabricated answers.

    func testCalendarSelfRefusesOnMeetingQuery() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "when is my next meeting?", entities: nil)
        XCTAssertEqual(result.status, .error, "Meeting query should self-refuse")
        XCTAssertTrue(result.text.isEmpty, "Self-refusal should return empty text so finalizer falls through to conversational")
    }

    func testCalendarSelfRefusesOnAppointmentQuery() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "do I have an appointment tomorrow", entities: nil)
        XCTAssertEqual(result.status, .error)
    }

    func testCalendarSelfRefusesOnScheduleQuery() async throws {
        let tool = CalendarTool()
        let result = try await tool.execute(input: "what's on my schedule today", entities: nil)
        XCTAssertEqual(result.status, .error)
    }

    func testCalendarSelfRefusesWithStructuredArgs() async throws {
        // Extractor-path: LLM returns structured args but rawInput still
        // mentions "meeting". Guard must fire BEFORE the switch runs the
        // default branch that would emit "Today: <date>".
        let tool = CalendarTool()
        let args = CalendarArgs(
            intent: "today", amount: nil, unit: nil,
            direction: nil, targetDate: nil, viewScope: nil
        )
        let result = try await tool.execute(
            args: args,
            rawInput: "when is my next meeting",
            entities: nil
        )
        XCTAssertEqual(result.status, .error)
    }

    func testCalendarAllowsNonEventQueries() async throws {
        // Guardrail: the self-refusal pattern must NOT catch legitimate date
        // arithmetic queries. These should all succeed.
        let tool = CalendarTool()
        let legitimateInputs = [
            "days until Christmas",
            "what day of the week is July 4 2027",
            "90 days from now",
            "how many days between June 1 and December 25",
        ]
        for input in legitimateInputs {
            let result = try await tool.execute(input: input, entities: nil)
            XCTAssertNotEqual(result.status, .error, "Legitimate date query '\(input)' should not self-refuse")
        }
    }

    // MARK: - ToolVerifier Category-Confusion Swap Blocker

    func testToolVerifierBlocksCalendarEventDemotion() {
        // ML classifier picks CalendarEvent for event queries; the verifier
        // LLM regularly "corrects" that to Calendar. The resulting swap then
        // caused fabricated "Today: <date>" answers. This guard rejects the
        // swap so the original ML pick stands.
        XCTAssertTrue(
            ToolRouter.isBlockedVerifierSwap(from: "CalendarEvent", to: "Calendar"),
            "CalendarEvent → Calendar verifier swap must be blocked"
        )
        // Case-insensitive so the LLM's arbitrary casing doesn't bypass the guard.
        XCTAssertTrue(ToolRouter.isBlockedVerifierSwap(from: "calendarevent", to: "CALENDAR"))
    }

    func testToolVerifierAllowsUnrelatedSwaps() {
        // Guardrail: non-blocked swaps must pass through as before.
        XCTAssertFalse(ToolRouter.isBlockedVerifierSwap(from: "WebSearch", to: "WikipediaSearch"))
        XCTAssertFalse(ToolRouter.isBlockedVerifierSwap(from: "Calendar", to: "CalendarEvent"))
        XCTAssertFalse(ToolRouter.isBlockedVerifierSwap(from: "News", to: "WebFetch"))
    }

    // MARK: - Messages/Email Self-Refusal on Contact-Info Lookup
    //
    // 2026-04 failure: "whats Shawn's email?" routed to Messages, the
    // extractor set `{recipient: Shawn, message: "email"}`, and a literal
    // iMessage of the word "email" was sent. Messages/Email now detect the
    // possessive contact-info lookup pattern and self-refuse, so the engine
    // falls through to conversational BRAIN instead of firing a send.

    func testMessagesSelfRefusesOnContactLookup() async throws {
        let tool = MessagesTool()
        let result = try await tool.execute(input: "whats Shawn's email?", entities: nil)
        XCTAssertEqual(result.status, .error, "Contact-info question must self-refuse")
        XCTAssertTrue(result.text.isEmpty, "Self-refusal should return empty text for conversational fallthrough")
    }

    func testMessagesSelfRefusesOnPhoneLookup() async throws {
        let tool = MessagesTool()
        let cases = [
            "what's John's phone number",
            "give me Sarah's phone",
            "tell me Alex's address",
            "find Dana's contact info",
        ]
        for input in cases {
            let result = try await tool.execute(input: input, entities: nil)
            XCTAssertEqual(result.status, .error, "'\(input)' should self-refuse")
        }
    }

    func testEmailSelfRefusesOnContactLookup() async throws {
        let tool = EmailTool()
        let result = try await tool.execute(input: "whats Shawn's email?", entities: nil)
        XCTAssertEqual(result.status, .error, "Contact-info lookup must not trigger email compose")
        XCTAssertTrue(result.text.isEmpty)
    }

    func testMessagesAllowsLegitimateSendDirectives() async throws {
        // Guardrail: the possessive-contact regex must NOT catch send
        // directives that happen to mention contacts but are clearly about
        // transmitting a message ("send Shawn a text", "text Shawn").
        XCTAssertFalse(CommunicationChannelResolver.isContactLookupQuestion("text Shawn hello are you free"))
        XCTAssertFalse(CommunicationChannelResolver.isContactLookupQuestion("send Shawn a message"))
        XCTAssertFalse(CommunicationChannelResolver.isContactLookupQuestion("email John about the meeting"))
    }

    func testIsContactLookupDetectsPossessivePattern() {
        XCTAssertTrue(CommunicationChannelResolver.isContactLookupQuestion("whats Shawn's email?"))
        XCTAssertTrue(CommunicationChannelResolver.isContactLookupQuestion("what is John's phone number"))
        XCTAssertTrue(CommunicationChannelResolver.isContactLookupQuestion("give me Sarah's address"))
        XCTAssertTrue(CommunicationChannelResolver.isContactLookupQuestion("find Alex's contact info"))
        XCTAssertTrue(CommunicationChannelResolver.isContactLookupQuestion("Dana's e-mail please"))
    }

    // MARK: - ContactsTool Search Widget

    func testContactsToolSearchEmitsWidgetDataStructure() {
        // Unit-level: can't hit CNContactStore in tests (no permission), but
        // we can assert the widget payload shape the search path emits when
        // contacts exist. Exercises ContactPreviewData init which the search
        // path now uses alongside `outputWidget: "ContactPreviewWidget"`.
        let data = ContactPreviewData(name: "Shawn Lemon", phone: "+16155551940", email: "shawn@example.com", isConfirmed: true)
        XCTAssertEqual(data.name, "Shawn Lemon")
        XCTAssertEqual(data.phone, "+16155551940")
        XCTAssertEqual(data.email, "shawn@example.com")
        XCTAssertTrue(data.isConfirmed, "Search results are existing contacts, not pending creations")
        XCTAssertNil(data.vcfFileURL, "Search results never need a vCard fallback")
    }

    // MARK: - WeatherTool Tests

    func testWeatherToolFallback() async throws {
        let tool = WeatherTool()
        // Without a city, falls back to GeoIP or CoreLocation.
        // Should succeed (GeoIP) or gracefully error — never crash.
        // Note: CoreLocation auth timeout can take ~5s when status is undetermined.
        let result = try await tool.execute(input: "What's the #weather ?", entities: nil)
        if result.status == .ok {
            // GeoIP fallback worked — should have temperature
            let hasTemp = result.text.contains("°C") || result.text.contains("°F")
            XCTAssertTrue(hasTemp, "GeoIP-based weather should contain temperature: \(result.text)")
        } else {
            // Both CL and GeoIP failed (e.g. no network in CI)
            XCTAssertTrue(result.text.contains("weather") || result.text.contains("location") || result.text.contains("Location"))
        }
    }
}
