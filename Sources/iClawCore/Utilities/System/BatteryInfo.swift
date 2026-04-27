#if canImport(IOKit)
import Foundation
import IOKit.ps

/// Centralized battery information via IOKit.
/// Replaces duplicated IOPSCopyPowerSourcesInfo patterns across tools.
public enum BatteryInfo: Sendable {
    public struct Status: Sendable {
        /// Battery charge level (0-100), or -1 if unavailable.
        public let capacity: Int
        /// Whether the battery is currently charging.
        public let isCharging: Bool
        /// Power source state string (e.g. "Battery Power", "AC Power").
        public let powerSourceState: String
        /// Estimated minutes until empty, if discharging. Nil or ≤0 if unavailable.
        public let timeToEmpty: Int?
        /// Estimated minutes until full, if charging. Nil or ≤0 if unavailable.
        public let timeToFull: Int?
    }

    /// Returns current battery status, or nil if no battery (desktop Mac).
    public static func current() -> Status? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return nil
        }

        let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? -1
        let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        let powerSourceState = desc[kIOPSPowerSourceStateKey as String] as? String ?? "Unknown"
        let timeToEmpty = desc[kIOPSTimeToEmptyKey as String] as? Int
        let timeToFull = desc[kIOPSTimeToFullChargeKey as String] as? Int

        return Status(
            capacity: capacity,
            isCharging: isCharging,
            powerSourceState: powerSourceState,
            timeToEmpty: timeToEmpty,
            timeToFull: timeToFull
        )
    }
}
#endif
