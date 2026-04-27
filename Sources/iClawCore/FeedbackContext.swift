import Foundation
import Observation

/// A snapshot of the conversation chain being reviewed for feedback.
public struct FeedbackContext: Sendable {
    /// Pairs of (user, agent) messages leading up to the feedback target.
    public let messageChain: [(user: String, agent: String)]
    /// The user's original feedback text.
    public var originalFeedback: String
    /// Additional clarifications added in follow-up rounds.
    public var clarifications: [String]
    /// LLM-suggested follow-up questions.
    public var suggestedQuestions: [String]

    public init(
        messageChain: [(user: String, agent: String)],
        originalFeedback: String = "",
        clarifications: [String] = [],
        suggestedQuestions: [String] = []
    ) {
        self.messageChain = messageChain
        self.originalFeedback = originalFeedback
        self.clarifications = clarifications
        self.suggestedQuestions = suggestedQuestions
    }

    /// Serializes the chain into the `[Feedback on: ...]` prefix format.
    public func serializedPrefix() -> String {
        let pairs = messageChain.map { "\"\($0.user)\"→\"\($0.agent)\"" }.joined(separator: " | ")
        return "[Feedback on: \(pairs)]"
    }
}

/// Data model for the FeedbackWidget.
public struct FeedbackWidgetData: Sendable {
    public enum Phase: String, Sendable {
        case review
        case sending
        case sent
        case cancelled
    }

    public let phase: Phase
    public let summary: String
    public let suggestedQuestions: [String]
    public let feedbackID: String
    public init(phase: Phase, summary: String, suggestedQuestions: [String] = [], feedbackID: String = UUID().uuidString) {
        self.phase = phase
        self.summary = summary
        self.suggestedQuestions = suggestedQuestions
        self.feedbackID = feedbackID
    }
}

/// Singleton bus for feedback widget actions (Clarify, Cancel, Send).
@MainActor
@Observable
public class FeedbackActionBus {
    public static let shared = FeedbackActionBus()

    public enum Action: Sendable, Equatable {
        case clarify
        case cancel
        case send
    }

    public var lastAction: Action? = nil
    public var feedbackID: String? = nil

    public func post(action: Action, feedbackID: String) {
        self.feedbackID = feedbackID
        self.lastAction = action
    }
}
