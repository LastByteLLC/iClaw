import Foundation
import AppIntents

/// Data structure for RandomWidgetView.
public struct RandomWidgetData: Sendable {
    public let type: String
    public let result: String
    public let details: String?
    // Args for refresh — allows the widget to regenerate without re-routing
    public let intent: String?
    public let sides: Int?
    public let count: Int?
    public let min: Int?
    public let max: Int?

    public init(type: String, result: String, details: String? = nil,
                intent: String? = nil, sides: Int? = nil, count: Int? = nil, min: Int? = nil, max: Int? = nil) {
        self.type = type
        self.result = result
        self.details = details
        self.intent = intent
        self.sides = sides
        self.count = count
        self.min = min
        self.max = max
    }
}

/// Structured arguments for LLM-extracted random requests.
public struct RandomArgs: ToolArguments {
    public let intent: String   // "coin", "dice", "card", "number", "date", "color", "password"
    public let sides: Int?
    public let count: Int?
    public let min: Int?
    public let max: Int?

    public init(intent: String, sides: Int? = nil, count: Int? = nil, min: Int? = nil, max: Int? = nil) {
        self.intent = intent
        self.sides = sides
        self.count = count
        self.min = min
        self.max = max
    }
}

/// Random tool for rolling dice, flipping coins, drawing cards, and generating random numbers.
public struct RandomTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Random"
    public let schema = "Generate random results: 'roll a d20', 'flip a coin', 'draw a card', 'random number between 1 and 100', or 'generate a password'."
    public let isInternal = false
    public let category = CategoryEnum.offline

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    public init() {}

    // MARK: - ExtractableCoreTool

    public typealias Args = RandomArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Random", fallback: "{\"intent\":\"coin|dice|card|number\"}"
    )

    public func execute(args: RandomArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            var resultType = ""
            var resultValue = ""
            var resultDetails: String? = nil
            // Resolved dice values — hoisted so widgetData can capture them.
            var resolvedSides: Int? = args.sides
            var resolvedCount: Int? = args.count

            switch args.intent {
            case "coin":
                resultType = "Coin Flip"
                resultValue = Bool.random() ? "Heads" : "Tails"
            case "card":
                return Self.buildCardResult()
            case "dice":
                resultType = "Dice Roll"
                // The on-device LLM often fails to extract count/sides from NdS
                // notation (e.g., "3d8"). Parse rawInput as fallback when the
                // extractor returned defaults.
                var sides = args.sides ?? 6
                var diceCount = args.count ?? 1
                if let ndRange = rawInput.lowercased().range(of: #"(\d+)d(\d+)"#, options: .regularExpression) {
                    let ndStr = String(rawInput[ndRange])
                    let parts = ndStr.split(separator: "d")
                    if parts.count == 2, let n = Int(parts[0]), let s = Int(parts[1]) {
                        if args.count == nil { diceCount = n }
                        if args.sides == nil { sides = s }
                    }
                } else if args.sides == nil,
                          let dRange = rawInput.lowercased().range(of: #"d(\d+)"#, options: .regularExpression),
                          let s = Int(rawInput[dRange].dropFirst()) {
                    sides = s
                }
                sides = max(sides, 1)
                diceCount = max(min(diceCount, 100), 1)
                resolvedSides = sides
                if diceCount > 1 { resolvedCount = diceCount }
                if diceCount == 1 {
                    resultValue = "\(Int.random(in: 1...sides))"
                    resultDetails = "d\(sides)"
                } else {
                    let rolls = (0..<diceCount).map { _ in Int.random(in: 1...sides) }
                    let total = rolls.reduce(0, +)
                    resultValue = rolls.map(String.init).joined(separator: ", ") + " (total: \(total))"
                    resultDetails = "\(diceCount)d\(sides)"
                }
            case "number":
                resultType = "Random Number"
                let rawMin = args.min ?? 1
                let rawMax = args.max ?? 100
                let minVal = min(rawMin, rawMax)
                let maxVal = max(rawMin, rawMax)
                resultValue = "\(Int.random(in: minVal...maxVal))"
                resultDetails = "\(minVal) to \(maxVal)"
            case "date":
                resultType = "Random Date"
                let calendar = Calendar.current
                let now = Date()
                let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now)!
                let oneYearAhead = calendar.date(byAdding: .year, value: 1, to: now)!
                let range = oneYearAgo.timeIntervalSince1970...oneYearAhead.timeIntervalSince1970
                let randomDate = Date(timeIntervalSince1970: Double.random(in: range))
                resultValue = Self.longDateFormatter.string(from: randomDate)
            case "color":
                resultType = "Random Color"
                let r = Int.random(in: 0...255)
                let g = Int.random(in: 0...255)
                let b = Int.random(in: 0...255)
                resultValue = String(format: "#%02X%02X%02X", r, g, b)
                resultDetails = "RGB(\(r), \(g), \(b))"
            case "password":
                resultType = "Password"
                let length = args.count ?? 16
                let charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
                var password = (0..<max(length, 12)).map { _ in
                    charset.randomElement()!
                }
                // Guarantee at least one of each type
                password[0] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()!
                password[1] = "abcdefghijklmnopqrstuvwxyz".randomElement()!
                password[2] = "0123456789".randomElement()!
                password[3] = "!@#$%^&*".randomElement()!
                resultValue = String(password.shuffled())
                resultDetails = "\(password.count) characters"
            default:
                resultType = "Random Number"
                resultValue = "\(Int.random(in: 1...100))"
                resultDetails = "1 to 100"
            }

            let widgetData = RandomWidgetData(
                type: resultType, result: resultValue, details: resultDetails,
                intent: args.intent, sides: resolvedSides, count: resolvedCount, min: args.min, max: args.max
            )
            let text = "Result: \(resultValue) (\(resultType)\(resultDetails != nil ? " " + resultDetails! : ""))"

            return ToolIO(
                text: text,
                status: .ok,
                outputWidget: "RandomWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let lowerInput = input.lowercased()

            // Check for compound requests: "flip a coin and roll a die"
            let segments = lowerInput.components(separatedBy: " and ")
            if segments.count >= 2 {
                let hasMultipleIntents = segments.allSatisfy { segment in
                    let s = segment.trimmingCharacters(in: .whitespaces)
                    return Self.hasAnyRandomIntent(s)
                }
                if hasMultipleIntents {
                    return executeCompound(segments: segments)
                }
            }

            return executeSingle(input: lowerInput)
        }
    }

    /// Multilingual intent table for random subtypes. Replaces the inline
    /// English `contains()` cascade.
    static let intentKeywords: MultilingualKeywords? = MultilingualKeywords.load("RandomIntentKeywords")

    /// Returns true if `text` matches any of the random sub-intents.
    static func hasAnyRandomIntent(_ text: String) -> Bool {
        guard let kw = intentKeywords else { return false }
        // d20 / 2d6 NdS notation is universal across languages.
        if text.range(of: #"\bd\d+|\d+d\d+"#, options: .regularExpression) != nil {
            return true
        }
        return kw.matches(intent: "coin_flip", in: text)
            || kw.matches(intent: "dice_roll", in: text)
            || kw.matches(intent: "card_draw", in: text)
            || kw.matches(intent: "random_number", in: text)
            || kw.matches(intent: "random_pick", in: text)
    }

    private func executeSingle(input: String) -> ToolIO {
        let lowerInput = input

        var resultType = ""
        var resultValue = ""
        var resultDetails: String? = nil
        var inferredIntent: String? = nil
        var inferredSides: Int? = nil
        var inferredCount: Int? = nil
        var inferredMin: Int? = nil
        var inferredMax: Int? = nil

        let kw = Self.intentKeywords
        if let kw, kw.matches(intent: "coin_flip", in: lowerInput) {
            resultType = "Coin Flip"
            resultValue = Bool.random() ? "Heads" : "Tails"
            inferredIntent = "coin"
        } else if let kw, kw.matches(intent: "card_draw", in: lowerInput) {
            return Self.buildCardResult()
        } else if (kw?.matches(intent: "dice_roll", in: lowerInput) ?? false)
                    || lowerInput.range(of: #"\bd\d+"#, options: .regularExpression) != nil {
            resultType = "Dice Roll"
            var sides = 6
            var diceCount = 1

            // Parse NdS notation: "2d6", "3d20"
            if let ndRange = lowerInput.range(of: #"(\d+)d(\d+)"#, options: .regularExpression) {
                let ndStr = String(lowerInput[ndRange])
                let parts = ndStr.split(separator: "d")
                if parts.count == 2, let n = Int(parts[0]), let s = Int(parts[1]) {
                    diceCount = max(min(n, 100), 1)
                    sides = max(s, 1)
                }
            } else {
                // Parse side count from "d20" notation
                if let range = lowerInput.range(of: "d(\\d+)", options: .regularExpression),
                   let s = Int(lowerInput[range].dropFirst()) {
                    sides = max(s, 1)
                }
                // Parse word-number count: "two dice", "three dice"
                let wordNumbers: [(word: String, value: Int)] = [
                    ("two", 2), ("three", 3), ("four", 4), ("five", 5), ("six", 6),
                    ("seven", 7), ("eight", 8), ("nine", 9), ("ten", 10),
                ]
                for (word, value) in wordNumbers {
                    if lowerInput.contains(word) { diceCount = value; break }
                }
                // Parse numeric count: "2 dice", "3 dice"
                if diceCount == 1,
                   let numRange = lowerInput.range(of: #"(\d+)\s*dice"#, options: .regularExpression) {
                    let numStr = lowerInput[numRange].prefix(while: { $0.isNumber })
                    if let n = Int(numStr) { diceCount = max(min(n, 100), 1) }
                }
            }

            if diceCount == 1 {
                resultValue = "\(Int.random(in: 1...sides))"
                resultDetails = "d\(sides)"
            } else {
                let rolls = (0..<diceCount).map { _ in Int.random(in: 1...sides) }
                let total = rolls.reduce(0, +)
                resultValue = rolls.map(String.init).joined(separator: ", ") + " (total: \(total))"
                resultDetails = "\(diceCount)d\(sides)"
            }
            inferredIntent = "dice"
            inferredSides = sides
            if diceCount > 1 { inferredCount = diceCount }
        } else if let kw, kw.matches(intent: "random_number", in: lowerInput) {
            resultType = "Random Number"
            let numbers = lowerInput.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { Int($0) }
            if numbers.count >= 2 {
                let minVal = min(numbers[0], numbers[1])
                let maxVal = max(numbers[0], numbers[1])
                resultValue = "\(Int.random(in: minVal...maxVal))"
                resultDetails = "\(minVal) to \(maxVal)"
                inferredMin = minVal
                inferredMax = maxVal
            } else {
                resultValue = "\(Int.random(in: 1...100))"
                resultDetails = "1 to 100"
            }
            inferredIntent = "number"
        } else if lowerInput.contains("date") || lowerInput.contains("day") {
            resultType = "Random Date"
            let calendar = Calendar.current
            let now = Date()
            let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now)!
            let oneYearAhead = calendar.date(byAdding: .year, value: 1, to: now)!
            let range = oneYearAgo.timeIntervalSince1970...oneYearAhead.timeIntervalSince1970
            let randomDate = Date(timeIntervalSince1970: Double.random(in: range))
            resultValue = Self.longDateFormatter.string(from: randomDate)
            inferredIntent = "date"
        } else if lowerInput.contains("color") || lowerInput.contains("colour") {
            resultType = "Random Color"
            let r = Int.random(in: 0...255)
            let g = Int.random(in: 0...255)
            let b = Int.random(in: 0...255)
            resultValue = String(format: "#%02X%02X%02X", r, g, b)
            resultDetails = "RGB(\(r), \(g), \(b))"
            inferredIntent = "color"
        } else if lowerInput.contains("password") {
            resultType = "Password"
            let charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*"
            var password = (0..<16).map { _ in charset.randomElement()! }
            password[0] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".randomElement()!
            password[1] = "abcdefghijklmnopqrstuvwxyz".randomElement()!
            password[2] = "0123456789".randomElement()!
            password[3] = "!@#$%^&*".randomElement()!
            resultValue = String(password.shuffled())
            resultDetails = "16 characters"
            inferredIntent = "password"
        } else {
            resultType = "Random Number"
            resultValue = "\(Int.random(in: 1...100))"
            resultDetails = "1 to 100"
            inferredIntent = "number"
        }

        let widgetData = RandomWidgetData(
            type: resultType, result: resultValue, details: resultDetails,
            intent: inferredIntent, sides: inferredSides, count: inferredCount, min: inferredMin, max: inferredMax
        )
        let text = "Result: \(resultValue) (\(resultType)\(resultDetails != nil ? " " + resultDetails! : ""))"

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "RandomWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    /// Builds a playing card result using DynamicWidgetBuilder.
    static func buildCardResult() -> ToolIO {
        let suits: [(symbol: String, name: String, icon: String, tint: WidgetTint?)] = [
            ("♠", "Spades", "suit.spade.fill", nil),
            ("♥", "Hearts", "suit.heart.fill", .red),
            ("♦", "Diamonds", "suit.diamond.fill", .red),
            ("♣", "Clubs", "suit.club.fill", nil),
        ]
        let ranks: [(short: String, name: String)] = [
            ("A", "Ace"), ("2", "Two"), ("3", "Three"), ("4", "Four"), ("5", "Five"),
            ("6", "Six"), ("7", "Seven"), ("8", "Eight"), ("9", "Nine"), ("10", "Ten"),
            ("J", "Jack"), ("Q", "Queen"), ("K", "King"),
        ]

        let suit = suits.randomElement()!
        let rank = ranks.randomElement()!
        let cardLabel = "\(rank.short)\(suit.symbol)"

        var builder = DynamicWidgetBuilder(tint: suit.tint)
        builder.header(icon: suit.icon, title: "Playing Card", subtitle: "Standard 52-card deck")
        builder.stat(value: cardLabel, label: "\(rank.name) of \(suit.name)")
        let data = builder.build()

        return ToolIO(
            text: "Card drawn: \(rank.name) of \(suit.name) (\(cardLabel))",
            status: .ok,
            outputWidget: "DynamicWidget",
            widgetData: data,
            isVerifiedData: true
        )
    }

    private func executeCompound(segments: [String]) -> ToolIO {
        var results: [String] = []
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let single = executeSingle(input: trimmed)
            results.append(single.text)
        }
        let combined = results.joined(separator: " | ")
        return ToolIO(
            text: combined,
            status: .ok,
            outputWidget: "RandomWidget",
            widgetData: RandomWidgetData(type: "Multiple", result: combined, details: "\(results.count) results", intent: "number"),
            isVerifiedData: true
        )
    }
}

public struct RandomIntent: AppIntent {
    public static var title: LocalizedStringResource { "Random Generator" }
    public static var description: IntentDescription? { IntentDescription("Generates random results using the iClaw RandomTool.") }

    @Parameter(title: "Query")
    public var query: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = RandomTool()
        let result = try await tool.execute(input: query, entities: nil)
        return .result(value: result.text)
    }
}
