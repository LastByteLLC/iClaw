import Foundation

/// A structured command object for widget interactions.
///
/// When a widget button is tapped, a `WidgetAction` carries both the user-visible
/// text (shown as the user's message) and a structured payload (passed to the tool
/// for precise execution). This replaces raw string injection, which loses specificity
/// when tools re-parse the text.
///
/// The payload is derived from widget data at render time. Since widget data is
/// persisted on `Message`, this works even for widgets from old turns.
///
/// ## Usage
/// ```swift
/// // In a widget view:
/// Button("Show episodes") {
///     NotificationCenter.default.post(
///         name: .widgetActionTapped,
///         object: WidgetAction(
///             displayText: "#podcast episodes The AI Podcast",
///             payload: ["collectionId": "12345"]
///         )
///     )
/// }
///
/// // In a tool:
/// if let id = entities?.widgetPayload?["collectionId"] {
///     // Fast path — skip re-search
/// }
/// ```
public struct WidgetAction: Sendable {
    /// Text shown to the user as their message and sent to the engine.
    public let displayText: String

    /// Structured data for the tool. Bypasses text parsing entirely.
    /// Keys and values are strings for `Sendable` safety and serialization simplicity.
    public let payload: [String: String]

    public init(displayText: String, payload: [String: String]) {
        self.displayText = displayText
        self.payload = payload
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted by widget buttons that carry structured payloads.
    /// Object is a `WidgetAction` instance.
    public static let widgetActionTapped = Notification.Name("iClaw.widgetActionTapped")
}
