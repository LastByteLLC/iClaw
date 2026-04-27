#if os(macOS)
import Foundation
import Network
import os

/// Actor managing communication with the browser extension via a local TCP socket.
/// Receives JSON-RPC requests from the native messaging host or Safari extension
/// and dispatches them to the connected browser extension.
///
/// Uses TCP on localhost instead of Unix domain sockets because NWListener's NECP
/// path evaluator rejects AF_UNIX in sandboxed apps. The listener binds to localhost:0
/// (OS-assigned port) and writes the port to a file in the App Group container so
/// the Safari extension and native messaging host can discover it.
public actor BrowserBridge {

    /// Well-known port for the BrowserBridge TLS listener.
    /// Safari extension and native host connect here directly — no App Group container
    /// or port file needed, which avoids the macOS "access data from other apps" dialog.
    public static let wellKnownPort: UInt16 = 19284

    /// Shared singleton instance.
    public static let shared = BrowserBridge()

    /// The TCP port the listener is bound to, or nil if not running.
    public private(set) var port: UInt16?

    /// Last browser context pushed by the extension (tab URL/title + optional full text).
    public private(set) var lastBrowserContext: BrowserContext?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var pendingRequests: [String: CheckedContinuation<BridgeResponse, Error>] = [:]

    // MARK: - Safari Pull Queue

    /// Connection mode detected from the first message on each connection.
    /// Chrome/Firefox send an `auth` handshake (persistent); Safari sends push events directly (one-shot).
    enum ConnectionMode: Sendable { case unknown, persistent, safariOneShot }

    /// Current connection mode, detected on first message.
    private var connectionMode: ConnectionMode = .unknown

    /// Queued pull requests waiting for Safari to pick up via piggyback or poll.
    private struct PendingPull {
        let id: String
        let method: String
        let params: [String: Any]
        let continuation: CheckedContinuation<BridgeResponse, Error>
    }
    private var pendingPullQueue: [PendingPull] = []

    /// Maximum number of queued pull requests for Safari.
    private static let maxPullQueueSize = 10

    private var isRunning = false
    private var listenerFailureCount = 0
    private var permanentlyDisabled = false
    private static let maxListenerRetries = 3

    /// Suppresses repeated log spam. Once start() succeeds (listener created),
    /// we don't retry on connection-level errors — only on listener state failures.
    private var startAttempted = false

    /// Tracks whether a browser extension has ever connected this session.
    /// Used to decide whether to keep the listener alive.
    private var hasEverConnected = false

    /// Time when the listener was started, used for idle shutdown.
    private var listenerStartTime: Date?

    /// Task handle for the idle shutdown timer, so it can be cancelled on stop().
    private var idleTimeoutTask: Task<Void, Never>?

    /// Set before cancelling the listener from idle shutdown, so the `.failed`
    /// state handler doesn't restart the listener we just intentionally stopped.
    private var isIdleShutdown = false

    /// If no connection arrives within this window, stop the listener.
    private static let idleListenerTimeout: TimeInterval = 300 // 5 minutes

    /// Last time any extension connection was received.
    /// Safari's one-shot model means connections open/close for each message,
    /// so we track recency instead of persistent connection state.
    private var lastConnectionTime: Date?

    /// Whether the bridge wants the extension to push full page content on next cycle.
    public var needsFullContent = false

    /// Notification posted when browser context changes (for UI updates).
    public static let contextUpdatedNotification = Notification.Name("BrowserContextUpdated")

    /// Shared nonce for authenticating local connections.
    /// Ephemeral — generated on start(), held in memory only.
    private var authNonce: String?

    /// Tracks whether a new connection has authenticated via nonce handshake.
    private var connectionAuthenticated = false

    /// Creates a BrowserBridge. Use `BrowserBridge.shared` for production.
    public init() {}

    /// Whether a browser extension has been heard from recently.
    /// Uses a 30-second window since Safari's one-shot model means connections
    /// don't persist — auto-push updates keep this alive.
    public var isConnected: Bool {
        guard let last = lastConnectionTime else { return false }
        return Date().timeIntervalSince(last) < 30
    }

    // MARK: - Lifecycle

    /// Start listening for connections on a localhost TLS port.
    /// Tries the well-known port first; falls back to a random OS-assigned port.
    public func start() throws {
        guard !isRunning, !permanentlyDisabled else { return }

        let params = BridgeTLS.serverParameters()

        // Try the well-known port first so clients can connect without discovery
        let wellKnownEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.wellKnownPort)!)
        params.requiredLocalEndpoint = wellKnownEndpoint

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            // Well-known port in use — fall back to random
            Log.bridge.debug("Well-known port \(Self.wellKnownPort) unavailable, using random port")
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: params)
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleListenerState(state)
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            Task { [weak self] in
                await self?.handleNewConnection(conn)
            }
        }

        let queue = DispatchQueue(label: "com.geticlaw.iClaw.bridge", qos: .utility)
        listener.start(queue: queue)
        self.listener = listener
        self.isRunning = true
        self.startAttempted = true
        self.listenerStartTime = Date()
        self.isIdleShutdown = false

        // Schedule idle shutdown
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(Self.idleListenerTimeout))
            guard !Task.isCancelled else { return }
            self.shutdownIfIdle()
        }
    }

    /// Called when the listener becomes ready — generates nonce and logs the port.
    private func onListenerReady() {
        guard let port else { return }
        self.authNonce = UUID().uuidString
        Log.bridge.debug("Bridge listener started on localhost:\(port) (TLS)")
    }

    /// Clear ephemeral state on shutdown.
    private func clearListenerState() {
        authNonce = nil
    }

    /// Stops the listener if no browser extension has connected.
    private func shutdownIfIdle() {
        guard isRunning, !hasEverConnected else { return }
        Log.bridge.debug("No browser extension connected after \(Self.idleListenerTimeout)s — stopping listener.")
        isIdleShutdown = true
        listener?.cancel()
        listener = nil
        port = nil
        isRunning = false
        clearListenerState()
    }

    /// Stop the bridge and clean up.
    public func stop() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        port = nil
        isRunning = false

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: BridgeError.disconnected)
        }
        pendingRequests.removeAll()

        // Cancel all queued Safari pull requests
        for pull in pendingPullQueue {
            pull.continuation.resume(throwing: BridgeError.disconnected)
        }
        pendingPullQueue.removeAll()
        connectionMode = .unknown

        clearListenerState()
    }

    // MARK: - Send requests to the browser

    /// Send a JSON-RPC request to the browser extension and await the response.
    /// For persistent connections (Chrome/Firefox), sends immediately on the wire.
    /// For Safari one-shot connections, enqueues for piggyback/poll delivery.
    public func request(method: String, params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> BridgeResponse {
        guard isConnected else {
            throw BridgeError.notConnected
        }

        let id = "\(Date().timeIntervalSince1970)-\(Int.random(in: 0...999999))"

        // Safari one-shot mode: enqueue for piggyback/poll delivery
        if connectionMode == .safariOneShot {
            guard pendingPullQueue.count < Self.maxPullQueueSize else {
                throw BridgeError.extensionError("Too many pending requests")
            }
            return try await withCheckedThrowingContinuation { continuation in
                pendingPullQueue.append(PendingPull(id: id, method: method, params: params, continuation: continuation))
                // Timeout
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    self.timeoutPullRequest(id: id)
                }
            }
        }

        // Persistent mode: send directly on wire
        guard let connection else {
            throw BridgeError.notConnected
        }

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id,
        ]

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[id] = continuation

            // Timeout
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = self.pendingRequests.removeValue(forKey: id) {
                    pending.resume(throwing: BridgeError.timeout)
                }
            }

            // Send
            do {
                let data = try JSONSerialization.data(withJSONObject: message)
                let framed = Self.frameMessage(data)
                connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                    if let error {
                        Task { [weak self] in
                            guard let self else { return }
                            if let pending = await self.removePendingRequest(forKey: id) {
                                pending.resume(throwing: error)
                            }
                        }
                    }
                })
            } catch {
                self.pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Remove a timed-out pull request from the Safari queue.
    private func timeoutPullRequest(id: String) {
        if let idx = pendingPullQueue.firstIndex(where: { $0.id == id }) {
            let entry = pendingPullQueue.remove(at: idx)
            entry.continuation.resume(throwing: BridgeError.timeout)
        }
    }

    /// Convenience: get page content from the active tab.
    public func getPageContent(tabId: Int? = nil) async throws -> BridgeResponse {
        var params: [String: Any] = [:]
        if let tabId { params["tabId"] = tabId }
        return try await request(method: "page.getContent", params: params)
    }

    /// Convenience: list all browser tabs.
    public func listTabs() async throws -> BridgeResponse {
        try await request(method: "tabs.list")
    }

    /// Convenience: query a CSS selector on the active tab.
    public func querySelector(_ selector: String, tabId: Int? = nil) async throws -> BridgeResponse {
        var params: [String: Any] = ["selector": selector]
        if let tabId { params["tabId"] = tabId }
        return try await request(method: "dom.querySelector", params: params)
    }

    // MARK: - Interactive Actions

    /// Get a compact accessibility-tree snapshot of interactive elements on the active tab.
    /// Returns element refs (@e0, @e1, ...) that can be targeted by click/fill actions.
    public func snapshot(tabId: Int? = nil) async throws -> BridgeResponse {
        var params: [String: Any] = [:]
        if let tabId { params["tabId"] = tabId }
        return try await request(method: "page.snapshot", params: params)
    }

    /// Click an element identified by an element ref (e.g., "@e3") or CSS selector.
    public func click(ref: String? = nil, selector: String? = nil, index: Int? = nil) async throws -> BridgeResponse {
        var params: [String: Any] = [:]
        if let ref { params["ref"] = ref }
        if let selector { params["selector"] = selector }
        if let index { params["index"] = index }
        return try await request(method: "dom.click", params: params)
    }

    /// Type text into an input/textarea identified by an element ref or CSS selector.
    public func fill(ref: String? = nil, selector: String? = nil, text: String, clear: Bool = true) async throws -> BridgeResponse {
        var params: [String: Any] = ["text": text, "clear": clear]
        if let ref { params["ref"] = ref }
        if let selector { params["selector"] = selector }
        return try await request(method: "dom.fill", params: params)
    }

    /// Scroll the page in the specified direction.
    public func scroll(direction: String = "down", amount: Int = 400, ref: String? = nil) async throws -> BridgeResponse {
        var params: [String: Any] = ["direction": direction, "amount": amount]
        if let ref { params["ref"] = ref }
        return try await request(method: "dom.scroll", params: params)
    }

    /// Submit a form, found by an element ref or CSS selector.
    public func submit(ref: String? = nil, selector: String? = nil) async throws -> BridgeResponse {
        var params: [String: Any] = [:]
        if let ref { params["ref"] = ref }
        if let selector { params["selector"] = selector }
        return try await request(method: "dom.submit", params: params)
    }

    /// Navigate the active tab to a URL.
    public func navigate(to url: String) async throws -> BridgeResponse {
        try await request(method: "page.navigate", params: ["url": url])
    }

    /// Actor-isolated helper for removing a pending request from a nonisolated context.
    private func removePendingRequest(forKey id: String) -> CheckedContinuation<BridgeResponse, Error>? {
        pendingRequests.removeValue(forKey: id)
    }

    // MARK: - Connection handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let listenerPort = listener?.port {
                self.port = listenerPort.rawValue
                onListenerReady()
            }
        case .failed(let error):
            listener?.cancel()
            listener = nil
            port = nil
            isRunning = false
            clearListenerState()

            guard !isIdleShutdown else {
                Log.bridge.debug("Listener stopped after idle shutdown.")
                return
            }

            listenerFailureCount += 1
            if listenerFailureCount <= Self.maxListenerRetries {
                let delay = UInt64(2) << UInt64(listenerFailureCount - 1)
                Log.bridge.debug("Listener failed (\(self.listenerFailureCount)/\(Self.maxListenerRetries)): \(error). Retrying in \(delay)s.")
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    try? self.start()
                }
            } else {
                Log.bridge.debug("Listener failed permanently after \(Self.maxListenerRetries) retries. Browser extension bridge disabled.")
                permanentlyDisabled = true
            }
        case .cancelled:
            isRunning = false
            clearListenerState()
        default:
            break
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        // For persistent connections, cancel previous and replace.
        // For Safari one-shot, each message is a new connection — don't reset mode.
        if connectionMode != .safariOneShot {
            self.connection?.cancel()
        }
        self.connection = conn
        self.connectionAuthenticated = false
        self.hasEverConnected = true
        self.lastConnectionTime = Date()

        conn.stateUpdateHandler = { [weak self] state in
            Task { [weak self] in
                await self?.handleConnectionState(state)
            }
        }

        conn.start(queue: .global(qos: .userInitiated))
        startReceiving(on: conn)
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            Log.bridge.debug("Extension connected")
        case .failed(let error):
            Log.bridge.debug("Connection failed: \(error)")
            connection = nil
        case .cancelled:
            connection = nil
        default:
            break
        }
    }

    // MARK: - Message framing (length-prefixed)

    /// Frame a message with a 4-byte little-endian length prefix.
    /// Same format as Chrome/Firefox native messaging.
    static func frameMessage(_ data: Data) -> Data {
        var length = UInt32(data.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(data)
        return framed
    }

    /// Read length-prefixed messages from a connection.
    private func startReceiving(on conn: NWConnection) {
        // Read 4-byte length header
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            guard let self, let content, content.count == 4 else {
                if isComplete || error != nil { return }
                Task { await self?.startReceiving(on: conn) }
                return
            }

            let length = content.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard length > 0, length < AppConfig.browserBridgeMaxMessageSize else {
                Task { await self.startReceiving(on: conn) }
                return
            }

            // Read message body
            conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] body, _, isComplete, error in
                guard let self else { return }
                if let body {
                    Task { await self.handleReceivedMessage(body) }
                }
                if !isComplete && error == nil {
                    Task { await self.startReceiving(on: conn) }
                }
            }
        }
    }

    private func handleReceivedMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Detect connection mode and handle authentication.
        // Chrome/Firefox send {"method":"auth"} as their first message (persistent port).
        // Safari sends push events directly without auth (one-shot per message).
        if !connectionAuthenticated {
            if let method = json["method"] as? String, method == "auth",
               let nonce = (json["params"] as? [String: Any])?["nonce"] as? String,
               nonce == authNonce {
                connectionAuthenticated = true
                connectionMode = .persistent
                Log.bridge.debug("Connection authenticated via nonce (persistent mode)")
                return
            }

            // Safari one-shot: no auth handshake — allow the message through.
            // Each Safari message arrives on a fresh TLS connection.
            if let method = json["method"] as? String, method != "auth" {
                connectionAuthenticated = true
                connectionMode = .safariOneShot
                Log.bridge.debug("Safari one-shot connection detected")
                // Fall through to process this message
            } else {
                Log.bridge.error("Connection rejected: invalid auth nonce")
                connection?.cancel()
                connection = nil
                connectionAuthenticated = false
                return
            }
        }

        // Response to a pending request (persistent pull flow)
        if let id = json["id"] as? String, let continuation = pendingRequests.removeValue(forKey: id) {
            let response = BridgeResponse(json: json)
            continuation.resume(returning: response)
            return
        }

        // Safari pull response — extension returning result of a queued request
        if let method = json["method"] as? String, method == "bridge.pullResponse" {
            let params = json["params"] as? [String: Any] ?? [:]
            handleSafariPullResponse(params: params)
            return
        }

        // Push event from browser extension (has "method" field)
        if let method = json["method"] as? String {
            let params = json["params"] as? [String: Any] ?? [:]
            let id = json["id"]
            handlePushEvent(method: method, params: params, requestID: id)
        }
    }

    /// Handle a pull response from Safari: match ID, resume continuation.
    private func handleSafariPullResponse(params: [String: Any]) {
        guard let id = params["id"] as? String else {
            Log.bridge.debug("Pull response missing id")
            return
        }

        guard let idx = pendingPullQueue.firstIndex(where: { $0.id == id }) else {
            // Already timed out or duplicate — ignore
            return
        }

        let entry = pendingPullQueue.remove(at: idx)

        if let error = params["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Extension error"
            entry.continuation.resume(throwing: BridgeError.extensionError(message))
        } else {
            let result = params["result"]
            let responseJSON: [String: Any] = result.map { ["result": $0] } ?? [:]
            entry.continuation.resume(returning: BridgeResponse(json: responseJSON))
        }

        // Acknowledge so SafariWebExtensionHandler doesn't hang
        sendPushResponse(requestID: nil)
    }

    private func handlePushEvent(method: String, params: [String: Any], requestID: Any?) {
        switch method {
        case "browser.contextUpdate":
            let url = params["url"] as? String ?? ""
            let title = params["title"] as? String ?? ""
            lastBrowserContext = BrowserContext(
                url: url,
                title: title,
                fullText: lastBrowserContext?.fullText, // Preserve existing full text
                timestamp: Date()
            )
            Log.bridge.debug("Context update: \(title) (\(url))")
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.contextUpdatedNotification, object: nil) }

        case "browser.pushContent":
            let url = params["url"] as? String ?? ""
            let title = params["title"] as? String ?? ""
            // Truncate pushed content to prevent excessive memory usage
            let rawText = params["text"] as? String
            let text = rawText.map { String($0.prefix(ContentCompactor.defaultLimit)) }
            let selectionOnly = params["selectionOnly"] as? Bool ?? false
            lastBrowserContext = BrowserContext(
                url: url,
                title: title,
                fullText: text,
                selectionOnly: selectionOnly,
                timestamp: Date()
            )
            needsFullContent = false
            Log.bridge.debug("Content pushed: \(title) (\(text?.count ?? 0) chars, selection=\(selectionOnly))")
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.contextUpdatedNotification, object: nil) }

        case "bridge.poll":
            Log.bridge.debug("Poll from Safari extension")
            // Handled by sendPushResponse which includes pending requests

        case "ping":
            Log.bridge.debug("Ping from extension")

        default:
            Log.bridge.debug("Unknown push method: \(method)")
        }

        // Send JSON-RPC success response so SafariWebExtensionHandler doesn't hang.
        // Includes piggybacked pending pull request if any are queued.
        sendPushResponse(requestID: requestID)
    }

    private func sendPushResponse(requestID: Any?) {
        guard let connection else { return }
        var result: [String: Any] = ["ok": true]
        if needsFullContent {
            result["requestContent"] = true
        }

        // Piggyback: include the next pending pull request for Safari to execute
        if let pending = pendingPullQueue.first {
            result["pendingRequest"] = [
                "jsonrpc": "2.0",
                "method": pending.method,
                "params": pending.params,
                "id": pending.id,
            ] as [String: Any]
            result["hasMorePending"] = pendingPullQueue.count > 1
        } else if connectionMode == .safariOneShot {
            result["idle"] = true
        }

        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = requestID {
            response["id"] = id
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        let framed = Self.frameMessage(data)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    /// Request the extension to push full page content on next cycle.
    public func requestFullContent() {
        needsFullContent = true
    }

    /// Clear all browser context (metadata + full text).
    public func clearBrowserContext() {
        lastBrowserContext = nil
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.contextUpdatedNotification, object: nil) }
    }

    /// Clear full text (called at end of turn). Metadata persists for follow-ups.
    public func clearFullText() {
        guard let ctx = lastBrowserContext else { return }
        lastBrowserContext = BrowserContext(
            url: ctx.url,
            title: ctx.title,
            fullText: nil,
            timestamp: ctx.timestamp
        )
    }
}

// MARK: - Types

/// Browser context pushed by the extension (tab metadata + optional page content).
public struct BrowserContext: Sendable {
    public let url: String
    public let title: String
    public let fullText: String?
    public let selectionOnly: Bool
    public let timestamp: Date

    public init(url: String, title: String, fullText: String? = nil, selectionOnly: Bool = false, timestamp: Date = Date()) {
        self.url = url
        self.title = title
        self.fullText = fullText
        self.selectionOnly = selectionOnly
        self.timestamp = timestamp
    }

    /// Whether this context has full page or selection text (not just metadata).
    public var hasContent: Bool { fullText != nil && !(fullText?.isEmpty ?? true) }
}

/// Response from the browser extension.
/// Stores the raw JSON data for flexible parsing while remaining Sendable.
public struct BridgeResponse: Sendable {
    /// Raw JSON data of the response.
    private let rawData: Data?
    /// Error message if the response is an error.
    public let errorMessage: String?

    init(data: Data?, errorMessage: String? = nil) {
        self.rawData = data
        self.errorMessage = errorMessage
    }

    init(json: [String: Any]) {
        if let error = json["error"] as? [String: Any] {
            self.errorMessage = error["message"] as? String ?? "Unknown error"
            self.rawData = nil
        } else if let result = json["result"] {
            self.rawData = try? JSONSerialization.data(withJSONObject: result)
            self.errorMessage = nil
        } else {
            self.rawData = nil
            self.errorMessage = nil
        }
    }

    public var isError: Bool { errorMessage != nil }

    /// Parse the result as a JSON dictionary.
    public var resultDict: [String: Any]? {
        guard let rawData else { return nil }
        return try? JSONSerialization.jsonObject(with: rawData) as? [String: Any]
    }

    /// Extract the text field from a page content result.
    public var text: String? { resultDict?["text"] as? String }

    /// Extract the title field from a page content result.
    public var title: String? { resultDict?["title"] as? String }
}

// BridgeError is defined in iClawCore/BridgeError.swift
#endif
