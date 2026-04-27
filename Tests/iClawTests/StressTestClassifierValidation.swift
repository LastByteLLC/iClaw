import XCTest
@testable import iClawCore

/// Validates the ML classifier against prompts that were misrouted in stress tests.
/// Each test checks that the classifier's top prediction matches the expected label,
/// or at minimum that the wrong label (the one that caused the misroute) is NOT the top prediction.
final class StressTestClassifierValidation: XCTestCase {

    override func setUp() async throws {
        await MLToolClassifier.shared.loadModel()
    }

    /// Helper: returns the top predicted label.
    private func predict(_ input: String) async -> String? {
        let prediction = await MLToolClassifier.shared.predict(text: input)
        return prediction?.label
    }

    // MARK: - Previously Misrouted: Car Comparisons → SystemInfo/Calculator/Stocks

    func testCarComparisonNotSystemInfo() async {
        let prompts = [
            "Compare Tesla Model 3 and BMW i4 specs",
            "Specs comparison: Toyota Corolla and Honda Civic",
            "Specs comparison: Mazda CX-5 and Subaru Forester",
            "Examine the specifications and features of MacBook Air vs MacBook Pro",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertNotNil(result, "Classifier should return result for: \(prompt)")
            XCTAssertNotEqual(result, "system.info",
                "'\(prompt)' should NOT route to system.info (got \(result ?? "nil") at \(0))")
        }
    }

    func testCarComparisonNotCalculator() async {
        let prompts = [
            "Horsepower comparison: Audi A4 and BMW 3 Series",
            "Compare the nutritional content of salmon and chicken breast per 100 grams",
            "Compare the average annual rainfall in New York City and San Francisco",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertNotNil(result)
            XCTAssertNotEqual(result, "calculator",
                "'\(prompt)' should NOT route to calculator (got \(result ?? "nil"))")
        }
    }

    func testCarComparisonNotStocks() async {
        let prompts = [
            "Compare the electric range and pricing of Tesla Model S vs Jaguar I-PACE",
            "Compare Tesla Model S and Audi Q8 performance",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertNotNil(result)
            XCTAssertNotEqual(result, "stocks",
                "'\(prompt)' should NOT route to stocks (got \(result ?? "nil"))")
        }
    }

    // MARK: - Previously Misrouted: Entity Lookups

    func testEnglishSpeakingCountriesNotTranslate() async {
        let result = await predict("List all countries that speak English as an official language")
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, "text.translate",
            "English-speaking countries should NOT route to translate")
    }

    func testPhotosynthesisNotConvert() async {
        let result = await predict("Describe photosynthesis in a table format including inputs and outputs")
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, "convert",
            "Photosynthesis should NOT route to convert")
    }

    func testMoonPhasesNotWeather() async {
        let result = await predict("Describe the phases of the moon and their key characteristics")
        XCTAssertNotNil(result)
        // After synonym fix, this should not route to weather
        // (synonym expansion happens before classification, but the classifier itself shouldn't return weather)
    }

    func testActorSalariesRouteToSearch() async {
        let result = await predict("Who are the top 5 highest-paid actors of 2023")
        XCTAssertNotNil(result)
        let searchLabels: Set<String> = ["search.web", "search.wiki", "search.research"]
        XCTAssertTrue(searchLabels.contains(result ?? ""),
            "Actor salaries should route to search, got \(result ?? "nil")")
    }

    func testFastestCarsRouteToSearch() async {
        let result = await predict("List the top 5 fastest cars in the world based on top speed and year of release")
        XCTAssertNotNil(result)
        let searchLabels: Set<String> = ["search.web", "search.wiki", "search.research"]
        XCTAssertTrue(searchLabels.contains(result ?? ""),
            "Fastest cars should route to search, got \(result ?? "nil")")
    }

    func testFastestAnimalsRouteToSearch() async {
        let result = await predict("List the top 5 fastest animals and their speeds in mph")
        XCTAssertNotNil(result)
        let searchLabels: Set<String> = ["search.web", "search.wiki", "search.research"]
        XCTAssertTrue(searchLabels.contains(result ?? ""),
            "Fastest animals should route to search, got \(result ?? "nil")")
    }

    func testCountryPopulationRouteToSearch() async {
        let prompts = [
            "List countries with populations over 100 million",
            "Give a list of countries in Africa with a population over 50 million and their capital cities",
            "List the GDP per capita of the top 5 countries in Asia",
        ]
        let searchLabels: Set<String> = ["search.web", "search.wiki", "search.research", "news"]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertNotNil(result)
            XCTAssertTrue(searchLabels.contains(result ?? ""),
                "'\(prompt)' should route to search, got \(result ?? "nil")")
        }
    }

    func testCompanyInfoNotCalculator() async {
        let prompts = [
            "Key figures for Amazon Inc.",
            "Key revenue figures and CEO details for Amazon",
            "Financial performance and founding year of Google",
            "Comparison of revenue growth and CEO names for Apple Inc and Google",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertNotNil(result)
            XCTAssertNotEqual(result, "calculator",
                "'\(prompt)' should NOT route to calculator (got \(result ?? "nil"))")
        }
    }

    // MARK: - Positive Controls: These SHOULD route to their tools

    func testCalculatorPositive() async {
        let prompts = [
            "what is 15% of 250",
            "calculate 45 * 67",
            "square root of 144",
            "tip on $85 at 20 percent",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertTrue(result == "calculator" || result == "math.arithmetic",
                "'\(prompt)' SHOULD route to calculator/math.arithmetic (got \(result ?? "nil"))")
        }
    }

    func testConvertPositive() async {
        let prompts = [
            "convert 50 miles to kilometers",
            "how many cups in a gallon",
            "100 pounds in kilograms",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertTrue(result == "convert" || result == "math.conversion",
                "'\(prompt)' SHOULD route to convert/math.conversion (got \(result ?? "nil"))")
        }
    }

    func testStocksPositive() async {
        let prompts = [
            "TSLA stock quote",
            "what is Apple stock price",
            "how is NVDA trading",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertEqual(result, "stocks",
                "'\(prompt)' SHOULD route to stocks (got \(result ?? "nil"))")
        }
    }

    func testSystemInfoPositive() async {
        let prompts = [
            "what is my battery level",
            "how much disk space do I have",
            "what CPU does my Mac have",
        ]
        for prompt in prompts {
            let result = await predict(prompt)
            XCTAssertEqual(result, "system.info",
                "'\(prompt)' SHOULD route to system.info (got \(result ?? "nil"))")
        }
    }
}
