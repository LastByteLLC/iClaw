import Foundation

extension GreetingManager {
    // MARK: - Side-Effect Detection

    /// Checks whether an input would trigger a side-effecting tool (audio playback,
    /// sending messages, creating events, etc.) that shouldn't auto-execute on launch.
    ///
    /// Uses the ML classifier + LabelRegistry to check the tool's consent policy and
    /// label action — no hardcoded natural-language verb matching against user input.
    func isSideEffecting(input: String) async -> Bool {
        // 1. Chip-based resolution: extract chip names, look up tools in LabelRegistry
        let chips = InputParsingUtilities.extractToolChipNames(from: input)
        for chip in chips {
            let chipLower = chip.lowercased()
            // Tools with audio/media side effects despite .safe consent policy
            if Self.sideEffectToolNames.contains(chipLower) { return true }
            for (label, entry) in LabelRegistry.entries {
                if entry.tool.lowercased() == chipLower || label == chipLower {
                    if entry.requiresConsent { return true }
                    if let action = LabelRegistry.action(of: label),
                       Self.sideEffectActions.contains(action) {
                        return true
                    }
                }
            }
        }

        // 2. ML classification: predict the label, check registry metadata
        await MLToolClassifier.shared.loadModel()
        if let prediction = await MLToolClassifier.shared.predict(text: input) {
            if let entry = LabelRegistry.lookup(prediction.label) {
                if entry.requiresConsent { return true }
                if Self.sideEffectToolNames.contains(entry.tool.lowercased()) { return true }
            }
            if let action = LabelRegistry.action(of: prediction.label),
               Self.sideEffectActions.contains(action) {
                return true
            }
        }

        return false
    }

    /// Label actions that produce real-world effects and must not auto-execute.
    /// Drawn from compound label actions in LabelRegistry (e.g., "email.compose" → "compose").
    private static let sideEffectActions: Set<String> = [
        "play", "send", "compose", "create", "delete", "modify", "manage",
    ]

    /// Tools with `.safe` consent policy that still produce side effects (e.g., audio playback).
    /// These are blocked from predicted repeat regardless of label action.
    private static let sideEffectToolNames: Set<String> = [
        "podcast",
    ]
}

// MARK: - Task Timeout Helper

func withTaskTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    // Use a separate task for the operation so we can cancel it independently
    // when the timeout fires, without the task group's cancelAll() racing
    // against an already-completed operation result.
    let operationTask = Task { await operation() }

    let didTimeout: Bool = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            _ = await operationTask.value
            return false // operation finished
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return true // timeout
        }
        let first = await group.next() ?? true
        group.cancelAll()
        return first
    }

    if didTimeout {
        operationTask.cancel()
        return nil
    }
    return await operationTask.value
}

// MARK: - Notification Name

extension Notification.Name {
    public static let iClawHUDDidAppear = Notification.Name("iClaw.hudDidAppear")
    public static let iClawHUDDidDisappear = Notification.Name("iClaw.hudDidDisappear")
}
