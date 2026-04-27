#if os(macOS)
import Foundation

/// Fetch backend that routes through the browser extension via BrowserBridge.
/// Gets real browser cookies, login sessions, and JS-rendered content.
public struct BrowserBridgeFetchBackend: FetchBackend {

    private let bridge: BrowserBridge

    public init(bridge: BrowserBridge = .shared) {
        self.bridge = bridge
    }

    /// Whether the browser bridge is currently connected.
    public var isConnected: Bool {
        get async { await bridge.isConnected }
    }

    public func fetch(url: URL) async throws -> FetchResult {
        let bridge = self.bridge

        guard await bridge.isConnected else {
            throw BridgeError.notConnected
        }

        // Navigate to the URL and extract content
        let response = try await bridge.request(
            method: "page.navigate",
            params: ["url": url.absoluteString, "wait": true]
        )

        if response.isError {
            throw BridgeError.extensionError(response.errorMessage ?? "Unknown error")
        }

        let text = response.text ?? ""
        let title = response.title ?? ""

        return FetchResult(
            text: text,
            title: title.isEmpty ? nil : title,
            statusCode: 200
        )
    }
}
#endif
