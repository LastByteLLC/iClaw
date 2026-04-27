import Foundation
import FoundationModels

// MARK: - ExecutionEngine Helper Methods
//
// Non-FSM helper methods extracted from ExecutionEngine.swift for readability.
// All methods are on the same actor — no isolation concerns.

extension ExecutionEngine {

    // MARK: - LLM Response Cleaning

    /// Pre-compiled regexes for response cleaning (avoids recompilation every turn).
    private static let cleaningRegexes: [NSRegularExpression] = {
        let patterns = [
            "\\[function call:[^\\]]*\\]",
            "messages\\.post\\([^)]*\\)",
            "\\{\"function\"[^}]*\"arguments\"[^}]*\\}",
            #"\{\s*"isCorrect"\s*:.*?"isConversational"\s*:.*?\}"#,
            #"\{\s*"isConversational"\s*:.*?"isCorrect"\s*:.*?\}"#,
            // Any opening/closing angle-bracket tag whose name starts with
            // one of our internal prefixes — catches variants like `<kibody>`,
            // `<ki_data>`, `<brain_notes>`, `<ctx_recent>` that the LLM
            // occasionally coins when paraphrasing the scaffold.
            "</?(?:soul|req|ki|brain|ctx|data)[a-z_\\-]*\\s*/?>",
            // Leading "<tool_name>:" prefixes where the LLM echoes the FM tool
            // it "intended" to invoke instead of producing a user-facing answer.
            // e.g., "Web search: 'query'." → strip the leading marker.
            #"^(?i:(?:web[ _]?search|read[ _]?file|web[ _]?fetch))\s*[:\-—]\s*['"]?[^'"\n]*['"]?[.!?]?\s*$"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let headerLeakRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "###\\s*(?:SOUL|KNOWLEDGE|INSTRUCTION|USER REQUEST)[^\\n]*\\n?", options: .caseInsensitive)

    /// Matches echoed BRAIN/system-prompt headers at line start. Covers the
    /// canonical token set leaked into user output in the 2026-04 60-prompt
    /// audit: `# Guidelines`, `## Precedence`, `## Behavior`, `## Refusals`,
    /// `## Output format`, plus the legacy `# Rules` / `## Priority` names.
    private static let brainHeaderLeakRegex: NSRegularExpression? =
        try? NSRegularExpression(
            pattern: #"(?m)^#{1,3}\s*(?:Guidelines|Rules|Precedence|Priority|Behavior|Refusals|Output format|Prompt-injection defense|Safety|Data)\s*\n?"#,
            options: .caseInsensitive
        )

    /// Strips trailing "per the rules" / "according to the rules" meta-phrases
    /// the LLM picks up from the "# Guidelines" block. Targets phrasing seen
    /// in the audit (e.g. "is not permitted per the rules").
    private static let rulesPhraseRegex: NSRegularExpression? =
        try? NSRegularExpression(
            pattern: #"(?i)\s*[,.]?\s*(?:per|according to|within|based on|as per)\s+(?:the\s+)?(?:specified\s+)?(?:rules|guidelines|directives|precedence)[^.!?\n]*[.!?]?"#,
            options: []
        )

    func cleanLLMResponse(_ input: String) -> String {
        var cleaned = input

        // Remove function call tags, FM tool leaks, structured output echoes, XML delimiters
        for regex in Self.cleaningRegexes {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }

        // Strip section header leaks (case-insensitive)
        if let headerRegex = Self.headerLeakRegex {
            cleaned = headerRegex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }

        // Strip echoed BRAIN headers (# Guidelines, ## Precedence, ## Behavior, ...)
        if let brainRegex = Self.brainHeaderLeakRegex {
            cleaned = brainRegex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }

        // Strip "per the rules" / "according to the guidelines" meta-phrases
        if let rulesRegex = Self.rulesPhraseRegex {
            cleaned = rulesRegex.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }

        // Strip fuzzy variants of prompt structure
        let fuzzyPatterns = ["Knowledge Ingredient", "Critical Constraints", "CRITICAL CONSTRAINTS:"]
        for pattern in fuzzyPatterns {
            if let range = cleaned.range(of: pattern, options: .caseInsensitive) {
                // Remove from the marker to the end of the line
                let lineEnd = cleaned[range.upperBound...].firstIndex(of: "\n") ?? cleaned.endIndex
                cleaned.removeSubrange(range.lowerBound..<lineEnd)
            }
        }

        // Guard against SOUL.md / system prompt leaks
        if Self.containsSystemPromptLeak(cleaned) {
            Log.engine.warning("Detected system prompt leak in LLM response -- stripping")
            cleaned = Self.stripSystemPromptContent(cleaned)
        }

        // Guard: if entire response is a JSON object, it's a structural leak -- return empty
        // so the caller falls back to ingredient summary
        let trimmedCheck = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCheck.hasPrefix("{") && trimmedCheck.hasSuffix("}") && trimmedCheck.contains(":") {
            Log.engine.warning("Detected pure JSON response leak -- stripping")
            cleaned = ""
        }

        // Guard against context/user block regurgitation.
        // Computes word overlap between the response and injected context blocks.
        // High overlap means the LLM echoed its context instead of answering.
        if !injectedContextWords.isEmpty && !cleaned.isEmpty {
            let responseWords = Set(
                cleaned.lowercased()
                    .components(separatedBy: .alphanumerics.inverted)
                    .filter { $0.count > 3 }
            )
            let overlap = responseWords.intersection(injectedContextWords)
            // If >60% of the context block's distinctive words appear in the response,
            // it's a leak. Use context word count as denominator since that's the
            // smaller, more specific set.
            let overlapRatio = injectedContextWords.isEmpty ? 0.0
                : Double(overlap.count) / Double(injectedContextWords.count)
            if overlapRatio > 0.6 {
                Log.engine.warning("Detected context block regurgitation (overlap: \(String(format: "%.0f%%", overlapRatio * 100))) -- stripping")
                cleaned = ""
            }
        }

        // Phrase-level echo detection (language-independent). If the response
        // reproduces two or more 4-word sequences from brain+soul+context,
        // it's paraphrasing the system prompt rather than answering.
        // Single-gram overlaps are common (discourse markers, stop words);
        // distinct multi-gram hits are the signal.
        if !injectedPhraseGrams.isEmpty && !cleaned.isEmpty {
            let responseGrams = Self.phraseGrams(of: cleaned, n: 4)
            let shared = responseGrams.intersection(injectedPhraseGrams)
            if shared.count >= 2 {
                Log.engine.warning("Detected system-prompt phrase echo (\(shared.count) shared 4-grams) -- stripping")
                cleaned = ""
            }
        }

        // Degeneration / repetition-loop detection. The LLM occasionally
        // enters a repetition trap, emitting the same 3-word phrase many
        // times ("Beat whitespace for clarity. Beat whitespace for clarity.
        // Beat whitespace…"). Detect by 3-gram frequency — if any single
        // 3-gram repeats ≥ 4 times, the response is degenerate and should
        // be dropped so the recovery ladder regenerates.
        if !cleaned.isEmpty {
            let grams3 = cleaned.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { !$0.isEmpty }
            if grams3.count >= 12 {
                var counts: [String: Int] = [:]
                for i in 0...(grams3.count - 3) {
                    let g = grams3[i..<i + 3].joined(separator: " ")
                    counts[g, default: 0] += 1
                }
                if let top = counts.max(by: { $0.value < $1.value }), top.value >= 4 {
                    Log.engine.warning("Detected repetition-loop degeneration (3-gram '\(top.key)' × \(top.value)) -- stripping")
                    cleaned = ""
                }
            }
        }

        // Strip common prompt-echo prefixes that slip through the BRAIN
        // rules. These are conversational-mode leaks we've observed: the
        // LLM prefacing with the user's name ("Tom Barrasso."), regurgi-
        // tating the state header line ("Recent topics: X. Your answer:
        // ..."), or starting with the "here/here's" tool-output idiom.
        let leadingLeakPatterns: [String] = [
            // "Tom Barrasso." / "Tom Barrasso here." / "Tom Barrasso, ..." —
            // strip the name prefix. We DON'T require another capital to
            // follow so pure-echo responses ("Tom Barrasso.") drop to empty
            // and trigger the upstream extractive fallback.
            // Negative lookahead excludes common discourse starters ("Sorry,",
            // "Actually,", "Wait,", etc.) that share the capitalized-word-
            // followed-by-comma shape but are part of the legitimate response,
            // not a leaked name. Added 2026-04 after `testToolFailureGraceful-
            // Degradation` regressed on "Sorry, weather unavailable."
            #"^(?!(?:Sorry|Apologies|Actually|Honestly|Frankly|Wait|Well|Yeah|Yes|No|Nope|Sure|Okay|OK|Alright|Unfortunately|Thanks|Hey|Hi|Hello|Hmm|Uh|Um|Oh|Wow|Maybe|Perhaps|Fine|Great|Right)\b)[A-Z][a-zA-Z'\-]{1,20}(?:\s+[A-Z][a-zA-Z'\-]{1,20}){0,2}[.,]\s*"#,
            // "Recent topics: ..." / "Active entities: ..." / "Turn: N"
            #"^(?:Recent topics|Active entities|Recent data|Preferences|Turn)\s*:[^\n]*\n?"#,
            // "Here's what I found:" + whitespace/newlines
            #"^(?i:here'?s what i found)\s*:\s*"#,
            // "Here's (a|the) (concise|helpful|possible|quick|direct|revised)
            //  response:" plus bare "Here's the response:" / "Here's my response:"
            #"^(?i:here'?s (?:a |the |my |your |what (?:it'?s|i'?ve|i) (?:got|found)|and\s)*(?:concise |helpful |possible |quick |direct |revised |thoughtful )?(?:response|answer|idea|take|output)(?:\s+for you)?:?)\s*"#,
            // "The response should be:" / "The response is:"
            #"^(?i:the (?:response|answer|output) (?:should be|is|would be|will be):?)\s*"#,
            // "The user's message/question/request is/wants..." — narrator leak
            #"^(?i:the (?:user'?s|following) (?:message|question|request|input|prompt))[^\n]*\n?"#,
            // "Based on the documentation for the ..." — tool-narrator leak
            #"^(?i:based on (?:the\s+)?documentation (?:for|of)[^\n]*)\n?"#,
            // "**Here is the output:**" bold-block preamble
            #"^\*\*[A-Z][^*\n]{3,40}:\*\*\s*\n?"#,
            // "I can help with that!" + newline starters where the reply
            // then asks for clarification instead of answering.
            #"^(?i:i can help (?:you )?with that!?\s+)(?=could|please|can you|what)"#,
            // "Sure thing!" / "Sure!" empty opener (strip only when followed
            // by a "Here's..." preamble on the next line)
            #"^(?i:sure(?:\s+thing)?!?)\s*(?=(?i:here'?s|the response))"#,
            // "I don't have a tool ..." / "I don't have a tool for that."
            #"^(?i:i don'?t have (?:a tool|a recipe|a data|a name|live data)[^.]*\.?)\s*"#,
            // "No tool needed" / "No tool is needed"
            #"^(?i:no tool (?:is )?needed[^.]*\.?)\s*"#,
            // Clarification-directive echoes — the LLM sometimes quotes
            // the gate's instruction to it verbatim.
            #"^(?i:the user'?s message is too short[^\n]*)\n?"#,
            #"^\[CLARIFY\][^\n]*\n?"#,
            // `[INGREDIENT]` or bare `[TAG]`-prefixed echoes (e.g. `[MEMORY] …`
            // or `[VERIFIED] …` leaking). Only strip when anchored at start.
            #"^\[[A-Z_]{2,20}\][^\n]*\n?"#,
            //
            // --- Language-agnostic token/markup strippers (2026-04) ---
            //
            // "**Answer**" bold header — markdown token, universal.
            #"^\*\*Answer\*\*\s*\n?"#,
            // Chat-role markers. These are pattern tokens the model echoes
            // from its training data regardless of the response language.
            #"^\s*(?i:\*\*assistant\*\*:?|assistant:)\s*\n?"#,
            #"^\s*<(?i:assistant)(?:\s+[^>]*)?>\s*"#,
            // "<res>" / "<ans>" opening tags (closing handled by midResponseStrip).
            #"^\s*<(?i:res|ans)>\s*\n?"#,
            // "<body><h1>...</h1>" HTML block opener — HTML token, universal.
            #"^\s*<body>\s*\n?<h1>[^<]*</h1>\s*\n?"#,
            //
            // NOTE (structural audit): We deliberately do NOT add English-
            // phrase regexes here (e.g. "Sure! Here's a response", "Here is
            // the response to the user's request", "Based on what I know").
            // Those were brittle single-language patches. The durable fix
            // is prompt-engineering (few-shot positive examples) + model
            // upgrade, not accumulating phrase regexes. When the small
            // AFM emits a preamble, it's a known small-model limitation;
            // we accept the output and rely on the conversational-judge
            // classifier (isSoftRefusalLadder) for semantic quality gates.
        ]
        // Apply patterns in a fixed-point loop: each strip may reveal the
        // next pattern at position 0 (e.g. "Here's what I found:\n\n[CLARIFY]"
        // needs the first pattern to expose the second).
        for _ in 0..<3 {
            let before = cleaned
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            for pattern in leadingLeakPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
                    if let first = regex.firstMatch(in: cleaned, options: [], range: range),
                       first.range.location == 0 {
                        cleaned = regex.stringByReplacingMatches(
                            in: cleaned, options: [], range: first.range, withTemplate: ""
                        )
                    }
                }
            }
            if cleaned == before { break }
        }

        // Mid-response tag/marker stripping. Runs anywhere in the text, not
        // just at the start. These are pure leaks and never carry meaning.
        for pattern in Self.midResponseStripPatterns {
            cleaned = pattern.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: ""
            )
        }
        // Strip <response>…</response> wrapping but keep inner content.
        if let responseTag = Self.responseTagRegex {
            cleaned = responseTag.stringByReplacingMatches(
                in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "$1"
            )
        }
        // Collapse runs of blank lines introduced by strips.
        cleaned = cleaned
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .replacingOccurrences(of: "  ", with: " ")

        // NOTE (structural audit): placeholder-only detection and identity
        // misassertion replacement were removed. Both relied on English
        // regex against freeform LLM output — brittle for multilingual
        // use. The durable path: positive few-shot in BRAIN.md/SOUL.md +
        // a dedicated pre-router identity-intent classifier (see plan).
        // The `isPlaceholderOnly` and `isIdentityMisassertion` helpers
        // remain callable for tests but are not invoked in the cleanup
        // flow.
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mid-response tag strippers. Regex scoped to the FULL text, not just
    /// the leading slice. Each pattern must be safe to apply globally — i.e.
    /// it would never destroy legitimate content.
    private static let midResponseStripPatterns: [NSRegularExpression] = {
        let raw = [
            // `[VERIFIED] [Entity] (Source) …` bracket-tag ingredients that
            // get regurgitated mid-response.
            #"\[(?:VERIFIED|MEMORY|BROWSER|CACHED|ERROR|RECALLED|CLARIFY|KNOWLEDGE|INGREDIENT)\][^\n]*"#,
            // `**ERROR**:` bolded error wrappers (`**WARNING**:` etc.)
            #"\*\*(?:ERROR|WARNING|NOTE|OUTPUT|RESULT)\*\*:\s*"#,
            // `<response>`, `</response>`, `<answer>`, `</answer>` bare opens
            // (the full wrapping case is handled by responseTagRegex).
            #"</?(?:response|answer|output|result)>"#,
            //
            // --- Added 2026-04: pure leak markers that the small model
            //     emits anywhere in the response, not just at start.
            //
            // "([stubbed])" — ContactsTool stub leakage marker. This is
            // the exact marker called out in CLAUDE.md leakage corpus.
            #"\s*\(\[stubbed\]\)\s*"#,
            // "[Score]" / "[score]" — NewsTool template placeholder that
            // should have been filled with real data.
            #"\[(?:Score|score)\]"#,
            // Chat-role / HTML wrapper close/open tags that slip through
            // to mid-response. Case-insensitive. Includes `<Assistant>`,
            // `</Assistant>`, `<user>`, `<body>`, `</body>`, `<h1>`–`<h6>`,
            // `<p>`, `</p>`. Preserves inner text.
            #"</?(?:assistant|user|body|p|h[1-6])(?:\s+[^>]*)?>"#,
            // Bare "<res>" / "</res>" / "<ans>" / "</ans>" anywhere.
            #"</?(?:res|ans)>"#,
            // Trailing "Note: This response is based on … guidelines." —
            // the small model sometimes appends this to signal compliance.
            // Observed in "flip a coin" → correct result + this trailer.
            // Scope to trailing position to avoid stripping legitimate
            // "Note:" sentences.
            #"\n+Note:\s+This\s+(?:response|answer|result)\s+is\s+based\s+on[^\n]*(?:guidelines?|rules?|available\s+data)[^\n]*\.?\s*$"#,
            // Trailing "This response was generated in accordance with …"
            // and similar compliance-boilerplate trailers.
            #"\n+This\s+(?:response|answer|output)\s+(?:was\s+generated|follows|is\s+provided)\s+(?:in\s+accordance\s+)?(?:with\s+)?[^\n]*(?:guidelines?|rules?|constraints?)[^\n]*\.?\s*$"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// Matches `<response>…</response>` (or `<answer>…</answer>`) wraps.
    /// Captures the inner content so we keep it but drop the tags.
    private static let responseTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"<(?:response|answer)>\s*([\s\S]*?)\s*</(?:response|answer)>"#,
            options: .caseInsensitive
        )
    }()

    /// Tokenizes text on `.alphanumerics.inverted` (so it works across
    /// scripts — English, CJK, Cyrillic, Arabic, etc.) and returns every
    /// contiguous `n`-token sequence as a lowercased space-joined string.
    /// Used for language-independent phrase-echo detection.
    static func phraseGrams(of text: String, n: Int) -> Set<String> {
        let tokens = text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard tokens.count >= n else { return [] }
        var grams: Set<String> = []
        grams.reserveCapacity(tokens.count - n + 1)
        for i in 0...(tokens.count - n) {
            grams.insert(tokens[i..<i + n].joined(separator: " "))
        }
        return grams
    }

    /// Short prompts where the LLM asks the user whether to proceed with
    /// more work instead of answering. These are leak-equivalent: the tool
    /// already produced data (or the conversational path should have), but
    /// the finalizer emitted a confirmation prompt. We blank the response
    /// so `ExecutionEngine`'s recovery ladder regenerates.
    /// Keep short — only match when these are essentially the WHOLE text.
    private static let placeholderOnlyPatterns: [NSRegularExpression] = {
        let raw = [
            #"^(?i:would you like me to (?:proceed|continue|summarize)[^\n]*)\s*\??$"#,
            #"^(?i:should i continue with the remaining steps[^\n]*)\s*\??$"#,
            #"^(?i:do you want me to (?:search|proceed|continue|summarize)[^\n]*)\s*\??$"#,
            #"^(?i:please confirm (?:if )?[^\n]*)\s*\??$"#,
            #"^(?i:is the task already complete)\s*[\?\.]*$"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Regexes that detect the base-model claiming to be a different
    /// product or being "made by" some other vendor. Each match triggers
    /// a full-response replacement with the canonical iClaw identity line.
    /// Designed to false-positive rarely: negations ("I am *not* Claude")
    /// are explicitly excluded via a negative lookbehind.
    private static let identityMisassertionPatterns: [NSRegularExpression] = {
        let raw = [
            // "Yes, I am Claude." / "I'm ChatGPT." / "I am GPT." —
            // affirmative identity claim naming a specific other product.
            // Requires no "not" between "I am" and the product name.
            #"(?i)\b(?:yes,?\s+)?i(?:'m|\s+am)(?!\s+not)\s+(?:the\s+)?(?:ChatGPT|Claude|Siri|Bard|Gemini|GPT-?\d*|Copilot)\b"#,
            // "I am a language model developed/created/made by OpenAI" —
            // or similar attributions to another vendor.
            #"(?i)\bi(?:'m|\s+am)(?:\s+an?)?\s+(?:AI\s+)?language\s+model(?:\s+developed|\s+created|\s+made|\s+built)?\s+by\s+(?:OpenAI|Anthropic|Google|Meta|DeepMind|Microsoft)\b"#,
            // "was developed by OpenAI" / "created by Anthropic" as a self-
            // description ("I was developed by...").
            #"(?i)\bi\s+was\s+(?:developed|created|made|built|trained)\s+by\s+(?:OpenAI|Anthropic|Google|Meta|DeepMind|Microsoft)\b"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Returns true if the text contains a base-model identity claim that
    /// contradicts the product's own identity (iClaw / Apple Foundation
    /// Models). Caller replaces the full response with the canonical line.
    static func isIdentityMisassertion(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in identityMisassertionPatterns {
            if pattern.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Returns true if the trimmed response is *only* a step-confirmation
    /// prompt — i.e., the tool/LLM punted on emitting a real answer.
    static func isPlaceholderOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only check short responses — real answers that happen to mention
        // "please confirm" mid-paragraph should NOT be stripped.
        guard trimmed.count < 200, !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for pattern in placeholderOnlyPatterns {
            if pattern.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Markers that indicate the on-device model echoed its system prompt.
    static let systemPromptMarkers = [
        "### SOUL / IDENTITY",
        "# Agent Soul",
        "**Personality Directives:**",
        "**Anti-Sycophant**",
        "4K context is for data, not fluff",
        "### KNOWLEDGE INGREDIENTS",
        "CRITICAL CONSTRAINTS:",
        "<soul>",
        "<ki>",
        "<req>",
        "<ctx>",
        "<brain>",
        "</brain>",
        "# Guidelines",
        "## Precedence",
        "# Rules",               // legacy name, still catch if it sneaks back
        "## Priority",           // legacy name
        "## Prompt-injection defense",
        "Recent exchange:",      // state-block leak
        "Active entities:",
        "Recent topics:",
        "respond to THIS message",
        "carries background from prior turns",
    ]

    static func containsSystemPromptLeak(_ text: String) -> Bool {
        systemPromptMarkers.contains { text.contains($0) }
    }

    /// Strips leaked system prompt sections and returns only user-facing content.
    static func stripSystemPromptContent(_ text: String) -> String {
        var result = text

        // Remove entire SOUL section if present (### SOUL header or # Agent Soul)
        for soulMarker in ["### SOUL", "# Agent Soul"] {
            if let soulStart = result.range(of: soulMarker) {
                let afterSoul = result[soulStart.upperBound...]
                if let nextSection = afterSoul.range(of: "###") {
                    result.removeSubrange(soulStart.lowerBound..<nextSection.lowerBound)
                } else {
                    result.removeSubrange(soulStart.lowerBound...)
                }
            }
        }

        // Remove personality directives block if leaked standalone
        if let dirStart = result.range(of: "**Personality Directives:**") {
            // Remove from directives to next blank line or end
            let after = result[dirStart.upperBound...]
            if let blankLine = after.range(of: "\n\n") {
                result.removeSubrange(dirStart.lowerBound..<blankLine.upperBound)
            } else {
                result.removeSubrange(dirStart.lowerBound...)
            }
        }

        // Remove KNOWLEDGE INGREDIENTS and INSTRUCTION sections
        for marker in ["### KNOWLEDGE INGREDIENTS", "### INSTRUCTION", "CRITICAL CONSTRAINTS:"] {
            if let range = result.range(of: marker) {
                if let nextSection = result[range.upperBound...].range(of: "###") {
                    result.removeSubrange(range.lowerBound..<nextSection.lowerBound)
                } else {
                    result.removeSubrange(range.lowerBound...)
                }
            }
        }

        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "I couldn't generate a proper response. Try rephrasing your request." : cleaned
    }

    // MARK: - Soft Refusal Detection

    /// Synchronous refusal check. Used only by `classifyFinalization` (in
    /// the recovery ladder, which runs synchronously per-tier). Async
    /// callers should use `isSoftRefusalLadder` which consults
    /// `ResponsePathologyClassifier` and `LLMJudge`.
    ///
    /// The list is intentionally *short and AI-trope-specific*: these
    /// phrases occur essentially only as AI safety boilerplate and almost
    /// never inside legitimate responses, in any language. The classifier
    /// catches the broader, multilingual surface — this list exists only
    /// because the recovery ladder can't await the classifier actor.
    func isSoftRefusal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        // AI-trope phrases that classifier-low-confidence cases must still
        // catch. These are *AI-product-vocabulary*, not general English —
        // they only appear in refusal contexts. The classifier handles
        // the broader, multilingual surface; this list is a safety net
        // for the 89% case the classifier misses, evaluated synchronously
        // by `classifyFinalization` in the recovery ladder.
        let aiRefusalBoilerplate = [
            "as a responsible ai",
            "as an ai language model",
            "as a large language model",
            "i am designed to ensure user safety",
            "violates the rules outlined",
            "cannot comply with your request",
            "cannot fulfill that request",
            "cannot fulfill this request",
            "unable to fulfill this request",
            "cannot help with that request",
            "i can't assist",
            "i cannot assist",
            "i'm sorry, but i can't",
            "i am sorry, but i can't",
            "i can't provide",
            "i cannot provide",
            "i can't respond",
            "i cannot respond",
        ]
        return aiRefusalBoilerplate.contains(where: { lowered.contains($0) })
    }

    /// Phase-5 wiring: a classifier-first refusal check. Runs the
    /// `ResponsePathologyClassifier` → `LLMJudge` ladder when the
    /// `useClassifierResponseCleaning` feature flag is on; falls back to
    /// the English phrase-list `isSoftRefusal` when the flag is off or
    /// the ladder can't resolve.
    ///
    /// Returns a plain Bool so callers don't have to branch on the ladder.
    /// Under the hood:
    ///   1. Classifier high-conf (≥0.85) refusal → true.
    ///   2. Classifier high-conf NON-refusal → false.
    ///   3. Classifier medium-conf (0.60–0.85) → consult `LLMJudge`. If judge
    ///      says `.refusal`, true; else false.
    ///   4. Classifier low-conf / nil (model missing) → fall through to
    ///      legacy `isSoftRefusal` phrase list.
    ///
    /// The `judgeResponder` parameter is for test injection. Production
    /// code leaves it `nil` so the shared `LLMAdapter` is used.
    func isSoftRefusalLadder(
        _ text: String,
        judgeResponder: SimpleLLMResponder? = nil
    ) async -> Bool {
        let start = ContinuousClock.now
        let flagOn = AppConfig.useClassifierResponseCleaning
        guard flagOn else {
            let legacy = isSoftRefusal(text)
            ClassifierTelemetry.recordLegacy(
                classifier: "pathology",
                label: legacy ? "refusal" : "ok",
                reason: "flag_off"
            )
            return legacy
        }

        guard let probe = await ResponsePathologyClassifier.shared.classify(text) else {
            let legacy = isSoftRefusal(text)
            ClassifierTelemetry.recordLegacy(
                classifier: "pathology",
                label: legacy ? "refusal" : "ok",
                reason: "model_missing"
            )
            return legacy
        }

        let legacyWouldSay = isSoftRefusal(text)
        let resolvedIsRefusal: Bool
        let via: String
        var judgeCalled = false

        switch probe.confidenceTier {
        case .high:
            resolvedIsRefusal = probe.label == .refusal
            via = "classifier"
        case .medium:
            let judgeFlagOn = AppConfig.useLLMJudge
            if judgeFlagOn {
                judgeCalled = true
                let judgeLabel = await LLMJudge.shared.judgePathology(
                    response: text,
                    classifierHint: probe,
                    responder: judgeResponder
                )
                resolvedIsRefusal = (judgeLabel ?? probe.label) == .refusal
                via = judgeLabel != nil ? "judge" : "classifier"
            } else {
                resolvedIsRefusal = probe.label == .refusal
                via = "classifier"
            }
        case .low:
            resolvedIsRefusal = isSoftRefusal(text)
            via = "legacy"
        }

        let elapsedMs = Int(start.duration(to: .now).components.seconds * 1000
                            + start.duration(to: .now).components.attoseconds / 1_000_000_000_000_000)
        ClassifierTelemetry.record(
            classifier: "pathology",
            label: probe.label.rawValue,
            confidence: probe.confidence,
            tier: String(describing: probe.confidenceTier),
            resolvedVia: via,
            judgeCalled: judgeCalled,
            latencyMs: elapsedMs,
            divergedFromLegacy: resolvedIsRefusal != legacyWouldSay
        )
        return resolvedIsRefusal
    }

    // MARK: - Skill Pre-Fetch Helpers

    /// Extracts non-parameterized HTTP(S) URLs from a skill instruction string.
    /// Reuses ToolRouter.urlDetector (NSDataDetector) for consistency with URL detection elsewhere.
    static func extractURLs(from text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = ToolRouter.urlDetector?.matches(in: text, options: [], range: range) ?? []
        return matches.compactMap { $0.url }.filter {
            ($0.scheme == "http" || $0.scheme == "https")
                // Skip parameterized URLs (e.g., {query}, {author}) — those need argument extraction
                && !$0.absoluteString.contains("{")
        }
    }

    /// Selects the most appropriate URL based on user input keywords.
    /// Falls back to the first URL if no keyword match is found.
    static func selectBestURL(from urls: [URL], for input: String) -> URL {
        let lower = input.lowercased()

        for url in urls {
            let path = url.path.lowercased()
            if path.contains("today") && (lower.contains("today") || lower.contains("of the day") || lower.contains("daily")) {
                return url
            }
        }

        return urls[0]
    }

}
