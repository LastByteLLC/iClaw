import Foundation

/// Type-safe widget output enum. Each case carries its correctly-typed widget data,
/// eliminating string-based dispatch and `(any Sendable)?` type erasure.
///
/// Tools can return `WidgetOutput` via the new `ToolIO.typedWidget` property.
/// `WidgetRenderer` supports both the legacy string-based dispatch and this enum.
/// New tools should prefer `WidgetOutput`; existing tools can migrate incrementally.
enum WidgetOutput: Sendable {
    case weather(WeatherWidgetData)
    case weatherForecast(WeatherForecastWidgetData)
    case weatherComparison(WeatherComparisonWidgetData)
    case calculator(CalculatorWidgetData)
    case calculation(CalculationWidgetData)
    case audioPlayer(AudioPlayerWidgetData)
    case backgroundTask(String) // Task description
    case clock(ClockWidgetData)
    case timeComparison(TimeComparisonWidgetData)
    case random(RandomWidgetData)
    case timer(TimerWidgetData)
    case calendar(CalendarWidgetData)
    case stock(StockWidgetData)
    case dictionary(DictionaryWidgetData)
    case podcastEpisodes(PodcastEpisodesWidgetData)
    case news(NewsWidgetData)
    case map(MapWidgetData)
    case todaySummary(TodaySummaryWidgetData)
    case emailList(ReadEmailTool.EmailListWidgetData)
    case emailCompose(EmailComposeWidgetData)
    case messageCompose(MessageComposeWidgetData)
    case reminderConfirmation(ReminderConfirmationData)
    case noteConfirmation(NoteConfirmationData)
    case contactPreview(ContactPreviewData)
    case feedback(FeedbackWidgetData)
    case remoteFileList(RemoteFileListWidgetData)
    case research(ResearchWidgetData)
    case moon(MoonWidgetData)
    case automate(AutomateWidgetData)
    case dynamic(DynamicWidgetData)
    case importPreview(ImportPreviewWidgetData)
    case speedTest(SpeedTestWidgetData)
    case dateView(DateViewWidgetData)
    case calendarEventConfirmation(CalendarEventConfirmationData)
    case none

    /// The legacy widget type string for backward compatibility with `WidgetRenderer`.
    var widgetTypeString: String? {
        switch self {
        case .weather: return "WeatherWidget"
        case .weatherForecast: return "WeatherForecastWidget"
        case .weatherComparison: return "WeatherComparisonWidget"
        case .calculator: return "MathWidget"
        case .calculation: return "MathWidget"
        case .audioPlayer: return "AudioPlayerWidget"
        case .backgroundTask: return "TaskWidget"
        case .clock: return "ClockWidget"
        case .timeComparison: return "TimeComparisonWidget"
        case .random: return "RandomWidget"
        case .timer: return "TimerWidget"
        case .calendar: return "CalendarWidget"
        case .stock: return "StockWidget"
        case .dictionary: return "DictionaryWidget"
        case .podcastEpisodes: return "PodcastEpisodesWidget"
        case .news: return "NewsWidget"
        case .map: return "MapWidget"
        case .todaySummary: return "TodaySummaryWidget"
        case .emailList: return "EmailListWidget"
        case .emailCompose: return "EmailComposeWidget"
        case .messageCompose: return "MessageComposeWidget"
        case .reminderConfirmation: return "ReminderConfirmationWidget"
        case .noteConfirmation: return "NoteConfirmationWidget"
        case .contactPreview: return "ContactPreviewWidget"
        case .feedback: return "FeedbackWidget"
        case .remoteFileList: return "RemoteFileListWidget"
        case .research: return "ResearchWidget"
        case .moon: return "MoonWidget"
        case .automate: return "AutomateWidget"
        case .dynamic: return "DynamicWidget"
        case .importPreview: return "ImportPreviewWidget"
        case .speedTest: return "SpeedTestWidget"
        case .dateView: return "DateViewWidget"
        case .calendarEventConfirmation: return "CalendarEventConfirmationWidget"
        case .none: return nil
        }
    }

    /// The type-erased widget data for backward compatibility.
    var widgetData: (any Sendable)? {
        switch self {
        case .weather(let d): return d
        case .weatherForecast(let d): return d
        case .weatherComparison(let d): return d
        case .calculator(let d): return d
        case .calculation(let d): return d
        case .audioPlayer(let d): return d
        case .backgroundTask(let d): return d
        case .clock(let d): return d
        case .timeComparison(let d): return d
        case .random(let d): return d
        case .timer(let d): return d
        case .calendar(let d): return d
        case .stock(let d): return d
        case .dictionary(let d): return d
        case .podcastEpisodes(let d): return d
        case .news(let d): return d
        case .map(let d): return d
        case .todaySummary(let d): return d
        case .emailList(let d): return d
        case .emailCompose(let d): return d
        case .messageCompose(let d): return d
        case .reminderConfirmation(let d): return d
        case .noteConfirmation(let d): return d
        case .contactPreview(let d): return d
        case .feedback(let d): return d
        case .remoteFileList(let d): return d
        case .research(let d): return d
        case .moon(let d): return d
        case .automate(let d): return d
        case .dynamic(let d): return d
        case .importPreview(let d): return d
        case .speedTest(let d): return d
        case .dateView(let d): return d
        case .calendarEventConfirmation(let d): return d
        case .none: return nil
        }
    }

    /// Creates a WidgetOutput from legacy string + data pair.
    /// Returns `.none` if the type string is nil or unrecognized.
    static func fromLegacy(widgetType: String?, widgetData: (any Sendable)?) -> WidgetOutput {
        guard let type = widgetType, let data = widgetData else { return .none }

        switch type {
        case "WeatherWidget":
            if let d = data as? WeatherWidgetData { return .weather(d) }
        case "WeatherForecastWidget":
            if let d = data as? WeatherForecastWidgetData { return .weatherForecast(d) }
        case "WeatherComparisonWidget":
            if let d = data as? WeatherComparisonWidgetData { return .weatherComparison(d) }
        case "MathWidget":
            if let d = data as? CalculationWidgetData { return .calculation(d) }
            if let d = data as? CalculatorWidgetData { return .calculator(d) }
        case "AudioPlayerWidget":
            if let d = data as? AudioPlayerWidgetData { return .audioPlayer(d) }
        case "TaskWidget":
            if let d = data as? String { return .backgroundTask(d) }
        case "ClockWidget":
            if let d = data as? ClockWidgetData { return .clock(d) }
        case "TimeComparisonWidget":
            if let d = data as? TimeComparisonWidgetData { return .timeComparison(d) }
        case "RandomWidget":
            if let d = data as? RandomWidgetData { return .random(d) }
        case "TimerWidget":
            if let d = data as? TimerWidgetData { return .timer(d) }
        case "CalendarWidget":
            if let d = data as? CalendarWidgetData { return .calendar(d) }
        case "StockWidget":
            if let d = data as? StockWidgetData { return .stock(d) }
        case "DictionaryWidget":
            if let d = data as? DictionaryWidgetData { return .dictionary(d) }
        case "PodcastEpisodesWidget":
            if let d = data as? PodcastEpisodesWidgetData { return .podcastEpisodes(d) }
        case "NewsWidget":
            if let d = data as? NewsWidgetData { return .news(d) }
        case "MapWidget":
            if let d = data as? MapWidgetData { return .map(d) }
        case "TodaySummaryWidget":
            if let d = data as? TodaySummaryWidgetData { return .todaySummary(d) }
        case "EmailListWidget":
            if let d = data as? ReadEmailTool.EmailListWidgetData { return .emailList(d) }
        case "EmailComposeWidget":
            if let d = data as? EmailComposeWidgetData { return .emailCompose(d) }
        case "MessageComposeWidget":
            if let d = data as? MessageComposeWidgetData { return .messageCompose(d) }
        case "ReminderConfirmationWidget":
            if let d = data as? ReminderConfirmationData { return .reminderConfirmation(d) }
        case "NoteConfirmationWidget":
            if let d = data as? NoteConfirmationData { return .noteConfirmation(d) }
        case "ContactPreviewWidget":
            if let d = data as? ContactPreviewData { return .contactPreview(d) }
        case "FeedbackWidget":
            if let d = data as? FeedbackWidgetData { return .feedback(d) }
        case "RemoteFileListWidget":
            if let d = data as? RemoteFileListWidgetData { return .remoteFileList(d) }
        case "ResearchWidget":
            if let d = data as? ResearchWidgetData { return .research(d) }
        case "MoonWidget":
            if let d = data as? MoonWidgetData { return .moon(d) }
        case "AutomateWidget":
            if let d = data as? AutomateWidgetData { return .automate(d) }
        case "DynamicWidget":
            if let d = data as? DynamicWidgetData { return .dynamic(d) }
        case "ImportPreviewWidget":
            if let d = data as? ImportPreviewWidgetData { return .importPreview(d) }
        case "SpeedTestWidget":
            if let d = data as? SpeedTestWidgetData { return .speedTest(d) }
        case "DateViewWidget":
            if let d = data as? DateViewWidgetData { return .dateView(d) }
        case "CalendarEventConfirmationWidget":
            if let d = data as? CalendarEventConfirmationData { return .calendarEventConfirmation(d) }
        default:
            break
        }
        return .none
    }
}
