import XCTest
@testable import iClawCore

final class SkillCacheTests: XCTestCase {

    // MARK: - SkillCache

    func testStoreAndRetrieve() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "Test Skill",
            input: "test input",
            ingredients: ["ingredient 1", "ingredient 2"],
            widgetType: nil,
            widgetData: nil,
            duration: .hour
        )

        let result = await cache.lookup(skillName: "Test Skill", input: "test input")
        XCTAssertNotNil(result, "Should retrieve cached result")
        XCTAssertEqual(result?.ingredients, ["ingredient 1", "ingredient 2"])
    }

    func testCacheMissForDifferentInput() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "Test Skill",
            input: "input A",
            ingredients: ["data"],
            widgetType: nil,
            widgetData: nil,
            duration: .hour
        )

        let result = await cache.lookup(skillName: "Test Skill", input: "input B")
        XCTAssertNil(result, "Different input should not return cached result")
    }

    func testCacheMissForDifferentSkill() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "Skill A",
            input: "same input",
            ingredients: ["data"],
            widgetType: nil,
            widgetData: nil,
            duration: .hour
        )

        let result = await cache.lookup(skillName: "Skill B", input: "same input")
        XCTAssertNil(result, "Different skill name should not match")
    }

    func testNoDurationSkipsCache() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "Test Skill",
            input: "test input",
            ingredients: ["data"],
            widgetType: nil,
            widgetData: nil,
            duration: .none
        )

        let count = await cache.count
        XCTAssertEqual(count, 0, ".none duration should not store anything")
    }

    func testKeyNormalizationIgnoresStopWords() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "Test",
            input: "what is the horoscope for Aries",
            ingredients: ["aries data"],
            widgetType: nil,
            widgetData: nil,
            duration: .day
        )

        // Same semantic query with different stop words
        let result = await cache.lookup(skillName: "Test", input: "horoscope for Aries")
        XCTAssertNotNil(result, "Stop word differences should still match")
    }

    func testKeyNormalizationIsCaseInsensitive() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "Test",
            input: "Horoscope for ARIES",
            ingredients: ["data"],
            widgetType: nil,
            widgetData: nil,
            duration: .day
        )

        let result = await cache.lookup(skillName: "Test", input: "horoscope for aries")
        XCTAssertNotNil(result, "Case differences should still match")
    }

    func testWidgetDataPreserved() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "Test",
            input: "test",
            ingredients: ["data"],
            widgetType: "TestWidget",
            widgetData: nil,
            duration: .session
        )

        let result = await cache.lookup(skillName: "Test", input: "test")
        XCTAssertEqual(result?.widgetType, "TestWidget")
    }

    func testReset() async {
        let cache = SkillCache()
        await cache.store(
            skillName: "A", input: "test", ingredients: ["x"],
            widgetType: nil, widgetData: nil, duration: .hour
        )
        await cache.store(
            skillName: "B", input: "test", ingredients: ["y"],
            widgetType: nil, widgetData: nil, duration: .hour
        )

        var count = await cache.count
        XCTAssertEqual(count, 2)

        await cache.reset()
        count = await cache.count
        XCTAssertEqual(count, 0)
    }

    // MARK: - CacheDuration

    func testDayTTLExpiresAtMidnight() {
        let ttl = CacheDuration.day.ttl()
        XCTAssertGreaterThan(ttl, 0)
        XCTAssertLessThanOrEqual(ttl, 86400, "Day TTL should be at most 24 hours")
    }

    func testHourTTL() {
        XCTAssertEqual(CacheDuration.hour.ttl(), 3600)
    }

    func testSessionTTL() {
        XCTAssertEqual(CacheDuration.session.ttl(), .infinity)
    }

    func testNoneTTL() {
        XCTAssertEqual(CacheDuration.none.ttl(), 0)
    }

    // MARK: - SkillParser Cache Section

    func testSkillParserParsesCacheSection() async throws {
        let parser = SkillParser()

        // Create a temporary skill file with a ## Cache section
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestCachedSkill.md")
        let content = """
        # Test Cached Skill

        A test skill with caching.

        ## Cache

        - unit: day

        ## Examples

        - "test query"
        """
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let skill = try await parser.parseSkill(from: tempURL)
        XCTAssertEqual(skill.name, "Test Cached Skill")
        XCTAssertEqual(skill.cacheDuration, .day)
        XCTAssertEqual(skill.examples, ["test query"])
    }

    func testSkillParserNoCacheSectionIsNil() async throws {
        let parser = SkillParser()

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestNoCacheSkill.md")
        let content = """
        # No Cache Skill

        A skill without caching.

        ## Examples

        - "test"
        """
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let skill = try await parser.parseSkill(from: tempURL)
        XCTAssertNil(skill.cacheDuration, "Skills without ## Cache should have nil cacheDuration")
    }

    func testSkillParserCacheHourUnit() async throws {
        let parser = SkillParser()

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("TestHourCacheSkill.md")
        let content = """
        # Hourly Skill

        A skill cached hourly.

        ## Cache

        - unit: hour

        ## Examples

        - "test"
        """
        try content.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let skill = try await parser.parseSkill(from: tempURL)
        XCTAssertEqual(skill.cacheDuration, .hour)
    }
}
