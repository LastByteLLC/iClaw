#if os(iOS)
import Foundation
import UIKit

public struct SystemInfoToolIOS: CoreTool, Sendable {
    public let name = "SystemInfo"
    public let schema = "system info battery wifi network disk space storage memory CPU uptime version ios"
    public let isInternal = false
    public let category = CategoryEnum.offline

    public init() {}

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        try await timed {
            var sections: [String] = []

            sections.append(deviceInfo())
            sections.append(batteryInfo())
            sections.append(diskInfo())
            sections.append(memoryInfo())
            sections.append(cpuInfo())
            sections.append(uptimeInfo())

            let result = sections.joined(separator: "\n")
            return ToolIO(
                text: result,
                status: .ok,
                outputWidget: "SystemInfoWidget"
            )
        }
    }

    @MainActor
    private func deviceInfo() -> String {
        let device = UIDevice.current
        return "\(device.systemName) \(device.systemVersion) — \(device.name) (\(device.model))"
    }

    @MainActor
    private func batteryInfo() -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        guard level >= 0 else { return "Battery: info unavailable" }

        let percent = Int(level * 100)
        let state: String
        switch device.batteryState {
        case .charging: state = "charging"
        case .full: state = "full"
        case .unplugged: state = "on battery"
        default: state = "unknown"
        }
        return "Battery: \(percent)%, \(state)"
    }

    private func diskInfo() -> String {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
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
        return "Memory: \(String(format: "%.0f", totalGB)) GB RAM"
    }

    private func cpuInfo() -> String {
        let count = ProcessInfo.processInfo.processorCount
        let active = ProcessInfo.processInfo.activeProcessorCount

        var chipName = "Unknown"
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
            chipName = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        return "CPU: \(chipName), \(count) cores (\(active) active)"
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
}
#endif
