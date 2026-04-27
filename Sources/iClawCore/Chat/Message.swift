import Foundation
import Observation

public struct Message: Identifiable {
    public let id = UUID()
    public let role: String
    public let content: String
    public var source: String = "local"  // "local" for UI, "imessage" for iMessage
    public var widgetType: String? = nil
    public var widgetData: (any Sendable)? = nil
    public var memoryID: Int64? = nil     // Database ID for deletion
    public var replyToID: UUID? = nil     // ID of the message this is replying to
    public var isError: Bool = false      // Error state for red-tinted display
    public var isGreeting: Bool = false    // Greeting/tip messages — no reply affordance
    public var errorAction: ErrorAction? = nil  // Actionable button (e.g. open settings)
    public var attachmentName: String? = nil    // File name for attachment indicator
    public var attachmentCategory: FileAttachment.FileCategory? = nil
    public var attachmentURL: URL? = nil          // File URL for thumbnail preview + QuickLook

    // Mode thread fields
    public var modeGroupId: UUID? = nil         // Groups messages into a Mode thread
    public var modeSummary: String? = nil        // Collapsed display text for summary bubble
    public var isModeSummary: Bool = false        // Whether this is the summary placeholder
    public var modeName: String? = nil            // Mode name for summary display
    public var modeIcon: String? = nil            // Mode icon for summary display
    public var suggestedQueries: [String]? = nil  // Follow-up suggestion pills for mode threads
    public var modelName: String? = nil            // Non-nil for non-AFM backends (e.g. "Ollama/llama3.2")
    public var originalInput: String? = nil         // Original user input for retry on error

    public init(role: String, content: String, source: String = "local", widgetType: String? = nil, widgetData: (any Sendable)? = nil, memoryID: Int64? = nil, replyToID: UUID? = nil, isError: Bool = false, errorAction: ErrorAction? = nil, attachmentName: String? = nil, attachmentCategory: FileAttachment.FileCategory? = nil, attachmentURL: URL? = nil, modeGroupId: UUID? = nil) {
        self.role = role
        self.content = content
        self.source = source
        self.widgetType = widgetType
        self.widgetData = widgetData
        self.memoryID = memoryID
        self.replyToID = replyToID
        self.isError = isError
        self.errorAction = errorAction
        self.attachmentName = attachmentName
        self.attachmentCategory = attachmentCategory
        self.attachmentURL = attachmentURL
        self.modeGroupId = modeGroupId
    }
}

/// An actionable fix the user can take directly from an error bubble.
public struct ErrorAction: Sendable {
    public let label: String
    public let urlString: String

    public init(label: String, urlString: String) {
        self.label = label
        self.urlString = urlString
    }
}

/// A lightweight snapshot of a message pair for reply context.
public struct ReplyContext {
    public let userMessage: Message
    public let agentMessage: Message
}

/// Shared bus for iMessage poller to push messages into the UI.
@MainActor
@Observable
public class MessageBus {
    public static let shared = MessageBus()
    public var pending: [Message] = []

    public func post(role: String, content: String) {
        pending.append(Message(role: role, content: content, source: "imessage"))
    }
}
