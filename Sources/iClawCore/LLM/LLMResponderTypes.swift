import FoundationModels

/// Single-input LLM responder used by most tools for text generation.
public typealias SimpleLLMResponder = @Sendable (String) async throws -> String

/// Dual-input LLM responder for tools that pass a system/context string alongside the prompt.
public typealias DualInputLLMResponder = @Sendable (String, String) async throws -> String

/// LLM responder that receives Foundation Model tools for tool-aware generation.
public typealias ToolAwareLLMResponder = @Sendable (String, [any Tool]) async throws -> String

/// Non-throwing dual-input responder for fire-and-forget LLM calls (e.g. feedback).
public typealias SafeLLMResponder = @Sendable (String, String) async -> String
