import Foundation
import Network
import os

/// Lightweight network reachability monitor using `NWPathMonitor`.
///
/// Used by `ExecutionEngine` to pre-flight check before executing tools that
/// require network access (`.online` category). Avoids wasting time on
/// multi-retry HTTP failures and provides immediate, clear feedback.
///
/// Starts monitoring on first access of `shared` and runs for the app lifetime.
public final class NetworkMonitor: Sendable {
    public static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.geticlaw.iClaw.networkMonitor", qos: .utility)

    /// Current network status. Updated asynchronously by `NWPathMonitor`.
    /// Thread-safe via OSAllocatedUnfairLock.
    private let _isSatisfied = OSAllocatedUnfairLock<Bool>(initialState: true)

    /// Whether the device currently has a viable network path.
    /// Returns `true` if the network is reachable (Wi-Fi, cellular, etc.).
    /// Defaults to `true` until the first path update arrives — this avoids
    /// false-positive offline blocking on cold start.
    public var isConnected: Bool { _isSatisfied.withLock { $0 } }

    private init() {
        monitor = NWPathMonitor()
        let satisfied = _isSatisfied
        monitor.pathUpdateHandler = { path in
            satisfied.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }
}
