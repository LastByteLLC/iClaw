#if os(macOS)
import Foundation
import AppKit
import CoreWLAN
import IOKit.ps

/// Interactive tech support tool for macOS. Performs system actions using native Swift APIs.
/// Used within the Tech Support mode for interactive diagnostics and fixes.
public struct TechSupportTool: CoreTool, Sendable {
    public let name = "TechSupport"
    public let schema = "tech support troubleshoot fix kill app force quit wifi bluetooth battery drain process slow mac help diagnose speed test internet bandwidth"
    public let isInternal = false
    public let category = CategoryEnum.offline
    public var consentPolicy: ActionConsentPolicy {
        .requiresConsent(description: "Perform a system action")
    }

    private let session: URLSession

    /// Verbs used to extract the target app name from a force-quit query.
    /// Loaded from `Resources/Config/ForceQuitKeywords.json` per the project
    /// convention of keeping keyword lists out of Swift source.
    static let forceQuitKeywords: [String] = ConfigLoader.loadStringArray("ForceQuitKeywords")

    public init(session: URLSession = .iClawDefault) {
        self.session = session
    }

    private typealias Handler = @Sendable (String) async -> ToolIO

    /// Dispatch table for keyword-based routing. Order matters — earlier entries take priority.
    /// Each entry maps a set of keywords to a handler that produces a `ToolIO` result.
    private var dispatchTable: [(keywords: [String], handler: Handler)] {
        [
            (["speed test", "internet speed", "download speed", "bandwidth"], { _ in
                await self.handleSpeedTest()
            }),
            (["kill", "force quit", "quit app"], { input in
                let result = await self.handleForceQuit(input: input)
                return ToolIO(text: result, status: .ok, isVerifiedData: true)
            }),
            (["wifi", "wi-fi", "network"], { _ in
                ToolIO(text: self.handleWiFiInfo(), status: .ok, isVerifiedData: true)
            }),
            (["bluetooth"], { _ in
                ToolIO(text: self.handleBluetoothInfo(), status: .ok, isVerifiedData: true)
            }),
            (["battery", "power", "drain"], { _ in
                let result = await self.handleBatteryDiagnostics()
                return ToolIO(text: result, status: .ok, isVerifiedData: true)
            }),
            (["running app", "running process", "what's running", "active app"], { _ in
                ToolIO(text: self.handleRunningApps(), status: .ok, isVerifiedData: true)
            }),
            (["disk", "storage", "space"], { _ in
                ToolIO(text: self.handleStorageInfo(), status: .ok, isVerifiedData: true)
            }),
            (["memory", "ram"], { _ in
                ToolIO(text: self.handleMemoryPressure(), status: .ok, isVerifiedData: true)
            }),
            (["login item", "startup", "launch at login"], { _ in
                ToolIO(text: self.handleLoginItems(), status: .ok, isVerifiedData: true)
            }),
            (["clear cache", "clear dns", "flush"], { _ in
                ToolIO(text: self.handleCacheClear(), status: .ok, isVerifiedData: true)
            }),
        ]
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let lowered = input.lowercased()

            for entry in dispatchTable {
                if entry.keywords.contains(where: { lowered.contains($0) }) {
                    return await entry.handler(lowered)
                }
            }

            // No keyword matched — run general diagnostics
            return ToolIO(
                text: handleQuickDiagnostics(),
                status: .ok,
                isVerifiedData: true
            )
        }
    }

    // MARK: - Speed Test

    private func handleSpeedTest() async -> ToolIO {
        // WiFi info
        let wifiClient = CWWiFiClient.shared().interface()
        let ssid = wifiClient?.ssid()
        let rssi = wifiClient?.rssiValue() ?? -100
        let signalQuality: String
        switch rssi {
        case -50...0: signalQuality = "Excellent"
        case -60 ... -51: signalQuality = "Good"
        case -70 ... -61: signalQuality = "Fair"
        default: signalQuality = "Weak"
        }

        let channelStr: String?
        if let ch = wifiClient?.wlanChannel() {
            channelStr = "\(ch.channelNumber) (\(ch.channelBand == .band5GHz ? "5 GHz" : "2.4 GHz"))"
        } else {
            channelStr = nil
        }

        let isConnected = ssid != nil

        // Tier 1: Latency (HEAD to Apple test URL)
        var latencyMs: Int?
        if isConnected {
            let latencyURL = URL(string: "https://www.apple.com/library/test/success.html")!
            var request = URLRequest(url: latencyURL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 10
            let pingStart = Date()
            if let _ = try? await session.data(for: request) {
                latencyMs = Int(Date().timeIntervalSince(pingStart) * 1000)
            }
        }

        // Tier 2: Download speed (~2MB from Apple CDN)
        var downloadMbps: Double?
        if isConnected {
            let downloadURL = URL(string: AppConfig.speedTestURL)!
            var request = URLRequest(url: downloadURL)
            request.timeoutInterval = 15
            let dlStart = Date()
            if let (data, _) = try? await session.data(for: request), data.count < 2_000_000 {
                let elapsed = Date().timeIntervalSince(dlStart)
                if elapsed > 0 {
                    let bits = Double(data.count) * 8
                    downloadMbps = (bits / elapsed) / 1_000_000
                }
            }
        }

        // Build widget data
        let widgetData = SpeedTestWidgetData(
            downloadMbps: downloadMbps,
            latencyMs: latencyMs,
            signalStrength: rssi,
            signalQuality: signalQuality,
            ssid: ssid,
            channel: channelStr,
            isConnected: isConnected
        )

        // Build text summary
        var lines = ["Wi-Fi Speed Test:"]
        if let ssid { lines.append("Network: \(ssid)") }
        lines.append("Signal: \(rssi) dBm (\(signalQuality))")
        if let latency = latencyMs { lines.append("Latency: \(latency) ms") }
        if let mbps = downloadMbps {
            lines.append("Download: \(String(format: "%.1f", mbps)) Mbps")
        } else if isConnected {
            lines.append("Download: Could not measure")
        } else {
            lines.append("Not connected to Wi-Fi")
        }

        return ToolIO(
            text: lines.joined(separator: "\n"),
            status: .ok,
            outputWidget: "SpeedTestWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    // MARK: - Force Quit

    private func handleForceQuit(input: String) async -> String {
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        // Try to extract app name from input
        let keywords = Self.forceQuitKeywords
        var targetName = input
        for kw in keywords {
            targetName = targetName.replacingOccurrences(of: kw, with: "")
        }
        targetName = targetName.trimmingCharacters(in: .whitespacesAndNewlines)

        if targetName.isEmpty {
            // List running apps
            let appList = runningApps.compactMap { $0.localizedName }.sorted().joined(separator: ", ")
            return "Running apps: \(appList)\n\nWhich app would you like to force quit?"
        }

        // Find matching app
        let matches = runningApps.filter {
            $0.localizedName?.lowercased().contains(targetName) == true
        }

        if matches.isEmpty {
            let appList = runningApps.compactMap { $0.localizedName }.sorted().joined(separator: ", ")
            return "No running app matches '\(targetName)'.\n\nRunning apps: \(appList)"
        }

        if let app = matches.first {
            let name = app.localizedName ?? "Unknown"
            let terminated = app.forceTerminate()
            if terminated {
                return "Force quit \(name) successfully."
            } else {
                return "Failed to force quit \(name). The app may be unresponsive to termination signals."
            }
        }

        return "Could not force quit the requested app."
    }

    // MARK: - WiFi

    private func handleWiFiInfo() -> String {
        guard let wifiClient = CWWiFiClient.shared().interface() else {
            return "No Wi-Fi interface found."
        }

        var lines: [String] = ["Wi-Fi Diagnostics:"]

        if let ssid = wifiClient.ssid() {
            lines.append("Connected to: \(ssid)")
        } else {
            lines.append("Not connected to any Wi-Fi network.")
        }

        let rssi = wifiClient.rssiValue()
        let quality: String
        switch rssi {
        case -50...0: quality = "Excellent"
        case -60 ... -51: quality = "Good"
        case -70 ... -61: quality = "Fair"
        default: quality = "Weak"
        }
        lines.append("Signal: \(rssi) dBm (\(quality))")

        if let channel = wifiClient.wlanChannel() {
            lines.append("Channel: \(channel.channelNumber) (\(channel.channelBand == .band5GHz ? "5 GHz" : "2.4 GHz"))")
        }

        // Scan for available networks
        if let networks = try? wifiClient.scanForNetworks(withSSID: nil) {
            let available = networks
                .compactMap { $0.ssid }
                .filter { !$0.isEmpty }
            let unique = Array(Set(available)).sorted().prefix(15)
            if !unique.isEmpty {
                lines.append("\nAvailable networks (\(unique.count)):")
                for ssid in unique {
                    lines.append("  - \(ssid)")
                }
            }
        }

        lines.append("\nTo connect to a different network, open System Settings > Wi-Fi.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Bluetooth

    private func handleBluetoothInfo() -> String {
        // Use IOBluetooth via IORegistry to get connected device info
        var lines: [String] = ["Bluetooth Devices:"]

        // Query IORegistry for Bluetooth controller
        let matching = IOServiceMatching("IOBluetoothDevice")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)

        if result == KERN_SUCCESS {
            var deviceCount = 0
            var service = IOIteratorNext(iterator)
            while service != 0 {
                deviceCount += 1
                if IORegistryEntryCreateCFProperty(service, "Name" as CFString, kCFAllocatorDefault, 0) != nil {
                    let props = IORegistryEntryCreateCFProperty(service, "Name" as CFString, kCFAllocatorDefault, 0)
                    if let name = props?.takeRetainedValue() as? String {
                        lines.append("  - \(name)")
                    }
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)

            if deviceCount == 0 {
                lines.append("No Bluetooth devices found in IORegistry.")
            }
        } else {
            lines.append("Could not query Bluetooth devices.")
        }

        lines.append("\nTo manage Bluetooth devices, open System Settings > Bluetooth.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Battery Diagnostics

    private func handleBatteryDiagnostics() async -> String {
        var lines: [String] = ["Battery & Energy Diagnostics:"]

        // Battery info via centralized BatteryInfo utility
        if let battery = BatteryInfo.current() {
            lines.append("Battery: \(battery.capacity)%")
            if battery.isCharging {
                lines.append("Charging: Yes")
                if let ttf = battery.timeToFull, ttf > 0 {
                    lines.append("Time to full: \(ttf / 60)h \(ttf % 60)m")
                }
            } else {
                lines.append("Charging: No")
                if let tte = battery.timeToEmpty, tte > 0 {
                    lines.append("Time remaining: \(tte / 60)h \(tte % 60)m")
                }
            }
        }

        // Per-app CPU usage — the real energy consumers
        let topApps = await Self.topCPUApps()
        if !topApps.isEmpty {
            lines.append("\nTop energy consumers:")
            for (name, cpu) in topApps {
                lines.append("  - \(name): \(String(format: "%.1f", cpu))% CPU")
            }
        } else {
            // Fallback: just list running app names
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated }
                .compactMap { $0.localizedName }
            if !apps.isEmpty {
                lines.append("\nRunning apps (\(apps.count)): \(apps.joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Queries per-app CPU % via `ps` and matches against visible applications.
    /// Returns up to 5 apps sorted by CPU usage, excluding idle (0%) apps.
    private static func topCPUApps() async -> [(name: String, cpu: Double)] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app -> (String, pid_t)? in
                guard let name = app.localizedName else { return nil }
                return (name, app.processIdentifier)
            }

        guard !apps.isEmpty else { return [] }

        let pids = apps.map { String($0.1) }.joined(separator: ",")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pids, "-o", "pid=,%cpu="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var cpuByPID: [pid_t: Double] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]) else { continue }
            cpuByPID[pid] = cpu
        }

        return apps
            .compactMap { (name, pid) -> (String, Double)? in
                guard let cpu = cpuByPID[pid], cpu > 0.0 else { return nil }
                return (name, cpu)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { $0 }
    }

    // MARK: - Running Apps

    private func handleRunningApps() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()

        var lines = ["Running Apps (\(apps.count)):"]
        for app in apps {
            lines.append("  - \(app)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Storage

    private func handleStorageInfo() -> String {
        var lines: [String] = ["Storage:"]

        let fileManager = FileManager.default
        if let attrs = try? fileManager.attributesOfFileSystem(forPath: "/"),
           let totalBytes = attrs[.systemSize] as? Int64,
           let freeBytes = attrs[.systemFreeSize] as? Int64 {
            let totalGB = Double(totalBytes) / 1_073_741_824
            let freeGB = Double(freeBytes) / 1_073_741_824
            let usedGB = totalGB - freeGB
            lines.append("Total: \(String(format: "%.1f", totalGB)) GB")
            lines.append("Used: \(String(format: "%.1f", usedGB)) GB")
            lines.append("Free: \(String(format: "%.1f", freeGB)) GB")

            let usagePercent = (usedGB / totalGB) * 100
            if usagePercent > 90 {
                lines.append("\nWarning: Disk is over 90% full. Consider freeing space.")
            }
        }

        // Check common space hogs — Downloads requires entitlement, Caches is sandbox-safe
        let fm = FileManager.default
        let checkDirs: [(String, URL?)] = [
            ("Downloads", fm.urls(for: .downloadsDirectory, in: .userDomainMask).first),
            ("Caches", fm.urls(for: .cachesDirectory, in: .userDomainMask).first),
        ]

        lines.append("\nQuick checks:")
        for (label, url) in checkDirs {
            guard let url else { continue }
            if let size = Self.directorySize(url) {
                let mb = Double(size) / 1_048_576
                if mb > 100 {
                    lines.append("  ~\(label): \(String(format: "%.0f", mb)) MB")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func directorySize(_ url: URL) -> Int64? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var total: Int64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 500 { break } // Don't scan too deep
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Memory Pressure

    private func handleMemoryPressure() -> String {
        var lines: [String] = ["Memory:"]

        let totalRAM = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalRAM) / 1_073_741_824
        lines.append("Total RAM: \(String(format: "%.0f", totalGB)) GB")

        // Running app count as a proxy for memory pressure
        let appCount = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .count
        lines.append("Running apps: \(appCount)")

        if appCount > 15 {
            lines.append("\nYou have a lot of apps open. Consider closing unused ones to free memory.")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Login Items

    private func handleLoginItems() -> String {
        var lines: [String] = ["Login Items:"]
        lines.append("To manage login items, go to System Settings > General > Login Items.")
        lines.append("Items that launch at login can slow down startup and consume resources.")
        lines.append("\nLaunch Agents and Daemons can also run at login. These are in:")
        lines.append("  ~/Library/LaunchAgents/")
        lines.append("  /Library/LaunchAgents/")

        lines.append("\nTo list your LaunchAgents, run in Terminal:")
        lines.append("  ls ~/Library/LaunchAgents/")

        return lines.joined(separator: "\n")
    }

    // MARK: - Cache Clear

    private func handleCacheClear() -> String {
        // We don't actually delete anything — just report and advise
        var lines: [String] = ["Cache Information:"]

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cachesDir, let size = Self.directorySize(cachesDir) {
            let mb = Double(size) / 1_048_576
            lines.append("User caches: ~\(String(format: "%.0f", mb)) MB")
        }

        lines.append("\nTo clear caches safely:")
        lines.append("1. Quit apps that may be using cached data")
        lines.append("2. Delete contents of ~/Library/Caches/ (keep the folder)")
        lines.append("3. Restart your Mac")
        lines.append("\nNote: Apps will rebuild their caches as needed. This is safe but some apps may be slower on first launch.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Quick Diagnostics

    private func handleQuickDiagnostics() -> String {
        var lines: [String] = ["Quick System Diagnostics:"]

        // OS
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        lines.append("macOS: \(osVersion)")

        // Uptime
        let uptime = ProcessInfo.processInfo.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        lines.append("Uptime: \(days)d \(hours)h")

        // Battery
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [Any],
           let source = sources.first,
           let desc = IOPSGetPowerSourceDescription(snapshot, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
           let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
            lines.append("Battery: \(capacity)%")
        }

        // Disk
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let freeBytes = attrs[.systemFreeSize] as? Int64 {
            let freeGB = Double(freeBytes) / 1_073_741_824
            lines.append("Free disk: \(String(format: "%.1f", freeGB)) GB")
        }

        // Running apps
        let appCount = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .count
        lines.append("Running apps: \(appCount)")

        // WiFi
        if let wifiClient = CWWiFiClient.shared().interface(),
           let ssid = wifiClient.ssid() {
            lines.append("Wi-Fi: \(ssid) (\(wifiClient.rssiValue()) dBm)")
        }

        lines.append("\nAsk about specific areas: wifi, bluetooth, battery, storage, running apps, login items, or memory.")

        return lines.joined(separator: "\n")
    }
}
#endif
