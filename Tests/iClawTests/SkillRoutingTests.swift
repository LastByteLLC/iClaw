import XCTest
@testable import iClawCore

final class SkillRoutingTests: XCTestCase {
    var router: ToolRouter!

    override func setUp() async throws {
        executionTimeAllowance = 30
        let coreTools = ToolRegistry.coreTools
        let fmTools = ToolRegistry.fmTools
        router = ToolRouter(availableTools: coreTools, fmTools: fmTools, llmResponder: makeStubRouterLLMResponder())

        // Ensure skills are loaded for testing
        _ = await SkillLoader.shared.awaitActiveSkills()
    }
    
    func testCryptoSkillRouting() async throws {
        let input = "What's 1 BTC worth?"
        let result = await router.route(input: input)

        switch result {
        case .tools(let tools):
            XCTAssertTrue(tools.contains { $0.name == "Convert" }, "Expected Convert, got \(tools.map { $0.name })")
        case .fmTools(let tools):
            XCTAssertTrue(tools.contains { $0.name == "Convert" }, "Expected Convert, got \(tools.map { $0.name })")
        case .mixed(let coreTools, _):
            XCTAssertTrue(coreTools.contains { $0.name == "Convert" }, "Expected Convert, got \(coreTools.map { $0.name })")
        default:
            XCTFail("Expected routing to match tools, but got \(result)")
        }
        
        let currentSkill = await router.currentSkill
        XCTAssertNotNil(currentSkill, "Expected a skill to be matched")
        XCTAssertEqual(currentSkill?.name, "Crypto Price Skill")
    }
    
    // MARK: - Research Skill

    func testResearchSkillRouting() async throws {
        let prompts = [
            "Research how mRNA vaccines work",
            "Help me understand quantum computing",
            "What's the current state of nuclear fusion research?",
            "Deep dive into how LLMs are trained",
            "Explain the pros and cons of microservices architecture",
            "I want to learn about the history of the Internet",
            "Research the latest findings on intermittent fasting",
            "What are the arguments for and against universal basic income?",
            "Help me understand CRISPR gene editing",
            "Research the best practices for system design interviews",
        ]

        for prompt in prompts {
            _ = await router.route(input: prompt)
            let skill = await router.currentSkill
            XCTAssertNotNil(skill, "Expected skill match for: \(prompt)")
            XCTAssertEqual(skill?.name, "Research Skill", "Wrong skill for: \(prompt), got: \(skill?.name ?? "nil")")
        }
    }

    // MARK: - Tech Support Skill

    func testTechSupportSkillRouting() async throws {
        let prompts = [
            "My Mac is running slow",
            "How do I check what's using all my storage?",
            "Wi-Fi keeps disconnecting",
            "How do I force quit an app?",
            "My Bluetooth headphones won't connect",
            "How do I free up disk space?",
            "What's eating my battery?",
            "How do I find my Mac's specs?",
            "My Mac won't connect to the printer",
            "Show me how to use Activity Monitor",
        ]

        let acceptableNames: Set<String> = ["Tech Support Skill", "TechSupport"]
        for prompt in prompts {
            // Deactivate any mode from prior iteration to avoid mode override
            await router.deactivateMode()
            _ = await router.route(input: prompt)
            let skill = await router.currentSkill
            XCTAssertNotNil(skill, "Expected skill/mode match for: \(prompt)")
            XCTAssertTrue(
                acceptableNames.contains(skill?.name ?? ""),
                "Wrong skill for: \(prompt), got: \(skill?.name ?? "nil")"
            )
        }
    }

    // MARK: - Skill Matching Precision (no false positives)

    func testUnrelatedPromptDoesNotMatchSkill() async throws {
        _ = await router.route(input: "what time is it")
        let skill = await router.currentSkill
        XCTAssertNil(skill, "'what time is it' should not match any skill")
    }

    // MARK: - Movies Skill

    func testMoviesSkillRouting() async throws {
        let prompts = [
            "What's the rating of Inception?",
            "Tell me about the movie Interstellar",
            "Look up The Office TV show",
            "What year did Pulp Fiction come out?",
            "Find me sci-fi movies rated above 8",
            "Who directed The Godfather?",
            "What is the plot of Breaking Bad?",
            "Top rated comedy movies",
            "How long is the movie Oppenheimer?",
            "Who stars in Dune?",
        ]

        for prompt in prompts {
            _ = await router.route(input: prompt)
            let skill = await router.currentSkill
            XCTAssertNotNil(skill, "Expected skill match for: \(prompt)")
            XCTAssertEqual(skill?.name, "Movies Skill", "Wrong skill for: \(prompt), got: \(skill?.name ?? "nil")")
        }
    }

    func testMoviesSkillRoutesToWebFetch() async throws {
        let result = await router.route(input: "What's the rating of Inception?")
        switch result {
        case .tools(let tools):
            XCTAssertTrue(tools.contains { $0.name == "WebFetch" }, "Expected WebFetch tool, got \(tools.map { $0.name })")
        case .mixed(let coreTools, _):
            XCTAssertTrue(coreTools.contains { $0.name == "WebFetch" }, "Expected WebFetch tool")
        default:
            XCTFail("Movies skill should route to WebFetch, got \(result)")
        }
        let skill = await router.currentSkill
        XCTAssertEqual(skill?.name, "Movies Skill")
    }

    // MARK: - Books Skill

    func testBooksSkillRouting() async throws {
        let prompts = [
            "Who wrote 1984?",
            "Tell me about the book Dune",
            "Books by Ursula K. Le Guin",
            "When was The Great Gatsby first published?",
            "Look up Sapiens by Yuval Noah Harari",
            "Find books about machine learning",
            "How many editions of Harry Potter are there?",
            "What is Project Hail Mary about?",
            "What has Stephen King written?",
            "What year was To Kill a Mockingbird published?",
        ]

        for prompt in prompts {
            _ = await router.route(input: prompt)
            let skill = await router.currentSkill
            XCTAssertNotNil(skill, "Expected skill match for: \(prompt)")
            XCTAssertEqual(skill?.name, "Books Skill", "Wrong skill for: \(prompt), got: \(skill?.name ?? "nil")")
        }
    }

    func testBooksSkillRoutesToWebFetch() async throws {
        let result = await router.route(input: "Who wrote 1984?")
        switch result {
        case .tools(let tools):
            XCTAssertTrue(tools.contains { $0.name == "WebFetch" }, "Expected WebFetch tool, got \(tools.map { $0.name })")
        case .mixed(let coreTools, _):
            XCTAssertTrue(coreTools.contains { $0.name == "WebFetch" }, "Expected WebFetch tool")
        default:
            XCTFail("Books skill should route to WebFetch, got \(result)")
        }
        let skill = await router.currentSkill
        XCTAssertEqual(skill?.name, "Books Skill")
    }

    // MARK: - Emoji Skill

    func testEmojiSkillRouting() async throws {
        let prompts = [
            "find the crab emoji",
            "emoji for celebration",
            "smiley face emoji",
            "give me a thumbs up",
            "party emoji",
            "sad face emoji",
            "emoji for food",
            "fire emoji",
            "heart emoji",
            "what emoji is 🦀",
        ]

        for prompt in prompts {
            _ = await router.route(input: prompt)
            let skill = await router.currentSkill
            XCTAssertNotNil(skill, "Expected skill match for: \(prompt)")
            XCTAssertEqual(skill?.name, "Emoji Skill", "Wrong skill for: \(prompt), got: \(skill?.name ?? "nil")")
        }
    }

    func testEmojiSkillRoutesConversational() async throws {
        let result = await router.route(input: "find the crab emoji")
        switch result {
        case .conversational:
            break // expected — no tool bindings
        default:
            XCTFail("Emoji skill should route conversational, got \(result)")
        }
        let skill = await router.currentSkill
        XCTAssertEqual(skill?.name, "Emoji Skill")
    }

    // MARK: - Horoscope Skill

    func testHoroscopeSkillRouting() async throws {
        let prompts = [
            "what's my horoscope",
            "horoscope for Aries",
            "daily horoscope",
            "zodiac reading",
            "am I compatible with a Scorpio",
            "what sign is March 15",
            "Gemini horoscope today",
            "weekly horoscope Leo",
            "what does my star sign say",
            "horoscope for today",
        ]

        for prompt in prompts {
            _ = await router.route(input: prompt)
            let skill = await router.currentSkill
            XCTAssertNotNil(skill, "Expected skill match for: \(prompt)")
            XCTAssertEqual(skill?.name, "Horoscope Skill", "Wrong skill for: \(prompt), got: \(skill?.name ?? "nil")")
        }
    }

    func testHoroscopeSkillHasCacheDuration() async throws {
        _ = await router.route(input: "horoscope for Aries")
        let skill = await router.currentSkill
        XCTAssertEqual(skill?.cacheDuration, .day, "Horoscope skill should have .day cache duration")
    }

    // MARK: - Quote Skill

    func testQuoteSkillRouting() async throws {
        let prompts = [
            "give me a quote",
            "inspire me",
            "daily quote",
            "random quote",
            "motivational quote",
            "quote of the day",
            "funny quote",
            "inspirational quote",
            "wisdom quote",
        ]

        for prompt in prompts {
            _ = await router.route(input: prompt)
            let skill = await router.currentSkill
            XCTAssertNotNil(skill, "Expected skill match for: \(prompt)")
            XCTAssertEqual(skill?.name, "Quote Skill", "Wrong skill for: \(prompt), got: \(skill?.name ?? "nil")")
        }
    }

    func testQuoteSkillRoutesToWebFetch() async throws {
        let result = await router.route(input: "give me a quote")
        switch result {
        case .tools(let tools):
            XCTAssertTrue(tools.contains { $0.name == "WebFetch" }, "Expected WebFetch tool, got \(tools.map { $0.name })")
        case .mixed(let coreTools, _):
            XCTAssertTrue(coreTools.contains { $0.name == "WebFetch" }, "Expected WebFetch tool")
        default:
            XCTFail("Quote skill should route to WebFetch, got \(result)")
        }
        let skill = await router.currentSkill
        XCTAssertEqual(skill?.name, "Quote Skill")
    }

}
