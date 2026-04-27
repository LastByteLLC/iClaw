import AppKit
import iClawCore

class FloatingPanel: NSPanel {
    /// When true, the panel stays visible even when it loses key window status
    /// (e.g. a system permission dialog appears over it).
    var keepVisibleOnResignKey = false

    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func resignKey() {
        super.resignKey()
        guard !keepVisibleOnResignKey else { return }
        // Only dismiss when the whole app becomes inactive (user clicked
        // another app). Transient in-app focus loss — permission dialogs,
        // remote view services (ViewBridge), AFM session handoff — must
        // not close the HUD mid-query. Defer by one runloop so
        // NSApp.isActive reflects the post-transition state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if !NSApp.isActive {
                self.orderOut(nil)
            }
        }
    }

    // Prevent re-entrant layout that triggers the _NSDetectedLayoutRecursion warning
    private var isLayingOut = false
    override func layoutIfNeeded() {
        guard !isLayingOut else { return }
        isLayingOut = true
        super.layoutIfNeeded()
        isLayingOut = false
    }
}
