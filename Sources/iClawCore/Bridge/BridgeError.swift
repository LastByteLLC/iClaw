import Foundation

/// Errors from the browser bridge.
public enum BridgeError: Error, LocalizedError {
    case notConnected
    case disconnected
    case timeout
    case extensionError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Browser extension is not connected"
        case .disconnected: "Browser extension disconnected"
        case .timeout: "Browser bridge request timed out"
        case .extensionError(let msg): "Browser extension error: \(msg)"
        }
    }
}
