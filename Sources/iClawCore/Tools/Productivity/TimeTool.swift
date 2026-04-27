import Foundation
import CoreLocation
import MapKit
import AppIntents
import UserNotifications

// MARK: - Widget Data Types

/// Data structure for ClockWidgetView (local-only time display).
public struct ClockWidgetData: Sendable {
    public let location: String
    public let timeZoneIdentifier: String

    public init(location: String, timeZoneIdentifier: String) {
        self.location = location
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// Data structure for TimeComparisonWidgetView (remote location with difference).
public struct TimeComparisonWidgetData: Sendable {
    public let localTimeZoneIdentifier: String
    public let remoteTimeZoneIdentifier: String
    public let remoteLocationName: String
    /// Signed difference in seconds (remote - local). Positive = remote is ahead.
    public let differenceSeconds: Int

    public init(localTimeZoneIdentifier: String, remoteTimeZoneIdentifier: String, remoteLocationName: String, differenceSeconds: Int) {
        self.localTimeZoneIdentifier = localTimeZoneIdentifier
        self.remoteTimeZoneIdentifier = remoteTimeZoneIdentifier
        self.remoteLocationName = remoteLocationName
        self.differenceSeconds = differenceSeconds
    }
}

/// Data structure for TimerWidgetView.
public struct TimerWidgetData: Sendable {
    public let duration: TimeInterval
    public let label: String

    public init(duration: TimeInterval, label: String) {
        self.duration = duration
        self.label = label
    }
}

/// Structured arguments for LLM-extracted timer requests.
public struct TimerArgs: ToolArguments {
    public let hours: Int?
    public let minutes: Int?
    public let seconds: Int?
    public let label: String?
}

// MARK: - Timezone Resolver

/// Closure that resolves a location string to a `(TimeZone, displayName)` pair.
/// Injected into `TimeTool` for testing so tests don't depend on `MKLocalSearch`.
public typealias TimezoneResolver = @Sendable (String) async -> (TimeZone, String)

// MARK: - Unified Time Tool

/// Unified time tool handling both clock queries and countdown timers.
///
/// Replaces the former separate `Clock` and `Timer` tools. The ML classifier
/// predicts either `"time"` (clock) or `"timer"` labels, both resolving to
/// this tool. The routing label is passed through so the tool knows which
/// sub-behavior was intended — no heuristic disambiguation needed.
///
/// **Clock path**: current time for a location, timezone comparison
/// **Timer path**: countdown timer with notification, structured extraction
///
/// Fallback (when `routingLabel` is nil, e.g., chip `#time`): attempts
/// `TimerArgs` extraction. If duration found → timer. Otherwise → clock.
public struct TimeTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Time"
    public let schema = "Get the current time for a location, or set a countdown timer. Examples: 'time in Tokyo', 'set a 5 minute timer'."
    public let isInternal = false
    public let category = CategoryEnum.online

    // MARK: - Clock Configuration

    /// Prefixes stripped when extracting a location from natural language input.
    private static let locationPrefixes: [String] = ConfigLoader.loadStringArray("TimeLocationPrefixes")

    /// Multilingual intent keywords loaded from
    /// `Resources/Config/TimeIntentKeywords.json`. Replaces the English-only
    /// `localOnlyPhrases` set.
    static let intentKeywords: MultilingualKeywords? = MultilingualKeywords.load("TimeIntentKeywords")

    /// Returns true when the input is asking for the local current time
    /// (no zone), in any supported language.
    static func isCurrentTimeQuery(_ input: String) -> Bool {
        intentKeywords?.matches(intent: "current_time", in: input) ?? false
    }

    // MARK: - Timer Configuration

    /// Pre-compiled duration regexes.
    private static let durationPatterns: [(NSRegularExpression, Double)] = [
        (try! NSRegularExpression(pattern: "(\\d+)\\s*hour"), 3600.0),
        (try! NSRegularExpression(pattern: "(\\d+)\\s*min"), 60.0),
        (try! NSRegularExpression(pattern: "(\\d+)\\s*sec"), 1.0),
    ]

    // MARK: - Init

    /// Optional injectable timezone resolver. When `nil`, falls back to `MKLocalSearch`.
    private let timezoneResolver: TimezoneResolver?

    public init(timezoneResolver: TimezoneResolver? = nil) {
        self.timezoneResolver = timezoneResolver
    }

    // MARK: - ExtractableCoreTool (Timer Extraction)

    public typealias Args = TimerArgs

    public static let extractionSchema: String = loadExtractionSchema(
        named: "Timer", fallback: "{\"hours\":\"int?\",\"minutes\":\"int?\",\"seconds\":\"int?\",\"label\":\"string?\"}"
    )

    /// ExtractableCoreTool path — always timer behavior (extraction only
    /// produces TimerArgs when the input has duration information).
    public func execute(args: TimerArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await executeTimer(args: args, rawInput: rawInput)
    }

    // MARK: - Label-Aware Dispatch

    /// Primary execution with routing label for disambiguation.
    public func execute(input: String, entities: ExtractedEntities?, routingLabel: String?) async throws -> ToolIO {
        switch routingLabel {
        case "timer":
            return try await executeTimerFromInput(input: input, entities: entities)
        case "time":
            return try await executeClock(input: input, entities: entities)
        default:
            // Fallback: no routing label (chip, follow-up, etc.)
            // Check if input has duration patterns → timer, else → clock
            if hasDurationSignal(input) {
                return try await executeTimerFromInput(input: input, entities: entities)
            }
            return try await executeClock(input: input, entities: entities)
        }
    }

    /// Standard CoreTool entry point (no label). Delegates to label-aware version.
    public func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        try await execute(input: input, entities: entities, routingLabel: nil)
    }

    // MARK: - Clock Execution

    private func executeClock(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            let normalizedInput = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            // Multilingual: matches "what time is it" / "什么时间" / "qué hora es" etc.
            // Only treat as local-only if the NER layer did NOT extract a place.
            // Phrasings like "current time in Mumbai" used to match the
            // "current_time" keyword and wipe the city out of the query before
            // timezone resolution; the NER gate keeps city-qualified questions
            // on the remote path.
            let hasPlaceEntity = !(entities?.places.isEmpty ?? true)
            let isLocalOnly = !hasPlaceEntity && Self.isCurrentTimeQuery(normalizedInput)

            let cleanedLocation: String
            if isLocalOnly {
                cleanedLocation = ""
            } else {
                cleanedLocation = InputParsingUtilities.extractLocation(
                    from: input, entities: entities, strippingPrefixes: Self.locationPrefixes
                ) ?? ""
            }

            let (timeZone, locationName) = await resolveTimezone(for: cleanedLocation)
            let now = Date()
            let isRemote = timeZone.identifier != TimeZone.current.identifier

            let remoteFormatter = DateFormatter()
            remoteFormatter.timeZone = timeZone
            remoteFormatter.dateStyle = .medium
            remoteFormatter.timeStyle = .long
            let remoteTimeString = remoteFormatter.string(from: now)

            if !isRemote {
                return ToolIO(
                    text: "The current time in \(locationName) is \(remoteTimeString).",
                    status: .ok,
                    outputWidget: "ClockWidget",
                    widgetData: ClockWidgetData(location: locationName, timeZoneIdentifier: timeZone.identifier),
                    isVerifiedData: true
                )
            }

            let localOffset = TimeZone.current.secondsFromGMT(for: now)
            let remoteOffset = timeZone.secondsFromGMT(for: now)
            let diffSeconds = remoteOffset - localOffset
            let diffHours = Double(diffSeconds) / 3600.0

            let localFormatter = DateFormatter()
            localFormatter.timeZone = .current
            localFormatter.dateStyle = .none
            localFormatter.timeStyle = .short
            let localTimeString = localFormatter.string(from: now)

            let differencePhrase: String
            if diffSeconds == 0 {
                differencePhrase = "\(locationName) is in the same timezone as you"
            } else {
                let absDiff = abs(diffHours)
                let direction = diffHours > 0 ? "ahead" : "behind"
                let hourLabel: String
                if absDiff == absDiff.rounded() {
                    hourLabel = "\(Int(absDiff)) hour\(Int(absDiff) == 1 ? "" : "s")"
                } else {
                    hourLabel = String(format: "%.1f hours", absDiff)
                }
                differencePhrase = "\(locationName) is \(hourLabel) \(direction)"
            }

            let resultText = "\(locationName): \(remoteTimeString). Your time: \(localTimeString). \(differencePhrase)."
            let widgetData = TimeComparisonWidgetData(
                localTimeZoneIdentifier: TimeZone.current.identifier,
                remoteTimeZoneIdentifier: timeZone.identifier,
                remoteLocationName: locationName,
                differenceSeconds: diffSeconds
            )

            return ToolIO(
                text: resultText,
                status: .ok,
                outputWidget: "TimeComparisonWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }
    }

    // MARK: - Timer Execution

    private func executeTimer(args: TimerArgs, rawInput: String) async -> ToolIO {
        await timed {
            let totalSeconds = (args.hours ?? 0) * 3600 + (args.minutes ?? 0) * 60 + (args.seconds ?? 0)
            let duration: TimeInterval = totalSeconds > 0 ? TimeInterval(totalSeconds) : 60.0
            await scheduleNotification(duration: duration, label: args.label ?? rawInput)

            let widgetData = TimerWidgetData(duration: duration, label: args.label ?? rawInput)
            return ToolIO(
                text: "Timer set for \(Self.formatDuration(duration)).",
                status: .ok,
                outputWidget: "TimerWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }
    }

    private func executeTimerFromInput(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            let lowerInput = input.lowercased()
            var duration: TimeInterval = 0

            for (regex, multiplier) in Self.durationPatterns {
                if let match = regex.firstMatch(in: lowerInput, options: [], range: NSRange(location: 0, length: lowerInput.utf16.count)) {
                    if let range = Range(match.range(at: 1), in: lowerInput),
                       let value = Double(lowerInput[range]) {
                        duration += value * multiplier
                    }
                }
            }

            if duration == 0 {
                let numbers = lowerInput.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .filter { !$0.isEmpty }.compactMap { Double($0) }
                if let first = numbers.first {
                    duration = first * 60.0
                }
            }

            if duration == 0 {
                return ToolIO(
                    text: "Could not understand the duration: \(input)",
                    status: .error
                )
            }

            await scheduleNotification(duration: duration, label: input)

            let widgetData = TimerWidgetData(duration: duration, label: input)
            return ToolIO(
                text: "Timer set for \(Self.formatDuration(duration)).",
                status: .ok,
                outputWidget: "TimerWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        }
    }

    // MARK: - Shared Helpers

    /// Checks if the input contains duration-like patterns (numbers + time units).
    private func hasDurationSignal(_ input: String) -> Bool {
        let lower = input.lowercased()
        for (regex, _) in Self.durationPatterns {
            if regex.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                return true
            }
        }
        // Also check for "timer" keyword as a signal
        return lower.contains("timer") || lower.contains("countdown")
    }

    private func scheduleNotification(duration: TimeInterval, label: String) async {
        guard let bundleID = Bundle.main.bundleIdentifier,
              !bundleID.hasPrefix("com.apple.dt.xctest"),
              Bundle.main.bundlePath.hasSuffix(".app") else { return }

        let authorized: Bool
        do {
            authorized = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                group.addTask { try await Task.sleep(nanoseconds: 3_000_000_000); throw CancellationError() }
                let result = try await group.next() ?? false
                group.cancelAll()
                return result
            }
        } catch {
            authorized = false
        }

        guard authorized else { return }

        let _ = await PermissionManager.requestPermission(.notifications, toolName: "Time", reason: "to alert you when the timer finishes")

        let content = UNMutableNotificationContent()
        content.title = "Timer Finished"
        content.body = "Your timer for '\(label)' has finished."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: duration, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        _ = try? await UNUserNotificationCenter.current().add(request)
    }

    private func resolveTimezone(for location: String) async -> (TimeZone, String) {
        guard !location.isEmpty else {
            return (.current, "Local Time")
        }

        if let resolver = timezoneResolver {
            return await resolver(location)
        }

        // MKLocalSearch is the best source, but in headless / no-network /
        // simulator environments it can silently succeed with a mapItem
        // whose timeZone falls back to the device's local zone. Detect that
        // case and prefer the bundled IANA lookup so "What time in Mumbai?"
        // never returns EDT on a US-configured device.
        do {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = location
            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            if let mapItem = response.mapItems.first(where: { $0.timeZone != nil }),
               let tz = mapItem.timeZone,
               tz.identifier != TimeZone.current.identifier {
                let name = mapItem.name ?? location.capitalized
                return (tz, name)
            }
        } catch {
            Log.tools.debug("Geocoding failed for '\(location)': \(error)")
        }

        // Bundled IANA fallback. Hand-rolled for the 40 most-queried cities so
        // the tool is correct offline and when MKLocalSearch returns local tz.
        if let tz = Self.cityTimezoneFallback(for: location) {
            return (tz, location.capitalized)
        }

        return (.current, "Local Time")
    }

    /// Cached alias table loaded once from `TimezoneCityAliases.json`.
    /// Values are IANA identifiers; keys are lowercased city / colloquial names
    /// for places whose common name differs from the IANA identifier (Mumbai
    /// vs Asia/Kolkata, Boston vs America/New_York).
    private static let cityAliasTable: [String: String] = {
        struct Wrapper: Decodable { let aliases: [String: String] }
        if let w: Wrapper = ConfigLoader.load("TimezoneCityAliases", as: Wrapper.self) {
            return w.aliases
        }
        return [:]
    }()

    /// Pre-normalized IANA identifiers keyed by their city portion for
    /// fast suffix/word matching ("los_angeles" → "America/Los_Angeles").
    private static let ianaByCity: [String: String] = {
        var map: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let cityPart = id.lowercased().components(separatedBy: "/").last else { continue }
            map[cityPart] = id
            // Also index the un-underscored form so "los angeles" and
            // "los_angeles" both hit.
            let spaced = cityPart.replacingOccurrences(of: "_", with: " ")
            if spaced != cityPart { map[spaced] = id }
        }
        return map
    }()

    /// Returns an IANA timezone for a city / location query, using (1) the
    /// IANA identifier suffix index (covers most cities whose name matches
    /// the zone, e.g. Paris → Europe/Paris), then (2) the alias resource
    /// (cities whose IANA identifier differs from their common name,
    /// e.g. Mumbai → Asia/Kolkata). No hardcoded English in code — the
    /// alias table is data in `TimezoneCityAliases.json`.
    private static func cityTimezoneFallback(for query: String) -> TimeZone? {
        let normalized = query.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !normalized.isEmpty else { return nil }

        // (1) Exact match against IANA city suffix
        if let id = ianaByCity[normalized], let tz = TimeZone(identifier: id) {
            return tz
        }
        // (2) Alias table lookup (Mumbai → Kolkata, Boston → New_York, …)
        if let id = cityAliasTable[normalized], let tz = TimeZone(identifier: id) {
            return tz
        }
        // (3) Token-level match — split by whitespace/punctuation and try
        // each individual token and each contiguous pair. Catches queries
        // like "in Mumbai", "Mumbai, India", "Mumbai India time".
        let tokens = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for t in tokens {
            if let id = ianaByCity[t], let tz = TimeZone(identifier: id) { return tz }
            if let id = cityAliasTable[t], let tz = TimeZone(identifier: id) { return tz }
        }
        // Two-token joins for multi-word city names (e.g. "new delhi", "abu dhabi")
        if tokens.count >= 2 {
            for i in 0..<(tokens.count - 1) {
                let pair = "\(tokens[i]) \(tokens[i+1])"
                if let id = ianaByCity[pair], let tz = TimeZone(identifier: id) { return tz }
                if let id = cityAliasTable[pair], let tz = TimeZone(identifier: id) { return tz }
            }
        }
        return nil
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            let hours = total / 3600
            let mins = (total % 3600) / 60
            if mins > 0 {
                return "\(hours) hour\(hours == 1 ? "" : "s") \(mins) minute\(mins == 1 ? "" : "s")"
            }
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        } else if total >= 60 {
            let mins = total / 60
            let secs = total % 60
            if secs > 0 {
                return "\(mins) minute\(mins == 1 ? "" : "s") \(secs) second\(secs == 1 ? "" : "s")"
            }
            return "\(mins) minute\(mins == 1 ? "" : "s")"
        } else {
            return "\(total) second\(total == 1 ? "" : "s")"
        }
    }
}

// MARK: - AppIntents

/// AppIntent wrapping TimeTool clock path for system-wide access.
public struct TimeIntent: AppIntent {
    public static var title: LocalizedStringResource { "Get Current Time" }
    public static var description: IntentDescription? { IntentDescription("Gets the current time using the iClaw TimeTool.") }

    @Parameter(title: "Location")
    public var location: String?

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = TimeTool()
        let result = try await tool.execute(input: location ?? "", entities: nil, routingLabel: "time")
        return .result(value: result.text)
    }
}

/// AppIntent wrapping TimeTool timer path for system-wide access.
public struct TimerIntent: AppIntent {
    public static var title: LocalizedStringResource { "Set Timer" }
    public static var description: IntentDescription? { IntentDescription("Sets a timer using the iClaw TimeTool.") }

    @Parameter(title: "Duration")
    public var duration: String

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = TimeTool()
        let result = try await tool.execute(input: duration, entities: nil, routingLabel: "timer")
        return .result(value: result.text)
    }
}
