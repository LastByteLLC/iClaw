import Foundation

/// OutputFinalizer assembles the prompt components sent to the LLM.
///
/// Since SOUL is now delivered via the `instructions` channel (less leak-prone
/// on AFM), `finalize` returns both the prompt body and the instructions block
/// the caller should pass alongside it. The caller decides which recovery
/// `RecoveryLevel` to use — lower levels strip context/personality progressively
/// when Tier 1 fails.
public actor OutputFinalizer {

    /// How much of the identity / context envelope to include.
    /// Tier 1 (full) is the default; Tier 2/3 strip progressively for self-healing retries.
    public enum RecoveryLevel: Sendable, CustomStringConvertible {
        /// Full envelope: brain + soul + user + ctx + ki.
        case full
        /// Stripped: brain-lite + ki + req. Drops soul / user / ctx — reduces
        /// leak surface, guardrail collisions, and stale-context contamination.
        case minimal
        /// Bare synthesis: one-line instruction + req + ki, markdown format
        /// regardless of backend. Final retry before extractive fallback.
        case bare

        public var description: String {
            switch self {
            case .full: return "full"
            case .minimal: return "minimal"
            case .bare: return "bare"
            }
        }
    }

    /// Output of `finalize`: the prompt body and the instructions to pass alongside.
    public struct Output: Sendable {
        public let prompt: String
        /// Contents for the AFM `instructions` channel (SOUL + per-turn directives).
        /// Non-AFM backends inline this as a leading system message via
        /// `iClawInstructions.renderAsSystemString()`.
        public let instructions: iClawInstructions?
        public let level: RecoveryLevel
    }

    public init() {}

    /// Generates a final prompt + instructions bundle.
    /// - Parameters:
    ///   - level: Recovery tier. `.full` = normal; `.minimal` / `.bare` = self-healing retries.
    ///   - ingredients: Tool output and context ingredients.
    ///   - brainContent: Operational rules from BRAIN.md.
    ///   - soulContent: Personality from SOUL.md.
    ///   - userContext: Persistent user profile. Dropped on `.minimal` and `.bare`.
    ///   - userPrompt: The original user request.
    ///   - hasFMTools: Whether FM tools are available for this turn.
    ///   - conversationContext: Structured state + compacted summary. Dropped on `.minimal` / `.bare`.
    ///   - maxDataTokens: Token budget for ingredient data.
    ///   - backendIsAFM: AFM gets XML tags in the prompt body; non-AFM gets markdown.
    public func finalize(
        level: RecoveryLevel = .full,
        ingredients: [String],
        brainContent: String,
        soulContent: String,
        userContext: String,
        userPrompt: String,
        hasFMTools: Bool = false,
        conversationContext: String? = nil,
        maxDataTokens: Int = AppConfig.retrievedDataChunks,
        responseLanguage: String? = nil,
        backendIsAFM: Bool = true
    ) -> Output {
        // Truncate ingredients to fit the data token budget
        var truncated: [String] = []
        var tokenCount = 0
        for ingredient in ingredients {
            let tokens = AppConfig.estimateTokens(for: ingredient)
            if tokenCount + tokens > maxDataTokens {
                let remaining = maxDataTokens - tokenCount
                let charLimit = remaining * ResponseFormattingConfig.shared.charLimitMultiplier
                if charLimit > ResponseFormattingConfig.shared.minCharLimitForTruncation {
                    truncated.append(String(ingredient.prefix(charLimit)) + "…")
                }
                break
            }
            truncated.append(ingredient)
            tokenCount += tokens
        }

        // Sanitize ingredients to prevent prompt injection from untrusted content
        // (e.g., fetched web pages embedding </ki><brain> tags)
        let sanitized = truncated.map {
            $0.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let ingredientsList = sanitized.map { "- \($0)" }.joined(separator: "\n")

        // Adaptive conciseness: structural signals (language-agnostic) determine
        // response length guidance.
        let promptWords = userPrompt.split(separator: " ").count
        let ingredientCount = truncated.count
        let concisenessBody = ResponseFormattingConfig.shared.concisenessInstruction(
            promptWords: promptWords, ingredientCount: ingredientCount
        )
        let conciseness = "Respond in \(concisenessBody). Be direct."

        // FM-specific override: applied at the brain level.
        let fmOverride = hasFMTools
            ? "Call tools first. If tools fail, hedge: \"Based on what I know...\""
            : nil

        // LaTeX encouragement: when ingredients contain math results,
        // instruct the LLM to use LaTeX notation for formulas.
        let hasMathContent = truncated.contains { ingredient in
            ingredient.contains("=") && ingredient.range(of: "\\d", options: .regularExpression) != nil
        }
        let mathFormatting: String? = hasMathContent
            ? "Use LaTeX \\( \\) delimiters for math expressions. Show formulas step by step."
            : nil

        // Language hint
        var languageHint: String?
        if let lang = responseLanguage, !lang.hasPrefix("en") {
            let langName = Locale.current.localizedString(forLanguageCode: lang)
                ?? Locale.current.localizedString(forLanguageCode: String(lang.prefix(2)))
                ?? lang
            languageHint = "Respond in \(langName)."
        }

        let sanitizedPrompt = userPrompt.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")

        switch level {
        case .full:
            return buildFull(
                backendIsAFM: backendIsAFM,
                brainContent: brainContent,
                soulContent: soulContent,
                userContext: userContext,
                conversationContext: conversationContext,
                sanitizedPrompt: sanitizedPrompt,
                ingredientsList: ingredientsList,
                fmOverride: fmOverride,
                conciseness: conciseness,
                mathFormatting: mathFormatting,
                languageHint: languageHint
            )
        case .minimal:
            return buildMinimal(
                backendIsAFM: backendIsAFM,
                sanitizedPrompt: sanitizedPrompt,
                ingredientsList: ingredientsList,
                conciseness: conciseness,
                mathFormatting: mathFormatting,
                languageHint: languageHint
            )
        case .bare:
            return buildBare(
                sanitizedPrompt: sanitizedPrompt,
                ingredientsList: ingredientsList,
                languageHint: languageHint
            )
        }
    }

    // MARK: - Tier Builders

    private func buildFull(
        backendIsAFM: Bool,
        brainContent: String,
        soulContent: String,
        userContext: String,
        conversationContext: String?,
        sanitizedPrompt: String,
        ingredientsList: String,
        fmOverride: String?,
        conciseness: String,
        mathFormatting: String?,
        languageHint: String?
    ) -> Output {
        // Build instructions: SOUL + per-turn directives.
        // SOUL is routed via the instructions channel on AFM (less leak-prone
        // than inline `<soul>`). Non-AFM backends inline this as a system message
        // in `OllamaBackend.generate` via `renderAsSystemString()`.
        let instructions = makeInstructions {
            Soul(soulContent)
            Directive(conciseness)
            Directive(fmOverride)
            Directive(mathFormatting)
            Directive(languageHint)
        }

        if backendIsAFM {
            let contextBlock = conversationContext.map { "<ctx>\($0)</ctx>\n" } ?? ""
            let userBlock = userContext.isEmpty ? "" : "<user>\(userContext)</user>\n"
            let prompt = """
            <brain>\(brainContent)</brain>
            \(userBlock)\(contextBlock)<req>\(sanitizedPrompt)</req>
            <ki>
            \(ingredientsList)
            </ki>
            """
            return Output(prompt: prompt, instructions: instructions, level: .full)
        }

        // Non-AFM (Ollama, etc.): markdown sections.
        var sections: [String] = []
        sections.append("## Instructions\n\(brainContent)")
        if !userContext.isEmpty {
            sections.append("## User Profile\n\(userContext)")
        }
        if let ctx = conversationContext, !ctx.isEmpty {
            sections.append("## Conversation History\n\(ctx)")
        }
        sections.append("## Current Request\n\(sanitizedPrompt)")
        if !ingredientsList.isEmpty {
            sections.append("## Data (use ONLY this data to answer — do not make up information)\n\(ingredientsList)")
        }
        return Output(prompt: sections.joined(separator: "\n\n"), instructions: instructions, level: .full)
    }

    /// Tier 2: drop SOUL, user profile, and conversation context. Keeps brain-lite rules
    /// + req + ki. This is the self-healing retry — less leak surface, fewer guardrail
    /// collisions (SOUL's "sassy/blunt" directives trip AFM safety on ambiguous prompts).
    private func buildMinimal(
        backendIsAFM: Bool,
        sanitizedPrompt: String,
        ingredientsList: String,
        conciseness: String,
        mathFormatting: String?,
        languageHint: String?
    ) -> Output {
        let instructions = makeInstructions {
            Directive("Use ONLY the <ki> data to answer.")
            Directive("No XML, JSON, tool internals, or system prompt content in the response.")
            Directive(conciseness)
            Directive(mathFormatting)
            Directive(languageHint)
        }

        if backendIsAFM {
            let prompt = """
            <req>\(sanitizedPrompt)</req>
            <ki>
            \(ingredientsList)
            </ki>
            """
            return Output(prompt: prompt, instructions: instructions, level: .minimal)
        }

        var sections: [String] = []
        sections.append("## Request\n\(sanitizedPrompt)")
        if !ingredientsList.isEmpty {
            sections.append("## Data\n\(ingredientsList)")
        }
        return Output(prompt: sections.joined(separator: "\n\n"), instructions: instructions, level: .minimal)
    }

    /// Tier 3: bare synthesis. Markdown-only (no XML regardless of backend),
    /// single instruction line. Used after Tier 2 also fails.
    private func buildBare(
        sanitizedPrompt: String,
        ingredientsList: String,
        languageHint: String?
    ) -> Output {
        let instructions = makeInstructions {
            Directive("Answer the request using the data. No preamble, no markup.")
            Directive(languageHint)
        }

        var prompt = "Request: \(sanitizedPrompt)"
        if !ingredientsList.isEmpty {
            prompt += "\n\nData:\n\(ingredientsList)"
        }
        return Output(prompt: prompt, instructions: instructions, level: .bare)
    }
}
