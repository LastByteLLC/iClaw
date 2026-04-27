import Foundation
import AppIntents

/// Data structure for CalendarWidgetView.
public struct CalendarWidgetData: Sendable {
    public let title: String
    public let result: String
    public let date: Date?
    
    public init(title: String, result: String, date: Date? = nil) {
        self.title = title
        self.result = result
        self.date = date
    }
}

public struct CalendarArgs: ToolArguments {
    public let intent: String
    public let amount: Int?
    public let unit: String?
    public let direction: String?
    public let targetDate: String?
    public let viewScope: String?
}

/// Calendar tool for date-related calculations.
///
/// Handles ONLY date arithmetic (days between, day-of-week lookup, relative-date
/// shifts, today's date). It does NOT list calendar events, meetings, or
/// appointments — those queries belong to `CalendarEventTool`. The self-refusal
/// guard in `execute(input:)` / `execute(args:)` prevents silent fabrication
/// when the router (or verifier LLM) mistakenly picks Calendar for an event
/// query: see `isEventQuery(_:)`.
public struct CalendarTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Calendar"
    public let schema = "Date arithmetic only: 'day of the week for July 4 2026', 'days between today and Christmas', 'days until next Friday', '90 days from now'. Does NOT list meetings, events, or appointments — CalendarEvent handles those."
    public let isInternal = false
    public let category = CategoryEnum.offline

    /// Multilingual intent keywords loaded from
    /// `Resources/Config/CalendarIntentKeywords.json`.
    static let intentKeywords: MultilingualKeywords? = MultilingualKeywords.load("CalendarIntentKeywords")

    private let session: URLSession

    public init(session: URLSession = .iClawDefault) {
        self.session = session
    }

    // MARK: - Cached Date Formatters

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    private static let apiDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    // MARK: - ExtractableCoreTool

    public typealias Args = CalendarArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Calendar", fallback: "{\"intent\":\"relative|between|dayOfWeek|until|today\"}"
    )

    // MARK: - Holiday Resolution

    /// Fixed holidays that don't need an API call. Month/day pairs.
    private static let fixedHolidays: [(keywords: [String], month: Int, day: Int)] = [
        (["christmas", "xmas", "christmas day"], 12, 25),
        (["new year", "new years", "new year's", "nye"], 1, 1),
        (["halloween"], 10, 31),
        (["valentine", "valentines", "valentine's"], 2, 14),
        (["independence day", "4th of july", "fourth of july", "july 4th", "july fourth"], 7, 4),
        (["st patrick", "saint patrick", "st. patrick"], 3, 17),
        (["boxing day"], 12, 26),
        (["new year's eve", "new years eve"], 12, 31),
    ]

    /// Resolves a holiday name from the input. Checks fixed holidays first,
    /// then queries Nager.Date API for locale-aware public holidays.
    private func resolveHoliday(from input: String, calendar: Calendar, now: Date) async -> Date? {
        let lower = input.lowercased()

        // 1. Check fixed holidays (instant, no network)
        for holiday in Self.fixedHolidays {
            if holiday.keywords.contains(where: { lower.contains($0) }) {
                var target = calendar.date(from: DateComponents(
                    year: calendar.component(.year, from: now),
                    month: holiday.month, day: holiday.day))!
                if target < now { target = calendar.date(byAdding: .year, value: 1, to: target)! }
                return target
            }
        }

        // 2. Query Nager.Date API for locale-aware public holidays
        guard let countryCode = Locale.current.region?.identifier, countryCode.count == 2 else {
            return nil
        }
        let year = calendar.component(.year, from: now)
        guard let url = APIEndpoints.Nager.holidays(year: year, countryCode: countryCode) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, _) = try await session.data(for: request)
            guard let holidays = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }

            for holiday in holidays {
                guard let name = holiday["localName"] as? String ?? holiday["name"] as? String,
                      let dateStr = holiday["date"] as? String,
                      let date = Self.apiDateFormatter.date(from: dateStr) else { continue }

                if lower.contains(name.lowercased()) {
                    // If this year's date has passed, check next year
                    if date < now {
                        guard let nextYearURL = APIEndpoints.Nager.holidays(year: year + 1, countryCode: countryCode) else {
                            return nil
                        }
                        var nextReq = URLRequest(url: nextYearURL)
                        nextReq.timeoutInterval = 5
                        if let (nextData, _) = try? await session.data(for: nextReq),
                           let nextHolidays = try? JSONSerialization.jsonObject(with: nextData) as? [[String: Any]] {
                            for nh in nextHolidays {
                                if let nn = nh["localName"] as? String ?? nh["name"] as? String,
                                   lower.contains(nn.lowercased()),
                                   let nds = nh["date"] as? String,
                                   let nd = Self.apiDateFormatter.date(from: nds) {
                                    return nd
                                }
                            }
                        }
                    }
                    return date
                }
            }
        } catch {
            Log.tools.debug("Nager.Date API failed: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Relative Date Arithmetic

    private static let timeUnits: [String: Calendar.Component] = [
        "year": .year, "years": .year,
        "month": .month, "months": .month,
        "week": .weekOfYear, "weeks": .weekOfYear,
        "day": .day, "days": .day,
    ]

    private static let directionKeywords: [String: [String]] = ConfigLoader.load(
        "DateDirectionKeywords", as: [String: [String]].self
    ) ?? [:]
    private static let pastDirections: Set<String> = Set(directionKeywords["past"] ?? [])
    private static let futureDirections: Set<String> = Set(directionKeywords["future"] ?? [])

    /// Scans tokens for a (number, time-unit, direction) tuple — works regardless of
    /// surrounding phrasing. Handles "60 years ago", "what year was 60 years ago?",
    /// "in 3 months", "90 days from now", etc.
    private func extractRelativeDate(from words: [String]) -> (amount: Int, component: Calendar.Component, isPast: Bool)? {
        for (i, word) in words.enumerated() {
            guard let component = Self.timeUnits[word] else { continue }
            // Look for a number immediately before the unit
            guard i > 0, let amount = Int(words[i - 1]), amount > 0 else { continue }

            // Direction: check word after the unit, or scan remaining words
            if i + 1 < words.count {
                let next = words[i + 1]
                if Self.pastDirections.contains(next) { return (amount, component, true) }
                if Self.futureDirections.contains(next) { return (amount, component, false) }
                // "from now", "from today" — two-word direction
                if next == "from" && i + 2 < words.count {
                    let after = words[i + 2]
                    if after == "now" || after == "today" { return (amount, component, false) }
                }
                // "in the future"
                if next == "in" && i + 3 < words.count && words[i + 2] == "the" && words[i + 3] == "future" {
                    return (amount, component, false)
                }
            }
            // Scan all words for a direction indicator (handles "ago" appearing elsewhere)
            for w in words {
                if Self.pastDirections.contains(w) { return (amount, component, true) }
            }
            for w in words {
                if Self.futureDirections.contains(w) { return (amount, component, false) }
            }
            // "in N units" with no explicit direction → future
            if i >= 2 && words[i - 2] == "in" { return (amount, component, false) }
        }
        return nil
    }

    /// Returns true when the input looks like an event/meeting lookup rather
    /// than a date-arithmetic query. Used as a self-refusal guard: when the
    /// ML classifier or the ToolVerifier mistakenly picks Calendar for
    /// "when is my next meeting?", we return an empty-error `ToolIO` so the
    /// engine falls through to conversational BRAIN instead of fabricating a
    /// "Today: <date>" answer. Multilingual via `CalendarIntentKeywords.json`.
    private static func isEventQuery(_ input: String) -> Bool {
        guard let kw = intentKeywords else { return false }
        return kw.matches(intent: "event_query", in: input)
    }

    public func execute(args: CalendarArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        try await timed {
            if Self.isEventQuery(rawInput) {
                Log.tools.debug("CalendarTool self-refused: event query ('\(rawInput.prefix(60))') — CalendarEvent handles this")
                return ToolIO(text: "", status: .error)
            }
            let calendar = Calendar.current
            let now = Date()

            switch args.intent {
            case "dateView":
                let mode: DateViewMode
                switch args.viewScope?.lowercased() {
                case "week": mode = .week
                case "month": mode = .month
                default: mode = .day
                }
                let viewData = DateViewWidgetData(referenceDate: now, viewMode: mode)
                let modeLabel = mode == .day ? "Today" : mode == .week ? "This Week" : "This Month"
                return ToolIO(
                    text: "\(modeLabel): \(Self.fullDateFormatter.string(from: now))",
                    status: .ok,
                    outputWidget: "DateViewWidget",
                    widgetData: viewData
                )

            case "relative":
                guard let amount = args.amount,
                      let unitStr = args.unit,
                      let component = Self.timeUnits[unitStr] ?? Self.timeUnits[unitStr + "s"] else {
                    return try await execute(input: rawInput, entities: entities)
                }
                let isPast = args.direction == "past"
                guard let result = calendar.date(byAdding: component, value: isPast ? -amount : amount, to: now) else {
                    return try await execute(input: rawInput, entities: entities)
                }
                let unitLabel = amount == 1 ? unitStr : (unitStr.hasSuffix("s") ? unitStr : unitStr + "s")
                let dirLabel = isPast ? "ago" : "from now"
                let year = calendar.component(.year, from: result)
                let title = "\(amount) \(unitLabel) \(dirLabel)"
                let resultText = "\(Self.fullDateFormatter.string(from: result)) (year \(year))"
                return ToolIO(
                    text: "\(title): \(resultText)",
                    status: .ok,
                    outputWidget: "CalendarWidget",
                    widgetData: CalendarWidgetData(title: title, result: "\(title): \(resultText)", date: result)
                )

            case "between":
                if let dateStr = args.targetDate {
                    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                    let range = NSRange(dateStr.startIndex..<dateStr.endIndex, in: dateStr)
                    if let date = detector?.firstMatch(in: dateStr, options: [], range: range)?.date {
                        let diff = calendar.dateComponents([.day], from: now, to: date)
                        let days = abs(diff.day ?? 0)
                        return ToolIO(
                            text: "Days Between: \(days) days",
                            status: .ok,
                            outputWidget: "CalendarWidget",
                            widgetData: CalendarWidgetData(title: "Days Between", result: "\(days) days", date: date)
                        )
                    }
                }
                return try await execute(input: rawInput, entities: entities)

            case "dayOfWeek":
                if let dateStr = args.targetDate {
                    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                    let range = NSRange(dateStr.startIndex..<dateStr.endIndex, in: dateStr)
                    if let date = detector?.firstMatch(in: dateStr, options: [], range: range)?.date {
                        let day = Self.weekdayFormatter.string(from: date)
                        return ToolIO(
                            text: "Day of Week: \(day)",
                            status: .ok,
                            outputWidget: "CalendarWidget",
                            widgetData: CalendarWidgetData(title: "Day of Week", result: day, date: date)
                        )
                    }
                }
                return try await execute(input: rawInput, entities: entities)

            case "until":
                if let dateStr = args.targetDate {
                    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                    let range = NSRange(dateStr.startIndex..<dateStr.endIndex, in: dateStr)
                    if let date = detector?.firstMatch(in: dateStr, options: [], range: range)?.date {
                        let diff = calendar.dateComponents([.day], from: now, to: date)
                        let days = max(0, diff.day ?? 0)
                        return ToolIO(
                            text: "Days Until: \(days) days",
                            status: .ok,
                            outputWidget: "CalendarWidget",
                            widgetData: CalendarWidgetData(title: "Days Until", result: "\(days) days", date: date)
                        )
                    }
                }
                return try await execute(input: rawInput, entities: entities)

            default: // "today"
                return ToolIO(
                    text: "Today: \(Self.fullDateFormatter.string(from: now))",
                    status: .ok,
                    outputWidget: "CalendarWidget",
                    widgetData: CalendarWidgetData(title: "Today", result: Self.fullDateFormatter.string(from: now), date: now)
                )
            }
        }
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            if Self.isEventQuery(input) {
                Log.tools.debug("CalendarTool self-refused: event query ('\(input.prefix(60))') — CalendarEvent handles this")
                return ToolIO(text: "", status: .error)
            }
            let lowerInput = input.lowercased()
            let calendar = Calendar.current
            let now = Date()

            var title = "Calendar Result"
            var resultText = ""
            var targetDate: Date? = nil

            // Date view keyword detection — match before arithmetic/between/until.
            // Multilingual via `Resources/Config/CalendarIntentKeywords.json`.
            let kw = Self.intentKeywords
            if let kw, kw.matches(intent: "month_view", in: input) {
                let viewData = DateViewWidgetData(referenceDate: now, viewMode: .month)
                return ToolIO(
                    text: "This Month",
                    status: .ok,
                    outputWidget: "DateViewWidget",
                    widgetData: viewData
                )
            }

            if let kw, kw.matches(intent: "week_view", in: input) {
                let viewData = DateViewWidgetData(referenceDate: now, viewMode: .week)
                return ToolIO(
                    text: "This Week",
                    status: .ok,
                    outputWidget: "DateViewWidget",
                    widgetData: viewData
                )
            }

            // Relative date arithmetic: tokenize and scan for (number, unit, direction)
            // Must run BEFORE day_query — otherwise "what date is 5 years from now"
            // matches the `what date` day_query keyword and returns today's date
            // instead of the computed future year.
            let words = lowerInput.wordTokens

            if let kw,
               extractRelativeDate(from: words) == nil,
               kw.matches(intent: "day_query", in: input) && !lowerInput.contains("for") && !lowerInput.contains("on") {
                let viewData = DateViewWidgetData(referenceDate: now, viewMode: .day)
                return ToolIO(
                    text: "Today: \(DateFormatter.localizedString(from: now, dateStyle: .full, timeStyle: .none))",
                    status: .ok,
                    outputWidget: "DateViewWidget",
                    widgetData: viewData
                )
            }

            if let rel = extractRelativeDate(from: words),
               let result = calendar.date(byAdding: rel.component, value: rel.isPast ? -rel.amount : rel.amount, to: now) {

                let unitLabel = rel.amount == 1
                    ? Self.timeUnits.first { $0.value == rel.component }?.key ?? "units"
                    : Self.timeUnits.first { $0.value == rel.component && $0.key.hasSuffix("s") }?.key ?? "units"
                let dirLabel = rel.isPast ? "ago" : "from now"
                let dateStr = Self.fullDateFormatter.string(from: result)
                let year = calendar.component(.year, from: result)

                title = "\(rel.amount) \(unitLabel) \(dirLabel)"
                resultText = "\(dateStr) (year \(year))"
                let widgetData = CalendarWidgetData(title: title, result: "\(title): \(resultText)", date: result)
                return ToolIO(
                    text: "\(title): \(resultText)",
                    status: .ok,
                    outputWidget: "CalendarWidget",
                    widgetData: widgetData
                )
            }

            if lowerInput.contains("between") {
                title = "Days Between"
                // Try holiday resolution when one date is "today"
                if lowerInput.contains("today"),
                   let holidayDate = await resolveHoliday(from: lowerInput, calendar: calendar, now: now) {
                    let diff = calendar.dateComponents([.day], from: now, to: holidayDate)
                    resultText = "\(diff.day ?? 0) days"
                    targetDate = holidayDate
                } else {
                    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                    let matches = detector?.matches(in: input, options: [], range: NSRange(location: 0, length: input.utf16.count))
                    if let firstDate = matches?.first?.date, let secondDate = matches?.dropFirst().first?.date {
                        let diff = calendar.dateComponents([.day], from: min(firstDate, secondDate), to: max(firstDate, secondDate))
                        resultText = "\(diff.day ?? 0) days"
                        targetDate = max(firstDate, secondDate)
                    } else {
                        resultText = "I couldn't parse those dates. Try something like 'how many days between June 1 and December 25'."
                    }
                }
            } else if lowerInput.contains("day of the week") || lowerInput.contains("what day is") {
                title = "Day of Week"
                // Use DataDetector or similar? For now, let's try a simple approach
                let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                let matches = detector?.matches(in: input, options: [], range: NSRange(location: 0, length: input.utf16.count))

                if let date = matches?.first?.date {
                    resultText = Self.weekdayFormatter.string(from: date)
                    targetDate = date
                } else {
                    resultText = "Could not parse date."
                }
            } else if lowerInput.contains("until") {
                title = "Days Until"

                // Try holiday resolution first (fixed dictionary + Nager.Date API)
                if let holidayDate = await resolveHoliday(from: lowerInput, calendar: calendar, now: now) {
                    let diff = calendar.dateComponents([.day], from: now, to: holidayDate)
                    resultText = "\(max(0, diff.day ?? 0)) days"
                    targetDate = holidayDate
                } else {
                    // Fall back to NSDataDetector for standard date formats
                    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                    let matches = detector?.matches(in: input, options: [], range: NSRange(location: 0, length: input.utf16.count))

                    if let date = matches?.first?.date {
                        let diff = calendar.dateComponents([.day], from: now, to: date)
                        resultText = "\(max(0, diff.day ?? 0)) days"
                        targetDate = date
                    } else {
                        resultText = "Could not parse date."
                    }
                }
            } else {
                // Default: today's date
                title = "Today"
                resultText = Self.fullDateFormatter.string(from: now)
                targetDate = now
            }

            let widgetData = CalendarWidgetData(title: title, result: resultText, date: targetDate)

            return ToolIO(
                text: "\(title): \(resultText)",
                status: .ok,
                outputWidget: "CalendarWidget",
                widgetData: widgetData
            )
        }
    }
}

public struct CalendarIntent: AppIntent {
    public static var title: LocalizedStringResource { "Calendar Query" }
    public static var description: IntentDescription? { IntentDescription("Performs calendar calculations using the iClaw CalendarTool.") }

    @Parameter(title: "Query")
    public var query: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = CalendarTool()
        let result = try await tool.execute(input: query, entities: nil)
        return .result(value: result.text)
    }
}
