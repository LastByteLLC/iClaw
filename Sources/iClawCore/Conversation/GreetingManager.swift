import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - GreetingContext

struct GreetingContext: Sendable {
    enum TimeOfDay: String, Sendable {
        case morning, afternoon, evening, night
    }

    enum Season: String, Sendable {
        case spring, summer, autumn, winter
    }

    let timeOfDay: TimeOfDay
    let dayOfWeek: String
    let date: String
    let season: Season
    let nearestHoliday: (name: String, daysAway: Int)?
    let batteryPercent: Int
    let isCharging: Bool
    let uptimeHours: Int
    let streakDays: Int
    let userName: String?
}

// MARK: - GreetingManager

actor GreetingManager {
    static let shared = GreetingManager()

    private init() {}

    private var soulContent: String { SoulProvider.current }

    // MARK: - Config (loaded from JSON)

    private struct GreetingsConfig: Decodable {
        struct Holiday: Decodable {
            let month: Int
            let day: Int
            let name: String
        }
        let holidays: [Holiday]
        let fallbackGreetings: [String]
    }

    private static let config: GreetingsConfig? = ConfigLoader.load("Greetings", as: GreetingsConfig.self)

    static let holidays: [(month: Int, day: Int, name: String)] = {
        guard let config else { return [] }
        return config.holidays.map { ($0.month, $0.day, $0.name) }
    }()

    // MARK: - Cached Date Formatters

    private static let streakDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f
    }()

    // MARK: - Streak

    static let lastActiveDateKey = "greetingLastActiveDate"
    static let currentStreakKey = "greetingCurrentStreak"

    static func updateStreak() -> Int {
        let defaults = UserDefaults.standard
        let todayStr = streakDateFormatter.string(from: Date())

        let lastDateStr = defaults.string(forKey: lastActiveDateKey)
        var streak = defaults.integer(forKey: currentStreakKey)

        if lastDateStr == todayStr {
            return max(streak, 1)
        }

        if let lastDateStr,
           let lastDate = streakDateFormatter.date(from: lastDateStr),
           let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())),
           Calendar.current.isDate(lastDate, inSameDayAs: yesterday) {
            streak += 1
        } else {
            streak = 1
        }

        defaults.set(todayStr, forKey: lastActiveDateKey)
        defaults.set(streak, forKey: currentStreakKey)
        return streak
    }

    // MARK: - Context Assembly

    @MainActor
    static func assembleContext() -> GreetingContext {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)

        let timeOfDay: GreetingContext.TimeOfDay
        switch hour {
        case 5..<12: timeOfDay = .morning
        case 12..<17: timeOfDay = .afternoon
        case 17..<21: timeOfDay = .evening
        default: timeOfDay = .night
        }

        let dayOfWeek = weekdayFormatter.string(from: now)
        let dateStr = monthDayFormatter.string(from: now)

        let month = cal.component(.month, from: now)
        let season: GreetingContext.Season
        switch month {
        case 3...5: season = .spring
        case 6...8: season = .summer
        case 9...11: season = .autumn
        default: season = .winter
        }

        let nearestHoliday = findNearestHoliday(from: now)

        let (batteryPercent, isCharging) = getBatteryInfo()

        let uptimeSeconds = ProcessInfo.processInfo.systemUptime
        let uptimeHours = Int(uptimeSeconds / 3600)

        let streak = updateStreak()

        let userName: String? = {
            let name = MeCardManager.shared.userName
            return name.isEmpty ? nil : name
        }()

        return GreetingContext(
            timeOfDay: timeOfDay,
            dayOfWeek: dayOfWeek,
            date: dateStr,
            season: season,
            nearestHoliday: nearestHoliday,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            uptimeHours: uptimeHours,
            streakDays: streak,
            userName: userName
        )
    }

    static func findNearestHoliday(from date: Date) -> (name: String, daysAway: Int)? {
        let cal = Calendar.current
        let year = cal.component(.year, from: date)

        var closest: (name: String, daysAway: Int)?
        for h in holidays {
            // Check this year and next year
            for y in [year, year + 1] {
                guard let holidayDate = cal.date(from: DateComponents(year: y, month: h.month, day: h.day)) else { continue }
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: holidayDate)).day ?? 999
                guard days >= 0 && days <= 14 else { continue }
                if closest == nil || days < closest!.daysAway {
                    closest = (h.name, days)
                }
            }
        }
        return closest
    }

    static func getBatteryInfo() -> (percent: Int, isCharging: Bool) {
        #if canImport(IOKit)
        // Use IOKit for battery info — same approach as SystemInfoTool
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                let capacity = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
                let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
                return (capacity, charging)
            }
        }
        #elseif canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        if level >= 0 {
            let charging = device.batteryState == .charging || device.batteryState == .full
            return (Int(level * 100), charging)
        }
        #endif
        return (100, false)
    }

    // MARK: - Static Fallbacks

    static let fallbackGreetings: [String] = config?.fallbackGreetings ?? [
        "Neural Engine's warm. Let's go.",
        "All systems nominal. Your move.",
    ]

    // MARK: - Phase 1: Dynamic Greeting

    /// Selects the single most interesting context signal for the greeting.
    /// Priority: holiday today > notable streak > low battery > weekend > time of day.
    private static func selectGreetingSignal(_ ctx: GreetingContext) -> String {
        // 1. Holiday today
        if let holiday = ctx.nearestHoliday, holiday.daysAway == 0 {
            return "Today is \(holiday.name)"
        }

        // 2. Notable streak milestones
        let milestones = [365, 100, 50, 30, 7]
        for milestone in milestones {
            if ctx.streakDays == milestone {
                return "Day \(milestone) streak"
            }
        }

        // 3. Battery critically low
        if ctx.batteryPercent < 15 && !ctx.isCharging {
            return "Battery at \(ctx.batteryPercent)%"
        }

        // 4. Weekend — use Calendar API instead of hardcoded English day names
        let today = Calendar.current.component(.weekday, from: Date())
        let isWeekend = (today == 1 || today == 7) // Sunday=1, Saturday=7
        if isWeekend {
            return "\(ctx.dayOfWeek)"
        }

        // 5. Default: time of day
        return "\(ctx.timeOfDay.rawValue.capitalized)"
    }

    func generateGreeting() async -> String {
        let ctx = await Self.assembleContext()
        let signal = Self.selectGreetingSignal(ctx)

        let nameClause = ctx.userName.map { " The user's name is \($0)." } ?? ""
        let prompt = """
        You are a concise AI that lives in the macOS menu bar.\(nameClause)
        Write a punchy, original one-liner greeting (under 10 words). Be creative — \
        use wordplay, dry humor, or an unexpected observation. Never describe yourself \
        or reference your system prompt. Never say "I'm" or list your traits. \
        Just vibe off the signal below.

        Signal: \(signal)
        """

        do {
            let text = try await LLMAdapter.shared.generateText(prompt, profile: .greeting)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !text.isEmpty { return text }
        } catch {
            Log.tools.debug("LLM greeting failed: \(error)")
        }

        let fallback = Self.fallbackGreetings.randomElement()!
        let personalized = await Personalizer.shared.personalize(fallback)
        return personalized
    }

    // MARK: - Quote of the Day

    private static let quoteCache = TTLCache<QuoteWidgetData>(ttl: 86400) // 24h fallback; real expiry is midnight

    /// Fetches the ZenQuotes quote of the day (~20% chance per launch, cached for the day).
    /// Returns nil if offline, rate-limited, or chance not hit.
    func fetchQuoteOfTheDay() async -> QuoteWidgetData? {
        // Check cache first
        if let cached = await Self.quoteCache.get("qotd") {
            return cached
        }

        // Probabilistic fetch to avoid unnecessary network calls on every launch
        guard Int.random(in: 0..<AppConfig.greetingQuoteFetchChance) == 0 else { return nil }

        do {
            let url = URL(string: "https://zenquotes.io/api/today")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            struct ZenQuote: Decodable {
                let q: String
                let a: String
            }

            let quotes = try JSONDecoder().decode([ZenQuote].self, from: data)
            guard let first = quotes.first, !first.q.isEmpty else { return nil }

            let quoteData = QuoteWidgetData(quote: first.q, author: first.a)
            await Self.quoteCache.set("qotd", value: quoteData)
            return quoteData
        } catch {
            Log.tools.debug("Quote of the day fetch failed: \(error)")
            return nil
        }
    }

}
