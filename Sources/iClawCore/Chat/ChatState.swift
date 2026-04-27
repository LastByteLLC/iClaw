import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public class ChatState {

    // MARK: - Conversation

    var messages: [Message] = []
    var dismissedMessageIDs: Set<UUID> = []
    var completedModeGroups: Set<UUID> = []
    var expandedModeGroup: UUID? = nil

    // MARK: - Input

    var input: String = ""
    var previousInput: String = ""
    var attachedFiles: [FileAttachment] = []
    var attachmentSuggestions: [(label: String, prompt: String)] = []
    var pasteSequence: Int = 0
    var pastedHashes: Set<String> = []

    // MARK: - Execution

    var isThinking = false
    var thinkingStartTime: Date?
    var thinkingElapsed: Int = 0
    var thinkingPhrase = thinkingPhrases.randomElement()!
    var stageHistory: [String] = []
    var isBreadcrumbExpanded = false
    var progressState: ProgressUpdate? = nil
    var currentTask: Task<Void, Never>?
    var pendingWidgetPayload: [String: String]?

    /// Consumed and cleared by the next `sendMessage` call. Set by the manual
    /// Retry button to force the engine's finalization ladder to start at Tier 2
    /// (stripped-identity prompt). Prevents repeating the Tier 1 path that just
    /// produced an empty / refusal response.
    var pendingRecoveryHint: RecoveryHint?

    // MARK: - Context

    var replyContext: ReplyContext? = nil
    var feedbackContext: FeedbackContext? = nil
    var browserContextTitle: String? = nil
    var toastMessage: String? = nil

    // MARK: - History

    var oldestLoadedMemoryID: Int64? = nil
    var hasMoreHistory = true
    var isLoadingHistory = false

    // MARK: - Search

    var isSearchActive = false
    var searchManager = ConversationSearchManager()

    // MARK: - UI

    var t: Float = 0.0
    var quickLookURL: URL? = nil
    var lastGreetingDate: Date? = nil

    // MARK: - Singleton References

    let contextPillState = ContextPillState.shared
    let skillModeState = SkillModeState.shared
    let podcastPlayer = PodcastPlayerManager.shared

    public init() {}
}
