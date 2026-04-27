#if os(macOS)
import Foundation
import AppKit
import CoreLocation
import CoreWLAN
import IOKit.ps
import Darwin
import NaturalLanguage

public struct SystemInfoTool: CoreTool, Sendable {
    public let name = "SystemInfo"
    public let schema = "system info battery wifi network disk space storage apps installed memory RAM free CPU usage uptime version macos bluetooth thermal temperature slow"
    public let isInternal = false
    public let category = CategoryEnum.offline

    public init() {}

    // MARK: - Query-Aware Section Filtering

    /// Keyword sets that determine which sections to include.
    /// When the input matches a specific section, only that section (+ OS header) is returned.
    /// This prevents the LLM from confusing "Disk: 83.9 GB free" with "Memory: X GB available".
    private static let sectionKeywords: [(keywords: Set<String>, sections: [String])] = [
        (["battery", "charge", "charging", "power", "plugged"], ["battery"]),
        (["wifi", "wi-fi", "network", "internet", "connected", "ssid", "signal", "ip", "ip address"], ["wifi"]),
        (["bluetooth", "bt", "airpods", "paired"], ["bluetooth"]),
        (["disk", "storage", "space", "ssd", "drive", "hard drive"], ["disk"]),
        (["memory", "ram", "free memory", "swap", "pressure"], ["memory"]),
        (["cpu", "processor", "core", "cores", "load", "usage", "slow", "performance", "thermal", "hot", "overheating", "temperature"], ["cpu", "thermal"]),
        (["uptime", "restart", "reboot", "how long"], ["uptime"]),
        (["app", "apps", "installed", "application", "software"], ["apps"]),
    ]

    // MARK: - Embedding-Based Category Detection

    /// Seed phrases for each section — used for semantic matching when keywords miss.
    /// Each entry maps a descriptive phrase to the sections it should activate.
    private static let categorySeedPhrases: [(phrase: String, sections: [String])] = [
        // Battery
        ("battery level and charging status", ["battery"]),
        ("how much charge is left", ["battery"]),
        ("is my laptop plugged in", ["battery"]),
        ("power source and battery health", ["battery"]),
        // WiFi / Network
        ("wifi connection and signal strength", ["wifi"]),
        ("am I connected to the internet", ["wifi"]),
        ("what network am I on", ["wifi"]),
        ("what is my IP address", ["wifi"]),
        ("public IP and network info", ["wifi"]),
        // Bluetooth
        ("bluetooth devices and connections", ["bluetooth"]),
        ("paired accessories and headphones", ["bluetooth"]),
        // Disk
        ("disk space and storage usage", ["disk"]),
        ("how much room is left on my drive", ["disk"]),
        ("running out of storage", ["disk"]),
        // Memory
        ("memory usage and available RAM", ["memory"]),
        ("is my system running low on memory", ["memory"]),
        ("memory pressure and swap usage", ["memory"]),
        // CPU / Thermal
        ("CPU load and processor usage", ["cpu", "thermal"]),
        ("is my Mac overheating or running hot", ["cpu", "thermal"]),
        ("why is my computer slow and laggy", ["cpu", "thermal"]),
        ("system performance and fan noise", ["cpu", "thermal"]),
        ("thermal state and temperature", ["thermal"]),
        // Uptime
        ("how long since last restart", ["uptime"]),
        ("system uptime and reboot history", ["uptime"]),
        // Apps
        ("what apps are installed", ["apps"]),
        ("list of applications on this Mac", ["apps"]),
    ]

    /// Pre-computed embedding vectors for seed phrases. Lazily initialized on first use.
    private static let seedVectors: [(vector: [Double], sections: [String])] = {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return [] }
        return categorySeedPhrases.compactMap { entry in
            guard let vec = embedding.vector(for: entry.phrase) else { return nil }
            return (vector: vec, sections: entry.sections)
        }
    }()

    /// Minimum cosine similarity to accept an embedding match.
    private static let embeddingThreshold: Double = 0.65

    /// Multilingual keyword pre-filter loaded from
    /// `Resources/Config/SystemInfoCategoryPhrases.json`. Faster + more
    /// accurate cross-lingually than the embedding fallback below.
    private static let phraseKeywords: MultilingualKeywords? = MultilingualKeywords.load("SystemInfoCategoryPhrases")

    /// Multilingual keyword check against per-section seed phrases.
    /// Returns the matched section set, or empty when no category fires.
    private static func matchSectionsWithKeywords(_ input: String) -> Set<String> {
        guard let kw = phraseKeywords else { return [] }
        var hits: Set<String> = []
        for category in ["battery", "wifi", "bluetooth", "disk", "memory", "cpu_thermal", "uptime", "apps"] {
            if kw.matches(intent: category, in: input) {
                if category == "cpu_thermal" {
                    hits.insert("cpu"); hits.insert("thermal")
                } else {
                    hits.insert(category)
                }
            }
        }
        return hits
    }

    /// Uses sentence embeddings to find the best matching category for a query.
    /// Returns empty set if no category exceeds the similarity threshold.
    /// Falls back through multilingual keyword matching first.
    private static func matchSectionsWithEmbedding(_ input: String) -> Set<String> {
        let kwHits = matchSectionsWithKeywords(input)
        if !kwHits.isEmpty { return kwHits }

        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let embedding = LocalizedEmbedding.sentenceEmbeddingSync(for: input),
              let queryVec = embedding.vector(for: input),
              !seedVectors.isEmpty else {
            return []
        }

        // Score each seed phrase and take the best match
        var bestScore: Double = 0
        var bestSections: [String] = []

        for seed in seedVectors {
            let score = VectorMath.cosineSimilarity(queryVec, seed.vector)
            if score > bestScore {
                bestScore = score
                bestSections = seed.sections
            }
        }

        if bestScore >= embeddingThreshold {
            Log.tools.debug("SystemInfo embedding match: \(bestSections) (score: \(String(format: "%.3f", bestScore)))")
            return Set(bestSections)
        }
        return []
    }


    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            let lower = input.lowercased()
            let words = lower.wordTokenSet

            // Layer 1: Keyword matching (fast, deterministic)
            var requestedSections: Set<String> = []
            for (keywords, sections) in Self.sectionKeywords {
                let hasPhrase = keywords.contains(where: { lower.contains($0) })
                let hasWord = !words.isDisjoint(with: keywords)
                if hasPhrase || hasWord {
                    requestedSections.formUnion(sections)
                }
            }

            // Layer 2: Embedding fallback — catches semantic queries that keywords miss
            // e.g., "is my laptop overheating" → thermal, "why is everything laggy" → cpu
            if requestedSections.isEmpty {
                requestedSections = Self.matchSectionsWithEmbedding(input)
            }

            var sections: [String] = []
            sections.append(osInfo())

            // Only list app names when explicitly asked for a list
            let wantsAppList = lower.contains("list") || lower.contains("what app") || lower.contains("which app")

            if requestedSections.isEmpty {
                // Generic "system info" — return everything
                sections.append(batteryInfo())
                sections.append(await wifiInfo())
                sections.append(diskInfo())
                sections.append(memoryInfo())
                sections.append(cpuInfo())
                sections.append(thermalInfo())
                sections.append(uptimeInfo())
                sections.append(installedAppsInfo(listNames: false))
            } else {
                // Targeted — only return what was asked for
                if requestedSections.contains("battery") { sections.append(batteryInfo()) }
                if requestedSections.contains("wifi") { sections.append(await wifiInfo()) }
                if requestedSections.contains("bluetooth") { sections.append(bluetoothInfo()) }
                if requestedSections.contains("disk") { sections.append(diskInfo()) }
                if requestedSections.contains("memory") { sections.append(memoryInfo()) }
                if requestedSections.contains("cpu") { sections.append(cpuInfo()) }
                if requestedSections.contains("thermal") { sections.append(thermalInfo()) }
                if requestedSections.contains("uptime") { sections.append(uptimeInfo()) }
                if requestedSections.contains("apps") { sections.append(installedAppsInfo(listNames: wantsAppList)) }
            }

            let result = sections.joined(separator: "\n")
            return ToolIO(
                text: result,
                status: .ok,
                outputWidget: "SystemInfoWidget",
                isVerifiedData: true
            )
        }
    }

    // MARK: - Info Gatherers

    private func batteryInfo() -> String {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        guard let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] else {
            return "Battery: info unavailable"
        }

        let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? -1
        let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        let powerSource = desc[kIOPSPowerSourceStateKey as String] as? String ?? "Unknown"
        let timeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int
        let timeToFull = desc[kIOPSTimeToFullChargeKey as String] as? Int

        var parts = ["Battery: \(capacity)%"]
        if isCharging {
            parts.append("charging")
            if let ttf = timeToFull, ttf > 0 { parts.append("\(ttf) min to full") }
        } else if powerSource == kIOPSBatteryPowerValue as String {
            parts.append("on battery")
            if let tte = timeToEmpty, tte > 0 { parts.append("\(tte) min remaining") }
        } else {
            parts.append("on AC power")
        }

        return parts.joined(separator: ", ")
    }

    private func wifiInfo() async -> String {
        // CWWiFiClient.ssid() requires Location Services on macOS 15+.
        // All shell fallbacks (networksetup, system_profiler, ipconfig) also
        // return redacted data without location authorization. Requesting
        // location permission is the only reliable path.
        await ensureLocationAuthorization()

        if let iface = CWWiFiClient.shared().interface() {
            if let ssid = iface.ssid(), !ssid.isEmpty {
                let rssi = iface.rssiValue()
                let signalQuality: String
                switch rssi {
                case -50...0: signalQuality = "excellent"
                case -60..<(-50): signalQuality = "good"
                case -70..<(-60): signalQuality = "fair"
                default: signalQuality = "weak"
                }
                var wifiResult = "WiFi: \(ssid) (signal: \(signalQuality), \(rssi) dBm)"
                if let ip = Self.getLocalIPAddresses() {
                    wifiResult += ", IP: \(ip)"
                }
                return wifiResult
            }
            // Interface exists but SSID is nil — connected but location denied,
            // or not connected. Check power state.
            if iface.powerOn() {
                return "WiFi: on, but SSID unavailable (grant Location Services in System Settings > Privacy)"
            }
            return "WiFi: off"
        }

        return "WiFi: no WiFi interface found"
    }

    /// Ensures Location Services authorization has been requested.
    /// CWWiFiClient.ssid() returns nil without it on macOS 15+.
    private func ensureLocationAuthorization() async {
        // Skip if test override is set (avoids hanging on CLLocationManager in tests)
        if LocationManager.testLocationOverride != nil { return }

        let status = await MainActor.run { CLLocationManager().authorizationStatus }
        guard status == .notDetermined else { return }
        // Trigger LocationManager's permission flow (which handles LSUIElement apps).
        // We don't need the actual location — just the authorization side effect.
        _ = try? await LocationManager.shared.resolveCurrentLocation()
    }

    /// Returns the local IPv4 address(es) from en0/en1 interfaces.
    private static func getLocalIPAddresses() -> String? {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let sa = ptr.pointee.ifa_addr.pointee
            guard sa.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(sa.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let addr = hostname.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !addr.isEmpty { addresses.append(addr) }
        }
        return addresses.isEmpty ? nil : addresses.joined(separator: ", ")
    }

    private func bluetoothInfo() -> String {
        // Query IORegistry for the Bluetooth host controller power state.
        let matching = IOServiceMatching("IOBluetoothHostController")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)

        guard result == KERN_SUCCESS else {
            return "Bluetooth: unable to determine"
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            return "Bluetooth: not available"
        }
        defer { IOObjectRelease(service) }

        // "HCIControllerPowerIsOn" is a boolean property on the host controller.
        if let prop = IORegistryEntryCreateCFProperty(service, "HCIControllerPowerIsOn" as CFString, kCFAllocatorDefault, 0) {
            let isOn = (prop.takeRetainedValue() as? Bool) ?? false
            return "Bluetooth: \(isOn ? "on" : "off")"
        }

        return "Bluetooth: unable to determine"
    }

    private func diskInfo() -> String {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            let total = (attrs[.systemSize] as? Int64) ?? 0
            let free = (attrs[.systemFreeSize] as? Int64) ?? 0
            let used = total - free

            func formatBytes(_ bytes: Int64) -> String {
                let gb = Double(bytes) / 1_073_741_824
                return String(format: "%.1f GB", gb)
            }

            return "Disk: \(formatBytes(used)) used / \(formatBytes(total)) total (\(formatBytes(free)) free)"
        } catch {
            return "Disk: info unavailable"
        }
    }

    private func memoryInfo() -> String {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / 1_073_741_824

        // Get detailed memory breakdown via Mach host_statistics64.
        // Reports used (active + wired + compressed) vs available (free + inactive).
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return "Memory: \(String(format: "%.0f", totalGB)) GB RAM"
        }

        let pageSize = UInt64(getpagesize())
        let freeBytes = UInt64(stats.free_count) * pageSize
        let activeBytes = UInt64(stats.active_count) * pageSize
        let inactiveBytes = UInt64(stats.inactive_count) * pageSize
        let wiredBytes = UInt64(stats.wire_count) * pageSize
        let compressedBytes = UInt64(stats.compressor_page_count) * pageSize
        let swapUsedBytes = UInt64(stats.swapins + stats.swapouts) > 0
            ? (UInt64(stats.swapins) * pageSize)
            : 0

        // "Used" matches Activity Monitor: active + wired + compressed
        let usedBytes = activeBytes + wiredBytes + compressedBytes
        // "Available" = free + inactive (reclaimable by the system)
        let availableBytes = freeBytes + inactiveBytes

        let usedGB = Double(usedBytes) / 1_073_741_824
        let availableGB = Double(availableBytes) / 1_073_741_824

        var parts = ["Memory: \(String(format: "%.1f", usedGB)) GB used, \(String(format: "%.1f", availableGB)) GB available of \(String(format: "%.0f", totalGB)) GB"]

        // Memory pressure indicator
        let pressure = Double(usedBytes) / Double(totalBytes)
        if pressure > 0.9 {
            parts.append("⚠ High memory pressure")
        }

        // Swap indicates the system ran out of physical RAM
        if swapUsedBytes > 100_000_000 { // >100MB swap
            let swapGB = Double(swapUsedBytes) / 1_073_741_824
            parts.append("Swap: \(String(format: "%.1f", swapGB)) GB (memory pressure)")
        }

        return parts.joined(separator: ". ")
    }

    private func cpuInfo() -> String {
        let count = ProcessInfo.processInfo.processorCount
        let active = ProcessInfo.processInfo.activeProcessorCount

        // Chip name via sysctl
        var chipName = "Unknown"
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
            chipName = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        var parts = ["CPU: \(chipName), \(count) cores (\(active) active)"]

        // Load averages (1, 5, 15 min) — shows recent CPU pressure without needing
        // a sampling delay. >1.0 per core indicates the system is under load.
        var loadAvg = [Double](repeating: 0, count: 3)
        getloadavg(&loadAvg, 3)
        let load1 = String(format: "%.1f", loadAvg[0])
        let load5 = String(format: "%.1f", loadAvg[1])
        let load15 = String(format: "%.1f", loadAvg[2])
        parts.append("Load average: \(load1) (1m), \(load5) (5m), \(load15) (15m)")

        // CPU usage from cumulative ticks — gives overall user/system/idle split
        var numCPUs: natural_t = 0
        var cpuLoadInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuLoadInfo, &numCPUInfo)
        if err == KERN_SUCCESS, let info = cpuLoadInfo {
            var totalUser: Int64 = 0, totalSystem: Int64 = 0, totalIdle: Int64 = 0
            for i in 0..<Int(numCPUs) {
                let offset = Int(CPU_STATE_MAX) * i
                totalUser += Int64(info[offset + Int(CPU_STATE_USER)]) + Int64(info[offset + Int(CPU_STATE_NICE)])
                totalSystem += Int64(info[offset + Int(CPU_STATE_SYSTEM)])
                totalIdle += Int64(info[offset + Int(CPU_STATE_IDLE)])
            }
            let total = Double(totalUser + totalSystem + totalIdle)
            if total > 0 {
                let userPct = Double(totalUser) / total * 100
                let sysPct = Double(totalSystem) / total * 100
                let idlePct = Double(totalIdle) / total * 100
                parts.append("Usage: \(String(format: "%.0f", userPct + sysPct))% active (\(String(format: "%.0f", userPct))% user, \(String(format: "%.0f", sysPct))% system, \(String(format: "%.0f", idlePct))% idle)")
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        return parts.joined(separator: ". ")
    }

    /// Thermal state — useful for "my Mac is slow/hot" queries.
    private func thermalInfo() -> String {
        let state = ProcessInfo.processInfo.thermalState
        let stateStr: String
        switch state {
        case .nominal: stateStr = "nominal (cool)"
        case .fair: stateStr = "fair (warm, performance unaffected)"
        case .serious: stateStr = "serious (throttling to reduce heat)"
        case .critical: stateStr = "critical (significant throttling)"
        @unknown default: stateStr = "unknown"
        }
        return "Thermal state: \(stateStr)"
    }

    private func uptimeInfo() -> String {
        let uptime = ProcessInfo.processInfo.systemUptime
        let days = Int(uptime) / 86400
        let hours = (Int(uptime) % 86400) / 3600
        let minutes = (Int(uptime) % 3600) / 60

        if days > 0 {
            return "Uptime: \(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "Uptime: \(hours)h \(minutes)m"
        } else {
            return "Uptime: \(minutes)m"
        }
    }

    private func osInfo() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) — \(name)"
    }

    private func installedAppsInfo(listNames: Bool = true) -> String {
        // Use NSWorkspace.runningApplications — sandbox-safe, no filesystem access needed.
        // This shows currently running apps rather than scanning /Applications.
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()

        let unique = Array(Set(runningApps)).sorted()

        if unique.isEmpty {
            return "Running apps: none found"
        }

        if !listNames {
            return "Running apps: \(unique.count) total"
        }

        let displayed = unique.prefix(50)
        var result = "Running apps (\(unique.count)): \(displayed.joined(separator: ", "))"
        if unique.count > 50 {
            result += "... and \(unique.count - 50) more"
        }
        return result
    }
}
#endif
