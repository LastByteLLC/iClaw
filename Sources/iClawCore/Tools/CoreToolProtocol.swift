import Foundation
import FoundationModels

/// Represents the status of a tool execution.
public enum StatusEnum: String, Codable, Sendable {
    case ok
    case error
    case pending
    case partial
}

/// Represents the execution category of a tool.
public enum CategoryEnum: String, Codable, Sendable {
    case online
    case async
    case offline
}

/// Consent policy for tool actions. Determines whether the engine must
/// prompt the user for confirmation before executing.
///
/// Tools default to `.safe`. Actions that create, modify, or send data
/// (e.g., composing emails, deleting files) should declare `.requiresConsent`
/// or `.destructive`. A user setting (`autoApproveActions`) can bypass the
/// consent UI, but `.destructive` actions always require confirmation.
public enum ActionConsentPolicy: Sendable {
    /// No confirmation needed — read-only or low-risk actions.
    case safe
    /// Requires user confirmation before execution (e.g., send email, create event).
    /// Bypassed when `autoApproveActions` is enabled.
    case requiresConsent(description: String)
    /// Always requires confirmation, even with `autoApproveActions` enabled
    /// (e.g., delete file, remove contact).
    case destructive(description: String)

    /// Whether this action needs confirmation (ignoring user settings).
    public var needsConsent: Bool {
        switch self {
        case .safe: return false
        case .requiresConsent, .destructive: return true
        }
    }

    /// Whether this action always requires confirmation regardless of settings.
    public var isDestructive: Bool {
        switch self {
        case .destructive: return true
        default: return false
        }
    }

    /// Human-readable description of the action for the confirmation UI.
    public var actionDescription: String? {
        switch self {
        case .safe: return nil
        case .requiresConsent(let desc), .destructive(let desc): return desc
        }
    }
}

/// A standardized output object for tool execution.
public struct ToolIO: Sendable {
    public let text: String
    public let attachments: [URL]
    public let status: StatusEnum
    public let timeTaken: TimeInterval
    public let outputWidget: String?
    public let widgetData: (any Sendable)?
    /// When `true`, the text contains live data fetched from an authoritative source
    /// (API, system call, etc.) and must not be altered or replaced by the LLM.
    public let isVerifiedData: Bool
    /// When `true`, the engine emits `text` to the user verbatim, bypassing
    /// the LLM finalizer. Use for tools whose output is already fully
    /// user-ready (exact math results, conversion tables, direct lookups) —
    /// the finalizer would only risk paraphrase drift here.
    public let emitDirectly: Bool
    /// Follow-up suggestions injected by the tool, bypassing LLM rephrasing.
    /// Propagated to `Message.suggestedQueries` and rendered as tappable pills.
    public let suggestedQueries: [String]?

    public init(
        text: String,
        attachments: [URL] = [],
        status: StatusEnum = .ok,
        timeTaken: TimeInterval = 0.0,
        outputWidget: String? = nil,
        widgetData: (any Sendable)? = nil,
        isVerifiedData: Bool = false,
        emitDirectly: Bool = false,
        suggestedQueries: [String]? = nil
    ) {
        self.text = text
        self.attachments = attachments
        self.status = status
        self.timeTaken = timeTaken
        self.outputWidget = outputWidget
        self.widgetData = widgetData
        self.isVerifiedData = isVerifiedData
        self.emitDirectly = emitDirectly
        self.suggestedQueries = suggestedQueries
    }

    /// Returns a copy with `timeTaken` replaced by the given interval.
    public func withTimeTaken(_ interval: TimeInterval) -> ToolIO {
        ToolIO(
            text: text, attachments: attachments, status: status,
            timeTaken: interval, outputWidget: outputWidget,
            widgetData: widgetData, isVerifiedData: isVerifiedData,
            emitDirectly: emitDirectly,
            suggestedQueries: suggestedQueries
        )
    }
}

/// Structured error types for tools, enabling precise healing decisions,
/// actionable error buttons, and better personalization.
public enum ToolError: Error, Sendable {
    /// A required permission was denied (e.g. location, contacts, microphone).
    case permissionDenied(permission: String, settingsURL: URL?)
    /// Network request failed or device is offline.
    case networkUnavailable(url: URL?)
    /// The tool couldn't parse or understand the input.
    case inputInvalid(reason: String, suggestion: String?)
    /// A required resource wasn't found (file, contact, calendar, etc.).
    case resourceNotFound(what: String)
    /// The operation exceeded its time limit.
    case timeout(duration: TimeInterval)
    /// An external API returned an error.
    case apiError(service: String, code: Int?, message: String)

    /// Whether the error is potentially recoverable by the healing loop.
    /// Permission and timeout errors are not worth retrying with different input.
    public var isHealable: Bool {
        switch self {
        case .inputInvalid, .apiError, .resourceNotFound: return true
        case .permissionDenied, .networkUnavailable, .timeout: return false
        }
    }

    /// A suggested System Settings deep-link URL, if applicable.
    public var settingsURL: URL? {
        switch self {
        case .permissionDenied(_, let url): return url
        default: return nil
        }
    }

    /// Human-readable summary for the Personalizer.
    public var userMessage: String {
        switch self {
        case .permissionDenied(let perm, _):
            return "\(perm) permission is required but was denied."
        case .networkUnavailable(let url):
            if let url { return "Couldn't reach \(url.host ?? "the server"). Check your internet connection." }
            return "No internet connection available."
        case .inputInvalid(let reason, _):
            return reason
        case .resourceNotFound(let what):
            return "Couldn't find \(what)."
        case .timeout(let duration):
            return "The operation timed out after \(Int(duration)) seconds."
        case .apiError(let service, let code, let message):
            if let code { return "\(service) returned error \(code): \(message)" }
            return "\(service) error: \(message)"
        }
    }
}

/// A standard protocol for iClaw tools.
///
/// **Error convention:** Tools should return `ToolIO(text: "...", status: .error)` for
/// expected failures (permission denied, invalid input, resource not found). The engine
/// injects these as `[ERROR]` tags in ingredients. Reserve `throw ToolError` for
/// infrastructure-level failures (timeouts, API HTTP errors) that the engine's healing
/// loop may attempt to recover from. See `ToolError.isHealable` for the distinction.
public protocol CoreTool: Sendable {
    var name: String { get }
    var schema: String { get }
    var isInternal: Bool { get }
    var category: CategoryEnum { get }
    /// Consent policy for this tool's action. Defaults to `.safe`.
    var consentPolicy: ActionConsentPolicy { get }
    /// Permission required before this tool can execute. If the user has
    /// previously rejected this permission, the engine can skip the tool
    /// during routing and prefer an alternative. Defaults to `nil` (no permission needed).
    var requiredPermission: PermissionManager.PermissionKind? { get }

    /// Executes the tool with the given input string.
    /// - Parameters:
    ///   - input: The raw input for the tool.
    ///   - entities: The extracted entities from the input preprocessor.
    /// - Returns: A standardized `ToolIO` object.
    func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO

    /// Executes the tool with the routing label that triggered selection.
    /// Tools that handle multiple intents (e.g., unified Time tool handling
    /// both clock and timer) use the label to disambiguate internally.
    /// Default implementation forwards to `execute(input:entities:)`.
    func execute(input: String, entities: ExtractedEntities?, routingLabel: String?) async throws -> ToolIO
}

extension CoreTool {
    public var consentPolicy: ActionConsentPolicy { .safe }
    public var requiredPermission: PermissionManager.PermissionKind? { nil }

    public func execute(input: String, entities: ExtractedEntities?, routingLabel: String?) async throws -> ToolIO {
        try await execute(input: input, entities: entities)
    }

    /// Wraps a tool body with automatic timing. The returned `ToolIO` gets
    /// `timeTaken` set to the elapsed wall-clock duration of `body`.
    /// Individual returns inside `body` can omit `timeTaken:`.
    public func timed(_ body: () async throws -> ToolIO) async rethrows -> ToolIO {
        let start = Date()
        let result = try await body()
        return result.withTimeTaken(Date().timeIntervalSince(start))
    }
}

/// A tool that can request follow-up execution steps within the same turn.
///
/// When ExecutionEngine runs a `ChainableTool`, it calls `nextStep()` after execution.
/// If a step is returned, the engine routes and executes the next tool, substituting
/// the prior result. This enables multi-tool workflows like:
/// - Research → WebFetch → synthesize
/// - Calendar → Weather (for meeting location)
/// - WebFetch → Translate
///
/// Chains are bounded by `AppConfig.maxToolCallsPerTurn`.
public protocol ChainableTool: CoreTool {
    /// After execution, optionally returns a next step for the engine to run.
    /// - Parameters:
    ///   - result: The tool's execution result.
    ///   - originalInput: The user's original input string.
    /// - Returns: A `ChainStep` if more work is needed, or `nil` if done.
    func nextStep(result: ToolIO, originalInput: String) -> ChainStep?
}

/// A follow-up step in a tool chain.
public enum ChainStep: Sendable {
    /// Run another tool with the given input. The engine will route by tool name.
    case runTool(name: String, input: String)
}

/// A descriptor for Foundation Model native tools.
public protocol FMToolDescriptor: Sendable {
    var name: String { get }
    var chipName: String { get }
    var routingKeywords: [String] { get }
    var category: CategoryEnum { get }
    /// Consent policy for this tool's action. Defaults to `.safe`.
    var consentPolicy: ActionConsentPolicy { get }
    func makeTool() -> any Tool
}

extension FMToolDescriptor {
    public var consentPolicy: ActionConsentPolicy { .safe }
}
