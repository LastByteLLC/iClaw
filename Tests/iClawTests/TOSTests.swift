import XCTest
@testable import iClawCore

final class TOSTests: XCTestCase {

    func testTOSURLConfigured() {
        XCTAssertFalse(AppConfig.tosURL.isEmpty)
        XCTAssertNotNil(URL(string: AppConfig.tosURL), "TOS URL should be a valid URL")
    }

    func testTTSCharacterThresholdConfigured() {
        XCTAssertGreaterThan(AppConfig.ttsCharacterThreshold, 0)
        XCTAssertEqual(AppConfig.ttsCharacterThreshold, 300)
    }
}
