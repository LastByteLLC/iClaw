import Foundation
import os
import FoundationModels
@testable import iClawCore

// MARK: - Stub URLSession (no-network)

/// URLProtocol that returns HTTP 200 with empty data for all requests.
/// Use to prevent real network calls in unit tests while keeping tools functional.
class NoNetworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Creates a URLSession that returns 200/empty for all requests (no network).
func makeStubURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NoNetworkURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - SpyTool

/// Recorded invocation from a SpyTool.
struct SpyInvocation: Sendable {
    let input: String
    let entities: ExtractedEntities?
}

/// A test double that records invocations for assertion.
final class SpyTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum

    private let _invocations = OSAllocatedUnfairLock(initialState: [SpyInvocation]())
    private let stubbedResult: ToolIO

    var invocations: [SpyInvocation] {
        _invocations.withLock { $0 }
    }

    init(
        name: String,
        schema: String,
        category: CategoryEnum = .offline,
        result: ToolIO = ToolIO(text: "spy result", status: .ok)
    ) {
        self.name = name
        self.schema = schema
        self.category = category
        self.stubbedResult = result
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        _invocations.withLock { $0.append(SpyInvocation(input: input, entities: entities)) }
        return stubbedResult
    }
}

// MARK: - ErrorThenSuccessSpyTool

/// Returns `.error` on the first call and `.ok` on subsequent calls.
/// Tracks invocation count for healing loop assertions.
final class ErrorThenSuccessSpyTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum

    private let _invocations = OSAllocatedUnfairLock(initialState: [SpyInvocation]())
    private let errorResult: ToolIO
    private let successResult: ToolIO

    var invocations: [SpyInvocation] {
        _invocations.withLock { $0 }
    }

    init(
        name: String,
        schema: String,
        category: CategoryEnum = .offline,
        errorResult: ToolIO = ToolIO(text: "something went wrong", status: .error),
        successResult: ToolIO = ToolIO(text: "healed result", status: .ok)
    ) {
        self.name = name
        self.schema = schema
        self.category = category
        self.errorResult = errorResult
        self.successResult = successResult
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let count = _invocations.withLock { invocations in
            invocations.append(SpyInvocation(input: input, entities: entities))
            return invocations.count
        }
        return count == 1 ? errorResult : successResult
    }
}

// MARK: - AlwaysErrorSpyTool

/// Always returns `.error` status. Tracks invocations for healing loop assertions.
final class AlwaysErrorSpyTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum

    private let _invocations = OSAllocatedUnfairLock(initialState: [SpyInvocation]())
    private let errorResult: ToolIO

    var invocations: [SpyInvocation] {
        _invocations.withLock { $0 }
    }

    init(
        name: String,
        schema: String,
        category: CategoryEnum = .offline,
        errorResult: ToolIO = ToolIO(text: "permanent failure", status: .error)
    ) {
        self.name = name
        self.schema = schema
        self.category = category
        self.errorResult = errorResult
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        _invocations.withLock { $0.append(SpyInvocation(input: input, entities: entities)) }
        return errorResult
    }
}

// MARK: - ThrowThenSuccessSpyTool

/// Throws on the first call, returns `.ok` on subsequent calls.
/// For testing healing of thrown errors (vs returned `.error` status).
final class ThrowThenSuccessSpyTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum

    private let _invocations = OSAllocatedUnfairLock(initialState: [SpyInvocation]())
    private let successResult: ToolIO

    var invocations: [SpyInvocation] {
        _invocations.withLock { $0 }
    }

    struct ToolError: Error, LocalizedError {
        let errorDescription: String?
    }

    init(
        name: String,
        schema: String,
        category: CategoryEnum = .offline,
        successResult: ToolIO = ToolIO(text: "healed after throw", status: .ok)
    ) {
        self.name = name
        self.schema = schema
        self.category = category
        self.successResult = successResult
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let count = _invocations.withLock { invocations in
            invocations.append(SpyInvocation(input: input, entities: entities))
            return invocations.count
        }
        if count == 1 {
            throw ToolError(errorDescription: "\(name) threw on first attempt")
        }
        return successResult
    }
}

// MARK: - NthCallSpyTool

/// Returns a different result for each call based on index.
/// Useful for testing multi-iteration ReAct scenarios.
final class NthCallSpyTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum

    private let _invocations = OSAllocatedUnfairLock(initialState: [SpyInvocation]())
    private let results: [ToolIO]
    private let fallbackResult: ToolIO

    var invocations: [SpyInvocation] {
        _invocations.withLock { $0 }
    }

    init(
        name: String,
        schema: String,
        category: CategoryEnum = .offline,
        results: [ToolIO],
        fallback: ToolIO = ToolIO(text: "fallback", status: .ok)
    ) {
        self.name = name
        self.schema = schema
        self.category = category
        self.results = results
        self.fallbackResult = fallback
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        let idx = _invocations.withLock { invocations in
            invocations.append(SpyInvocation(input: input, entities: entities))
            return invocations.count - 1
        }
        return idx < results.count ? results[idx] : fallbackResult
    }
}

// MARK: - Thread-Safe Counter

/// Thread-safe integer counter for use in @Sendable closures.
final class AtomicCounter: @unchecked Sendable {
    private let _value = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { _value.withLock { $0 } }

    @discardableResult
    func increment() -> Int {
        _value.withLock { val in
            val += 1
            return val
        }
    }
}

/// Thread-safe array collector for use in @Sendable closures.
final class AtomicArray<T: Sendable>: @unchecked Sendable {
    private let _value = OSAllocatedUnfairLock(initialState: [T]())

    var value: [T] { _value.withLock { $0 } }

    func append(_ element: T) {
        _value.withLock { $0.append(element) }
    }
}

// MARK: - FailingTool

/// A tool that always throws, for error-path testing.
final class FailingTool: CoreTool, @unchecked Sendable {
    let name: String
    let schema: String
    let isInternal: Bool = false
    let category: CategoryEnum = .offline

    struct ToolError: Error, LocalizedError {
        let errorDescription: String?
    }

    init(name: String, schema: String) {
        self.name = name
        self.schema = schema
    }

    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        throw ToolError(errorDescription: "\(name) intentionally failed")
    }
}

// MARK: - Thread-Safe Prompt Capture

/// Thread-safe container for capturing prompt strings in @Sendable closures.
final class CapturedPrompt: @unchecked Sendable {
    private let _value = OSAllocatedUnfairLock(initialState: "")

    var value: String {
        _value.withLock { $0 }
    }

    func set(_ newValue: String) {
        _value.withLock { $0 = newValue }
    }

    /// First-write-wins: captures the first non-empty prompt seen, ignoring
    /// subsequent overwrites from recovery-ladder escalation. Tests that
    /// inspect the finalization prompt want the TOP-tier prompt, which comes
    /// first. If the top tier's response looks like a refusal, the ladder
    /// re-invokes the responder with a recovery prompt — without this guard
    /// that second prompt clobbers the capture and brain/req assertions fail.
    func setIfEmpty(_ newValue: String) {
        _value.withLock { if $0.isEmpty { $0 = newValue } }
    }
}

// MARK: - Stub LLM Responders

/// Returns a canned response and optionally captures the prompt into a CapturedPrompt box.
func makeStubLLMResponder(
    response: String = "stub response",
    capture: CapturedPrompt? = nil,
    captureFirstOnly: Bool = false
) -> LLMResponder {
    return { prompt, _ in
        if captureFirstOnly {
            capture?.setIfEmpty(prompt)
        } else {
            capture?.set(prompt)
        }
        return response
    }
}

/// Thread-safe container for capturing the tools passed to the LLM responder.
/// Used to verify FM tool attachment without relying on prompt-text markers
/// (which the LLM echoes back, leaking tool internals into user-facing text).
final class CapturedTools: @unchecked Sendable {
    private let _tools = OSAllocatedUnfairLock(initialState: [any Tool]())
    var value: [any Tool] { _tools.withLock { $0 } }
    func set(_ tools: [any Tool]) { _tools.withLock { $0 = tools } }
    func contains(toolNamed name: String) -> Bool {
        value.contains { $0.name == name }
    }
}

/// Canned-response LLM responder that captures both the prompt and the tools.
func makeToolCapturingLLMResponder(
    response: String = "stub response",
    capture: CapturedPrompt? = nil,
    toolCapture: CapturedTools? = nil
) -> LLMResponder {
    return { prompt, tools in
        capture?.set(prompt)
        toolCapture?.set(tools)
        return response
    }
}

/// Returns a fixed tool name for the router's LLM fallback stage.
func makeStubRouterLLMResponder(toolName: String = "none") -> RouterLLMResponder {
    return { _, _ in
        return toolName
    }
}

// MARK: - Test Engine Factory

/// Creates an ExecutionEngine wired with injectable LLM closures and custom tools.
/// Defaults router LLM to "none" to prevent hitting real Foundation Models.
func makeTestEngine(
    tools: [any CoreTool],
    fmTools: [any FMToolDescriptor] = [],
    routerLLMResponder: RouterLLMResponder? = makeStubRouterLLMResponder(),
    engineLLMResponder: LLMResponder? = makeStubLLMResponder(),
    widgetLLMResponder: LLMResponder? = nil
) -> ExecutionEngine {
    TestLocationSetup.install()
    let router = ToolRouter(
        availableTools: tools,
        fmTools: fmTools,
        llmResponder: routerLLMResponder
    )
    // Create a test LLMAdapter so WidgetLayoutGenerator (and other internal
    // LLM callers) don't hit the real Foundation Model. Uses a dedicated
    // widgetLLMResponder if provided; otherwise returns a simple stub.
    // Must NOT forward to engineLLMResponder by default, because that would
    // overwrite prompt captures used by tests that inspect the finalization prompt.
    let widgetResponder = widgetLLMResponder
    let testAdapter = LLMAdapter(testResponder: { prompt, _ in
        if let r = widgetResponder {
            return try await r(prompt, [])
        }
        return "stub response"
    })
    return ExecutionEngine(
        preprocessor: InputPreprocessor(),
        router: router,
        conversationManager: ConversationManager(),
        finalizer: OutputFinalizer(),
        llmAdapter: testAdapter,
        llmResponder: engineLLMResponder
    )
}

/// Variant that loads built-in skills before returning the engine, for skill routing E2E tests.
@MainActor
func makeTestEngineWithSkills(
    tools: [any CoreTool],
    fmTools: [any FMToolDescriptor] = [],
    routerLLMResponder: RouterLLMResponder? = makeStubRouterLLMResponder(),
    engineLLMResponder: LLMResponder? = makeStubLLMResponder()
) async -> ExecutionEngine {
    _ = await SkillLoader.shared.awaitActiveSkills()

    let router = ToolRouter(
        availableTools: tools,
        fmTools: fmTools,
        llmResponder: routerLLMResponder
    )
    let testAdapter = LLMAdapter(testResponder: { _, _ in "stub response" })
    return ExecutionEngine(
        preprocessor: InputPreprocessor(),
        router: router,
        conversationManager: ConversationManager(),
        finalizer: OutputFinalizer(),
        llmAdapter: testAdapter,
        llmResponder: engineLLMResponder
    )
}
