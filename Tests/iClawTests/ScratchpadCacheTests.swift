import XCTest
@testable import iClawCore

final class ScratchpadCacheTests: XCTestCase {

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    // MARK: - Basic Operations

    func testStoreAndLookup() async throws {
        let entry = ScratchpadCache.Entry(
            toolName: "Weather",
            textSummary: "London: 15°C, partly cloudy",
            isVerifiedData: true,
            ttl: 1800
        )
        await ScratchpadCache.shared.store(key: "Weather:london", entry: entry)

        let result = await ScratchpadCache.shared.lookup(key: "Weather:london")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.textSummary, "London: 15°C, partly cloudy")
        XCTAssertTrue(result?.isVerifiedData == true)
    }

    func testLookupMiss() async throws {
        let result = await ScratchpadCache.shared.lookup(key: "nonexistent")
        XCTAssertNil(result)
    }

    // MARK: - TTL Expiry

    func testExpiredEntryReturnsNil() async throws {
        let entry = ScratchpadCache.Entry(
            toolName: "Weather",
            textSummary: "expired data",
            timestamp: Date().addingTimeInterval(-100),
            ttl: 50  // Already expired (100s ago, 50s TTL)
        )
        await ScratchpadCache.shared.store(key: "Weather:test", entry: entry)

        let result = await ScratchpadCache.shared.lookup(key: "Weather:test")
        XCTAssertNil(result, "Expired entry should return nil")
    }

    func testNonExpiredEntryReturns() async throws {
        let entry = ScratchpadCache.Entry(
            toolName: "Weather",
            textSummary: "fresh data",
            timestamp: Date(),
            ttl: 3600
        )
        await ScratchpadCache.shared.store(key: "Weather:test", entry: entry)

        let result = await ScratchpadCache.shared.lookup(key: "Weather:test")
        XCTAssertNotNil(result, "Non-expired entry should be returned")
    }

    // MARK: - LRU Eviction

    func testLRUEvictionAt11Entries() async throws {
        // Store 11 entries; first should be evicted (max 10)
        for i in 0..<11 {
            let entry = ScratchpadCache.Entry(
                toolName: "Test",
                textSummary: "entry \(i)",
                ttl: 3600
            )
            await ScratchpadCache.shared.store(key: "key\(i)", entry: entry)
        }

        let count = await ScratchpadCache.shared.count
        XCTAssertEqual(count, 10, "Cache should have max 10 entries")

        let evicted = await ScratchpadCache.shared.lookup(key: "key0")
        XCTAssertNil(evicted, "First entry should have been evicted")

        let kept = await ScratchpadCache.shared.lookup(key: "key10")
        XCTAssertNotNil(kept, "Last entry should still exist")
    }

    func testLRUAccessRefreshesOrder() async throws {
        // Store 10 entries
        for i in 0..<10 {
            let entry = ScratchpadCache.Entry(
                toolName: "Test",
                textSummary: "entry \(i)",
                ttl: 3600
            )
            await ScratchpadCache.shared.store(key: "key\(i)", entry: entry)
        }

        // Access key0 to refresh it
        _ = await ScratchpadCache.shared.lookup(key: "key0")

        // Store 11th entry — key1 should be evicted (oldest un-accessed), not key0
        let entry = ScratchpadCache.Entry(toolName: "Test", textSummary: "new", ttl: 3600)
        await ScratchpadCache.shared.store(key: "key10", entry: entry)

        let refreshed = await ScratchpadCache.shared.lookup(key: "key0")
        XCTAssertNotNil(refreshed, "Recently accessed entry should survive eviction")

        let evicted = await ScratchpadCache.shared.lookup(key: "key1")
        XCTAssertNil(evicted, "Least recently used entry should be evicted")
    }

    // MARK: - Key Derivation

    func testKeyWordOrderInvariance() {
        let key1 = ScratchpadCache.makeKey(toolName: "Weather", input: "weather in London")
        let key2 = ScratchpadCache.makeKey(toolName: "Weather", input: "London weather")
        XCTAssertEqual(key1, key2, "Word order should not affect cache key")
    }

    func testKeyStopWordStripping() {
        let key1 = ScratchpadCache.makeKey(toolName: "Weather", input: "what's the weather in London")
        let key2 = ScratchpadCache.makeKey(toolName: "Weather", input: "weather London")
        XCTAssertEqual(key1, key2, "Stop words should be stripped from cache key")
    }

    func testKeyDifferentToolsDifferentKeys() {
        let key1 = ScratchpadCache.makeKey(toolName: "Weather", input: "London")
        let key2 = ScratchpadCache.makeKey(toolName: "Maps", input: "London")
        XCTAssertNotEqual(key1, key2, "Different tools should produce different keys")
    }

    func testKeyCaseInsensitive() {
        let key1 = ScratchpadCache.makeKey(toolName: "Weather", input: "LONDON")
        let key2 = ScratchpadCache.makeKey(toolName: "Weather", input: "london")
        XCTAssertEqual(key1, key2, "Key derivation should be case-insensitive")
    }

    // MARK: - Reset

    func testReset() async throws {
        let entry = ScratchpadCache.Entry(toolName: "Test", textSummary: "data", ttl: 3600)
        await ScratchpadCache.shared.store(key: "test", entry: entry)

        let beforeCount = await ScratchpadCache.shared.count
        XCTAssertEqual(beforeCount, 1)

        await ScratchpadCache.shared.reset()

        let afterCount = await ScratchpadCache.shared.count
        XCTAssertEqual(afterCount, 0, "Reset should clear all entries")
    }

    // MARK: - Widget Data

    func testWidgetDataPreserved() async throws {
        let widgetData: [String: String] = ["temp": "15", "city": "London"]
        let entry = ScratchpadCache.Entry(
            toolName: "Weather",
            textSummary: "London: 15°C",
            widgetData: widgetData,
            widgetType: "WeatherWidget",
            ttl: 3600
        )
        await ScratchpadCache.shared.store(key: "Weather:london", entry: entry)

        let result = await ScratchpadCache.shared.lookup(key: "Weather:london")
        XCTAssertEqual(result?.widgetType, "WeatherWidget")
        XCTAssertNotNil(result?.widgetData)
    }
}
