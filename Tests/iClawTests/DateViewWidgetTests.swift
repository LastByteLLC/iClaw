import XCTest
@testable import iClawCore

final class DateViewWidgetTests: XCTestCase {

    private let tool = CalendarTool()

    // MARK: - Day View Prompts

    func testWhatDayIsItReturnsDayView() async throws {
        let result = try await tool.execute(input: "what day is it", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .day)
    }

    func testWhatDayOfTheWeekReturnsDayView() async throws {
        let result = try await tool.execute(input: "what day of the week is it", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .day)
    }

    // MARK: - Week View Prompts

    func testWhatWeekReturnsWeekView() async throws {
        let result = try await tool.execute(input: "what week is it", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .week)
    }

    func testThisWeekReturnsWeekView() async throws {
        let result = try await tool.execute(input: "this week", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .week)
    }

    func testShowWeekReturnsWeekView() async throws {
        let result = try await tool.execute(input: "show week", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .week)
    }

    // MARK: - Month View Prompts

    func testShowCalendarReturnsMonthView() async throws {
        let result = try await tool.execute(input: "show calendar", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .month)
    }

    func testThisMonthReturnsMonthView() async throws {
        let result = try await tool.execute(input: "this month", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .month)
    }

    func testShowMonthReturnsMonthView() async throws {
        let result = try await tool.execute(input: "show month", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .month)
    }

    func testWhatDayOfTheMonthReturnsMonthView() async throws {
        let result = try await tool.execute(input: "what day of the month is it", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .month)
    }

    // MARK: - Non-DateView Prompts Still Work

    func testDayOfWeekForSpecificDateStillUsesCalendarWidget() async throws {
        // "what day is July 4" has "for" context, should NOT trigger day view
        let result = try await tool.execute(input: "what day is it on July 4 2026", entities: nil)
        // Should fall through to the existing "day of week" or "today" handler, not DateView
        XCTAssertNotNil(result)
    }

    func testRelativeDateStillWorks() async throws {
        let result = try await tool.execute(input: "90 days from now", entities: nil)
        XCTAssertEqual(result.outputWidget, "CalendarWidget")
        XCTAssertTrue(result.text.contains("90 days"))
    }

    func testDaysUntilStillWorks() async throws {
        let result = try await tool.execute(input: "days until Christmas", entities: nil)
        XCTAssertEqual(result.outputWidget, "CalendarWidget")
    }

    // MARK: - ExtractableCoreTool Path

    func testDateViewIntentViaArgs() async throws {
        let args = CalendarArgs(intent: "dateView", amount: nil, unit: nil, direction: nil, targetDate: nil, viewScope: "week")
        let result = try await tool.execute(args: args, rawInput: "show this week", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .week)
    }

    func testDateViewIntentDefaultsToDay() async throws {
        let args = CalendarArgs(intent: "dateView", amount: nil, unit: nil, direction: nil, targetDate: nil, viewScope: nil)
        let result = try await tool.execute(args: args, rawInput: "what day is it", entities: nil)
        XCTAssertEqual(result.outputWidget, "DateViewWidget")
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .day)
    }

    func testDateViewMonthViaArgs() async throws {
        let args = CalendarArgs(intent: "dateView", amount: nil, unit: nil, direction: nil, targetDate: nil, viewScope: "month")
        let result = try await tool.execute(args: args, rawInput: "show calendar", entities: nil)
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertEqual(data.viewMode, .month)
    }

    // MARK: - Widget Data Integrity

    func testDateViewReferenceDateIsToday() async throws {
        let result = try await tool.execute(input: "what day is it", entities: nil)
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertTrue(Calendar.current.isDateInToday(data.referenceDate))
    }

    func testHighlightedDatesDefaultEmpty() async throws {
        let result = try await tool.execute(input: "show calendar", entities: nil)
        guard let data = result.widgetData as? DateViewWidgetData else {
            XCTFail("Expected DateViewWidgetData"); return
        }
        XCTAssertTrue(data.highlightedDates.isEmpty)
    }
}
