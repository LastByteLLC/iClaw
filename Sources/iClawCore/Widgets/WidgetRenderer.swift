import SwiftUI

// MARK: - Widget Environment Keys

/// Environment key allowing any widget to dismiss its parent message row.
struct WidgetDismissKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

/// Environment key providing the parent message's ID to widgets.
/// Widgets use this to link actions (e.g. "Explain") back to the originating message.
struct ParentMessageIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

/// Environment key indicating whether the HUD window is currently visible.
/// Timer-bearing child views should gate updates on this to avoid wasted work.
struct HUDVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var dismissWidget: (() -> Void)? {
        get { self[WidgetDismissKey.self] }
        set { self[WidgetDismissKey.self] = newValue }
    }

    var parentMessageID: UUID? {
        get { self[ParentMessageIDKey.self] }
        set { self[ParentMessageIDKey.self] = newValue }
    }

    var isHUDVisible: Bool {
        get { self[HUDVisibleKey.self] }
        set { self[HUDVisibleKey.self] = newValue }
    }
}

// MARK: - Widget Explain Action

/// Structured payload for widget-initiated actions that bypass the normal
/// user message flow. The prompt is sent silently to the engine, and the
/// response appears as a reply linked to `sourceMessageID`.
///
/// Any widget can use this pattern:
/// 1. Read `@Environment(\.parentMessageID)`
/// 2. Post a `WidgetExplainAction` to `.widgetExplainRequested`
/// 3. ChatView runs the prompt silently and links the response.
public struct WidgetExplainAction {
    public let sourceMessageID: UUID
    public let prompt: String

    public init(sourceMessageID: UUID, prompt: String) {
        self.sourceMessageID = sourceMessageID
        self.prompt = prompt
    }
}

extension Notification.Name {
    /// Posted by any widget's "Explain" (or similar) button.
    /// The notification's `object` is a `WidgetExplainAction`.
    public static let widgetExplainRequested = Notification.Name("iClaw.widgetExplainRequested")
}

// MARK: - Widget Registry

/// Registry-based widget rendering. Each entry maps a widget type string to a
/// factory closure that casts `Any` data and returns `AnyView`.
///
/// To add a new widget: add one entry to `WidgetRegistry.entries`.
@MainActor
private enum WidgetRegistry {

    typealias Factory = @MainActor (Any, String?) -> AnyView?

    /// Standard factory: cast data to `D` and construct widget `V`.
    static func entry<D, V: View>(_: D.Type, _ make: @escaping (D) -> V) -> Factory {
        { data, _ in
            guard let d = data as? D else { return nil }
            return AnyView(make(d))
        }
    }

    static let entries: [String: Factory] = {
        var e: [String: Factory] = [
            "WeatherWidget":           entry(WeatherWidgetData.self) { WeatherWidgetView(data: $0) },
            "AudioPlayerWidget":       entry(AudioPlayerWidgetData.self) { AudioPlayerWidgetView(data: $0) },
            "ClockWidget":             entry(ClockWidgetData.self) { ClockWidgetView(data: $0) },
            "TimeComparisonWidget":    entry(TimeComparisonWidgetData.self) { TimeComparisonWidgetView(data: $0) },
            "RandomWidget":            entry(RandomWidgetData.self) { RandomWidgetView(data: $0) },
            "TimerWidget":             entry(TimerWidgetData.self) { TimerWidgetView(data: $0) },
            "CalendarWidget":          entry(CalendarWidgetData.self) { CalendarWidgetView(data: $0) },
            "CalendarEventConfirmationWidget": entry(CalendarEventConfirmationData.self) { CalendarEventConfirmationWidgetView(data: $0) },
            "StockWidget":             entry(StockWidgetData.self) { StockWidgetView(data: $0) },
            "DictionaryWidget":        entry(DictionaryWidgetData.self) { DictionaryWidgetView(data: $0) },
            "WeatherForecastWidget":   entry(WeatherForecastWidgetData.self) { WeatherForecastWidgetView(data: $0) },
            "WeatherComparisonWidget": entry(WeatherComparisonWidgetData.self) { WeatherComparisonWidgetView(data: $0) },
            "PodcastEpisodesWidget":   entry(PodcastEpisodesWidgetData.self) { PodcastEpisodesWidgetView(data: $0) },
            "PodcastSearchWidget":     entry(PodcastSearchWidgetData.self) { PodcastSearchWidgetView(data: $0) },
            "NewsWidget":              entry(NewsWidgetData.self) { NewsWidgetView(data: $0) },
            "MapWidget":               entry(MapWidgetData.self) { MapWidgetView(data: $0) },
            "TodaySummaryWidget":      entry(TodaySummaryWidgetData.self) { TodaySummaryWidgetView(data: $0) },
            "EmailListWidget":         entry(ReadEmailTool.EmailListWidgetData.self) { EmailListWidgetView(data: $0) },
            "EmailComposeWidget":      entry(EmailComposeWidgetData.self) { EmailComposeWidgetView(data: $0) },
            "MessageComposeWidget":    entry(MessageComposeWidgetData.self) { MessageComposeWidgetView(data: $0) },
            "ReminderConfirmationWidget": entry(ReminderConfirmationData.self) { ReminderConfirmationWidgetView(data: $0) },
            "NoteConfirmationWidget":  entry(NoteConfirmationData.self) { NoteConfirmationWidgetView(data: $0) },
            "ContactPreviewWidget":    entry(ContactPreviewData.self) { ContactPreviewWidgetView(data: $0) },
            "FeedbackWidget":          entry(FeedbackWidgetData.self) { FeedbackWidgetView(data: $0) },
            "MoonWidget":              entry(MoonWidgetData.self) { MoonWidgetView(data: $0) },
            "SunWidget":               entry(SunWidgetData.self) { SunWidgetView(data: $0) },
            "AutomateWidget":          entry(AutomateWidgetData.self) { AutomateWidgetView(data: $0) },
            "EmojiWidget":             entry(EmojiWidgetData.self) { EmojiWidgetView(data: $0) },
            "HoroscopeWidget":         entry(HoroscopeWidgetData.self) { HoroscopeWidgetView(data: $0) },
            "CryptoWidget":            entry(CryptoWidgetData.self) { CryptoWidgetView(data: $0) },
            "DynamicWidget":           entry(DynamicWidgetData.self) { DynamicWidgetView(data: $0) },
            "ToolTipCard":             entry(ToolTipCardData.self) { ToolTipCardView(data: $0) },
            "HelpOverviewWidget":      entry(HelpOverviewWidgetData.self) { HelpOverviewWidgetView(data: $0) },
            "HelpCategoryWidget":      entry(HelpCategoryWidgetData.self) { HelpCategoryWidgetView(data: $0) },
            "HelpTourStepWidget":      entry(HelpTourStepWidgetData.self) { HelpTourStepWidgetView(data: $0) },
            "HelpLimitationsWidget":   entry(HelpLimitationsWidgetData.self) { HelpLimitationsWidgetView(data: $0) },
            "QuoteWidget":             entry(QuoteWidgetData.self) { QuoteWidgetView(data: $0) },
            "AutomationWidget":        entry(AutomationWidgetData.self) { AutomationWidgetView(data: $0) },
            "ComputeWidget":           entry(ComputeWidgetData.self) { ComputeWidgetView(data: $0) },
            "DateViewWidget":          entry(DateViewWidgetData.self) { DateViewWidget(data: $0) },
            "TOSWidget":               { _, _ in AnyView(TOSWidgetView()) },
            "TaskWidget":              { data, _ in AnyView(BackgroundTaskWidgetView(data: data as? Double)) },

            // ResearchWidget needs messageContent
            "ResearchWidget": { data, messageContent in
                guard let d = data as? ResearchWidgetData else { return nil }
                return AnyView(ResearchWidgetView(data: d, messageContent: messageContent))
            },

            // MathWidget with legacy fallback
            "MathWidget": { data, _ in
                if let d = data as? CalculationWidgetData {
                    return AnyView(CalculatorWidgetView(data: d))
                } else if let legacy = data as? CalculatorWidgetData {
                    return AnyView(CalculatorWidgetView(data: CalculationWidgetData(
                        expression: legacy.equation, result: legacy.result)))
                }
                return nil
            },
        ]

        #if os(macOS)
        e["ImportPreviewWidget"] = entry(ImportPreviewWidgetData.self) { ImportPreviewWidgetView(data: $0) }
        e["SpeedTestWidget"] = entry(SpeedTestWidgetData.self) { SpeedTestWidgetView(data: $0) }
        #endif

        #if CONTINUITY_ENABLED
        e["RemoteFileListWidget"] = entry(RemoteFileListWidgetData.self) { RemoteFileListWidgetView(data: $0) }
        #endif

        return e
    }()

    static func render(type: String, data: Any, messageContent: String?) -> AnyView? {
        entries[type]?(data, messageContent)
    }
}

// MARK: - WidgetRenderer View

@MainActor
public struct WidgetRenderer: View {
    public let widgetType: String
    public let data: Any
    public var messageContent: String?

    public init(widgetType: String, data: Any, messageContent: String? = nil) {
        self.widgetType = widgetType
        self.data = data
        self.messageContent = messageContent
    }

    public var body: some View {
        if let view = WidgetRegistry.render(type: widgetType, data: data, messageContent: messageContent) {
            view
        } else {
            let _ = Log.ui.error("WidgetRenderer: Unknown widget type '\(widgetType)'. Check tool's outputWidget string.")
            VStack {
                Text("Unknown Widget: \(widgetType)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .glassContainer()
        }
    }
}
