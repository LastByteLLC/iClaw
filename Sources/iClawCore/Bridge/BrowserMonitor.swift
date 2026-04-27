#if os(macOS)
import AppKit
import Observation

/// Represents a browser that iClaw can integrate with.
public struct SupportedBrowser: Identifiable, Hashable, Sendable {
    public let id: String              // Bundle identifier
    public let displayName: String
    public let isSupported: Bool       // Whether iClaw's extension is available for this browser

    /// Well-known browsers iClaw can detect.
    public static let safari = SupportedBrowser(
        id: "com.apple.Safari",
        displayName: "Safari",
        isSupported: true
    )
    public static let chrome = SupportedBrowser(
        id: "com.google.Chrome",
        displayName: "Google Chrome",
        isSupported: false
    )
    public static let firefox = SupportedBrowser(
        id: "org.mozilla.firefox",
        displayName: "Firefox",
        isSupported: false
    )
    public static let arc = SupportedBrowser(
        id: "company.thebrowser.Browser",
        displayName: "Arc",
        isSupported: false
    )
    public static let brave = SupportedBrowser(
        id: "com.brave.Browser",
        displayName: "Brave",
        isSupported: false
    )
    public static let edge = SupportedBrowser(
        id: "com.microsoft.edgemac",
        displayName: "Microsoft Edge",
        isSupported: false
    )

    /// All browsers iClaw knows about, in display order.
    public static let allKnown: [SupportedBrowser] = [safari, chrome, firefox, arc, brave, edge]
}

/// Monitors whether the selected browser is running using NSWorkspace notifications (event-driven, no polling).
@MainActor
@Observable
public final class BrowserMonitor {
    public static let shared = BrowserMonitor()

    /// The currently selected browser for integration.
    public var selectedBrowser: SupportedBrowser = .safari

    /// Whether the selected browser process is currently running.
    public private(set) var isBrowserRunning: Bool = false

    /// Browsers detected as installed on this machine.
    public private(set) var installedBrowsers: [SupportedBrowser] = []

    @ObservationIgnored private var launchObserver: Any?
    @ObservationIgnored private var terminateObserver: Any?

    private init() {
        detectInstalledBrowsers()
        isBrowserRunning = isAppRunning(bundleID: selectedBrowser.id)
        startObserving()
    }

    /// Returns the NSImage icon for a browser, or nil.
    public func icon(for browser: SupportedBrowser) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Call when the user picks a different browser.
    public func select(_ browser: SupportedBrowser) {
        selectedBrowser = browser
        isBrowserRunning = isAppRunning(bundleID: browser.id)
    }

    // MARK: - Private

    private func detectInstalledBrowsers() {
        installedBrowsers = SupportedBrowser.allKnown.filter { browser in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.id) != nil
        }
    }

    private func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter

        launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, bundleID == self.selectedBrowser.id else { return }
                self.isBrowserRunning = true
                if UserDefaults.standard.bool(forKey: AppConfig.browserBridgeEnabledKey) {
                    try? await BrowserBridge.shared.start()
                }
            }
        }

        terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, bundleID == self.selectedBrowser.id else { return }
                self.isBrowserRunning = false
                await BrowserBridge.shared.stop()
            }
        }
    }

    // No deinit needed — singleton lives for app lifetime.
}
#endif
