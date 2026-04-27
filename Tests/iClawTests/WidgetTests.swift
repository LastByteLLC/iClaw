import XCTest
import SwiftUI
@testable import iClawCore

@MainActor
final class WidgetTests: XCTestCase {
    
    func testAudioPlayerWidgetViewCompilesAndAcceptsData() throws {
        let data = AudioPlayerWidgetData(
            id: "test_id",
            title: "Test Title",
            subtitle: "Test Subtitle",
            duration: 300
        )
        let view = AudioPlayerWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testWeatherWidgetViewCompilesAndAcceptsData() throws {
        let data = WeatherWidgetData(
            city: "San Francisco",
            temperature: "72°F",
            condition: "Sunny",
            iconName: "sun.max.fill"
        )
        let view = WeatherWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }
    
    // MARK: - Legacy Calculator Widget

    func testCalculatorWidgetViewCompilesWithLegacyData() throws {
        // Legacy CalculatorWidgetData is converted to CalculationWidgetData at the renderer boundary
        let legacy = CalculatorWidgetData(equation: "2 + 2", result: "4")
        let data = CalculationWidgetData(expression: legacy.equation, result: legacy.result)
        let view = CalculatorWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    // MARK: - Rich Calculation Widget

    func testCalculationWidgetSimpleResult() throws {
        let data = CalculationWidgetData(
            expression: "5 + 5",
            result: "10"
        )
        let view = CalculatorWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testCalculationWidgetWithSymbolAndUnit() throws {
        let data = CalculationWidgetData(
            expression: "100 km to miles",
            result: "62.14",
            unit: "mi",
            symbol: nil
        )
        let view = CalculatorWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testCalculationWidgetWithCurrency() throws {
        let data = CalculationWidgetData(
            expression: "$500 + $300",
            result: "800.00",
            symbol: "$",
            label: nil
        )
        let view = CalculatorWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testCalculationWidgetWithSupplementary() throws {
        let data = CalculationWidgetData(
            expression: "Loan interest on $1000 at 5% for 3 years",
            result: "150.00",
            symbol: "$",
            label: "Interest",
            supplementary: [
                .init(label: "Principal", value: "$1,000.00"),
                .init(label: "Total Paid", value: "$1,150.00"),
            ]
        )
        let view = CalculatorWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testCalculationWidgetWithTable() throws {
        let table = CalculationWidgetData.TableData(
            title: "Amortization",
            columns: ["Month", "Payment", "Interest", "Balance"],
            rows: [
                ["1", "$286.13", "$41.67", "$9,755.54"],
                ["2", "$286.13", "$40.65", "$9,510.06"],
                ["3", "$286.13", "$39.63", "$9,263.56"],
            ]
        )
        let data = CalculationWidgetData(
            expression: "Monthly payment on $10,000 at 5%",
            result: "286.13",
            symbol: "$",
            label: "Monthly Payment",
            table: table
        )
        let view = CalculatorWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testCalculationWidgetWithLargeTable() throws {
        // Table with more than 8 rows — should show "… N more rows"
        let rows = (1...12).map { i in
            ["Day \(i)", "$\(i * 10)", "$\(i * 5)"]
        }
        let table = CalculationWidgetData.TableData(
            title: "Daily Expenses",
            columns: ["Day", "Income", "Expense"],
            rows: rows
        )
        let data = CalculationWidgetData(
            expression: "Daily tracking for 12 days",
            result: "720.00",
            symbol: "$",
            table: table
        )
        let view = CalculatorWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
        XCTAssertEqual(table.rows.count, 12)
    }

    func testCalculationWidgetDataDefaults() throws {
        // Minimal data — no optional fields
        let data = CalculationWidgetData(expression: "1+1", result: "2")
        XCTAssertNil(data.unit)
        XCTAssertNil(data.symbol)
        XCTAssertNil(data.label)
        XCTAssertTrue(data.supplementary.isEmpty)
        XCTAssertNil(data.table)
    }

    // MARK: - WidgetOutput Integration

    func testWidgetOutputFromLegacyCalculation() throws {
        let data = CalculationWidgetData(expression: "5+5", result: "10")
        let output = WidgetOutput.fromLegacy(widgetType: "MathWidget", widgetData: data)
        if case .calculation(let d) = output {
            XCTAssertEqual(d.expression, "5+5")
            XCTAssertEqual(d.result, "10")
        } else {
            XCTFail("Expected .calculation case, got \(output)")
        }
    }

    func testWidgetOutputFromLegacyCalculator() throws {
        let data = CalculatorWidgetData(equation: "2+2", result: "4")
        let output = WidgetOutput.fromLegacy(widgetType: "MathWidget", widgetData: data)
        if case .calculator(let d) = output {
            XCTAssertEqual(d.equation, "2+2")
        } else {
            XCTFail("Expected .calculator case, got \(output)")
        }
    }

    func testWidgetOutputCalculationTypeString() throws {
        let data = CalculationWidgetData(expression: "5+5", result: "10")
        let output = WidgetOutput.calculation(data)
        XCTAssertEqual(output.widgetTypeString, "MathWidget")
    }

    func testBackgroundTaskWidgetViewCompilesAndAcceptsData() throws {
        let progress = 0.75
        let view = BackgroundTaskWidgetView(data: progress)
        let _ = view.body
        XCTAssertNotNil(view)
    }
    
    func testBackgroundTaskWidgetViewAcceptsNilProgress() throws {
        let view = BackgroundTaskWidgetView(data: nil)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testRandomWidgetViewCompilesAndAcceptsData() throws {
        let data = RandomWidgetData(type: "Dice Roll", result: "20", details: "d20")
        let view = RandomWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testTimerWidgetViewCompilesAndAcceptsData() throws {
        let data = TimerWidgetData(duration: 60, label: "Test Timer")
        let view = TimerWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testCalendarWidgetViewCompilesAndAcceptsData() throws {
        let data = CalendarWidgetData(title: "Day of Week", result: "Saturday", date: Date())
        let view = CalendarWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testWeatherForecastWidgetViewCompilesAndAcceptsData() throws {
        let data = WeatherForecastWidgetData(
            city: "London",
            currentTemp: "14°C",
            currentCondition: "Partly cloudy",
            currentIcon: "cloud.sun",
            forecast: [
                WeatherForecastEntry(dayLabel: "Today", high: "15°C", low: "9°C",
                    condition: "Partly cloudy", iconName: "cloud.sun", precipChance: 20),
                WeatherForecastEntry(dayLabel: "Thu", high: "17°C", low: "10°C",
                    condition: "Clear sky", iconName: "sun.max", precipChance: nil),
            ]
        )
        let view = WeatherForecastWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testWeatherComparisonWidgetViewCompilesAndAcceptsData() throws {
        let data = WeatherComparisonWidgetData(
            city1: "London", temp1: "14°C", condition1: "Partly cloudy",
            icon1: "cloud.sun", humidity1: 72,
            city2: "Paris", temp2: "18°C", condition2: "Clear sky",
            icon2: "sun.max", humidity2: 58
        )
        let view = WeatherComparisonWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testNewsWidgetViewCompilesAndAcceptsData() throws {
        let data = NewsWidgetData(
            articles: [
                NewsArticle(title: "Test Headline", link: "https://example.com/1", source: "BBC News", domain: "bbc.com", pubDate: "2h ago"),
                NewsArticle(title: "Second Story", link: "https://example.com/2", source: "NPR", domain: "npr.org"),
            ],
            category: "tech"
        )
        let view = NewsWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testNewsWidgetViewHandlesEmptyArticles() throws {
        let data = NewsWidgetData(articles: [], category: nil)
        let view = NewsWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testPodcastEpisodesWidgetViewCompilesAndAcceptsData() throws {
        let data = PodcastEpisodesWidgetData(
            showName: "Lenny's Podcast",
            episodes: [
                PodcastEpisodeItem(title: "Episode 1", date: "Mar 12", duration: "1h 6m", episodeUrl: "https://example.com/ep1.mp3", showName: "Lenny's Podcast"),
                PodcastEpisodeItem(title: "Episode 2", date: "Mar 8", duration: "1h 24m", showName: "Lenny's Podcast"),
            ]
        )
        let view = PodcastEpisodesWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testPodcastEpisodesWidgetViewHandlesEmptyList() throws {
        let data = PodcastEpisodesWidgetData(showName: "Empty Show", episodes: [])
        let view = PodcastEpisodesWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

}
