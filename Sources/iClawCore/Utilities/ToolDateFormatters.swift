import Foundation

/// Shared date formatters for tools. Eliminates duplicate static formatter
/// definitions across CalendarTool, WeatherTool, PodcastTool, NewsTool, etc.
///
/// All formatters are lazily initialized and cached. Thread-safe via static let.
public enum ToolDateFormatters {

    // MARK: - Style-Based (Locale-Respecting)

    /// Short time only (e.g., "3:30 PM" or "15:30"). Respects 12h/24h.
    public static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    /// Medium date only (e.g., "Jan 15, 2026"). Respects locale.
    public static let mediumDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    /// Full date (e.g., "Wednesday, January 15, 2026"). Respects locale.
    public static let fullDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    /// Long date (e.g., "January 15, 2026"). Respects locale.
    public static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    /// Short weekday abbreviation (e.g., "Wed").
    public static let shortWeekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    // MARK: - API Formats (Fixed, Not Locale-Dependent)

    /// ISO date only: "yyyy-MM-dd" (for REST APIs like Nager, Open-Meteo).
    public static let apiDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// ISO 8601 without fractional seconds.
    public nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO-like without seconds: "yyyy-MM-dd'T'HH:mm" (Open-Meteo hourly).
    public static let isoNoSeconds: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Display Helpers

    /// "Today" for today's date, medium format otherwise. Respects locale.
    public static func displayDate(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return String(localized: "Today", bundle: .iClawCore)
        }
        return mediumDate.string(from: date)
    }
}
