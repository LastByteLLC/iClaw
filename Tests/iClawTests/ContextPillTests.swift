import XCTest
@testable import iClawCore

/// Tests for the context pill system: state lifecycle, entity extraction,
/// auto-dismiss behavior, and anchor mechanics.
@MainActor
final class ContextPillTests: XCTestCase {

    // MARK: - ContextPillState Lifecycle

    func testInitialState() {
        let state = ContextPillState.shared
        // Reset to known state
        state.dismiss()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.isAnchored)
    }

    func testShowMakesVisible() {
        let state = ContextPillState.shared
        state.show(toolName: "Weather", primaryEntity: "Paris", toolIcon: "cloud.sun")
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.toolName, "Weather")
        XCTAssertEqual(state.primaryEntity, "Paris")
        XCTAssertEqual(state.toolIcon, "cloud.sun")
        XCTAssertFalse(state.isAnchored)
        XCTAssertEqual(state.progress, 1.0)
        state.dismiss()
    }

    func testDismissHides() {
        let state = ContextPillState.shared
        state.show(toolName: "Weather", primaryEntity: "Paris", toolIcon: "cloud.sun")
        state.dismiss()
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.isAnchored)
    }

    func testDisplayTextWithEntity() {
        let state = ContextPillState.shared
        state.show(toolName: "Weather", primaryEntity: "Paris", toolIcon: "cloud.sun")
        XCTAssertEqual(state.displayText, "Weather · Paris")
        state.dismiss()
    }

    func testDisplayTextWithoutEntity() {
        let state = ContextPillState.shared
        state.show(toolName: "Timer", primaryEntity: nil, toolIcon: "timer")
        XCTAssertEqual(state.displayText, "Timer")
        state.dismiss()
    }

    // MARK: - Anchor Behavior

    func testToggleAnchor() {
        let state = ContextPillState.shared
        state.show(toolName: "Weather", primaryEntity: "Paris", toolIcon: "cloud.sun")

        state.toggleAnchor()
        XCTAssertTrue(state.isAnchored)
        XCTAssertEqual(state.progress, 1.0, "Progress should reset to full when anchored")

        state.toggleAnchor()
        XCTAssertFalse(state.isAnchored)
        state.dismiss()
    }

    // MARK: - Auto-Dismiss on Long Input

    func testShortInputDoesNotDismiss() {
        let state = ContextPillState.shared
        state.show(toolName: "Weather", primaryEntity: "Paris", toolIcon: "cloud.sun")
        state.onInputChanged("and London?")
        XCTAssertTrue(state.isVisible, "Short input should not dismiss pill")
        state.dismiss()
    }

    func testLongInputDismissesPill() {
        let state = ContextPillState.shared
        state.show(toolName: "Weather", primaryEntity: "Paris", toolIcon: "cloud.sun")
        state.onInputChanged("hey so I was wondering if you could tell me what the weather is like outside right now please")
        XCTAssertFalse(state.isVisible, "Long input (≥10 words) should dismiss pill")
    }

    func testLongInputDoesNotDismissWhenAnchored() {
        let state = ContextPillState.shared
        state.show(toolName: "Weather", primaryEntity: "Paris", toolIcon: "cloud.sun")
        state.toggleAnchor()
        state.onInputChanged("hey so I was wondering if you could tell me what the weather is like outside right now please")
        XCTAssertTrue(state.isVisible, "Anchored pill should not auto-dismiss on long input")
        state.dismiss()
    }

    // MARK: - PrimaryEntityExtractor

    func testExtractWeatherEntity() {
        let entities = makeEntities(places: ["Paris"])
        let result = PrimaryEntityExtractor.extract(toolName: "Weather", entities: entities, input: "weather in Paris")
        XCTAssertEqual(result, "Paris")
    }

    func testExtractStockEntity() {
        let result = PrimaryEntityExtractor.extract(toolName: "Stocks", entities: nil, input: "$AAPL stock price")
        XCTAssertEqual(result, "AAPL")
    }

    func testExtractEmailEntity() {
        let entities = makeEntities(names: ["John"])
        let result = PrimaryEntityExtractor.extract(toolName: "ReadEmail", entities: entities, input: "emails from John")
        XCTAssertEqual(result, "John")
    }

    func testExtractTranslateEntity() {
        let result = PrimaryEntityExtractor.extract(toolName: "Translate", entities: nil, input: "translate hello to Spanish")
        XCTAssertEqual(result, "Spanish")
    }

    func testExtractDictionaryEntity() {
        let result = PrimaryEntityExtractor.extract(toolName: "Dictionary", entities: nil, input: "define serendipity")
        XCTAssertEqual(result, "serendipity")
    }

    func testExtractTimerEntity() {
        let result = PrimaryEntityExtractor.extract(toolName: "Timer", entities: nil, input: "set timer for 5 minutes")
        XCTAssertEqual(result, "5 minutes")
    }

    func testExtractNewsEntity() {
        let result = PrimaryEntityExtractor.extract(toolName: "News", entities: nil, input: "news about AI")
        XCTAssertEqual(result, "AI")
    }

    func testExtractSystemControlAppEntity() {
        let result = PrimaryEntityExtractor.extract(toolName: "system_control", entities: nil, input: "open Safari")
        XCTAssertEqual(result, "Safari")
    }

    // MARK: - Icon Mapping

    func testIconMapping() {
        XCTAssertEqual(PrimaryEntityExtractor.icon(for: "Weather"), "cloud.sun")
        XCTAssertEqual(PrimaryEntityExtractor.icon(for: "Stocks"), "chart.line.uptrend.xyaxis")
        XCTAssertEqual(PrimaryEntityExtractor.icon(for: "Time"), "clock")
        XCTAssertEqual(PrimaryEntityExtractor.icon(for: "ReadEmail"), "envelope")
        XCTAssertEqual(PrimaryEntityExtractor.icon(for: "Translate"), "globe")
        XCTAssertEqual(PrimaryEntityExtractor.icon(for: "Research"), "magnifyingglass")
        XCTAssertNotEqual(PrimaryEntityExtractor.icon(for: "UnknownTool"), "", "Unknown tools should get default icon")
    }

    // MARK: - Helpers

    private func makeEntities(
        names: [String] = [],
        places: [String] = [],
        orgs: [String] = []
    ) -> ExtractedEntities {
        ExtractedEntities(
            names: names, places: places, organizations: orgs,
            urls: [], phoneNumbers: [], emails: [], ocrText: nil
        )
    }
}
