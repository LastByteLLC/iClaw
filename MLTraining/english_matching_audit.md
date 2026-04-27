# English-Matching Audit — `Sources/iClawCore/`

Produced by the Phase-0 audit agent. 80 findings across the codebase;
priority rollup: **42 high, 28 medium, 10 low**.

## Category counts

| Category | Count |
|---|---|
| `refusal_phrase_list` | 4 |
| `meta_leak_regex` | 8 |
| `intent_keyword` | 37 |
| `preference_detector` | 3 |
| `label_literal` | 3 |
| `tool_keyword` | 18 |
| `forbidden_output_list` | 7 |
| `sentence_structure_regex` | 6 |
| `other` | 4 |

## High-leverage clusters (for roadmap)

1. **Response cleaning / recovery** — densest English region (14 findings in
   `LLMResponseCleaning.swift`). `isSoftRefusal` phrase lists, leading-leak
   regex, name-echo regex. Any non-English refusal bypasses silently.
   Target for **Phase 1** (`ResponsePathologyClassifier` — currently
   training).

2. **Follow-up detection** (`PriorTurnContext.swift`, `FollowUpDetection.swift`)
   — English anaphora (`anaphoricMarkers`, `actionVerbs`,
   `followUpPhrases`, `referentialNouns`, `pivotVerbs`, `retryPhrases`,
   `ordinalMap`) AND `NLEmbedding.sentenceEmbedding(for: .english)`
   unconditionally. Target for **Phase 2** (Multilingual follow-up +
   anaphora head).

3. **Meta-query detection** (`ToolRouter+Helpers.swift` ≈line 389) —
   English seed phrases, English embedding, English self-referential
   pronouns. Target for Phase 2 or a dedicated meta-query classifier.

4. **Preference detection** (`PreferenceDetector.swift`) — partial
   multilingual coverage but hand-curated and duplicated in
   `mirrorPreferenceToUserDefaults`. Target for **Phase 3**
   (`UserFactClassifier`).

5. **Tool-internal intent gates** — per-tool `contains("direction")`,
   `contains("nearby")`, `contains("latest")`, etc. in
   `MapsTool_Core`, `PodcastTool`, `CalendarTool`, `TimeTool`,
   `RandomTool`, `CalculatorTool`, `IntentSplitter`, `SystemInfoTool`,
   `CommunicationChannelResolver`. Target for Phase 3/4 —
   per-domain classifiers OR centralized `ConversationIntentClassifier`.

6. **BRAIN forbidden-output lists** — duplicate the cleaning regex in
   prompt form. English-only; won't match translated equivalents.
   Phase 1 replaces this via classifier-gated output validation.

## Label-literal findings (keep, just structural)

These don't need classifier replacement — labels are engine-emitted, so
English matching is safe under language change:

- `toolAdvertisingRegex`, `identityLinesRegex` in `ExecutionEngine+Recovery.swift`
- `leadingLeakPatterns` entries for `Recent topics:`, `Active entities:`, etc.
- `fuzzyPatterns` list in `LLMResponseCleaning.swift`
- `metaPrefixes` in `IngredientFilter.swift`

Fix: centralize the label tokens behind a single `EngineEmittedLabel`
enum so rename can't desync the regex and the matcher.

## Recommendation order

1. **Phase 1 (in progress)**: `ResponsePathologyClassifier` replaces the
   14 findings in `LLMResponseCleaning.swift` + 6 forbidden-output lines
   in `BRAIN-conversational.md`.
2. **Phase 2**: `ConversationIntentClassifier` +
   multilingual `PriorTurnContext` (replace English anaphora / action verbs
   + swap `NLEmbedding.sentenceEmbedding(for: .english)` for a
   language-aware loader).
3. **Phase 3**: `UserFactClassifier` + BIO span extractor (replaces
   `PreferenceDetector` + scattered preference regex).
4. **Phase 4**: Per-tool intent cleanup — consolidate `contains()` gates
   into the central `ConversationIntentClassifier` with domain hint.

Total: 42 high-priority regexes can be replaced by 3–4 classifiers.
