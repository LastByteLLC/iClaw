import Foundation

/// Marker protocol for structured tool arguments decoded from LLM extraction.
public protocol ToolArguments: Sendable, Decodable {}

/// Loads a JSON schema from `Resources/Config/ToolSchemas/<name>.json`.
/// Shared helper to eliminate boilerplate across all ExtractableCoreTool conformants.
public func loadExtractionSchema(named name: String, fallback: String) -> String {
    guard let url = Bundle.iClawCore.url(forResource: name, withExtension: "json", subdirectory: "Config/ToolSchemas"),
          let data = try? Data(contentsOf: url),
          let str = String(data: data, encoding: .utf8) else {
        return fallback
    }
    return str
}

/// A CoreTool that can receive structured, LLM-extracted arguments instead of raw text.
///
/// Tools conforming to this protocol get their parameters extracted by `ToolArgumentExtractor`
/// before execution. The extraction uses a compact JSON schema and an LLM call to parse
/// natural-language input into structured `Args`. If extraction fails, the engine falls back
/// to the standard `execute(input:entities:)` method.
///
/// Zero breaking changes to `CoreTool` — this is purely additive.
public protocol ExtractableCoreTool: CoreTool {
    associatedtype Args: ToolArguments

    /// Compact JSON schema template for LLM extraction.
    /// Loaded from `Resources/Config/ToolSchemas/<Name>.json`.
    static var extractionSchema: String { get }

    /// Execute with structured arguments extracted by the LLM.
    /// - Parameters:
    ///   - args: The extracted and decoded arguments.
    ///   - rawInput: The original user input (for fallback or logging).
    ///   - entities: NER-extracted entities from preprocessing.
    /// - Returns: A standardized `ToolIO` result.
    func execute(args: Args, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO
}

extension ExtractableCoreTool {
    /// Type-erased trampoline that opens `Self.Args` without the caller needing the concrete type.
    /// Called from `ExecutionEngine._extractAndExecute` to avoid a manual switch over every conformant.
    func extractAndRun(input: String, entities: ExtractedEntities?, extractor: ToolArgumentExtractor) async -> ToolIO? {
        guard let args = await extractor.extract(
            input: input,
            schema: Self.extractionSchema,
            toolName: name,
            as: Args.self
        ) else {
            return nil
        }
        return try? await execute(args: args, rawInput: input, entities: entities)
    }
}
