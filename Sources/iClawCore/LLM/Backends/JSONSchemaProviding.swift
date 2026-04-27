import Foundation

/// Types that provide a JSON Schema for non-AFM structured generation.
///
/// When Ollama or other non-AFM backends need structured output, the schema
/// is passed directly to the Ollama `format` parameter, which constrains
/// the model's output to match the schema structurally.
///
/// Conforming types should mirror their `@Guide(description:)` annotations
/// in the schema's `description` fields.
public protocol JSONSchemaProviding {
    /// A JSON Schema object describing the expected output structure.
    /// Must be a valid JSON Schema (type, properties, required, etc.).
    static var jsonSchema: [String: Any] { get }
}
