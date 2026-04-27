import Foundation
import Observation

/// Observable state for the context pill that appears after tool execution.
///
/// The pill shows the prior tool name + primary entity, with a countdown bar.
/// Tapping anchors the context (boosting follow-up classifier confidence).
/// The pill auto-dismisses after `duration` seconds or when input ≥ 10 words.
@MainActor
@Observable
public class ContextPillState {
    /// Whether the pill is currently visible.
    public var isVisible = false

    /// Whether the user has tapped to anchor the context.
    public var isAnchored = false

    /// The tool that ran in the prior turn.
    public var toolName: String = ""

    /// Primary entity for display (e.g., "Paris", "AAPL", "John").
    public var primaryEntity: String?

    /// SF Symbol icon for the tool.
    public var toolIcon: String = "sparkles"

    /// Countdown progress (1.0 → 0.0).
    public var progress: CGFloat = 1.0

    /// How long the pill stays visible (seconds).
    public let duration: TimeInterval = 30

    /// The auto-dismiss task.
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    public static let shared = ContextPillState()
    private init() {}

    /// Shows the pill with tool info. Called after each successful tool execution.
    public func show(toolName: String, primaryEntity: String?, toolIcon: String) {
        self.toolName = toolName
        self.primaryEntity = primaryEntity
        self.toolIcon = toolIcon
        self.isAnchored = false
        self.progress = 1.0
        self.isVisible = true

        // Start countdown
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            // Animate progress bar over duration
            let steps = 60
            let stepDuration = duration / Double(steps)
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(stepDuration))
                guard !Task.isCancelled else { return }
                if isAnchored { return } // Stop countdown if anchored
                progress = 1.0 - CGFloat(i) / CGFloat(steps)
            }
            // Auto-dismiss after countdown
            if !isAnchored {
                dismiss()
            }
        }
    }

    /// Toggles the anchor state. When anchored, the countdown stops and the
    /// pill stays until the user sends a message or dismisses manually.
    public func toggleAnchor() {
        isAnchored.toggle()
        if isAnchored {
            progress = 1.0 // Reset bar to full when anchored
        } else {
            // Restart countdown from current progress
            show(toolName: toolName, primaryEntity: primaryEntity, toolIcon: toolIcon)
        }
    }

    /// Dismisses the pill.
    public func dismiss() {
        dismissTask?.cancel()
        isVisible = false
        isAnchored = false
    }

    /// Called when the input text changes. Auto-dismisses if input ≥ 10 words
    /// and the pill is not anchored (long inputs are self-contained queries).
    public func onInputChanged(_ text: String) {
        guard isVisible, !isAnchored else { return }
        let wordCount = text.split(separator: " ").count
        if wordCount >= 10 {
            dismiss()
        }
    }

    /// Display text for the pill.
    public var displayText: String {
        if let entity = primaryEntity, !entity.isEmpty {
            return "\(toolName) · \(entity)"
        }
        return toolName
    }
}
