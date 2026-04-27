import Foundation
import NaturalLanguage

/// Verdict emitted by `ToolOutputClassifier.score` — a lightweight quality
/// check that runs after every tool execution, before finalization.
///
/// The engine uses this to decide whether to:
///   * accept the output (`.ok` / `.degraded`)
///   * try the next tool in `ToolFallbackLadder.json` (`.failed` / `.offTopic`)
public struct ToolOutputQuality: Sendable {
    public enum Verdict: String, Sendable { case ok, degraded, failed, offTopic }
    public let verdict: Verdict
    public let reasons: [String]
}

/// Post-execution output classifier. Deterministic heuristics only; no LLM
/// call, no English phrase lists. Runs in microseconds.
public enum ToolOutputClassifier {

    /// Tools whose role is to RETRIEVE information about a named entity.
    /// If the user's NER entities are absent from the response, the tool
    /// produced an off-topic answer.
    private static let retrievalTools: Set<String> = [
        "Contacts", "Notes", "ReadEmail", "WikipediaSearch", "Stocks", "Weather"
    ]

    /// Returns a quality verdict for a tool's output.
    /// - Parameters:
    ///   - input: the user's original input (needed to detect off-topic responses).
    ///   - tool: the tool's name.
    ///   - expectedWidget: the widget type the tool should return (from manifest), or nil.
    ///   - output: the ToolIO the tool returned.
    public static func score(
        input: String,
        tool: String,
        expectedWidget: String? = nil,
        output: ToolIO
    ) -> ToolOutputQuality {
        var reasons: [String] = []
        let trimmed = output.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // (1) Hard failure signals
        if output.status == .error {
            reasons.append("status=error")
            return .init(verdict: .failed, reasons: reasons)
        }
        if trimmed.isEmpty && output.widgetData == nil {
            reasons.append("empty_text_no_widget")
            return .init(verdict: .failed, reasons: reasons)
        }
        if trimmed.hasPrefix("[ERROR]") {
            reasons.append("error_prefix")
            return .init(verdict: .failed, reasons: reasons)
        }

        // (2) Expected widget missing
        if let expected = expectedWidget {
            let got = output.outputWidget ?? ""
            let match = got.lowercased().contains(expected.lowercased())
                || expected.lowercased().contains(got.lowercased())
            if !match {
                reasons.append("widget_missing:expected=\(expected) got=\(got)")
                return .init(verdict: .degraded, reasons: reasons)
            }
        }

        // (3) Off-topic check for retrieval tools
        if retrievalTools.contains(tool), !trimmed.isEmpty {
            let inputEntities = extractSalientNouns(input)
            if !inputEntities.isEmpty {
                let outputLower = trimmed.lowercased()
                let present = inputEntities.filter { outputLower.contains($0.lowercased()) }
                if present.isEmpty {
                    reasons.append("offtopic:none_of_\(inputEntities.joined(separator: ","))_in_output")
                    return .init(verdict: .offTopic, reasons: reasons)
                }
            }
        }

        // (4) Otherwise: ok. Mark degraded only for specific near-miss signals.
        if trimmed.count < 3 { reasons.append("very_short_text") }
        return .init(verdict: reasons.isEmpty ? .ok : .degraded, reasons: reasons)
    }

    /// NLTagger name entities + bare uppercase tokens (tickers, acronyms) +
    /// standalone numbers (ZIP codes, years). Language-independent within
    /// NLTagger's coverage; falls back gracefully when tagger finds nothing.
    private static func extractSalientNouns(_ input: String) -> [String] {
        var nouns: Set<String> = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = input
        let opts: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: input.startIndex..<input.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            if tag == .placeName || tag == .personalName || tag == .organizationName {
                nouns.insert(String(input[range]))
            }
            return true
        }
        // Bare uppercase tickers / acronyms (≥2 chars, all caps)
        let words = input.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for w in words where w.count >= 2 && w.allSatisfy({ $0.isLetter && $0.isUppercase }) {
            nouns.insert(String(w))
        }
        return Array(nouns)
    }
}

/// Per-tool fallback ladder loaded from `Resources/Config/ToolFallbackLadder.json`.
public enum ToolFallbackLadder {
    private struct Wrapper: Decodable { let ladders: [String: [String]] }

    private static let ladders: [String: [String]] = {
        if let w: Wrapper = ConfigLoader.load("ToolFallbackLadder", as: Wrapper.self) {
            return w.ladders
        }
        return [:]
    }()

    /// Returns the first fallback tool name for `tool`, or nil if none configured.
    public static func firstFallback(for tool: String) -> String? {
        ladders[tool]?.first
    }

    /// Returns the full fallback chain for `tool`.
    public static func chain(for tool: String) -> [String] {
        ladders[tool] ?? []
    }
}
