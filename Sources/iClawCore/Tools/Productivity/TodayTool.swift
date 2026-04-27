import Foundation
import EventKit
import CoreLocation

// MARK: - Widget Data

public struct TodaySummaryWidgetData: Sendable {
    public let events: [EventItem]
    public let reminders: [ReminderItem]
    public let weather: WeatherSummary?
    public let hints: [String]
    public let date: Date

    public struct EventItem: Sendable {
        public let title: String
        public let startTime: Date
        public let endTime: Date?
        public let isAllDay: Bool
    }

    public struct ReminderItem: Sendable {
        public let title: String
        public let dueDate: Date?
    }

    public struct WeatherSummary: Sendable {
        public let city: String
        public let temperature: String
        public let condition: String
        public let iconName: String
        public let high: String
        public let low: String
    }
}

// MARK: - TodayTool

public struct TodayTool: CoreTool, Sendable {
    public let name = "Today"
    public let schema = "Daily summary briefing: 'what's my day look like', 'morning briefing', 'daily summary', 'today overview'."
    public let isInternal = false
    public let category = CategoryEnum.online

    private let session: URLSession

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    public init(session: URLSession = .iClawDefault) {
        self.session = session
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            // Fetch all data sources in parallel — never prompt for permissions,
            // just silently skip unavailable sources and hint about them instead
            async let calendarResult = fetchCalendarEvents()
            async let remindersResult = fetchReminders()
            async let weatherResult = fetchWeather()

            let (events, calendarAvailable) = await calendarResult
            let (reminders, remindersAvailable) = await remindersResult
            let weather = await weatherResult

            // Build hints for unavailable data sources
            var hints: [String] = []
            if !calendarAvailable {
                hints.append("Tip: Grant Calendar access to see your events here.")
            }
            if !remindersAvailable {
                hints.append("Tip: Grant Reminders access to track your to-dos here.")
            }
            if weather == nil {
                hints.append("Tip: Grant Location access to include weather in your summary.")
            }

            let text = buildTextSummary(events: events, reminders: reminders, weather: weather, hints: hints)

            let widgetData = TodaySummaryWidgetData(
                events: events,
                reminders: reminders,
                weather: weather,
                hints: hints,
                date: Date()
            )

            return ToolIO(
                text: text,
                status: .ok,
                outputWidget: "TodaySummaryWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }
    }

    // MARK: - Calendar Events

    /// Returns (events, wasAuthorized). Never requests permission — silently returns empty if not authorized.
    private func fetchCalendarEvents() async -> ([TodaySummaryWidgetData.EventItem], Bool) {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .event)

        guard status == .fullAccess else {
            return ([], false)
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return ([], true) }

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let ekEvents = store.events(matching: predicate).prefix(10)

        let items = ekEvents.map { event in
            TodaySummaryWidgetData.EventItem(
                title: event.title ?? "Untitled",
                startTime: event.startDate,
                endTime: event.endDate,
                isAllDay: event.isAllDay
            )
        }
        return (items, true)
    }

    // MARK: - Reminders

    /// Returns (reminders, wasAuthorized). Never requests permission — silently returns empty if not authorized.
    private func fetchReminders() async -> ([TodaySummaryWidgetData.ReminderItem], Bool) {
        let store = EKEventStore()
        let status = EKEventStore.authorizationStatus(for: .reminder)

        guard status == .fullAccess else {
            return ([], false)
        }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: Date(),
            calendars: nil
        )

        let items: [TodaySummaryWidgetData.ReminderItem] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let mapped = (reminders ?? []).prefix(10).map { reminder in
                    TodaySummaryWidgetData.ReminderItem(
                        title: reminder.title ?? "Untitled",
                        dueDate: reminder.dueDateComponents?.date
                    )
                }
                continuation.resume(returning: Array(mapped))
            }
        }
        return (items, true)
    }

    // MARK: - Weather

    private func fetchWeather() async -> TodaySummaryWidgetData.WeatherSummary? {
        do {
            let resolved = try await LocationManager.shared.resolveCurrentLocation()
            let lat = resolved.coordinate.coordinate.latitude
            let lon = resolved.coordinate.coordinate.longitude

            let unitParam: String? = useFahrenheit ? "fahrenheit" : nil

            guard let url = APIEndpoints.OpenMeteo.todaySummary(lat: lat, lon: lon, temperatureUnit: unitParam) else { return nil }

            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let current = json?["current"] as? [String: Any],
                  let temp = current["temperature_2m"] as? Double,
                  let code = current["weather_code"] as? Int,
                  let daily = json?["daily"] as? [String: Any],
                  let maxTemps = daily["temperature_2m_max"] as? [Double],
                  let minTemps = daily["temperature_2m_min"] as? [Double],
                  let high = maxTemps.first,
                  let low = minTemps.first else { return nil }

            let unit = useFahrenheit ? "\u{00B0}F" : "\u{00B0}C"
            let cityName = resolved.cityName

            return TodaySummaryWidgetData.WeatherSummary(
                city: cityName,
                temperature: "\(Int(round(temp)))\(unit)",
                condition: WeatherTool.mapWeatherCode(code),
                iconName: WeatherTool.mapWeatherIcon(code),
                high: "\(Int(round(high)))\(unit)",
                low: "\(Int(round(low)))\(unit)"
            )
        } catch {
            Log.tools.debug("TodayTool: weather fetch failed — \(error.localizedDescription)")
            return nil
        }
    }

    private var useFahrenheit: Bool {
        TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: AppConfig.temperatureUnitKey) ?? "system")?.usesFahrenheit
            ?? TemperatureUnit.system.usesFahrenheit
    }

    // MARK: - Text Summary

    private func buildTextSummary(
        events: [TodaySummaryWidgetData.EventItem],
        reminders: [TodaySummaryWidgetData.ReminderItem],
        weather: TodaySummaryWidgetData.WeatherSummary?,
        hints: [String]
    ) -> String {
        var parts: [String] = []

        parts.append("Today's Summary — \(Self.headerDateFormatter.string(from: Date()))")

        // Weather
        if let w = weather {
            parts.append("Weather: \(w.temperature) \(w.condition) in \(w.city) (High \(w.high), Low \(w.low))")
        }

        // Calendar
        if events.isEmpty {
            parts.append("Calendar: No events today.")
        } else {
            let lines = events.map { event in
                if event.isAllDay {
                    return "  \u{2022} \(event.title) (All day)"
                }
                return "  \u{2022} \(event.title) at \(Self.shortTimeFormatter.string(from: event.startTime))"
            }
            parts.append("Calendar: \(events.count) event\(events.count == 1 ? "" : "s")\n\(lines.joined(separator: "\n"))")
        }

        // Reminders
        if reminders.isEmpty {
            parts.append("Reminders: All clear.")
        } else {
            let lines = reminders.map { "  \u{2022} \($0.title)" }
            parts.append("Reminders: \(reminders.count) pending\n\(lines.joined(separator: "\n"))")
        }

        // Hints for unavailable sources
        if !hints.isEmpty {
            parts.append(hints.joined(separator: " "))
        }

        return parts.joined(separator: "\n")
    }
}
