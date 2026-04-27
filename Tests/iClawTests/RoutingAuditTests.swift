import XCTest
@testable import iClawCore

/// Comprehensive routing audit — runs 500 prompts through the pipeline and generates a report.
/// Each prompt records: which tool was selected, what input the tool received, and whether it matched expectations.
final class RoutingAuditTests: XCTestCase {

    override func setUp() async throws { await ScratchpadCache.shared.reset() }

    struct PromptCase {
        let input: String
        let expectedTool: String?       // nil = no tool expected (clarification)
        let expectedInputContains: String? // what the tool input should contain (key substring)
        let category: String
    }

    struct AuditResult {
        let input: String
        let category: String
        let expectedTool: String?
        let actualTool: String?
        let toolInput: String?
        let expectedInputContains: String?
        let pass: Bool
        let notes: String
    }

    // Build the full prompt catalogue
    static let prompts: [PromptCase] = {
        var p: [PromptCase] = []

        // ============================================================
        // CATEGORY: Weather (25 prompts)
        // ============================================================
        let weather = "Weather"
        p += [
            PromptCase(input: "#weather London", expectedTool: "Weather", expectedInputContains: "London", category: weather),
            PromptCase(input: "#weather", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "What's the weather?", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "Weather in Tokyo", expectedTool: "Weather", expectedInputContains: "Tokyo", category: weather),
            PromptCase(input: "How's the weather in Paris?", expectedTool: "Weather", expectedInputContains: "Paris", category: weather),
            PromptCase(input: "Is it raining in Seattle?", expectedTool: "Weather", expectedInputContains: "Seattle", category: weather),
            PromptCase(input: "Temperature in Berlin", expectedTool: "Weather", expectedInputContains: "Berlin", category: weather),
            PromptCase(input: "forecast for New York", expectedTool: "Weather", expectedInputContains: "New York", category: weather),
            PromptCase(input: "will it rain tomorrow", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "weather forecast", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "what's it like outside", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "do I need an umbrella", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "Hey, what's the weather like in San Francisco?", expectedTool: "Weather", expectedInputContains: "San Francisco", category: weather),
            PromptCase(input: "Tell me the temperature", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "current conditions in Miami", expectedTool: "Weather", expectedInputContains: "Miami", category: weather),
            PromptCase(input: "is it cold in Chicago", expectedTool: "Weather", expectedInputContains: "Chicago", category: weather),
            PromptCase(input: "how hot is it in Dubai", expectedTool: "Weather", expectedInputContains: "Dubai", category: weather),
            PromptCase(input: "What's the temp?", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "weather please", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "#weather NYC", expectedTool: "Weather", expectedInputContains: "NYC", category: weather),
            PromptCase(input: "That's cool. Anyway, #weather London", expectedTool: "Weather", expectedInputContains: "London", category: weather),
            PromptCase(input: "I was thinking about trips. What's the weather in Rome?", expectedTool: "Weather", expectedInputContains: "Rome", category: weather),
            PromptCase(input: "Haha nice. Weather?", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "ok fine, #weather", expectedTool: "Weather", expectedInputContains: nil, category: weather),
            PromptCase(input: "WEATHER IN LONDON", expectedTool: "Weather", expectedInputContains: "LONDON", category: weather),
        ]

        // ============================================================
        // CATEGORY: Stocks (30 prompts) — key area with known bugs
        // ============================================================
        let stocks = "Stocks"
        p += [
            PromptCase(input: "#stocks AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: stocks),
            PromptCase(input: "#stocks META", expectedTool: "Stocks", expectedInputContains: "META", category: stocks),
            PromptCase(input: "$AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: stocks),
            PromptCase(input: "$META", expectedTool: "Stocks", expectedInputContains: "META", category: stocks),
            PromptCase(input: "$TSLA", expectedTool: "Stocks", expectedInputContains: "TSLA", category: stocks),
            PromptCase(input: "$NVDA price", expectedTool: "Stocks", expectedInputContains: "NVDA", category: stocks),
            PromptCase(input: "stock price for AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: stocks),
            PromptCase(input: "price of MSFT", expectedTool: "Stocks", expectedInputContains: "MSFT", category: stocks),
            PromptCase(input: "quote for GOOGL", expectedTool: "Stocks", expectedInputContains: "GOOGL", category: stocks),
            PromptCase(input: "What's AAPL trading at?", expectedTool: "Stocks", expectedInputContains: "AAPL", category: stocks),
            PromptCase(input: "How's Tesla stock?", expectedTool: "Stocks", expectedInputContains: nil, category: stocks),
            PromptCase(input: "NVDA stock", expectedTool: "Stocks", expectedInputContains: "NVDA", category: stocks),
            // Conversational preamble + chip (THE BUG from the log)
            PromptCase(input: "That's unhinged, what's the price of #stocks AAPL?", expectedTool: "Stocks", expectedInputContains: "AAPL", category: stocks),
            PromptCase(input: "Hmm interesting. #stocks TSLA", expectedTool: "Stocks", expectedInputContains: "TSLA", category: stocks),
            PromptCase(input: "ok let me check #stocks NVDA real quick", expectedTool: "Stocks", expectedInputContains: "NVDA", category: stocks),
            PromptCase(input: "lol that's funny. Anyway $GOOG", expectedTool: "Stocks", expectedInputContains: "GOOG", category: stocks),
            PromptCase(input: "What's $AMZN at right now?", expectedTool: "Stocks", expectedInputContains: "AMZN", category: stocks),
            PromptCase(input: "show me $JPM", expectedTool: "Stocks", expectedInputContains: "JPM", category: stocks),
            PromptCase(input: "#stocks", expectedTool: "Stocks", expectedInputContains: nil, category: stocks),
            PromptCase(input: "stock AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: stocks),
            PromptCase(input: "Check the Apple stock price", expectedTool: "Stocks", expectedInputContains: nil, category: stocks),
            PromptCase(input: "What's META worth?", expectedTool: "Stocks", expectedInputContains: "META", category: stocks),
            PromptCase(input: "How much is one share of Google?", expectedTool: "Stocks", expectedInputContains: nil, category: stocks),
            PromptCase(input: "Give me a quote on AMD", expectedTool: "Stocks", expectedInputContains: "AMD", category: stocks),
            PromptCase(input: "#stocks AAPL MSFT", expectedTool: "Stocks", expectedInputContains: "AAPL", category: stocks),
            PromptCase(input: "I love this app. Now show me #stocks V", expectedTool: "Stocks", expectedInputContains: "V", category: stocks),
            PromptCase(input: "That's not right, try #stocks MA instead", expectedTool: "Stocks", expectedInputContains: "MA", category: stocks),
            PromptCase(input: "Sure thing! What about #stocks COST?", expectedTool: "Stocks", expectedInputContains: "COST", category: stocks),
            PromptCase(input: "$V", expectedTool: "Stocks", expectedInputContains: "V", category: stocks),
            PromptCase(input: "Before I forget, $MSFT", expectedTool: "Stocks", expectedInputContains: "MSFT", category: stocks),
        ]

        // ============================================================
        // CATEGORY: Calculator (25 prompts)
        // ============================================================
        let calc = "Calculator"
        p += [
            PromptCase(input: "#calculator 5+5", expectedTool: "Calculator", expectedInputContains: "5+5", category: calc),
            PromptCase(input: "5 + 5", expectedTool: "Calculator", expectedInputContains: "5", category: calc),
            PromptCase(input: "what's 12 * 7?", expectedTool: "Calculator", expectedInputContains: "12", category: calc),
            PromptCase(input: "calculate 100 / 4", expectedTool: "Calculator", expectedInputContains: "100", category: calc),
            PromptCase(input: "math: 2^10", expectedTool: "Calculator", expectedInputContains: "2", category: calc),
            PromptCase(input: "what is 15% of 200", expectedTool: "Calculator", expectedInputContains: "15", category: calc),
            PromptCase(input: "sqrt(144)", expectedTool: "Calculator", expectedInputContains: "144", category: calc),
            PromptCase(input: "how much is 3.14 * 2", expectedTool: "Calculator", expectedInputContains: "3.14", category: calc),
            PromptCase(input: "#calculator sin(45)", expectedTool: "Calculator", expectedInputContains: "sin", category: calc),
            PromptCase(input: "1000 - 347", expectedTool: "Calculator", expectedInputContains: "1000", category: calc),
            PromptCase(input: "What's 2+2?", expectedTool: "Calculator", expectedInputContains: "2", category: calc),
            PromptCase(input: "99 * 99", expectedTool: "Calculator", expectedInputContains: "99", category: calc),
            PromptCase(input: "divide 500 by 3", expectedTool: "Calculator", expectedInputContains: "500", category: calc),
            PromptCase(input: "#math 7*8", expectedTool: "Calculator", expectedInputContains: "7", category: calc),
            PromptCase(input: "Quick math: 256 + 512", expectedTool: "Calculator", expectedInputContains: "256", category: calc),
            PromptCase(input: "Hey, what's 10 * 20?", expectedTool: "Calculator", expectedInputContains: "10", category: calc),
            PromptCase(input: "I need to know 45 + 67", expectedTool: "Calculator", expectedInputContains: "45", category: calc),
            PromptCase(input: "That's wild. Anyway, 8 * 9?", expectedTool: "Calculator", expectedInputContains: "8", category: calc),
            PromptCase(input: "solve 100 - 42", expectedTool: "Calculator", expectedInputContains: "100", category: calc),
            PromptCase(input: "what does 7! equal", expectedTool: "Calculator", expectedInputContains: "7", category: calc),
            PromptCase(input: "compute 2 to the power of 8", expectedTool: "Calculator", expectedInputContains: "2", category: calc),
            PromptCase(input: "arithmetic: 13 + 29", expectedTool: "Calculator", expectedInputContains: "13", category: calc),
            PromptCase(input: "please calculate 88 / 11", expectedTool: "Calculator", expectedInputContains: "88", category: calc),
            PromptCase(input: "3 * 3 * 3", expectedTool: "Calculator", expectedInputContains: "3", category: calc),
            PromptCase(input: "calculate this: 1024 / 32", expectedTool: "Calculator", expectedInputContains: "1024", category: calc),
        ]

        // ============================================================
        // CATEGORY: Timer (20 prompts)
        // ============================================================
        let timer = "Timer"
        p += [
            PromptCase(input: "#timer 5 minutes", expectedTool: "Timer", expectedInputContains: "5 minutes", category: timer),
            PromptCase(input: "set a timer for 10 minutes", expectedTool: "Timer", expectedInputContains: "10", category: timer),
            PromptCase(input: "timer 30 seconds", expectedTool: "Timer", expectedInputContains: "30", category: timer),
            PromptCase(input: "remind me in 5 min", expectedTool: "Timer", expectedInputContains: "5", category: timer),
            PromptCase(input: "countdown 2 hours", expectedTool: "Timer", expectedInputContains: "2", category: timer),
            PromptCase(input: "set timer 1 hour", expectedTool: "Timer", expectedInputContains: "1", category: timer),
            PromptCase(input: "start a 15 minute timer", expectedTool: "Timer", expectedInputContains: "15", category: timer),
            PromptCase(input: "#timer 90s", expectedTool: "Timer", expectedInputContains: "90", category: timer),
            PromptCase(input: "timer for cooking: 20 minutes", expectedTool: "Timer", expectedInputContains: "20", category: timer),
            PromptCase(input: "set alarm for 3 minutes", expectedTool: "Timer", expectedInputContains: "3", category: timer),
            PromptCase(input: "That was good. Timer 5 minutes please", expectedTool: "Timer", expectedInputContains: "5", category: timer),
            PromptCase(input: "Ok cool. #timer 10 min", expectedTool: "Timer", expectedInputContains: "10", category: timer),
            PromptCase(input: "pomodoro 25 minutes", expectedTool: "Timer", expectedInputContains: "25", category: timer),
            PromptCase(input: "wake me up in 45 min", expectedTool: "Timer", expectedInputContains: "45", category: timer),
            PromptCase(input: "#timer 1m", expectedTool: "Timer", expectedInputContains: "1", category: timer),
            PromptCase(input: "Set a 5 min timer", expectedTool: "Timer", expectedInputContains: "5", category: timer),
            PromptCase(input: "2 minute timer", expectedTool: "Timer", expectedInputContains: "2", category: timer),
            PromptCase(input: "timer", expectedTool: "Timer", expectedInputContains: nil, category: timer),
            PromptCase(input: "count down from 60", expectedTool: "Timer", expectedInputContains: "60", category: timer),
            PromptCase(input: "can you set a timer for 8 minutes", expectedTool: "Timer", expectedInputContains: "8", category: timer),
        ]

        // ============================================================
        // CATEGORY: Convert (25 prompts)
        // ============================================================
        let convert = "Convert"
        p += [
            PromptCase(input: "#convert 10 miles to km", expectedTool: "Convert", expectedInputContains: "miles", category: convert),
            PromptCase(input: "convert 100 USD to EUR", expectedTool: "Convert", expectedInputContains: "USD", category: convert),
            PromptCase(input: "10 miles to km", expectedTool: "Convert", expectedInputContains: "miles", category: convert),
            PromptCase(input: "5 feet to meters", expectedTool: "Convert", expectedInputContains: "feet", category: convert),
            PromptCase(input: "100 kg to pounds", expectedTool: "Convert", expectedInputContains: "kg", category: convert),
            PromptCase(input: "how many cm in 6 inches", expectedTool: "Convert", expectedInputContains: "inches", category: convert),
            PromptCase(input: "32°F to celsius", expectedTool: "Convert", expectedInputContains: "32", category: convert),
            PromptCase(input: "1 BTC to USD", expectedTool: "Convert", expectedInputContains: "BTC", category: convert),
            PromptCase(input: "What is 1 bitcoin worth?", expectedTool: "Convert", expectedInputContains: nil, category: convert),
            PromptCase(input: "50 euros in dollars", expectedTool: "Convert", expectedInputContains: "euro", category: convert),
            PromptCase(input: "1 mile in meters", expectedTool: "Convert", expectedInputContains: "mile", category: convert),
            PromptCase(input: "convert 500ml to cups", expectedTool: "Convert", expectedInputContains: "500", category: convert),
            PromptCase(input: "100 yen to usd", expectedTool: "Convert", expectedInputContains: "yen", category: convert),
            PromptCase(input: "how much is 1 ETH", expectedTool: "Convert", expectedInputContains: nil, category: convert),
            PromptCase(input: "2.5 liters to gallons", expectedTool: "Convert", expectedInputContains: "liters", category: convert),
            PromptCase(input: "what's 200 pounds in kg", expectedTool: "Convert", expectedInputContains: "pounds", category: convert),
            PromptCase(input: "72°F in celsius", expectedTool: "Convert", expectedInputContains: "72", category: convert),
            PromptCase(input: "#convert 1 GBP to USD", expectedTool: "Convert", expectedInputContains: "GBP", category: convert),
            PromptCase(input: "exchange rate USD to JPY", expectedTool: "Convert", expectedInputContains: nil, category: convert),
            PromptCase(input: "10 stone to kg", expectedTool: "Convert", expectedInputContains: "stone", category: convert),
            PromptCase(input: "Hmm ok. Convert 5 miles to km", expectedTool: "Convert", expectedInputContains: "miles", category: convert),
            PromptCase(input: "500 grams to ounces", expectedTool: "Convert", expectedInputContains: "grams", category: convert),
            PromptCase(input: "1 inch in mm", expectedTool: "Convert", expectedInputContains: "inch", category: convert),
            PromptCase(input: "how many teaspoons in a tablespoon", expectedTool: "Convert", expectedInputContains: nil, category: convert),
            PromptCase(input: "100 CAD to USD", expectedTool: "Convert", expectedInputContains: "CAD", category: convert),
        ]

        // ============================================================
        // CATEGORY: Time (20 prompts)
        // ============================================================
        let time = "Time"
        p += [
            PromptCase(input: "#time Tokyo", expectedTool: "Time", expectedInputContains: "Tokyo", category: time),
            PromptCase(input: "what time is it", expectedTool: "Time", expectedInputContains: nil, category: time),
            PromptCase(input: "time in London", expectedTool: "Time", expectedInputContains: "London", category: time),
            PromptCase(input: "current time", expectedTool: "Time", expectedInputContains: nil, category: time),
            PromptCase(input: "what time is it in New York?", expectedTool: "Time", expectedInputContains: "New York", category: time),
            PromptCase(input: "time in Sydney", expectedTool: "Time", expectedInputContains: "Sydney", category: time),
            PromptCase(input: "what's the time?", expectedTool: "Time", expectedInputContains: nil, category: time),
            PromptCase(input: "#time", expectedTool: "Time", expectedInputContains: nil, category: time),
            PromptCase(input: "time zone for Berlin", expectedTool: "Time", expectedInputContains: "Berlin", category: time),
            PromptCase(input: "what hour is it in Mumbai", expectedTool: "Time", expectedInputContains: "Mumbai", category: time),
            PromptCase(input: "What time is it in LA?", expectedTool: "Time", expectedInputContains: "LA", category: time),
            PromptCase(input: "clock", expectedTool: "Time", expectedInputContains: nil, category: time),
            PromptCase(input: "Hey what's the time in Paris?", expectedTool: "Time", expectedInputContains: "Paris", category: time),
            PromptCase(input: "time check", expectedTool: "Time", expectedInputContains: nil, category: time),
            PromptCase(input: "show me the time in Singapore", expectedTool: "Time", expectedInputContains: "Singapore", category: time),
            PromptCase(input: "is it morning in Tokyo?", expectedTool: "Time", expectedInputContains: "Tokyo", category: time),
            PromptCase(input: "Tell me the time", expectedTool: "Time", expectedInputContains: nil, category: time),
            PromptCase(input: "What's the current time in Dubai?", expectedTool: "Time", expectedInputContains: "Dubai", category: time),
            PromptCase(input: "Neat. Time in Rome?", expectedTool: "Time", expectedInputContains: "Rome", category: time),
            PromptCase(input: "that's great, #time Berlin", expectedTool: "Time", expectedInputContains: "Berlin", category: time),
        ]

        // ============================================================
        // CATEGORY: Calendar (20 prompts)
        // ============================================================
        let calendar = "Calendar"
        p += [
            PromptCase(input: "#calendar July 4 2026", expectedTool: "Calendar", expectedInputContains: "July", category: calendar),
            PromptCase(input: "what day is Christmas", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "day of the week for Jan 1 2030", expectedTool: "Calendar", expectedInputContains: "2030", category: calendar),
            PromptCase(input: "what day is my birthday March 15", expectedTool: "Calendar", expectedInputContains: "March", category: calendar),
            PromptCase(input: "how many days until Christmas", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "days between Jan 1 and Dec 31", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "when is Easter 2027", expectedTool: "Calendar", expectedInputContains: "Easter", category: calendar),
            PromptCase(input: "what day is today", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "#calendar", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "day of week November 28 2025", expectedTool: "Calendar", expectedInputContains: "November", category: calendar),
            PromptCase(input: "when is thanksgiving", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "is 2028 a leap year", expectedTool: "Calendar", expectedInputContains: "2028", category: calendar),
            PromptCase(input: "date calculation: 30 days from now", expectedTool: "Calendar", expectedInputContains: "30", category: calendar),
            PromptCase(input: "Interesting. What day is July 4th 2030?", expectedTool: "Calendar", expectedInputContains: "July", category: calendar),
            PromptCase(input: "Ok cool. #calendar Dec 25 2026", expectedTool: "Calendar", expectedInputContains: "Dec", category: calendar),
            PromptCase(input: "how many days since Jan 1 2000", expectedTool: "Calendar", expectedInputContains: "2000", category: calendar),
            PromptCase(input: "days left in this year", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "what's today's date", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "weeks until summer", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
            PromptCase(input: "calendar for next month", expectedTool: "Calendar", expectedInputContains: nil, category: calendar),
        ]

        // ============================================================
        // CATEGORY: Random (20 prompts)
        // ============================================================
        let random = "Random"
        p += [
            PromptCase(input: "#random roll d20", expectedTool: "Random", expectedInputContains: "d20", category: random),
            PromptCase(input: "roll a dice", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "flip a coin", expectedTool: "Random", expectedInputContains: "coin", category: random),
            PromptCase(input: "random number between 1 and 100", expectedTool: "Random", expectedInputContains: "100", category: random),
            PromptCase(input: "pick a card", expectedTool: "Random", expectedInputContains: "card", category: random),
            PromptCase(input: "roll 2d6", expectedTool: "Random", expectedInputContains: "2d6", category: random),
            PromptCase(input: "coinflip", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "give me a random number", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "#random", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "heads or tails", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "pick a number 1-10", expectedTool: "Random", expectedInputContains: "10", category: random),
            PromptCase(input: "draw a card from the deck", expectedTool: "Random", expectedInputContains: "card", category: random),
            PromptCase(input: "roll dice", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "choose a random color", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "coin toss", expectedTool: "Random", expectedInputContains: "coin", category: random),
            PromptCase(input: "d20", expectedTool: "Random", expectedInputContains: "d20", category: random),
            PromptCase(input: "toss a coin for me", expectedTool: "Random", expectedInputContains: "coin", category: random),
            PromptCase(input: "random", expectedTool: "Random", expectedInputContains: nil, category: random),
            PromptCase(input: "Funny. Roll me a d20", expectedTool: "Random", expectedInputContains: "d20", category: random),
            PromptCase(input: "ok sure. #random coin", expectedTool: "Random", expectedInputContains: "coin", category: random),
        ]

        // ============================================================
        // CATEGORY: Translate (20 prompts)
        // ============================================================
        let translate = "Translate"
        p += [
            PromptCase(input: "#translate Hello world", expectedTool: "Translate", expectedInputContains: "Hello", category: translate),
            PromptCase(input: "translate this to Spanish: hello", expectedTool: "Translate", expectedInputContains: "hello", category: translate),
            PromptCase(input: "how do you say goodbye in French", expectedTool: "Translate", expectedInputContains: nil, category: translate),
            PromptCase(input: "translate 'thank you' to Japanese", expectedTool: "Translate", expectedInputContains: "thank", category: translate),
            PromptCase(input: "what's hello in German", expectedTool: "Translate", expectedInputContains: "hello", category: translate),
            PromptCase(input: "#translate Bonjour", expectedTool: "Translate", expectedInputContains: "Bonjour", category: translate),
            PromptCase(input: "translate: good morning", expectedTool: "Translate", expectedInputContains: "good morning", category: translate),
            PromptCase(input: "say 'I love you' in Italian", expectedTool: "Translate", expectedInputContains: nil, category: translate),
            PromptCase(input: "Spanish for 'where is the bathroom'", expectedTool: "Translate", expectedInputContains: nil, category: translate),
            PromptCase(input: "translate hello to Korean", expectedTool: "Translate", expectedInputContains: "hello", category: translate),
            PromptCase(input: "how to say thanks in Mandarin", expectedTool: "Translate", expectedInputContains: nil, category: translate),
            PromptCase(input: "what does 'merci' mean", expectedTool: "Translate", expectedInputContains: "merci", category: translate),
            PromptCase(input: "translate water to Portuguese", expectedTool: "Translate", expectedInputContains: "water", category: translate),
            PromptCase(input: "German translation of goodbye", expectedTool: "Translate", expectedInputContains: "goodbye", category: translate),
            PromptCase(input: "#translate おはよう", expectedTool: "Translate", expectedInputContains: nil, category: translate),
            PromptCase(input: "what's 'cheers' in Russian", expectedTool: "Translate", expectedInputContains: nil, category: translate),
            PromptCase(input: "Cool. Translate 'yes' to Arabic", expectedTool: "Translate", expectedInputContains: "yes", category: translate),
            PromptCase(input: "Ok fine. #translate Danke", expectedTool: "Translate", expectedInputContains: "Danke", category: translate),
            PromptCase(input: "translate please to Hindi", expectedTool: "Translate", expectedInputContains: "please", category: translate),
            PromptCase(input: "how do I say 'help' in Swedish", expectedTool: "Translate", expectedInputContains: nil, category: translate),
        ]

        // ============================================================
        // CATEGORY: Dictionary (20 prompts)
        // ============================================================
        let dictionary = "Dictionary"
        p += [
            PromptCase(input: "#dictionary ephemeral", expectedTool: "Dictionary", expectedInputContains: "ephemeral", category: dictionary),
            PromptCase(input: "define ephemeral", expectedTool: "Dictionary", expectedInputContains: "ephemeral", category: dictionary),
            PromptCase(input: "what does ubiquitous mean", expectedTool: "Dictionary", expectedInputContains: "ubiquitous", category: dictionary),
            PromptCase(input: "definition of serendipity", expectedTool: "Dictionary", expectedInputContains: "serendipity", category: dictionary),
            PromptCase(input: "meaning of petrichor", expectedTool: "Dictionary", expectedInputContains: "petrichor", category: dictionary),
            PromptCase(input: "#dictionary paradigm", expectedTool: "Dictionary", expectedInputContains: "paradigm", category: dictionary),
            PromptCase(input: "look up the word ameliorate", expectedTool: "Dictionary", expectedInputContains: "ameliorate", category: dictionary),
            PromptCase(input: "dictionary: sycophant", expectedTool: "Dictionary", expectedInputContains: "sycophant", category: dictionary),
            PromptCase(input: "what's the meaning of ostensible", expectedTool: "Dictionary", expectedInputContains: "ostensible", category: dictionary),
            PromptCase(input: "define verbose", expectedTool: "Dictionary", expectedInputContains: "verbose", category: dictionary),
            PromptCase(input: "word meaning: tacit", expectedTool: "Dictionary", expectedInputContains: "tacit", category: dictionary),
            PromptCase(input: "what is a platitude", expectedTool: "Dictionary", expectedInputContains: "platitude", category: dictionary),
            PromptCase(input: "define 'cogent'", expectedTool: "Dictionary", expectedInputContains: "cogent", category: dictionary),
            PromptCase(input: "meaning of obfuscate", expectedTool: "Dictionary", expectedInputContains: "obfuscate", category: dictionary),
            PromptCase(input: "Interesting word. Define 'quixotic'", expectedTool: "Dictionary", expectedInputContains: "quixotic", category: dictionary),
            PromptCase(input: "Ok. #dictionary aberration", expectedTool: "Dictionary", expectedInputContains: "aberration", category: dictionary),
            PromptCase(input: "define hubris", expectedTool: "Dictionary", expectedInputContains: "hubris", category: dictionary),
            PromptCase(input: "what does 'pragmatic' mean?", expectedTool: "Dictionary", expectedInputContains: "pragmatic", category: dictionary),
            PromptCase(input: "definition: ephemeral", expectedTool: "Dictionary", expectedInputContains: "ephemeral", category: dictionary),
            PromptCase(input: "define love", expectedTool: "Dictionary", expectedInputContains: "love", category: dictionary),
        ]

        // ============================================================
        // CATEGORY: Email (15 prompts)
        // ============================================================
        let email = "Email"
        p += [
            PromptCase(input: "#email Hello from iClaw", expectedTool: "Email", expectedInputContains: "Hello", category: email),
            PromptCase(input: "send an email", expectedTool: "Email", expectedInputContains: nil, category: email),
            PromptCase(input: "compose email to john@example.com", expectedTool: "Email", expectedInputContains: "john", category: email),
            PromptCase(input: "email: meeting tomorrow at 3pm", expectedTool: "Email", expectedInputContains: "meeting", category: email),
            PromptCase(input: "write an email about the project", expectedTool: "Email", expectedInputContains: "project", category: email),
            PromptCase(input: "#email", expectedTool: "Email", expectedInputContains: nil, category: email),
            PromptCase(input: "draft an email", expectedTool: "Email", expectedInputContains: nil, category: email),
            PromptCase(input: "email about lunch plans", expectedTool: "Email", expectedInputContains: "lunch", category: email),
            PromptCase(input: "send mail saying I'll be late", expectedTool: "Email", expectedInputContains: "late", category: email),
            PromptCase(input: "compose a message about the report", expectedTool: "Email", expectedInputContains: "report", category: email),
            PromptCase(input: "write email: status update", expectedTool: "Email", expectedInputContains: "status", category: email),
            PromptCase(input: "Hmm. #email Thanks for the update", expectedTool: "Email", expectedInputContains: "Thanks", category: email),
            PromptCase(input: "new email", expectedTool: "Email", expectedInputContains: nil, category: email),
            PromptCase(input: "email reminder about dentist", expectedTool: "Email", expectedInputContains: "dentist", category: email),
            PromptCase(input: "send a quick email", expectedTool: "Email", expectedInputContains: nil, category: email),
        ]

        // ============================================================
        // CATEGORY: Podcast (15 prompts)
        // ============================================================
        let podcast = "Podcast"
        p += [
            PromptCase(input: "#podcast Serial", expectedTool: "Podcast", expectedInputContains: "Serial", category: podcast),
            PromptCase(input: "search for podcasts about AI", expectedTool: "Podcast", expectedInputContains: "AI", category: podcast),
            PromptCase(input: "find a podcast about history", expectedTool: "Podcast", expectedInputContains: "history", category: podcast),
            PromptCase(input: "play podcast Radiolab", expectedTool: "Podcast", expectedInputContains: "Radiolab", category: podcast),
            PromptCase(input: "podcast recommendations", expectedTool: "Podcast", expectedInputContains: nil, category: podcast),
            PromptCase(input: "#podcast", expectedTool: "Podcast", expectedInputContains: nil, category: podcast),
            PromptCase(input: "latest episodes of This American Life", expectedTool: "Podcast", expectedInputContains: nil, category: podcast),
            PromptCase(input: "find podcasts about true crime", expectedTool: "Podcast", expectedInputContains: "crime", category: podcast),
            PromptCase(input: "podcast about technology", expectedTool: "Podcast", expectedInputContains: "technology", category: podcast),
            PromptCase(input: "search podcast: comedy", expectedTool: "Podcast", expectedInputContains: "comedy", category: podcast),
            PromptCase(input: "play a tech podcast", expectedTool: "Podcast", expectedInputContains: "tech", category: podcast),
            PromptCase(input: "Hmm interesting. #podcast science", expectedTool: "Podcast", expectedInputContains: "science", category: podcast),
            PromptCase(input: "any good podcasts?", expectedTool: "Podcast", expectedInputContains: nil, category: podcast),
            PromptCase(input: "podcast search: music", expectedTool: "Podcast", expectedInputContains: "music", category: podcast),
            PromptCase(input: "listen to a podcast", expectedTool: "Podcast", expectedInputContains: nil, category: podcast),
        ]

        // ============================================================
        // CATEGORY: SystemInfo (10 prompts)
        // ============================================================
        let sysinfo = "SystemInfo"
        p += [
            PromptCase(input: "#systeminfo", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "#system_info", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "system info", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "battery level", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "how much disk space do I have", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "CPU usage", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "memory usage", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "what's my WiFi network", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "system status", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
            PromptCase(input: "uptime", expectedTool: "SystemInfo", expectedInputContains: nil, category: sysinfo),
        ]

        // ============================================================
        // CATEGORY: Screenshot (10 prompts)
        // ============================================================
        let screenshot = "Screenshot"
        p += [
            PromptCase(input: "#screenshot", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "take a screenshot", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "capture screen", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "screenshot", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "screen capture", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "what's on my screen", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "OCR the screen", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "read my screen", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "snap the screen", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
            PromptCase(input: "grab a screenshot for me", expectedTool: "Screenshot", expectedInputContains: nil, category: screenshot),
        ]

        // ============================================================
        // CATEGORY: WebFetch (10 prompts)
        // ============================================================
        let webfetch = "WebFetch"
        p += [
            PromptCase(input: "#webfetch https://example.com", expectedTool: "WebFetch", expectedInputContains: "example.com", category: webfetch),
            PromptCase(input: "fetch https://apple.com", expectedTool: "WebFetch", expectedInputContains: "apple.com", category: webfetch),
            PromptCase(input: "get the page at https://news.ycombinator.com", expectedTool: "WebFetch", expectedInputContains: "ycombinator", category: webfetch),
            PromptCase(input: "download https://example.org/data", expectedTool: "WebFetch", expectedInputContains: "example.org", category: webfetch),
            PromptCase(input: "read this URL: https://docs.swift.org", expectedTool: "WebFetch", expectedInputContains: "swift.org", category: webfetch),
            PromptCase(input: "#webfetch", expectedTool: "WebFetch", expectedInputContains: nil, category: webfetch),
            PromptCase(input: "open https://github.com", expectedTool: "WebFetch", expectedInputContains: "github", category: webfetch),
            PromptCase(input: "fetch URL https://api.example.com/data", expectedTool: "WebFetch", expectedInputContains: "api.example", category: webfetch),
            PromptCase(input: "scrape https://wikipedia.org", expectedTool: "WebFetch", expectedInputContains: "wikipedia", category: webfetch),
            PromptCase(input: "Interesting. Fetch https://example.com for me", expectedTool: "WebFetch", expectedInputContains: "example.com", category: webfetch),
        ]

        // ============================================================
        // CATEGORY: Rewrite (10 prompts)
        // ============================================================
        let rewrite = "Rewrite"
        p += [
            PromptCase(input: "#rewrite teh quick brown fox", expectedTool: "Rewrite", expectedInputContains: "teh", category: rewrite),
            PromptCase(input: "fix typos: I hav a problm", expectedTool: "Rewrite", expectedInputContains: "problm", category: rewrite),
            PromptCase(input: "proofread this: recieve the package", expectedTool: "Rewrite", expectedInputContains: "recieve", category: rewrite),
            PromptCase(input: "correct spelling: accomodate", expectedTool: "Rewrite", expectedInputContains: "accomodate", category: rewrite),
            PromptCase(input: "#rewrite", expectedTool: "Rewrite", expectedInputContains: nil, category: rewrite),
            PromptCase(input: "spellcheck: definately", expectedTool: "Rewrite", expectedInputContains: "definately", category: rewrite),
            PromptCase(input: "fix this text: their going too the store", expectedTool: "Rewrite", expectedInputContains: "their", category: rewrite),
            PromptCase(input: "rewrite with correct grammar: me and him went", expectedTool: "Rewrite", expectedInputContains: nil, category: rewrite),
            PromptCase(input: "edit: I should of known better", expectedTool: "Rewrite", expectedInputContains: nil, category: rewrite),
            PromptCase(input: "check spelling: occassionally", expectedTool: "Rewrite", expectedInputContains: "occassionally", category: rewrite),
        ]

        // ============================================================
        // CATEGORY: Read/Write tools (10 prompts)
        // ============================================================
        let readwrite = "ReadWrite"
        p += [
            PromptCase(input: "#read analyze this text", expectedTool: "Read", expectedInputContains: "analyze", category: readwrite),
            PromptCase(input: "#write a poem about the ocean", expectedTool: "Write", expectedInputContains: "ocean", category: readwrite),
            PromptCase(input: "write me a haiku", expectedTool: "Write", expectedInputContains: "haiku", category: readwrite),
            PromptCase(input: "write a short story about robots", expectedTool: "Write", expectedInputContains: "robots", category: readwrite),
            PromptCase(input: "#write", expectedTool: "Write", expectedInputContains: nil, category: readwrite),
            PromptCase(input: "analyze the tone of: I'm so happy today!", expectedTool: "Read", expectedInputContains: "happy", category: readwrite),
            PromptCase(input: "write about artificial intelligence", expectedTool: "Write", expectedInputContains: "artificial", category: readwrite),
            PromptCase(input: "compose a limerick", expectedTool: "Write", expectedInputContains: "limerick", category: readwrite),
            PromptCase(input: "read /tmp/test.txt", expectedTool: "Read", expectedInputContains: "/tmp", category: readwrite),
            PromptCase(input: "write a joke", expectedTool: "Write", expectedInputContains: "joke", category: readwrite),
        ]

        // ============================================================
        // CATEGORY: Transcribe (10 prompts)
        // ============================================================
        let transcribe = "Transcribe"
        p += [
            PromptCase(input: "#transcribe /tmp/audio.m4a", expectedTool: "Transcribe", expectedInputContains: "audio.m4a", category: transcribe),
            PromptCase(input: "#transcribe /Users/test/recording.wav", expectedTool: "Transcribe", expectedInputContains: "recording.wav", category: transcribe),
            PromptCase(input: "transcribe this audio file", expectedTool: "Transcribe", expectedInputContains: nil, category: transcribe),
            PromptCase(input: "convert speech to text /tmp/voice.mp3", expectedTool: "Transcribe", expectedInputContains: "voice.mp3", category: transcribe),
            PromptCase(input: "#transcribe", expectedTool: "Transcribe", expectedInputContains: nil, category: transcribe),
            PromptCase(input: "audio to text", expectedTool: "Transcribe", expectedInputContains: nil, category: transcribe),
            PromptCase(input: "transcribe meeting recording", expectedTool: "Transcribe", expectedInputContains: "meeting", category: transcribe),
            PromptCase(input: "speech to text", expectedTool: "Transcribe", expectedInputContains: nil, category: transcribe),
            PromptCase(input: "transcribe /tmp/interview.mp3", expectedTool: "Transcribe", expectedInputContains: "interview", category: transcribe),
            PromptCase(input: "Sure. #transcribe /tmp/test.m4a", expectedTool: "Transcribe", expectedInputContains: "test.m4a", category: transcribe),
        ]

        // ============================================================
        // CATEGORY: Ambiguous / Cross-tool (30 prompts)
        // ============================================================
        let ambiguous = "Ambiguous"
        p += [
            PromptCase(input: "convert time zones", expectedTool: nil, expectedInputContains: nil, category: ambiguous),  // Time or Convert?
            PromptCase(input: "how much is Apple?", expectedTool: nil, expectedInputContains: nil, category: ambiguous),  // stocks or convert?
            PromptCase(input: "what's 5 o'clock in Tokyo", expectedTool: "Time", expectedInputContains: "Tokyo", category: ambiguous),
            PromptCase(input: "random weather in London", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "email the stock price", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "calculate the weather", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "translate 5 + 5", expectedTool: "Translate", expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "What day was July 4 1776?", expectedTool: "Calendar", expectedInputContains: "1776", category: ambiguous),
            PromptCase(input: "play me something", expectedTool: "Podcast", expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "set a reminder", expectedTool: nil, expectedInputContains: nil, category: ambiguous),  // Timer or FM Reminders?
            PromptCase(input: "write an email about the weather", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "how much does AAPL cost in euros", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "read the news", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "convert this to French", expectedTool: nil, expectedInputContains: nil, category: ambiguous), // Translate or Convert?
            PromptCase(input: "search for restaurants", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "calendar and timer", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "define the weather", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "stock timer", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "translate the time", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "write a poem and email it", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "screenshot and read it", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "what can you do?", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "help", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "hello", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "thanks", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "who are you?", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "tell me a joke", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "what's the meaning of life?", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
            PromptCase(input: "sing me a song", expectedTool: nil, expectedInputContains: nil, category: ambiguous),
        ]

        // ============================================================
        // CATEGORY: Conversational preamble + chip (40 prompts)
        // These test the key bug: does preamble text corrupt tool input?
        // ============================================================
        let preamble = "Preamble"
        p += [
            PromptCase(input: "That's great! #weather London", expectedTool: "Weather", expectedInputContains: "London", category: preamble),
            PromptCase(input: "Hmm ok. #timer 5 minutes", expectedTool: "Timer", expectedInputContains: "5", category: preamble),
            PromptCase(input: "Sure, let me check. #stocks MSFT", expectedTool: "Stocks", expectedInputContains: "MSFT", category: preamble),
            PromptCase(input: "Interesting point. #calculator 2+2", expectedTool: "Calculator", expectedInputContains: "2+2", category: preamble),
            PromptCase(input: "That's wild! Now #translate hello", expectedTool: "Translate", expectedInputContains: "hello", category: preamble),
            PromptCase(input: "Wow, ok. #dictionary serendipity", expectedTool: "Dictionary", expectedInputContains: "serendipity", category: preamble),
            PromptCase(input: "Yeah I agree. #convert 10 miles to km", expectedTool: "Convert", expectedInputContains: "miles", category: preamble),
            PromptCase(input: "No way! #random d20", expectedTool: "Random", expectedInputContains: "d20", category: preamble),
            PromptCase(input: "Fine fine. #email hello world", expectedTool: "Email", expectedInputContains: "hello", category: preamble),
            PromptCase(input: "Ok but first, #screenshot", expectedTool: "Screenshot", expectedInputContains: nil, category: preamble),
            PromptCase(input: "That's unhinged. #stocks AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: preamble),
            PromptCase(input: "Ha! Good one. #weather Paris", expectedTool: "Weather", expectedInputContains: "Paris", category: preamble),
            PromptCase(input: "Wait what? #time Berlin", expectedTool: "Time", expectedInputContains: "Berlin", category: preamble),
            PromptCase(input: "lol that's hilarious. #calendar July 4 2030", expectedTool: "Calendar", expectedInputContains: "July", category: preamble),
            PromptCase(input: "Idk about that. #podcast tech", expectedTool: "Podcast", expectedInputContains: "tech", category: preamble),
            PromptCase(input: "Makes sense. #systeminfo", expectedTool: "SystemInfo", expectedInputContains: nil, category: preamble),
            PromptCase(input: "Ok fine. $NVDA", expectedTool: "Stocks", expectedInputContains: "NVDA", category: preamble),
            PromptCase(input: "Sure thing. $META please", expectedTool: "Stocks", expectedInputContains: "META", category: preamble),
            PromptCase(input: "You're right. #rewrite teh spellin is wrong", expectedTool: "Rewrite", expectedInputContains: "teh", category: preamble),
            PromptCase(input: "Absolutely. #write a poem about cats", expectedTool: "Write", expectedInputContains: "cats", category: preamble),
            // Multi-sentence preambles
            PromptCase(input: "I was thinking about this earlier. Anyway. #weather Tokyo", expectedTool: "Weather", expectedInputContains: "Tokyo", category: preamble),
            PromptCase(input: "That was a weird response. Let me try again. #stocks GOOG", expectedTool: "Stocks", expectedInputContains: "GOOG", category: preamble),
            PromptCase(input: "Ok so I had this idea. But first, #timer 10 min", expectedTool: "Timer", expectedInputContains: "10", category: preamble),
            PromptCase(input: "Right. Good point. Now #calculator 100/7", expectedTool: "Calculator", expectedInputContains: "100", category: preamble),
            PromptCase(input: "I don't think that's correct. Check $AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: preamble),
            // Emotional/expressive preambles
            PromptCase(input: "OMG!!! #weather London", expectedTool: "Weather", expectedInputContains: "London", category: preamble),
            PromptCase(input: "Nah, that's wrong. #stocks TSLA", expectedTool: "Stocks", expectedInputContains: "TSLA", category: preamble),
            PromptCase(input: "Bruh. #timer 2 minutes", expectedTool: "Timer", expectedInputContains: "2", category: preamble),
            PromptCase(input: "LMAO ok. #random coin", expectedTool: "Random", expectedInputContains: "coin", category: preamble),
            PromptCase(input: "hahaha that was great. #translate merci", expectedTool: "Translate", expectedInputContains: "merci", category: preamble),
            // Preambles with apostrophes/contractions (the exact bug)
            PromptCase(input: "That's cool, #stocks V", expectedTool: "Stocks", expectedInputContains: "V", category: preamble),
            PromptCase(input: "I'm curious, #weather NYC", expectedTool: "Weather", expectedInputContains: "NYC", category: preamble),
            PromptCase(input: "Don't care, #timer 30s", expectedTool: "Timer", expectedInputContains: "30", category: preamble),
            PromptCase(input: "He's asking about #stocks AMD", expectedTool: "Stocks", expectedInputContains: "AMD", category: preamble),
            PromptCase(input: "They're wrong. #convert 5 kg to lbs", expectedTool: "Convert", expectedInputContains: "kg", category: preamble),
            PromptCase(input: "It's whatever. #dictionary hubris", expectedTool: "Dictionary", expectedInputContains: "hubris", category: preamble),
            PromptCase(input: "We've been through this. #weather Berlin", expectedTool: "Weather", expectedInputContains: "Berlin", category: preamble),
            PromptCase(input: "You're killing me. $JPM", expectedTool: "Stocks", expectedInputContains: "JPM", category: preamble),
            PromptCase(input: "I can't believe it. #stocks COST", expectedTool: "Stocks", expectedInputContains: "COST", category: preamble),
            PromptCase(input: "Wouldn't you know it. #time Tokyo", expectedTool: "Time", expectedInputContains: "Tokyo", category: preamble),
        ]

        // ============================================================
        // CATEGORY: Edge cases (35 prompts)
        // ============================================================
        let edge = "Edge"
        p += [
            PromptCase(input: "   ", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "!!!", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "???", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "#", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "$", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "#nonexistenttool", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "$ZZZZZ", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "12345", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "#weather #stocks #timer", expectedTool: "Weather", expectedInputContains: nil, category: edge),
            PromptCase(input: "$50 cash", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "$100 dollars", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "I have $20", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "A", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "ok", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "yes", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "no", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "stop", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "cancel", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "never mind", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "WEATHER", expectedTool: "Weather", expectedInputContains: nil, category: edge),
            PromptCase(input: "STOCKS AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: edge),
            PromptCase(input: "#WEATHER London", expectedTool: "Weather", expectedInputContains: "London", category: edge),
            PromptCase(input: "#STOCKS AAPL", expectedTool: "Stocks", expectedInputContains: "AAPL", category: edge),
            PromptCase(input: "weather!!", expectedTool: "Weather", expectedInputContains: nil, category: edge),
            PromptCase(input: "stocks???", expectedTool: "Stocks", expectedInputContains: nil, category: edge),
            PromptCase(input: "Can you please tell me the weather forecast for London, UK?", expectedTool: "Weather", expectedInputContains: "London", category: edge),
            PromptCase(input: "I would really appreciate it if you could show me the current stock price for Apple Inc (AAPL) please", expectedTool: "Stocks", expectedInputContains: "AAPL", category: edge),
            PromptCase(input: "你好", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "🌤️ weather?", expectedTool: "Weather", expectedInputContains: nil, category: edge),
            PromptCase(input: "#weather\n\nLondon", expectedTool: "Weather", expectedInputContains: nil, category: edge),
            PromptCase(input: "the the the the the", expectedTool: nil, expectedInputContains: nil, category: edge),
            PromptCase(input: "weather weather weather", expectedTool: "Weather", expectedInputContains: nil, category: edge),
            PromptCase(input: "#stocks #stocks #stocks", expectedTool: "Stocks", expectedInputContains: nil, category: edge),
            PromptCase(input: "What is the meaning of $AAPL in the context of stocks?", expectedTool: "Stocks", expectedInputContains: "AAPL", category: edge),
            PromptCase(input: "I spent $5 on coffee", expectedTool: nil, expectedInputContains: nil, category: edge),
        ]

        // ============================================================
        // CATEGORY: Natural language (no chips) for various tools (50 prompts)
        // ============================================================
        let natural = "NaturalLang"
        p += [
            PromptCase(input: "What's Bitcoin worth right now", expectedTool: "Convert", expectedInputContains: nil, category: natural),
            PromptCase(input: "flip a coin for me", expectedTool: "Random", expectedInputContains: nil, category: natural),
            PromptCase(input: "how do you say hello in Spanish", expectedTool: "Translate", expectedInputContains: nil, category: natural),
            PromptCase(input: "convert 100 dollars to euros", expectedTool: "Convert", expectedInputContains: nil, category: natural),
            PromptCase(input: "roll a d6", expectedTool: "Random", expectedInputContains: nil, category: natural),
            PromptCase(input: "what day of the week is Christmas this year", expectedTool: "Calendar", expectedInputContains: nil, category: natural),
            PromptCase(input: "what's 42 times 17", expectedTool: "Calculator", expectedInputContains: nil, category: natural),
            PromptCase(input: "fix the typos in: I shoud hav known", expectedTool: "Rewrite", expectedInputContains: nil, category: natural),
            PromptCase(input: "write a haiku about rain", expectedTool: "Write", expectedInputContains: nil, category: natural),
            PromptCase(input: "what's happening in the news", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "take a photo", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "open Safari", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "copy that to clipboard", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "search Wikipedia for Alan Turing", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "find files named report.pdf", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "text mom I'll be late", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "get directions to the airport", expectedTool: "Maps", expectedInputContains: nil, category: natural),
            PromptCase(input: "add a reminder to buy milk", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "schedule a meeting at 3pm", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "read my contacts", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "analyze /tmp/document.txt", expectedTool: "Read", expectedInputContains: "/tmp", category: natural),
            PromptCase(input: "check my health data", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "run the 'Morning' shortcut", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "create a note about meeting", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "what's the ETA to downtown", expectedTool: "Maps", expectedInputContains: nil, category: natural),
            PromptCase(input: "lock the screen", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "turn up the volume", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "dim the display", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "empty the trash", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "what are my steps today", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "how far did I walk", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "search my files for budget", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "mute", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "sleep", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "restart", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "shut down", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "log out", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "brightness 50%", expectedTool: nil, expectedInputContains: nil, category: natural),
            PromptCase(input: "what's my battery at", expectedTool: "SystemInfo", expectedInputContains: nil, category: natural),
            PromptCase(input: "how much storage is left", expectedTool: "SystemInfo", expectedInputContains: nil, category: natural),
            PromptCase(input: "define schadenfreude", expectedTool: "Dictionary", expectedInputContains: "schadenfreude", category: natural),
            PromptCase(input: "what does 'sonder' mean", expectedTool: "Dictionary", expectedInputContains: "sonder", category: natural),
            PromptCase(input: "spell check: recieve, occassion, definately", expectedTool: "Rewrite", expectedInputContains: nil, category: natural),
            PromptCase(input: "compose a tweet about AI", expectedTool: "Write", expectedInputContains: nil, category: natural),
            PromptCase(input: "email John about the project deadline", expectedTool: "Email", expectedInputContains: nil, category: natural),
            PromptCase(input: "search for cooking podcasts", expectedTool: "Podcast", expectedInputContains: nil, category: natural),
            PromptCase(input: "what's the current time in Hong Kong", expectedTool: "Time", expectedInputContains: "Hong Kong", category: natural),
            PromptCase(input: "days until New Year", expectedTool: "Calendar", expectedInputContains: nil, category: natural),
            PromptCase(input: "pick a random number 1-1000", expectedTool: "Random", expectedInputContains: "1000", category: natural),
            PromptCase(input: "how many liters in a gallon", expectedTool: "Convert", expectedInputContains: nil, category: natural),
        ]

        return p
    }()

    func testComprehensiveRoutingAudit() async throws {
        try require(.auditTests)
        let allCoreToolNames = ["Calendar", "Time", "Timer", "Random", "Rewrite", "Read", "Write",
                                "Email", "Convert", "Calculator", "WebFetch", "Translate",
                                "Transcribe", "Podcast", "Weather", "Stocks", "Dictionary",
                                "SystemInfo", "Screenshot", "Maps"]

        var results: [AuditResult] = []
        var passCount = 0
        var failCount = 0

        for prompt in Self.prompts {
            // Create spy tools for ALL tools to see which one gets invoked
            let spies: [SpyTool] = allCoreToolNames.map { name in
                SpyTool(name: name, schema: "\(name) tool schema", result: ToolIO(text: "result from \(name)", status: .ok, outputWidget: name == "Stocks" ? "StockWidget" : nil))
            }

            let engine = makeTestEngine(tools: spies)
            _ = await engine.run(input: prompt.input)

            // Find which spy was invoked
            let invokedSpy = spies.first { !$0.invocations.isEmpty }
            let actualTool = invokedSpy?.name
            let toolInput = invokedSpy?.invocations.first?.input

            // Evaluate pass/fail
            var pass = true
            var notes = ""

            if let expected = prompt.expectedTool {
                if actualTool != expected {
                    pass = false
                    notes = "ROUTING: Expected '\(expected)', got '\(actualTool ?? "none")'"
                } else if let expectedContains = prompt.expectedInputContains {
                    if let input = toolInput, !input.contains(expectedContains) {
                        pass = false
                        notes = "INPUT: Expected tool input to contain '\(expectedContains)', got '\(input)'"
                    }
                }
            } else {
                // Expected no specific tool match (ambiguous/edge case)
                // These are "soft" — we note what happened but don't auto-fail
                if let actual = actualTool {
                    notes = "INFO: No specific tool expected, routed to '\(actual)'"
                } else {
                    notes = "OK: No tool matched (as potentially expected)"
                }
            }

            if pass { passCount += 1 } else { failCount += 1 }

            results.append(AuditResult(
                input: prompt.input,
                category: prompt.category,
                expectedTool: prompt.expectedTool,
                actualTool: actualTool,
                toolInput: toolInput,
                expectedInputContains: prompt.expectedInputContains,
                pass: pass,
                notes: notes
            ))
        }

        // Generate report
        var report = "# iClaw Routing Audit Report\n\n"
        report += "**Total prompts:** \(results.count)\n"
        report += "**Pass:** \(passCount) | **Fail:** \(failCount)\n"
        report += "**Pass rate:** \(String(format: "%.1f", Double(passCount) / Double(results.count) * 100))%\n\n"

        // Summary by category
        let categories = Dictionary(grouping: results, by: \.category)
        report += "## Summary by Category\n\n"
        report += "| Category | Total | Pass | Fail | Rate |\n"
        report += "|----------|-------|------|------|------|\n"
        for (cat, catResults) in categories.sorted(by: { $0.key < $1.key }) {
            let catPass = catResults.filter(\.pass).count
            let catFail = catResults.count - catPass
            let rate = String(format: "%.0f%%", Double(catPass) / Double(catResults.count) * 100)
            report += "| \(cat) | \(catResults.count) | \(catPass) | \(catFail) | \(rate) |\n"
        }

        // Failures detail
        let failures = results.filter { !$0.pass }
        if !failures.isEmpty {
            report += "\n## Failures\n\n"
            report += "| # | Category | Input | Expected | Actual | Tool Input | Notes |\n"
            report += "|---|----------|-------|----------|--------|------------|-------|\n"
            for (i, f) in failures.enumerated() {
                let escapedInput = f.input.replacingOccurrences(of: "|", with: "\\|").prefix(60)
                let escapedToolInput = (f.toolInput ?? "—").replacingOccurrences(of: "|", with: "\\|").prefix(40)
                report += "| \(i+1) | \(f.category) | \(escapedInput) | \(f.expectedTool ?? "none") | \(f.actualTool ?? "none") | \(escapedToolInput) | \(f.notes) |\n"
            }
        }

        // Full results
        report += "\n## Full Results\n\n"
        report += "| # | P/F | Category | Input | Expected | Actual | Tool Input | Notes |\n"
        report += "|---|-----|----------|-------|----------|--------|------------|-------|\n"
        for (i, r) in results.enumerated() {
            let status = r.pass ? "✅" : "❌"
            let escapedInput = r.input.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ").prefix(50)
            let escapedToolInput = (r.toolInput ?? "—").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ").prefix(35)
            let escapedNotes = r.notes.replacingOccurrences(of: "|", with: "\\|").prefix(60)
            report += "| \(i+1) | \(status) | \(r.category) | \(escapedInput) | \(r.expectedTool ?? "—") | \(r.actualTool ?? "—") | \(escapedToolInput) | \(escapedNotes) |\n"
        }

        // Write report
        let reportPath = "/tmp/iclaw_routing_audit.md"
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        print("\n📊 AUDIT REPORT written to: \(reportPath)")
        print("Total: \(results.count) | Pass: \(passCount) | Fail: \(failCount)")

        // Don't fail the test — this is an audit, not a gate
        // But print summary for visibility
        if failCount > 0 {
            print("\n⚠️  \(failCount) FAILURES detected. See report for details.")
            for f in failures {
                print("  ❌ [\(f.category)] \"\(f.input.prefix(50))\" → expected \(f.expectedTool ?? "none"), got \(f.actualTool ?? "none"). \(f.notes)")
            }
        }
    }
}
