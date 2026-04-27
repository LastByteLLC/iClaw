import Foundation
import os

/// Closure type for injecting a test LLM responder into ComputeTool.
public typealias ComputeLLMResponder = SimpleLLMResponder

/// Executes complex math, statistics, data transformations, and encoding via
/// LLM-generated JavaScript running in a sandboxed WKWebView.
///
/// For simple arithmetic ("2+3"), CalculatorTool is preferred (faster, no LLM call).
/// ComputeTool handles the overflow: statistics, matrices, sorting, base64, regex, etc.
public struct ComputeTool: CoreTool, Sendable {
    public let name = "Compute"
    public let schema = "Complex math, statistics, data transformation, encoding, regex, and sorting."
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.safe

    private let llmResponder: ComputeLLMResponder?

    public init(llmResponder: ComputeLLMResponder? = nil) {
        self.llmResponder = llmResponder
    }

    public func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
        // 0. Structured math reducers — exact answers for patterns
        // (integral of polynomial, GCD, LCM, factorial, etc.) that the
        // LLM-generated JS path drifts on. When a pattern matches, we
        // short-circuit with a verified result and `emitDirectly` so the
        // finalizer can't paraphrase the number.
        if let advanced = AdvancedMathReducers.reduce(input) {
            return ToolIO(
                text: advanced.display,
                status: .ok,
                outputWidget: "ComputeWidget",
                widgetData: ComputeWidgetData(
                    query: input,
                    code: "// reduced exactly by AdvancedMathReducers",
                    result: advanced.display,
                    truncated: false
                ),
                isVerifiedData: true,
                emitDirectly: true
            )
        }

        // 0a. Encoding / decoding — delegate to ConvertTool's deterministic
        // encoders when the input clearly names an encoding format. The
        // LLM-JS path drifts on these (e.g. treating "help!" as RGB integer
        // 0xC50D0001 instead of UTF-8 bytes 0x68656C7021), and the reverse
        // direction ("<bits> in ascii") needs the same pipeline. Gated by a
        // keyword check so bare arithmetic doesn't accidentally hit Convert's
        // currency API fallback.
        if ComputeTool.looksLikeEncodingOp(input) {
            let convert = ConvertTool()
            if let encoded = try? await convert.execute(input: input, entities: entities),
               encoded.status == .ok, !encoded.text.isEmpty {
                return ToolIO(
                    text: encoded.text,
                    status: .ok,
                    outputWidget: "ComputeWidget",
                    widgetData: ComputeWidgetData(
                        query: input,
                        code: "// delegated to ConvertTool",
                        result: encoded.text,
                        truncated: false
                    ),
                    isVerifiedData: true,
                    emitDirectly: true
                )
            }
        }

        // 1. Generate JavaScript from natural language
        let prompt = """
        Write JavaScript to: \(input)
        Rules: Pure computation. No DOM, no fetch, no setTimeout, no import.
        console.log() the FINAL RESULT (not the input). Actually perform the operation.
        JS only, no explanation:
        """

        let code: String
        if let responder = llmResponder {
            code = try await responder(prompt)
        } else {
            code = try await LLMAdapter.shared.generateText(prompt)
        }

        // 2. Static validation — defense-in-depth
        let blocked = ["fetch(", "XMLHttpRequest", "WebSocket(", "import(", "require(", "eval(", "Function(", "Worker(", "SharedWorker("]
        for pattern in blocked {
            if code.contains(pattern) {
                return ToolIO(text: "Generated code contained blocked API (\(pattern)). Try rephrasing.", status: .error)
            }
        }

        // 3. Code length check
        guard code.count <= 2000 else {
            return ToolIO(text: "Generated code is too long (\(code.count) chars). Try a simpler formulation.", status: .error)
        }

        // 4. Execute in sandbox
        let cleanCode = extractCodeBlock(from: code)
        do {
            let result = try await JSExecutor.shared.execute(code: cleanCode, mode: .script)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !output.isEmpty else {
                return ToolIO(text: "Computation produced no output. Try rephrasing.", status: .error)
            }

            let widgetData = ComputeWidgetData(
                query: input,
                code: cleanCode,
                result: output,
                truncated: result.truncated
            )

            return ToolIO(
                text: output,
                status: .ok,
                outputWidget: "ComputeWidget",
                widgetData: widgetData,
                isVerifiedData: true
            )
        } catch let error as ToolError {
            throw error
        } catch {
            return ToolIO(text: "Computation failed: \(error.localizedDescription)", status: .error)
        }
    }

    /// Recognises natural-language encoding/decoding requests so ComputeTool
    /// can delegate to ConvertTool's deterministic encoders. Matches patterns
    /// like `"help!" in binary`, `XXVIII to hex`, `decode base64 SGVsbG8=`,
    /// and raw binary/hex blobs that need to be decoded back to text.
    private static let encodingFormats: Set<String> = [
        "binary", "hex", "hexadecimal", "ascii", "base64", "nato", "morse",
        "octal", "rot13", "roman", "url"
    ]

    private static let toPattern = try! NSRegularExpression(
        pattern: #"\b(?:to|in)\s+(binary|hex|hexadecimal|ascii|base64|nato|morse|octal|rot13|roman|url)\b"#,
        options: [.caseInsensitive]
    )
    private static let decodePattern = try! NSRegularExpression(
        pattern: #"\bdecode\s+(binary|hex|hexadecimal|ascii|base64|nato|morse|octal|rot13|roman|url)\b"#,
        options: [.caseInsensitive]
    )
    private static let rawBinaryPattern = try! NSRegularExpression(
        pattern: #"^[01\s]{8,}$"#
    )

    static func looksLikeEncodingOp(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if toPattern.firstMatch(in: trimmed, options: [], range: range) != nil { return true }
        if decodePattern.firstMatch(in: trimmed, options: [], range: range) != nil { return true }
        // Raw binary/hex blobs with no keyword — ConvertTool auto-detects these.
        if rawBinaryPattern.firstMatch(in: trimmed, options: [], range: range) != nil { return true }
        return false
    }

    /// Strips markdown code fences if the LLM wrapped the code in ```javascript ... ```
    private func extractCodeBlock(from text: String) -> String {
        var code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip ```javascript or ``` fences
        if code.hasPrefix("```") {
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            var start = 0
            var end = lines.count
            if lines.first?.hasPrefix("```") == true { start = 1 }
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { end -= 1 }
            code = lines[start..<end].joined(separator: "\n")
        }
        return code
    }
}

// MARK: - Widget Data

public struct ComputeWidgetData: Sendable {
    public let query: String
    public let code: String
    public let result: String
    public let truncated: Bool
}
