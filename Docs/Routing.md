# ToolRouter Stage Order

The router is a sequential fallback ladder. Each stage is a filter: match → return; miss → continue to the next stage. Ordering is load-bearing — adding a new stage or re-ordering existing ones changes routing behavior for every input that passes through.

This document is the source of truth for which stage catches which class of input. Keep it in sync with `Sources/iClawCore/Pipeline/ToolRouter.swift::route(input:suppressedTools:)`.

## Design principles

1. **Explicit signals always win.** If the user typed `#weather`, `$AAPL`, or a URL, their intent is deterministic; no classifier gets a vote.
2. **Prior context is consulted before fresh classification.** Follow-up and attachment hints run early so that a short query like "in celsius" doesn't get re-classified from scratch.
3. **Content-pattern matching before ML.** Cheap regex/keyword checks (skills, encoding formats, tool help, meta-query) run before the ML classifier to preserve a latency budget on obvious inputs.
4. **ML is the default, not the fallback.** Stages 3-4 are the primary classification path; stages 5-6 exist only for inputs ML doesn't have an answer for.
5. **Conversational is the terminal fallback.** Every stage that chooses not to match is voting for "the LLM should just answer directly."

## Stage-by-stage contract

| # | Stage | Location (file:line) | Catches | Example input |
|---|---|---|---|---|
| -1 | Mode override | `ToolRouter.swift:296` | Active mode intercepts routing — the whole input goes to the mode's allowed tools. | User in Rubberduck mode types anything → stays in mode. |
| -1b | Mode chip activation | `ToolRouter.swift:310` (→ `checkModeChipActivation`) | A chip whose mode binding should take over the session (e.g. `#rubberduck`). Skipped if that chip is a direct tool name — `checkToolChips` handles it at stage 1. | `#rubberduck` (bare) → activate Rubberduck mode. |
| 0a | Attachment hint | `ToolRouter.swift:317` (→ `checkAttachmentHint`) | An `[Attached: path]` tag implies a file-aware tool. Routes to ReadFile / Transcribe / etc based on extension. | `[Attached: /tmp/foo.pdf] summarize` → ReadFile. |
| 0b | Follow-up detection | `ToolRouter.swift:323` (→ `checkFollowUp`) | Prior-turn context is being referenced (anaphora, action verb, short slot fill, entity overlap). Returns the prior tool with merged input. Gated by the linguistic-signal + entity-overlap check for 4+ word queries. | After `#weather Paris`: "in celsius" → Weather. |
| 1 | Tool chips | `ToolRouter.swift:330` (→ `checkToolChips`) | Explicit `#tool` handoff. | `#stocks AAPL` → StockTool. |
| 1a2 | `#remote` chip | `ToolRouter.swift:337` | Remote-device dispatch. Only compiled when `CONTINUITY_ENABLED`. | `#remote spotlight foo` → remote device. |
| 1b | Ticker symbols | `ToolRouter.swift:344` (→ `checkTickerSymbols`) | `$XYZ` where XYZ resolves via `TickerLookup`. Unknown tickers fall through (so `$FOOBAR` doesn't force Stocks). | `$AAPL price` → Stocks. |
| 1c | URLs | `ToolRouter.swift:350` (→ `checkURLs`) | HTTP/HTTPS URL with explicit scheme. Bare domains fall through. Every URL is routed to WebFetch regardless of surrounding text — if a user pastes a URL they want its content. | `summarize https://example.com` → WebFetch. |
| 1d | Mode entry phrase | `ToolRouter.swift:356` | Natural-language phrase that activates a mode (e.g. "let's rubberduck this"). Phrases live in `ToolManifest.json::modeConfig.entryPhrases`. | "let's rubberduck" → Rubberduck mode. |
| 2 | Skill (tiered) | `ToolRouter.swift:367` (→ `checkSkillExamples`) | Skill example coverage. ≥90% match wins immediately; 50–89% is kept as `tentativeSkill` and reconsidered at stage 4b if ML is inconclusive. See the comment at `ToolRouter.swift:363-365`. | "give me a quote on AMD" matches stock-quote skill at 67%; ML says Stocks → ML wins. |
| 2.5 | Encoding formats | `ToolRouter.swift:385` (→ `checkEncodingFormats`) | Format names (hex, base64, roman) or raw encoded data. Routes to ConvertTool. | "convert to base64" → ConvertTool. |
| 2a | Tool help query | `ToolRouter.swift:391` (→ `checkToolHelpQuery`) | "how do I use X", "what can the calculator do". | "weather help" → HelpTool with tool-context. |
| 2b | Meta-query | `ToolRouter.swift:400` (→ `isMetaQueryAsync`) | Questions about iClaw itself. Multilingual classifier ladder. | "what can you do?" → HelpTool. |
| 2c | Emoji-dominated input | `ToolRouter.swift:410` | Emoji-majority inputs are intentional actions, not pleasantries. Bypasses the short-input conversational filter. | "🎲🎲🎲" → ML → RandomTool. |
| 2d | Short non-actionable bypass | `ToolRouter.swift:418` | ≤2 words, no explicit signal, low ML confidence → conversational (prevents false-positive routing on greetings). | "hey" → conversational. |
| 2e | Synonym expansion | `ToolRouter.swift:442` | Canonicalizes input before ML — pure text transformation, never returns. | "forecast" → "weather forecast". |
| 3 | ML classifier | `ToolRouter.swift:445` (→ `classifyWithML`) | Trained MaxEnt model. Primary classification path. | "weather in Paris" → Weather (high confidence). |
| 4 | Confidence tier + verifier + heuristics | `ToolRouter.swift:449` (→ `evaluateMLResults`, `toolVerifier.verify`, `applyHeuristicOverrides`) | **HIGH (≥0.75)**: trust ML. **MEDIUM (0.35-0.75)**: LLM verifier validates. **LOW (<0.35)**: fall through. Heuristic overrides catch edge cases the ML model gets wrong on known input classes. | "how tall is Everest" (0.6 WikipediaSearch) → verifier confirms → WikipediaSearch. |
| 4a2 | Communication intent safety net | `ToolRouter.swift:527` (→ `CommunicationChannelResolver`) | ML resolution failed but the input has messaging intent — resolve to Messages/Email with confidence 0.5 so the protected-tool filter still arbitrates. | "email Shawn about Tuesday" after ML fails to resolve. |
| 4b | Tentative skill fallback | `ToolRouter.swift:558` | Accepts the 50-89% skill match stashed at stage 2, if ML returned nothing. | Skill matches at 67%, ML inconclusive → accept skill. |
| 5 | Short-query structural fallback | `ToolRouter.swift:573` | ≤10 words with no ML match → conversational. Cheap short-circuit before the LLM fallback. | "tell me a joke" → conversational. |
| 5b | LLM fallback | `ToolRouter.swift:581` (→ `llmFallback`) | Long ambiguous query where the LLM call is justified. Returns at confidence 0.6 (below bypass threshold). | Long, evidence-poor query. |
| 6 | Conversational terminal | `ToolRouter.swift:589` | Nothing matched. The LLM will answer directly. | anything remaining. |

## Invariants

- Every explicit-signal stage (chips, tickers, URLs) sets `lastRouteConfidence = 1.0`.
- Every fallback-ish stage (communication safety net, LLM fallback, tentative skill) sets confidence below `AppConfig.routeHighConfidenceThreshold` (0.70) so the engine's protected-tool filter can still arbitrate.
- `lastDetectedTurnRelation` is set only by `checkFollowUp` (stage 0b). Downstream stages that override a follow-up set it to `nil` explicitly, which signals "pivot; do not inherit prior tool context" to `ExecutionEngine`.
- Mode activation (stages -1b and 1d) share the same downstream path: `activateMode` → `routeWithinMode`. If the two sites ever diverge, extract a helper.

## Tiered skill pattern (stages 2 + 4b)

This is **not** a duplicate stage. Stage 2 finds the best skill match and records its coverage. If the coverage is overwhelming (≥90%), it returns the skill immediately — the user's phrasing overlaps a canonical skill example too closely to doubt.

If the coverage is partial (50–89%), the match is saved as `tentativeSkill` and the router continues to ML. This gives ML a chance to overrule an ambiguous skill match when it has domain evidence the skill system doesn't see. If ML also fails to return a decision, stage 4b accepts the saved skill as the best available signal.

Collapsing stages 2 and 4b into a single "accept any skill match" call would regress inputs like "give me a quote on AMD" (partial stock-quote skill match, but ML correctly routes to Stocks).

## When you add a stage

- Document it here with file:line and a concrete example.
- Decide where it goes in the confidence hierarchy (explicit > context > pattern > ML > fallback).
- Add a unit test in `EndToEndRoutingTests` or `ExplicitRoutingTests` covering the positive case and at least one negative case (input that should NOT trigger it).
- If the stage sets `lastRouteConfidence`, pick a value consistent with the invariants above.
