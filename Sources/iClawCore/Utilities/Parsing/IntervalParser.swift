import Foundation

/// Parses natural-language time intervals into seconds and computes the next run date.
///
/// Supports patterns like:
/// - "every 30 minutes", "every 2 hours", "every 3 days"
/// - "hourly", "daily", "weekly"
/// - "every morning", "every evening"
/// - "daily at 8am", "daily at 14:30"
/// - "every Monday at 9am" (weekly)
public enum IntervalParser {

    public struct ParsedInterval: Sendable {
        /// Repeat interval in seconds.
        public let intervalSeconds: Int
        /// When the first execution should occur.
        public let nextRunDate: Date
        /// Human-readable description (e.g., "every 30 minutes", "daily at 8:00 AM").
        public let displayLabel: String
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    // MARK: - Patterns

    private static let relativePatterns: [(NSRegularExpression, @Sendable (Int) -> Int)] = [
        (try! NSRegularExpression(pattern: #"(?:every\s+)?(\d+)\s*h(?:ours?|rs?)"#, options: .caseInsensitive), { $0 * 3600 }),
        (try! NSRegularExpression(pattern: #"(?:every\s+)?(\d+)\s*min(?:utes?|s)?"#, options: .caseInsensitive), { $0 * 60 }),
        (try! NSRegularExpression(pattern: #"(?:every\s+)?(\d+)\s*days?"#, options: .caseInsensitive), { $0 * 86400 }),
    ]

    private static let fixedKeywords: [(String, Int)] = [
        ("hourly", 3600),
        ("daily", 86400),
        ("weekly", 604800),
    ]

    private static let periodKeywords: [(String, (hour: Int, minute: Int), Int)] = [
        ("every morning", (8, 0), 86400),
        ("every evening", (18, 0), 86400),
        ("every night", (21, 0), 86400),
        ("every afternoon", (14, 0), 86400),
    ]

    private static let timePattern = try! NSRegularExpression(
        pattern: #"(?:daily\s+)?at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#,
        options: .caseInsensitive
    )

    // MARK: - Parse

    /// Parses an interval string into structured data, or returns nil if unparseable.
    public static func parse(_ input: String) -> ParsedInterval? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cal = Calendar.current
        let now = Date()

        // 1. Fixed-time patterns: "daily at 8am", "at 14:30"
        if let match = timePattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
            var hour = Int(extractGroup(trimmed, match: match, group: 1)) ?? 8
            let minute = Int(extractGroup(trimmed, match: match, group: 2)) ?? 0
            let ampm = extractGroup(trimmed, match: match, group: 3).lowercased()

            if ampm == "pm" && hour < 12 { hour += 12 }
            if ampm == "am" && hour == 12 { hour = 0 }

            let components = DateComponents(hour: hour, minute: minute)
            let next = cal.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86400)
            return clamped(ParsedInterval(
                intervalSeconds: 86400,
                nextRunDate: next,
                displayLabel: "daily at \(Self.shortTimeFormatter.string(from: next))"
            ))
        }

        // 2. Period keywords: "every morning", "every evening"
        for (keyword, time, interval) in periodKeywords {
            if trimmed.contains(keyword) {
                let components = DateComponents(hour: time.hour, minute: time.minute)
                let next = cal.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now.addingTimeInterval(Double(interval))
                return clamped(ParsedInterval(
                    intervalSeconds: interval,
                    nextRunDate: next,
                    displayLabel: keyword
                ))
            }
        }

        // 3. Relative patterns: "every 30 minutes", "every 2 hours"
        for (regex, converter) in relativePatterns {
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: nsRange) {
                let numStr = extractGroup(trimmed, match: match, group: 1)
                if let num = Int(numStr) {
                    let seconds = converter(num)
                    return clamped(ParsedInterval(
                        intervalSeconds: seconds,
                        nextRunDate: now.addingTimeInterval(Double(seconds)),
                        displayLabel: "every \(formatInterval(seconds))"
                    ))
                }
            }
        }

        // 4. Fixed keywords: "hourly", "daily", "weekly"
        for (keyword, seconds) in fixedKeywords {
            if trimmed.contains(keyword) {
                return clamped(ParsedInterval(
                    intervalSeconds: seconds,
                    nextRunDate: now.addingTimeInterval(Double(seconds)),
                    displayLabel: keyword
                ))
            }
        }

        return nil
    }

    // MARK: - Bounds

    private static let minIntervalSeconds = 300       // 5 minutes
    private static let maxIntervalSeconds = 30 * 24 * 3600  // 30 days

    private static func clamped(_ interval: ParsedInterval) -> ParsedInterval {
        let clamped = max(minIntervalSeconds, min(maxIntervalSeconds, interval.intervalSeconds))
        if clamped == interval.intervalSeconds { return interval }
        return ParsedInterval(
            intervalSeconds: clamped,
            nextRunDate: interval.nextRunDate,
            displayLabel: interval.displayLabel
        )
    }

    // MARK: - Helpers

    private static func extractGroup(_ text: String, match: NSTextCheckingResult, group: Int) -> String {
        guard group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: text) else { return "" }
        return String(text[range])
    }

    private static func formatInterval(_ seconds: Int) -> String {
        if seconds >= 86400 {
            let days = seconds / 86400
            return days == 1 ? "day" : "\(days) days"
        } else if seconds >= 3600 {
            let hours = seconds / 3600
            return hours == 1 ? "hour" : "\(hours) hours"
        } else {
            let minutes = seconds / 60
            return minutes == 1 ? "minute" : "\(minutes) minutes"
        }
    }
}
