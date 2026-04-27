import Foundation

/// Centralized provider for the agent's operational rules (BRAIN.md).
/// Loads the base rules and injects runtime values like the generation token budget.
/// Two variants:
///   • `current` (or `.tool`) — tool-assisted turns. Ingredient-oriented.
///   • `conversational` — tool-free turns (gate said conversational /
///     clarification / replyElaboration). Strips every tool reference so
///     the LLM never announces "I don't need a tool" or "I'm not a recipe
///     generator".
public enum BrainProvider {

    public enum Mode: Sendable {
        case tool
        case conversational
    }

    /// Variant selection resolution order:
    ///   1. `UserDefaults["{defaultsKey}.path"]` — absolute filesystem path.
    ///      Lets prompt_mutate.py variants in /tmp/ drive evaluation without
    ///      a rebuild.
    ///   2. `UserDefaults["{defaultsKey}"]` — bundle lookup by variant name,
    ///      resolving `{base}.{variant}.md`.
    ///   3. Bundle lookup of `{base}.md`.
    ///   4. Inline fallback string.
    static func resolveContent(base: String, defaultsKey: String, inlineFallback: String) -> String {
        if let path = UserDefaults.standard.string(forKey: "\(defaultsKey).path"),
           !path.isEmpty,
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return content
        }
        let variant = UserDefaults.standard.string(forKey: defaultsKey)
        if let v = variant, !v.isEmpty,
           let url = Bundle.iClawCore.url(forResource: "\(base).\(v)", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let url = Bundle.iClawCore.url(forResource: base, withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return inlineFallback
    }

    /// Tool-mode brain. `UserDefaults["prompt.brain.variant"]` switches to
    /// `BRAIN.{variant}.md` for experiments.
    private static var baseBrainContent: String {
        resolveContent(
            base: "BRAIN",
            defaultsKey: "prompt.brain.variant",
            inlineFallback: "Use only provided data. No hallucination. No JSON output. Be concise."
        )
    }

    /// Conversational-mode brain. `UserDefaults["prompt.brain-conversational.variant"]`
    /// switches to `BRAIN-conversational.{variant}.md`.
    private static var conversationalBrainContent: String {
        resolveContent(
            base: "BRAIN-conversational",
            defaultsKey: "prompt.brain-conversational.variant",
            inlineFallback: """
            Respond naturally to the user's message. Match their tone and length.
            Do not mention tools, your architecture, or capability limitations.
            Do not prefix with "Here's what I found:" or similar tool-output phrasing.
            Stay under {generationSpace} tokens.
            """
        )
    }

    /// Returns the operational rules for the given mode, with `{generationSpace}`
    /// replaced by the current budget.
    public static func content(for mode: Mode) -> String {
        let base: String
        switch mode {
        case .tool: base = baseBrainContent
        case .conversational: base = conversationalBrainContent
        }
        return base.replacingOccurrences(
            of: "{generationSpace}",
            with: "\(AppConfig.generationSpace)"
        )
    }

    /// Back-compat: tool-mode rules (default).
    public static var current: String { content(for: .tool) }
}
