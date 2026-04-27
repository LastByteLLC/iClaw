import XCTest
import Network
@testable import iClawCore

final class BrowserBridgeTests: XCTestCase {

    /// Each test gets its own BrowserBridge instance.
    private var bridge: BrowserBridge!

    override func invokeTest() {
        guard TestCapabilities.isAvailable(.auditTests) else { return }
        super.invokeTest()
    }

    override func setUp() async throws {
        bridge = BrowserBridge()
    }

    override func tearDown() async throws {
        await bridge.stop()
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - Lifecycle

    func testStartCreatesPortFile() async throws {
        try await bridge.start()
        // Wait for listener to become ready and write port file
        try await Task.sleep(for: .milliseconds(500))
        let port = await bridge.port
        XCTAssertNotNil(port, "Bridge should have an assigned port after start")
    }

    func testStopClearsPort() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))
        await bridge.stop()
        let port = await bridge.port
        XCTAssertNil(port)
    }

    func testDoubleStartIsIdempotent() async throws {
        try await bridge.start()
        try await bridge.start()
    }

    func testDoubleStopIsIdempotent() async throws {
        try await bridge.start()
        await bridge.stop()
        await bridge.stop()
    }

    // MARK: - Connection State

    func testIsConnectedFalseWhenNoExtension() async throws {
        try await bridge.start()
        let connected = await bridge.isConnected
        XCTAssertFalse(connected)
    }

    func testRequestThrowsWhenNotConnected() async throws {
        try await bridge.start()

        do {
            _ = try await bridge.request(method: "page.getContent", timeout: 1)
            XCTFail("Expected BridgeError.notConnected")
        } catch let error as BridgeError {
            if case .notConnected = error {} else {
                XCTFail("Expected .notConnected, got \(error)")
            }
        }
    }

    // MARK: - Mock Client Tests

    func testAcceptsClientAndSendsJSONRPC() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        let connected = await bridge.isConnected
        XCTAssertTrue(connected, "Bridge should detect the mock client connection")

        let receivedExpectation = expectation(description: "Received message")
        nonisolated(unsafe) var receivedData: Data?

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                receivedData = body
                receivedExpectation.fulfill()
            }
        }

        let b = bridge!
        Task {
            _ = try? await b.request(method: "tabs.list", timeout: 3)
        }

        await fulfillment(of: [receivedExpectation], timeout: 5)

        let json = try XCTUnwrap(receivedData)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(parsed["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(parsed["method"] as? String, "tabs.list")
        XCTAssertNotNil(parsed["id"])
    }

    func testRequestTimeoutWhenNoResponse() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        do {
            _ = try await bridge.request(method: "page.getContent", timeout: 1)
            XCTFail("Expected BridgeError.timeout")
        } catch let error as BridgeError {
            if case .timeout = error {} else {
                XCTFail("Expected .timeout, got \(error)")
            }
        }
    }

    func testMockClientCanSendResponse() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        setupMockResponder(connection: connection) { id in
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["tabs": [["id": 1, "title": "Test Tab", "url": "https://example.com"]]]
            ]
        }

        let result = try await bridge.request(method: "tabs.list", timeout: 5)
        let tabs = result.resultDict?["tabs"] as? [[String: Any]]
        XCTAssertEqual(tabs?.count, 1)
        XCTAssertEqual(tabs?.first?["title"] as? String, "Test Tab")
    }

    func testMockClientErrorResponse() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        setupMockResponder(connection: connection) { id in
            return [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32001, "message": "Tab not found"]
            ]
        }

        let result = try await bridge.request(method: "tabs.list", timeout: 5)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.errorMessage, "Tab not found")
    }

    // MARK: - BridgeResponse Unit Tests

    func testBridgeResponseParsesText() {
        let json: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "test",
            "result": ["text": "Hello World", "title": "Test Page"]
        ]
        let response = BridgeResponse(json: json)

        XCTAssertFalse(response.isError)
        XCTAssertEqual(response.text, "Hello World")
        XCTAssertEqual(response.title, "Test Page")
    }

    func testBridgeResponseParsesError() {
        let json: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "test",
            "error": ["code": -32600, "message": "Bad request"]
        ]
        let response = BridgeResponse(json: json)

        XCTAssertTrue(response.isError)
        XCTAssertEqual(response.errorMessage, "Bad request")
        XCTAssertNil(response.text)
    }

    func testBridgeResponseEmptyResult() {
        let json: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "test",
        ]
        let response = BridgeResponse(json: json)

        XCTAssertFalse(response.isError)
        XCTAssertNil(response.resultDict)
    }

    // MARK: - BridgeFetchBackend

    func testBridgeFetchBackendThrowsWhenNotConnected() async throws {
        try await bridge.start()

        let backend = BrowserBridgeFetchBackend(bridge: bridge)
        do {
            _ = try await backend.fetch(url: URL(string: "https://example.com")!)
            XCTFail("Expected BridgeError")
        } catch is BridgeError {
            // Expected
        }
    }

    // MARK: - Push Event Tests

    func testPushEventStoresContext() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        // Send a browser.pushContent push event
        let push: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "browser.pushContent",
            "params": ["url": "https://example.com", "title": "Example Page", "text": "Hello from browser"],
            "id": "push-1",
        ]
        let pushData = try JSONSerialization.data(withJSONObject: push)
        let framed = framePush(pushData)
        connection.send(content: framed, completion: .contentProcessed { _ in })

        // Wait for bridge to process
        try await Task.sleep(for: .milliseconds(500))

        let ctx = await bridge.lastBrowserContext
        XCTAssertNotNil(ctx, "Push event should store BrowserContext")
        XCTAssertEqual(ctx?.url, "https://example.com")
        XCTAssertEqual(ctx?.title, "Example Page")
        XCTAssertEqual(ctx?.fullText, "Hello from browser")
    }

    func testPushEventSendsResponse() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        let push: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "browser.contextUpdate",
            "params": ["url": "https://test.com", "title": "Test"],
            "id": "ctx-1",
        ]
        let pushData = try JSONSerialization.data(withJSONObject: push)
        let framed = framePush(pushData)

        let responseExpectation = expectation(description: "Received push response")
        nonisolated(unsafe) var responseBody: Data?

        // Read the response
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                responseBody = body
                responseExpectation.fulfill()
            }
        }

        connection.send(content: framed, completion: .contentProcessed { _ in })

        await fulfillment(of: [responseExpectation], timeout: 5)

        let json = try XCTUnwrap(responseBody)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNotNil(parsed["result"], "Bridge should send a success response to push events")
    }

    func testContextUpdatePreservesFullText() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        // First push content
        let push1: [String: Any] = [
            "jsonrpc": "2.0", "method": "browser.pushContent",
            "params": ["url": "https://a.com", "title": "A", "text": "Full page text"],
            "id": "p1",
        ]
        connection.send(content: framePush(try JSONSerialization.data(withJSONObject: push1)), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(300))

        // Then context update (should preserve full text)
        let push2: [String: Any] = [
            "jsonrpc": "2.0", "method": "browser.contextUpdate",
            "params": ["url": "https://a.com", "title": "A Updated"],
            "id": "p2",
        ]
        connection.send(content: framePush(try JSONSerialization.data(withJSONObject: push2)), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(300))

        let ctx = await bridge.lastBrowserContext
        XCTAssertEqual(ctx?.title, "A Updated")
        XCTAssertEqual(ctx?.fullText, "Full page text", "contextUpdate should preserve existing fullText")
    }

    func testClearFullText() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        let push: [String: Any] = [
            "jsonrpc": "2.0", "method": "browser.pushContent",
            "params": ["url": "https://x.com", "title": "X", "text": "Some content"],
            "id": "p1",
        ]
        connection.send(content: framePush(try JSONSerialization.data(withJSONObject: push)), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(300))

        await bridge.clearFullText()

        let ctx = await bridge.lastBrowserContext
        XCTAssertEqual(ctx?.url, "https://x.com", "Metadata should persist")
        XCTAssertNil(ctx?.fullText, "Full text should be cleared")
    }

    // MARK: - Safari Pull Flow Tests

    func testSafariPullRequestEnqueues() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        // Establish Safari one-shot connection mode by sending a push event
        let connection = try await connectMockClient()
        defer { connection.cancel() }

        let push: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "browser.contextUpdate",
            "params": ["url": "https://test.com", "title": "Test"],
            "id": "ctx-1",
        ]
        connection.send(content: framePush(try JSONSerialization.data(withJSONObject: push)), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(500))

        // Now request in Safari mode — should enqueue, not send on wire
        let b = bridge!
        let requestTask = Task {
            try await b.request(method: "page.getContent", timeout: 2)
        }

        // Give time for enqueue
        try await Task.sleep(for: .milliseconds(200))

        // The request should still be pending (not resolved yet since no poll/piggyback)
        XCTAssertFalse(requestTask.isCancelled)

        // It should timeout since nobody is polling
        do {
            _ = try await requestTask.value
            XCTFail("Expected timeout")
        } catch let error as BridgeError {
            if case .timeout = error {} else {
                XCTFail("Expected .timeout, got \(error)")
            }
        }
    }

    func testSafariPullPiggybackIncludesRequest() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        let connection = try await connectMockClient()
        defer { connection.cancel() }

        // Establish Safari mode with initial push
        let push1: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "browser.contextUpdate",
            "params": ["url": "https://a.com", "title": "A"],
            "id": "ctx-1",
        ]
        connection.send(content: framePush(try JSONSerialization.data(withJSONObject: push1)), completion: .contentProcessed { _ in })
        // Drain the response
        try await Task.sleep(for: .milliseconds(500))

        // Enqueue a pull request
        let b = bridge!
        Task {
            _ = try? await b.request(method: "page.getContent", timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(200))

        // Send another push — the response should piggyback the pending request
        let connection2 = try await connectMockClient()
        defer { connection2.cancel() }

        let push2: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "bridge.poll",
            "params": [:],
            "id": "poll-1",
        ]

        let responseExpectation = expectation(description: "Got piggybacked response")
        nonisolated(unsafe) var piggybackResponse: [String: Any]?

        connection2.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            connection2.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    piggybackResponse = json
                }
                responseExpectation.fulfill()
            }
        }

        connection2.send(content: framePush(try JSONSerialization.data(withJSONObject: push2)), completion: .contentProcessed { _ in })
        await fulfillment(of: [responseExpectation], timeout: 5)

        let result = piggybackResponse?["result"] as? [String: Any]
        XCTAssertNotNil(result?["pendingRequest"], "Push response should include piggybacked pending request")
        let pendingReq = result?["pendingRequest"] as? [String: Any]
        XCTAssertEqual(pendingReq?["method"] as? String, "page.getContent")
    }

    func testSafariPullResponseResumesContinuation() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        // Establish Safari mode
        let connection = try await connectMockClient()
        defer { connection.cancel() }

        let push: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "browser.contextUpdate",
            "params": ["url": "https://b.com", "title": "B"],
            "id": "ctx-1",
        ]
        connection.send(content: framePush(try JSONSerialization.data(withJSONObject: push)), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(500))

        // Enqueue a pull request
        let b = bridge!
        let requestTask = Task {
            try await b.request(method: "page.getContent", timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(200))

        // Poll to discover the pending request
        let pollConn = try await connectMockClient()
        defer { pollConn.cancel() }

        let pollMsg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "bridge.poll",
            "params": [:],
            "id": "poll-1",
        ]

        let pollExpectation = expectation(description: "Got poll response")
        nonisolated(unsafe) var pendingId: String?

        pollConn.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            pollConn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let result = json["result"] as? [String: Any],
                   let req = result["pendingRequest"] as? [String: Any] {
                    pendingId = req["id"] as? String
                }
                pollExpectation.fulfill()
            }
        }

        pollConn.send(content: framePush(try JSONSerialization.data(withJSONObject: pollMsg)), completion: .contentProcessed { _ in })
        await fulfillment(of: [pollExpectation], timeout: 5)

        let requestId = try XCTUnwrap(pendingId)

        // Send the pull response with result
        let responseConn = try await connectMockClient()
        defer { responseConn.cancel() }

        let pullResponse: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "bridge.pullResponse",
            "params": ["id": requestId, "result": ["text": "Page content here", "title": "Test Page"]],
            "id": "pull-resp-1",
        ]
        responseConn.send(content: framePush(try JSONSerialization.data(withJSONObject: pullResponse)), completion: .contentProcessed { _ in })

        // The original request should now resolve
        let result = try await requestTask.value
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.text, "Page content here")
        XCTAssertEqual(result.title, "Test Page")
    }

    func testSafariPullQueueOverflowRejects() async throws {
        try await bridge.start()
        try await Task.sleep(for: .milliseconds(500))

        // Establish Safari mode
        let connection = try await connectMockClient()
        defer { connection.cancel() }

        let push: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "browser.contextUpdate",
            "params": ["url": "https://c.com", "title": "C"],
            "id": "ctx-1",
        ]
        connection.send(content: framePush(try JSONSerialization.data(withJSONObject: push)), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(500))

        // Fill the queue with 10 requests
        let b = bridge!
        for i in 0..<10 {
            Task { _ = try? await b.request(method: "page.getContent.\(i)", timeout: 30) }
        }
        try await Task.sleep(for: .milliseconds(300))

        // 11th request should fail immediately
        do {
            _ = try await bridge.request(method: "page.overflow", timeout: 1)
            XCTFail("Expected error for queue overflow")
        } catch let error as BridgeError {
            if case .extensionError(let msg) = error {
                XCTAssertTrue(msg.contains("pending"), "Error should mention pending requests")
            } else {
                XCTFail("Expected .extensionError, got \(error)")
            }
        }
    }

    /// Helper: frame data with 4-byte length prefix.
    private func framePush(_ data: Data) -> Data {
        var length = UInt32(data.count).littleEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(data)
        return framed
    }

    // MARK: - Helpers

    private func connectMockClient() async throws -> NWConnection {
        let port = try await waitForPort()
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)

        let connectedExpectation = expectation(description: "Client connected")
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connectedExpectation.fulfill()
            }
        }
        connection.start(queue: .global())

        await fulfillment(of: [connectedExpectation], timeout: 5)
        try await Task.sleep(for: .milliseconds(300))

        return connection
    }

    /// Wait for the bridge to have a port assigned.
    private func waitForPort() async throws -> UInt16 {
        for _ in 0..<20 {
            if let port = await bridge.port { return port }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BridgeError.notConnected
    }

    private func setupMockResponder(connection: NWConnection, responseBuilder: @escaping @Sendable (Any) -> [String: Any]) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else { return }
            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, _ in
                guard let body,
                      let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let id = request["id"] else { return }

                let response = responseBuilder(id)
                guard let responseData = try? JSONSerialization.data(withJSONObject: response) else { return }
                var responseLength = UInt32(responseData.count).littleEndian
                var framed = Data(bytes: &responseLength, count: 4)
                framed.append(responseData)

                connection.send(content: framed, completion: .contentProcessed { _ in })
            }
        }
    }
}
