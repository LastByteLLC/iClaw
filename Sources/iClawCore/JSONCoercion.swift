import Foundation

/// Normalizes JSON type mismatches from on-device LLM output before decoding.
///
/// On-device models (especially quantized ones) frequently return wrong JSON types:
/// strings instead of numbers, JSON-encoded arrays as strings, booleans as strings.
/// This layer fixes the most common mismatches so `JSONDecoder` succeeds more often,
/// reducing fallback to raw `execute(input:entities:)`.
///
/// Inspired by osaurus's ArgumentCoercion pattern.
public enum JSONCoercion {

    /// Attempts to coerce a JSON object's values to match expected types.
    /// Returns the original data unchanged if parsing fails at any stage.
    public static func coerce(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              var dict = object as? [String: Any] else {
            return data
        }

        var changed = false
        for (key, value) in dict {
            if let coerced = coerceValue(value) {
                dict[key] = coerced
                changed = true
            }
        }

        guard changed,
              let result = try? JSONSerialization.data(withJSONObject: dict) else {
            return data
        }
        return result
    }

    /// Coerces a single value. Returns nil if no coercion needed.
    private static func coerceValue(_ value: Any) -> Any? {
        guard let string = value as? String else { return nil }

        // "true"/"false" → Bool
        if string.lowercased() == "true" { return true }
        if string.lowercased() == "false" { return false }

        // "null" → NSNull
        if string.lowercased() == "null" { return NSNull() }

        // String-encoded number → number
        // Only coerce if the entire string is a number (not "5 miles")
        if let intVal = Int(string) { return intVal }
        if let doubleVal = Double(string), !string.contains(" ") { return doubleVal }

        // String-encoded JSON array → actual array (e.g., "[\"a\",\"b\"]" → ["a","b"])
        if string.hasPrefix("["),
           let arrayData = string.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: arrayData) as? [Any] {
            return array
        }

        // String-encoded JSON object → actual object
        if string.hasPrefix("{"),
           let objData = string.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: objData) as? [String: Any] {
            return obj
        }

        return nil
    }
}
