import AppKit
import SwiftUI
import TipKit
import UserNotifications
import iClawCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var hudWindow: FloatingPanel?
    var heartbeatTimer: Timer?
    private var hasUnreadIndicator = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register UserDefaults defaults so bool(forKey:) matches @AppStorage defaults
        UserDefaults.standard.register(defaults: [
            AppConfig.knowledgeMemoryEnabledKey: true
        ])

        // Configure TipKit for progressive feature discovery
        try? Tips.configure([
            .displayFrequency(.daily),
            .datastoreLocation(.applicationDefault)
        ])

        ToolRegistry.registerConditionalTools()

        LaunchModeManager.shared.configureAppActivationPolicy()
        setupStatusItem()
        setupHUDWindow()
        startHeartbeat()
        startPreFetch()


        // Auto-detect the best LLM backend (AFM if available, Ollama if running).
        // Prewarming happens when the HUD is shown, not at launch.
        Task {
            await LLMAdapter.shared.autoConfigureBackend()
        }

        // LoRA adapter loading is not wired up pending
        // https://developer.apple.com/forums/thread/823001 — the base
        // SystemLanguageModel is used until that issue is resolved.

        // Clean up stale script files from interrupted NSUserAppleScriptTask executions.
        UserScriptRunner.cleanupStaleScripts()

        // Start global hotkey monitoring (sandbox-safe)
        HotkeyManager.shared.startMonitoring()
        NotificationCenter.default.addObserver(
            forName: .iClawHotkeyChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                HotkeyManager.shared.reload()
            }
        }

        // Prewarm ML classifiers in background so first query doesn't pay ~500ms load penalty.
        Task.detached(priority: .utility) {
            await MLToolClassifier.shared.loadModel()
            await FollowUpClassifier.shared.loadModel()
            await ToxicityClassifier.shared.loadModel()
        }

        // Ensure database is initialized
        _ = DatabaseManager.shared

        // Enable MetricKit if user opted in
        if UserDefaults.standard.bool(forKey: "sendAnonymousCrashData") {
            MetricsManager.shared.enable()
        }

        // Start browser bridge if enabled AND browser is running.
        // BrowserMonitor uses NSWorkspace notifications to reactively start/stop
        // the bridge when the browser opens or closes — no polling needed.
        if UserDefaults.standard.bool(forKey: "browserBridgeEnabled"),
           BrowserMonitor.shared.isBrowserRunning {
            Task {
                try? await BrowserBridge.shared.start()
            }
        }

        // Start screen context capture if enabled
        if UserDefaults.standard.bool(forKey: "screenContextEnabled") {
            Task {
                await ScreenContextManager.shared.start()
            }
        }

        // Notification observers
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAutomationResult(_:)),
            name: .iClawAutomationResult, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleClearBadge),
            name: .iClawClearBadge, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePersistHUD(_:)),
            name: .iClawPersistHUD, object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage.clawMenuBar
            button.action = #selector(toggleWindow)
            button.target = self
        }
    }

    private func setupHUDWindow() {
        hudWindow = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        hudWindow?.isFloatingPanel = true
        hudWindow?.level = .floating
        hudWindow?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hudWindow?.backgroundColor = .clear
        hudWindow?.isOpaque = false
        hudWindow?.hasShadow = false
        hudWindow?.contentView = NSHostingView(rootView: ChatView())
    }

    @objc func toggleWindow() {
        guard let hudWindow = hudWindow else { return }
        if hudWindow.isVisible {
            hudWindow.orderOut(nil)
            NotificationCenter.default.post(name: .iClawHUDDidDisappear, object: nil)
            // Discard the prewarmed session when the HUD is hidden.
            Task { await LLMAdapter.shared.invalidatePrewarm() }
        } else {
            // Position near the status item
            if let button = statusItem?.button, let window = button.window {
                let frame = window.frame
                hudWindow.setFrameOrigin(NSPoint(x: frame.minX - hudWindow.frame.width / 2 + frame.width / 2, y: frame.minY - hudWindow.frame.height - 5))
            }
            hudWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .iClawHUDDidAppear, object: nil)

            // Prewarm the LLM session so the first query is fast.
            // Cleared on first prompt (generate() sets prewarmedSession = nil)
            // or when HUD is hidden (invalidatePrewarm above).
            Task { await LLMAdapter.shared.prewarmForFinalization() }

            // Clear notification indicators when HUD opens
            if hasUnreadIndicator {
                clearMenuBarIndicator()
                Task { await NotificationEngine.shared.clearBadge() }
            }
        }
    }

    // MARK: - Dock Icon Reopen

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !(hudWindow?.isVisible ?? false) {
            toggleWindow()
        }
        return false
    }

    // MARK: - Menu Bar Indicator

    @objc private func handleAutomationResult(_ notification: Notification) {
        let modeRaw = notification.userInfo?["mode"] as? String ?? "basic"
        let count = notification.userInfo?["count"] as? Int ?? 1

        guard let button = statusItem?.button else { return }

        if modeRaw == "basic" {
            addMenuBarDot(to: button)
        } else if modeRaw == "full" {
            addMenuBarBadge(count: count, to: button)
        }
        hasUnreadIndicator = true
    }

    @objc private func handleClearBadge() {
        clearMenuBarIndicator()
    }

    @objc private func handlePersistHUD(_ notification: Notification) {
        guard let persist = notification.object as? Bool else { return }
        hudWindow?.keepVisibleOnResignKey = persist
    }

    private func addMenuBarDot(to button: NSStatusBarButton) {
        clearMenuBarIndicator()
        let dotSize: CGFloat = 6
        let dot = NSView(frame: NSRect(
            x: button.bounds.width - dotSize - 1,
            y: button.bounds.height - dotSize - 1,
            width: dotSize,
            height: dotSize
        ))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = dotSize / 2
        dot.identifier = NSUserInterfaceItemIdentifier("notificationDot")
        button.addSubview(dot)
        button.setAccessibilityLabel("iClaw — new results available")
        hasUnreadIndicator = true
    }

    private func addMenuBarBadge(count: Int, to button: NSStatusBarButton) {
        clearMenuBarIndicator()
        let text = "\(count)"
        let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let badgeWidth = max(textSize.width + 6, 14)
        let badgeHeight: CGFloat = 12

        let badge = NSView(frame: NSRect(
            x: button.bounds.width - badgeWidth - 1,
            y: button.bounds.height - badgeHeight - 1,
            width: badgeWidth,
            height: badgeHeight
        ))
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = badgeHeight / 2
        badge.identifier = NSUserInterfaceItemIdentifier("notificationBadge")

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: badgeWidth, height: badgeHeight)
        badge.addSubview(label)

        button.addSubview(badge)
        button.setAccessibilityLabel("iClaw — \(count) unread notification\(count == 1 ? "" : "s")")
        hasUnreadIndicator = true
    }

    private func clearMenuBarIndicator() {
        guard let button = statusItem?.button else { return }
        let dotID = NSUserInterfaceItemIdentifier("notificationDot")
        let badgeID = NSUserInterfaceItemIdentifier("notificationBadge")
        button.subviews.filter { $0.identifier == dotID || $0.identifier == badgeID }.forEach { $0.removeFromSuperview() }
        button.setAccessibilityLabel("iClaw")
        hasUnreadIndicator = false
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let messageIDString = response.notification.request.content.userInfo["messageID"] as? String

        await MainActor.run {
            // Open the HUD if closed
            if !(hudWindow?.isVisible ?? false) {
                toggleWindow()
            }

            // Navigate to the specific message if ID is available
            if let messageIDString,
               let messageID = UUID(uuidString: messageIDString) {
                NotificationCenter.default.post(
                    name: .iClawNavigateToMessage,
                    object: messageID
                )
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: - Pre-Fetch

    private func startPreFetch() {
        Task {
            await PreFetchScheduler.shared.registerTool(NewsTool())
            await PreFetchScheduler.shared.registerTool(WeatherTool())
            await PreFetchScheduler.shared.start()
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let intervalMinutes = UserDefaults.standard.integer(forKey: "heartbeatInterval")
        guard intervalMinutes > 0 else {
            Log.engine.debug("Heartbeat disabled (interval=0)")
            return
        }
        let interval = TimeInterval(intervalMinutes * 60)
        Log.engine.debug("Starting heartbeat with \(intervalMinutes)-minute interval")

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.runHeartbeatAction()
            }
        }
    }

    /// Restarts the heartbeat timer when the user changes the interval in Settings.
    func restartHeartbeat() {
        heartbeatTimer?.invalidate()
        startHeartbeat()
    }

    private func runHeartbeatAction() async {
        await HeartbeatManager.shared.runHeartbeat()
    }
}
