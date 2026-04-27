import XCTest
import Replay
@testable import iClawCore

/// URLProtocol that returns a configurable HTTP status and captures request details.
private class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode: Int = 201
    nonisolated(unsafe) static var responseBody: Data = Data("{\"ok\":true}".utf8)
    nonisolated(unsafe) static var capturedURL: URL?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedHeaders: [String: String]?
    nonisolated(unsafe) static var wasCalled: Bool = false

    static func reset() {
        capturedURL = nil
        capturedMethod = nil
        capturedBody = nil
        capturedHeaders = nil
        wasCalled = false
    }

    override class func canInit(with request: URLRequest) -> Bool {
        capturedURL = request.url
        capturedMethod = request.httpMethod
        capturedHeaders = request.allHTTPHeaderFields
        // httpBody is nil in URLProtocol — read from httpBodyStream
        if let body = request.httpBody {
            capturedBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 65536)
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            stream.close()
            capturedBody = data
        }
        wasCalled = true
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeStubSession(status: Int = 201, body: String = "{\"ok\":true}") -> URLSession {
    StubURLProtocol.statusCode = status
    StubURLProtocol.responseBody = Data(body.utf8)
    StubURLProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

/// URLProtocol that always fails with a network error.
private class NetworkErrorURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

private func makeNetworkErrorSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NetworkErrorURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - FeedbackSender Tests

final class FeedbackSenderTests: XCTestCase {

    func testSendSuccess() async {
        let session = makeStubSession(status: 201)
        let sender = FeedbackSender(session: session)
        let result = await sender.send(summary: "Love the app!", feedbackID: "test-1")
        XCTAssertTrue(result)

        XCTAssertEqual(StubURLProtocol.capturedMethod, "POST")
        XCTAssertTrue(StubURLProtocol.capturedURL?.absoluteString.contains("/api/feedback") ?? false)
        XCTAssertEqual(StubURLProtocol.capturedHeaders?["Content-Type"], "application/json")

        guard let body = StubURLProtocol.capturedBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            XCTFail("Could not parse request body")
            return
        }
        XCTAssertEqual(json["message"], "Love the app!")
        XCTAssertEqual(json["category"], "general")
        XCTAssertNotNil(json["app_version"])
    }

    func testSendServerError() async {
        let session = makeStubSession(status: 500, body: "{\"error\":\"Internal server error\"}")
        let sender = FeedbackSender(session: session)
        let result = await sender.send(summary: "Bug report", feedbackID: "test-2")
        XCTAssertFalse(result)
    }

    func testSendBadRequest() async {
        let session = makeStubSession(status: 400, body: "{\"error\":\"message is required\"}")
        let sender = FeedbackSender(session: session)
        let result = await sender.send(summary: "Test", feedbackID: "test-3")
        XCTAssertFalse(result)
    }

    func testSendNetworkError() async {
        let session = makeNetworkErrorSession()
        let sender = FeedbackSender(session: session)
        let result = await sender.send(summary: "Offline test", feedbackID: "test-4")
        XCTAssertFalse(result)
    }

    func testSendEmptySummary() async {
        let session = makeStubSession()
        let sender = FeedbackSender(session: session)
        let result = await sender.send(summary: "", feedbackID: "test-5")
        XCTAssertFalse(result)
        XCTAssertFalse(StubURLProtocol.wasCalled, "Empty summary should not make a network request")
    }

    func testSendTruncatesLongMessage() async {
        let session = makeStubSession()
        let sender = FeedbackSender(session: session)
        let longMessage = String(repeating: "x", count: 10000)
        let result = await sender.send(summary: longMessage, feedbackID: "test-6")
        XCTAssertTrue(result)

        guard let body = StubURLProtocol.capturedBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            XCTFail("Could not parse request body")
            return
        }
        XCTAssertEqual(json["message"]?.count, 5000)
    }

    // MARK: - Replay HAR Tests

    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    private func harURL(_ name: String) -> URL {
        Self.fixturesDir.appendingPathComponent("\(name).har")
    }

    func testSendWithReplaySuccess() async throws {
        let config = PlaybackConfiguration(
            source: .file(harURL("feedback_submit")),
            playbackMode: .strict,
            recordMode: .none,
            matchers: [.method, .host, .path]
        )
        let session = try await Playback.session(configuration: config)
        let sender = FeedbackSender(session: session)
        let result = await sender.send(summary: "Test feedback", feedbackID: "replay-1")
        XCTAssertTrue(result)
    }
}

// MARK: - CrashLogSender Tests

final class CrashLogSenderTests: XCTestCase {

    func testSendSuccess() async {
        let session = makeStubSession(status: 201)
        let sender = CrashLogSender(session: session)
        await sender.send(report: "Fatal error: test crash")

        XCTAssertTrue(StubURLProtocol.wasCalled)
        XCTAssertEqual(StubURLProtocol.capturedMethod, "POST")
        XCTAssertTrue(StubURLProtocol.capturedURL?.absoluteString.contains("/api/crash-logs") ?? false)

        guard let body = StubURLProtocol.capturedBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            XCTFail("Could not parse request body")
            return
        }
        XCTAssertEqual(json["report"], "Fatal error: test crash")
        XCTAssertNotNil(json["app_version"])
        XCTAssertNotNil(json["os_version"])
        XCTAssertNotNil(json["device"])
    }

    func testSendServerError() async {
        let session = makeStubSession(status: 500)
        let sender = CrashLogSender(session: session)
        await sender.send(report: "Test crash report")
        // Should not crash — fire-and-forget
        XCTAssertTrue(StubURLProtocol.wasCalled)
    }

    func testSendNetworkError() async {
        let session = makeNetworkErrorSession()
        let sender = CrashLogSender(session: session)
        await sender.send(report: "Test crash report")
        // Should not crash — fire-and-forget
    }

    func testSendEmptyReport() async {
        let session = makeStubSession()
        let sender = CrashLogSender(session: session)
        await sender.send(report: "")
        XCTAssertFalse(StubURLProtocol.wasCalled, "Empty report should not make a network request")
    }

    func testSendTruncatesLongReport() async {
        let session = makeStubSession()
        let sender = CrashLogSender(session: session)
        let longReport = String(repeating: "x", count: 100000)
        await sender.send(report: longReport)

        guard let body = StubURLProtocol.capturedBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            XCTFail("Could not parse request body")
            return
        }
        XCTAssertEqual(json["report"]?.count, 50000)
    }

    // MARK: - Replay HAR Tests

    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    private func harURL(_ name: String) -> URL {
        Self.fixturesDir.appendingPathComponent("\(name).har")
    }

    func testSendWithReplaySuccess() async throws {
        let config = PlaybackConfiguration(
            source: .file(harURL("crashlog_submit")),
            playbackMode: .strict,
            recordMode: .none,
            matchers: [.method, .host, .path]
        )
        let session = try await Playback.session(configuration: config)
        let sender = CrashLogSender(session: session)
        await sender.send(report: "Fatal error: Index out of range")
        // No assertion needed — fire-and-forget. Test confirms no crash.
    }
}
