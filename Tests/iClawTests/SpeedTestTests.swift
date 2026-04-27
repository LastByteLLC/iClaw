#if os(macOS)
import XCTest
@testable import iClawCore

final class SpeedTestTests: XCTestCase {

    private var tool: TechSupportTool!

    override func setUp() {
        TestLocationSetup.install()
        tool = TechSupportTool(session: makeStubURLSession())
    }

    func testSpeedTestKeywordRouting() async throws {
        let tool = self.tool!
        let keywords = [
            "speed test",
            "run a speed test",
            "internet speed",
            "check my download speed",
            "test bandwidth",
        ]

        for keyword in keywords {
            let result = try await tool.execute(input: keyword, entities: nil)
            XCTAssertEqual(result.status, .ok, "'\(keyword)' should succeed")
            XCTAssertEqual(result.outputWidget, "SpeedTestWidget", "'\(keyword)' should produce SpeedTestWidget")
            XCTAssertNotNil(result.widgetData as? SpeedTestWidgetData, "'\(keyword)' should return SpeedTestWidgetData")
        }
    }

    func testSpeedTestWidgetDataFields() async throws {
        let tool = self.tool!
        let result = try await tool.execute(input: "speed test", entities: nil)
        guard let data = result.widgetData as? SpeedTestWidgetData else {
            XCTFail("Expected SpeedTestWidgetData")
            return
        }
        // Signal quality should be one of the known values
        let validQualities = ["Excellent", "Good", "Fair", "Weak"]
        XCTAssertTrue(validQualities.contains(data.signalQuality),
                      "Signal quality '\(data.signalQuality)' should be a known value")
    }

    func testNonSpeedTestKeywordsDoNotTriggerSpeedTest() async throws {
        let tool = self.tool!
        let nonSpeedInputs = [
            "wifi info",
            "battery diagnostics",
            "check bluetooth",
        ]

        for input in nonSpeedInputs {
            let result = try await tool.execute(input: input, entities: nil)
            XCTAssertNotEqual(result.outputWidget, "SpeedTestWidget",
                              "'\(input)' should NOT produce SpeedTestWidget")
        }
    }
}
#endif
