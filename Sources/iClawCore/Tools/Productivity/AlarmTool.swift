#if os(iOS)
import Foundation
import AlarmKit
import AppIntents

// MARK: - Authorization Monitor

/// Observes AlarmKit authorization changes and notifies the UI via MessageBus.
/// Starts once on first alarm use and runs for the app's lifetime.
public actor AlarmAuthorizationMonitor {
    public static let shared = AlarmAuthorizationMonitor()

    private var isMonitoring = false

    /// Starts observing `authorizationUpdates` if not already running.
    public func startIfNeeded() {
        guard !isMonitoring else { return }
        isMonitoring = true

        Task.detached { [weak self] in
            let manager = AlarmManager.shared
            for await state in manager.authorizationUpdates {
                await self?.handleStateChange(state)
            }
        }
    }

    private func handleStateChange(_ state: AlarmManager.AuthorizationState) async {
        switch state {
        case .authorized:
            await MainActor.run {
                MessageBus.shared.post(role: "system", content: "Alarm permission granted. You can now set alarms.")
            }
        case .denied:
            await MainActor.run {
                MessageBus.shared.post(role: "system", content: "Alarm permission was revoked. Re-enable in Settings > iClaw > Alarms to use this feature.")
            }
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - Widget Data

/// Data structure for alarm widget display.
public struct AlarmWidgetData: Sendable {
    public let alarmDate: Date
    public let label: String
    public let isRepeating: Bool
    public let repeatDays: [String]

    public init(alarmDate: Date, label: String, isRepeating: Bool = false, repeatDays: [String] = []) {
        self.alarmDate = alarmDate
        self.label = label
        self.isRepeating = isRepeating
        self.repeatDays = repeatDays
    }
}

/// Sets alarms using AlarmKit (iOS 26+).
/// Supports one-time alarms at specific times, repeating alarms on specific days,
/// and countdown-based alarms.
public struct AlarmTool: CoreTool, Sendable {
    public let name = "Alarm"
    public let schema = "Set an alarm. Example: 'alarm at 7:30 AM', 'alarm every Monday at 8 AM', 'alarm in 45 minutes'."
    public let isInternal = false
    public let category = CategoryEnum.offline

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    public init() {}

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await timed {
            let lowerInput = input.lowercased()

            let manager = AlarmManager.shared

            // Start monitoring authorization changes (idempotent)
            await AlarmAuthorizationMonitor.shared.startIfNeeded()

            // Check current authorization, request if not yet determined
            let currentState = manager.authorizationState
            switch currentState {
            case .denied:
                return ToolIO(
                    text: "Alarm permission is denied. Please re-enable in Settings > iClaw > Alarms.",
                    status: .error
                )
            case .notDetermined:
                let _ = await PermissionManager.requestPermission(.alarms, toolName: "Alarm", reason: "to set alarms and timers on your Lock Screen")
                do {
                    try await manager.requestAuthorization()
                } catch {
                    return ToolIO(
                        text: "Alarm permission denied. Please allow alarms in Settings.",
                        status: .error
                    )
                }
            case .authorized:
                break
            @unknown default:
                break
            }

            // Detect intent: countdown ("in X minutes"), repeating ("every Monday"), or fixed time ("at 7:30")
            if let countdownResult = parseCountdown(lowerInput) {
                return try await scheduleCountdown(
                    duration: countdownResult.duration,
                    label: countdownResult.label,
                    manager: manager
                )
            }

            if let repeatingResult = parseRepeating(lowerInput) {
                return try await scheduleRepeating(
                    time: repeatingResult.time,
                    days: repeatingResult.days,
                    label: repeatingResult.label,
                    manager: manager
                )
            }

            if let fixedResult = parseFixedTime(lowerInput) {
                return try await scheduleFixed(
                    date: fixedResult.date,
                    label: fixedResult.label,
                    manager: manager
                )
            }

            return ToolIO(
                text: "Could not understand alarm time from: \(input). Try 'alarm at 7:30 AM', 'alarm every Monday at 8 AM', or 'alarm in 30 minutes'.",
                status: .error
            )
        }
    }

    // MARK: - Countdown ("in X minutes/hours")

    private struct CountdownResult {
        let duration: TimeInterval
        let label: String
    }

    // Pre-compiled regexes for countdown/time parsing
    private static let countdownPatterns: [(NSRegularExpression, Double)] = [
        (try! NSRegularExpression(pattern: "(\\d+)\\s*hour"), 3600.0),
        (try! NSRegularExpression(pattern: "(\\d+)\\s*min"), 60.0),
        (try! NSRegularExpression(pattern: "(\\d+)\\s*sec"), 1.0),
    ]
    private static let bareNumberRegex = try! NSRegularExpression(pattern: "in\\s+(\\d+)")
    private static let timePatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "(\\d{1,2}):(\\d{2})\\s*(am|pm)", options: .caseInsensitive),
        try! NSRegularExpression(pattern: "(\\d{1,2}):(\\d{2})"),
        try! NSRegularExpression(pattern: "(\\d{1,2})\\s*(am|pm)", options: .caseInsensitive),
    ]

    private func parseCountdown(_ input: String) -> CountdownResult? {
        // Match "in X hour(s) Y min(s)" or "in X min(s)" or "in X sec(s)"
        guard input.contains(" in ") || input.hasPrefix("in ") else { return nil }

        var totalSeconds: TimeInterval = 0

        for (regex, multiplier) in Self.countdownPatterns {
            if let match = regex.firstMatch(in: input, range: NSRange(location: 0, length: input.utf16.count)),
               let range = Range(match.range(at: 1), in: input),
               let value = Double(input[range]) {
                totalSeconds += value * multiplier
            }
        }

        // Fallback: bare number after "in" assumed to be minutes
        if totalSeconds == 0 {
            if let match = Self.bareNumberRegex.firstMatch(in: input, range: NSRange(location: 0, length: input.utf16.count)),
               let range = Range(match.range(at: 1), in: input),
               let value = Double(input[range]) {
                totalSeconds = value * 60.0
            }
        }

        guard totalSeconds > 0 else { return nil }
        return CountdownResult(duration: totalSeconds, label: input)
    }

    // MARK: - Repeating ("every Monday/Tuesday at HH:MM")

    private struct RepeatingResult {
        let time: (hour: Int, minute: Int)
        let days: [Locale.Weekday]
        let label: String
    }

    private static let dayMap: [(String, Locale.Weekday)] = [
        ("sunday", .sunday), ("sun", .sunday),
        ("monday", .monday), ("mon", .monday),
        ("tuesday", .tuesday), ("tue", .tuesday), ("tues", .tuesday),
        ("wednesday", .wednesday), ("wed", .wednesday),
        ("thursday", .thursday), ("thu", .thursday), ("thurs", .thursday),
        ("friday", .friday), ("fri", .friday),
        ("saturday", .saturday), ("sat", .saturday),
        ("weekday", .monday), // "every weekday" handled specially below
        ("weekend", .saturday)
    ]

    private func parseRepeating(_ input: String) -> RepeatingResult? {
        guard input.contains("every ") else { return nil }

        // Parse days
        var days: [Locale.Weekday] = []

        if input.contains("weekday") {
            days = [.monday, .tuesday, .wednesday, .thursday, .friday]
        } else if input.contains("weekend") {
            days = [.saturday, .sunday]
        } else if input.contains("every day") || input.contains("everyday") {
            days = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        } else {
            for (name, weekday) in Self.dayMap {
                if input.contains(name) && !["weekday", "weekend"].contains(name) {
                    if !days.contains(weekday) {
                        days.append(weekday)
                    }
                }
            }
        }

        guard !days.isEmpty else { return nil }

        // Parse time
        guard let time = parseTimeOfDay(input) else { return nil }

        return RepeatingResult(time: time, days: days, label: input)
    }

    // MARK: - Fixed time ("at 7:30 AM", "at 14:00")

    private struct FixedResult {
        let date: Date
        let label: String
    }

    private func parseFixedTime(_ input: String) -> FixedResult? {
        guard let time = parseTimeOfDay(input) else { return nil }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0

        guard var alarmDate = Calendar.current.date(from: components) else { return nil }

        // If the time has already passed today, schedule for tomorrow
        if alarmDate <= Date() {
            alarmDate = Calendar.current.date(byAdding: .day, value: 1, to: alarmDate)!
        }

        return FixedResult(date: alarmDate, label: input)
    }

    // MARK: - Time parsing helper

    private func parseTimeOfDay(_ input: String) -> (hour: Int, minute: Int)? {
        // Match "HH:MM AM/PM" or "HH:MM" or "H AM/PM"
        for regex in Self.timePatterns {
            guard let match = regex.firstMatch(in: input, range: NSRange(location: 0, length: input.utf16.count)) else {
                continue
            }

            if match.numberOfRanges == 4 {
                // HH:MM AM/PM
                guard let hourRange = Range(match.range(at: 1), in: input),
                      let minRange = Range(match.range(at: 2), in: input),
                      let periodRange = Range(match.range(at: 3), in: input),
                      var hour = Int(input[hourRange]),
                      let minute = Int(input[minRange]) else { continue }

                let period = String(input[periodRange]).lowercased()
                if period == "pm" && hour != 12 { hour += 12 }
                if period == "am" && hour == 12 { hour = 0 }
                return (hour, minute)
            } else if match.numberOfRanges == 3 {
                guard let hourRange = Range(match.range(at: 1), in: input) else { continue }

                if let secondRange = Range(match.range(at: 2), in: input) {
                    let secondStr = String(input[secondRange]).lowercased()
                    if secondStr == "am" || secondStr == "pm" {
                        // H AM/PM
                        guard var hour = Int(input[hourRange]) else { continue }
                        if secondStr == "pm" && hour != 12 { hour += 12 }
                        if secondStr == "am" && hour == 12 { hour = 0 }
                        return (hour, 0)
                    } else if let minute = Int(secondStr) {
                        // HH:MM (24h)
                        guard let hour = Int(input[hourRange]) else { continue }
                        return (hour, minute)
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Scheduling

    private func scheduleCountdown(
        duration: TimeInterval,
        label: String,
        manager: AlarmManager
    ) async throws -> ToolIO {
        let alarmID = "iclaw-alarm-\(UUID().uuidString)"

        let stopButton = AlarmButton(text: "Stop", textColor: .white)
        let alert = AlarmPresentation.Alert(title: "iClaw Alarm", stopButton: stopButton)
        let attributes = AlarmAttributes<EmptyAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert)
        )

        let configuration = AlarmConfiguration(
            countdownDuration: duration,
            attributes: attributes
        )

        try await manager.schedule(id: alarmID, configuration: configuration)

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let durationText: String
        if minutes > 0 && seconds > 0 {
            durationText = "\(minutes) minute\(minutes == 1 ? "" : "s") and \(seconds) second\(seconds == 1 ? "" : "s")"
        } else if minutes > 0 {
            durationText = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            durationText = "\(seconds) second\(seconds == 1 ? "" : "s")"
        }

        let alarmDate = Date().addingTimeInterval(duration)
        let widgetData = AlarmWidgetData(alarmDate: alarmDate, label: label)

        return ToolIO(
            text: "Alarm set for \(durationText) from now.",
            status: .ok,
            outputWidget: "AlarmWidget",
            widgetData: widgetData
        )
    }

    private func scheduleFixed(
        date: Date,
        label: String,
        manager: AlarmManager
    ) async throws -> ToolIO {
        let alarmID = "iclaw-alarm-\(UUID().uuidString)"

        let stopButton = AlarmButton(text: "Stop", textColor: .white)
        let alert = AlarmPresentation.Alert(title: "iClaw Alarm", stopButton: stopButton)
        let attributes = AlarmAttributes<EmptyAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert)
        )

        let schedule = Alarm.Schedule.fixed(date)
        let configuration = AlarmConfiguration(
            schedule: schedule,
            attributes: attributes
        )

        try await manager.schedule(id: alarmID, configuration: configuration)

        let timeStr = Self.shortTimeFormatter.string(from: date)

        let isTomorrow = !Calendar.current.isDateInToday(date)
        let dayStr = isTomorrow ? " tomorrow" : ""

        let widgetData = AlarmWidgetData(alarmDate: date, label: label)

        return ToolIO(
            text: "Alarm set for \(timeStr)\(dayStr).",
            status: .ok,
            outputWidget: "AlarmWidget",
            widgetData: widgetData
        )
    }

    private func scheduleRepeating(
        time: (hour: Int, minute: Int),
        days: [Locale.Weekday],
        label: String,
        manager: AlarmManager
    ) async throws -> ToolIO {
        let alarmID = "iclaw-alarm-\(UUID().uuidString)"

        let stopButton = AlarmButton(text: "Stop", textColor: .white)
        let alert = AlarmPresentation.Alert(title: "iClaw Alarm", stopButton: stopButton)
        let attributes = AlarmAttributes<EmptyAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert)
        )

        let alarmTime = Alarm.Schedule.Relative.Time(hour: time.hour, minute: time.minute)
        let recurrence = Alarm.Schedule.Relative.Recurrence.weekly(Set(days))
        let relativeSchedule = Alarm.Schedule.Relative(time: alarmTime, repeats: recurrence)
        let schedule = Alarm.Schedule.relative(relativeSchedule)

        let configuration = AlarmConfiguration(
            schedule: schedule,
            attributes: attributes
        )

        try await manager.schedule(id: alarmID, configuration: configuration)

        var components = DateComponents()
        components.hour = time.hour
        components.minute = time.minute
        let sampleDate = Calendar.current.date(from: components) ?? Date()
        let timeStr = Self.shortTimeFormatter.string(from: sampleDate)

        let dayNames = days.map { dayName($0) }
        let dayStr = dayNames.joined(separator: ", ")

        // Build widget data with next alarm date
        var nextComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        nextComponents.hour = time.hour
        nextComponents.minute = time.minute
        let nextDate = Calendar.current.date(from: nextComponents) ?? Date()
        let widgetData = AlarmWidgetData(
            alarmDate: nextDate,
            label: label,
            isRepeating: true,
            repeatDays: dayNames
        )

        return ToolIO(
            text: "Repeating alarm set for \(timeStr) every \(dayStr).",
            status: .ok,
            outputWidget: "AlarmWidget",
            widgetData: widgetData
        )
    }

    /// Returns the locale-aware day name instead of hardcoded English.
    private func dayName(_ day: Locale.Weekday) -> String {
        let index: Int
        switch day {
        case .sunday: index = 0
        case .monday: index = 1
        case .tuesday: index = 2
        case .wednesday: index = 3
        case .thursday: index = 4
        case .friday: index = 5
        case .saturday: index = 6
        @unknown default: return "Unknown"
        }
        let symbols = Calendar.current.weekdaySymbols
        // Calendar.weekdaySymbols starts with Sunday (index 0)
        guard index < symbols.count else { return "Unknown" }
        return symbols[index]
    }
}

/// Empty metadata conforming to AlarmMetadata for simple alarms.
public struct EmptyAlarmMetadata: AlarmMetadata {
    public init() {}
}

// MARK: - AppIntent

public struct AlarmIntent: AppIntent {
    public static var title: LocalizedStringResource { "Set Alarm" }
    public static var description: IntentDescription? { IntentDescription("Sets an alarm using iClaw's AlarmTool.") }

    @Parameter(title: "Time")
    public var time: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = AlarmTool()
        let result = try await tool.execute(input: time, entities: nil)
        return .result(value: result.text)
    }
}
#endif
