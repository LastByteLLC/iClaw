# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project Overview

iClaw is a native macOS 26+ AI agent that runs entirely on-device using Apple Foundation Models. Menu bar "Liquid Glass" HUD, GRDB persistence, NLEmbedding vector memory. Operates within a strict **4K token context window** (budget defined in `AppConfig.swift`).

## Build & Run

```bash
make build        # Debug build → .build/arm64-apple-macosx/debug/iClaw.app
make run          # Debug build + open
make release      # Release build
make dmg          # Distributable DMG
make mas          # MAS .pkg (uses iClaw-MAS.entitlements)
make cli          # Headless CLI daemon → .build/debug/iClawCLI
make test         # All tests (parallel, 60s timeout enforced)
make clean
```

**CLI Daemon (headless iClaw):** Runs the full ExecutionEngine pipeline with no GUI, reading JSON commands from stdin. See `Scripts/iclaw-daemon.py` for usage; protocol is documented in `Sources/iClawCLI/main.swift`.

**Tests:**
```bash
swift test --parallel                               # All parallel-safe
swift test --filter iClawTests.RouterTests          # Single class
swift test --filter iClawTests.RouterTests/testName # Single method
```

## Architecture

### Execution Pipeline (ExecutionEngine.swift)

Three paths based on ML classifier confidence:
- **≥0.90** → fast path (single tool)
- **0.35–0.90** → planning path (`@Generable` plan decomposition)
- **<0.35** → agent path (multi-turn reasoning)

FSM states: `idle → preprocessing → routing → [planning] → toolExecution → finalization → idle`. Core stages: `InputPreprocessor` (NER + spellcheck + translation), `ToolRouter` (multi-stage fallback), `ToolArgumentExtractor` (for `ExtractableCoreTool`), tool execution (max 4 per turn), ReAct ingredient validation, `OutputFinalizer` (SOUL + ingredients), optional widget layout generation.

**Context protection:** On pivot turns the engine uses `minimalContext()` to prevent stale data from dominating the LLM response.

**Error handling:** Tool errors are compact `[ERROR]` tags in ingredients. Failed turns only bump the turn counter — they don't record topics/data.

### Agent Architecture (Agent/)

Multi-step reasoning for complex queries while preserving the fast path. Key files: `AgentPlan.swift`, `AgentRunner.swift`, `ToolDomain.swift`, `Fact.swift`, `ProgressiveMemory.swift`, `Guardrail.swift`, `AgentDecision.swift`, `KnowledgeExtraction.swift`, `ToolVerifier.swift`. Tools are grouped into 8 semantic domains (AFM handles 3-8 tools well; 15+ causes selection failures). Decisions use `@Generable` types instead of hardcoded English phrase lists.

### Tool System

Two families:
- **Core Tools** (`Tools/CoreToolProtocol.swift`) — `execute(input:entities:) async throws -> ToolIO`. Registered in `ToolRegistry.coreTools`.
- **FM Tools** (`Tools/FM/FMToolDescriptors.swift`) — Apple `FoundationModels.Tool` called by the LLM directly.

Both carry an `ActionConsentPolicy` (`.safe`, `.requiresConsent`, `.destructive`).

**ExtractableCoreTool** — optional protocol for schema-driven argument extraction via `ToolArgumentExtractor`. Chips bypass extraction.

Tool categories, chip aliases, and NL-only tools are defined in `ToolCategory.swift` and `ToolManifest.json`.

### Tool Routing (ToolRouter.swift)

Multi-stage fallback actor. Order: attachment hint → follow-up detection → chips → ticker symbols → URLs → skills → synonyms → ML classifier → heuristic overrides → LLM fallback → conversational. See `ToolRouter.swift` header for stage details.

**Compound Labels:** ML labels use `domain.action` format. `LabelRegistry.json` maps labels → tools; `DomainRules.json` disambiguates within a domain; `DomainDisambiguator` resolves ambiguous top-2 results.

### Follow-Up Detection

Three-layer pipeline in `ToolRouter.checkFollowUp()`: slot-based (`ToolSlotRegistry`) → ML classifier (`FollowUpClassifier`, 6 outcomes) → NLP heuristics (`PriorTurnContext`). Context Pill UI anchors follow-up intent; tap boosts confidence threshold.

### Conversation Memory (ConversationManager.swift)

Three tiers: working facts (5 slots, ~50 tokens) → running summary (~80 tokens, incremental LLM fold) → vector archive (NLEmbedding cosine similarity). `ConversationState` is engine-managed — no LLM-generated state blobs.

### Subsystem pointers

- **Personality** — `SoulProvider.current` is the single source of truth. Never load `SOUL.md` directly.
- **Web Fetch** — `FetchBackend` protocol with three layers: `HTTPFetchBackend` (known APIs), `BrowserFetchBackend` (WKWebView), `BrowserBridgeFetchBackend` (browser extension via TLS localhost:19284). `ContentCompactor` cleans fetched text.
- **Browser Extension** — see `Extension/README.md` and `BrowserBridge.swift` header. Safari uses `sendNativeMessage` through `SafariWebExtensionHandler`; Chrome/Firefox use persistent `connectNative` through `iClawNativeHost`.
- **MAS Build** — `-DMAS_BUILD` flag switches AppleScript tools to native APIs. See `#if MAS_BUILD` branches; AutomateTool and ReadEmailTool are DMG-only.
- **Dynamic Widgets** — `WidgetLayoutGenerator` produces a `<dw>` DSL block via a second LLM call. Token budget gate at 2500; quality filter rejects thin widgets.
- **LaTeX Rendering** — `LaTeXDetector` + `LaTeXView` (SwiftMath) + `RichMathText`. CalculatorTool emits LaTeX for formulas.
- **ReAct Validation** — domain keywords (`ToolDomainKeywords.json`) → entity overlap → LLM validation → corrective re-routing (max 1 retry).
- **Skills** — `SkillLoader`/`SkillParser` reads `~/Documents/AgentSkills`. Sandboxed to HTTP Fetch. Built-ins in `Resources/Skills/`.
- **Continuity** — currently disabled (`ContinuityManager.isEnabled = false`). Code preserved for future activation.
- **ML Retraining** — see `MLTraining/README.md` for both classifiers (tool + follow-up).
- **CI/CD** — `.github/workflows/release.yml` on `macos-26`. Always run `actionlint` after edits.

## Tool Design Principles

- **Compute, don't delegate math to the LLM** — tools return computed results; the LLM only personalizes phrasing.
- **Route correctly** — add synonym expansions in `SynonymMap.json`. No regex intent classifiers inside tools.
- **Always compute fully** — don't return raw data for the LLM to process.
- **Use `InputParsingUtilities.extractLocation`** — no custom regex parsers per tool.
- **Widget data must be self-contained** — carry timezone identifiers, not offsets.
- **Multi-intent tools** use `ExtractableCoreTool` for schema-driven extraction.

### Widget Design

- **Monochrome SF Symbols** — `.symbolRenderingMode(.monochrome)` with `.foregroundStyle(.primary)`. Color only for semantic signals.
- **System locale** — use `DateFormatter.timeStyle`/`dateStyle`, never hardcoded format strings.
- **"Today" for today** — show "Today" for current date, localized `.medium` otherwise.
- **Real location names** — resolve via `resolveLocation(city: nil)`. No "your location" placeholders.
- **Copy affordance** — discrete values need copy-to-clipboard.
- **Data-driven visibility** — `showsInUI` in `ToolManifest.json` controls chip/pill visibility.

## SwiftUI Regression Prevention

Violations are bugs — fix before considering work complete.

**Deprecated APIs — never introduce:**
- `.foregroundStyle()` not `.foregroundColor()`
- `.clipShape(.rect(cornerRadius:))` not `.cornerRadius()`
- `.ignoresSafeArea()` not `.edgesIgnoringSafeArea()`
- `NavigationStack` / `NavigationSplitView` not `NavigationView`
- `.confirmationDialog()` not `.actionSheet()`

**Rules:**
- **Availability gating** — new APIs must be `if #available` with a fallback.
- **ForEach identity** — use `Identifiable` or explicit stable `id:`. Never `ForEach(indices, id: \.self)` for dynamic content.
- **Accessibility on tappable views** — bare `onTapGesture` must have `.accessibilityAddTraits(.isButton)` + `.accessibilityLabel`, or use `Button`.
- **State hygiene** — `@State`/`@StateObject` must be `private`; never for passed-in values. `.animation(_:value:)` must include `value`.
- **View identity stability** — avoid conditional modifiers that change the view's type (e.g., custom `.if()` wrappers).

## Conventions

- **Swift 6.2 strict concurrency** — shared state lives in actors. `Sendable` everywhere.
- **No cloud AI** — inference is on-device. External network is for tool execution and Continuity only.
- **Token-conscious** — every prompt component has a budget in `AppConfig`.
- **Personality via `SoulProvider.current`** — never load `SOUL.md` directly.
- **DI for testing** — online tools accept `URLSession` via init; `ToolArgumentExtractor` accepts `ExtractorLLMResponder`; WebFetch/WebSearch accept `FetchBackend`.
- **Zero warnings** — builds must produce zero warnings. Run `swift build 2>&1 | grep "warning:"` as a final check. **A task is NOT finished if there are warnings.**
- **No SFSpeechRecognizer** — use `SpeechTranscriber` + `SpeechAnalyzer`.
- **ObjC exception safety** — wrap Foundation APIs that may throw `NSException` with `ObjCTryCatch`.
- **Separate code from content** — keywords, patterns, URLs go in `Resources/Config/*.json` via `ConfigLoader`.
- **Logging** — use `Log.*` (`os.Logger`) with categories. Never `print()`.
- **Constants** — magic numbers/strings go in `AppConfig`.
- **Ignore transient SourceKit errors** — LSP diagnostics matching "Internal SourceKit error" or "Loading the standard library failed" are false positives. Do not mention or act on them.
- **Accessibility required** — every interactive element needs `.accessibilityLabel`. Use `.accessibilityElement(children: .combine)` for composite rows, `.accessibilityHidden(true)` for decorative content, `.accessibilityAddTraits(.isModal)` for blocking overlays. Check `accessibilityReduceMotion` before continuous animations. Use semantic fonts (`.body`, `.headline`) or `TextSizePreference.scaleFactor`. Minimum 44x44pt tap targets.

## Testing Workflow

**Every new feature or change MUST be validated with E2E tests before completion.**

1. **Build**: `make build` — must compile cleanly, zero warnings
2. **Existing tests**: `make test` — all must pass within the 60-second timeout
3. **E2E pipeline test**: Write/update test in `PipelineE2ETests.swift` using `makeTestEngine()` and SpyTools
4. **Prompt robustness**: Test minimum **10 natural-language prompts** per tool/skill (chips, natural language, edge cases, ambiguous prompts)

**A timeout is a test failure** — investigate and fix the root cause, never just raise the limit.

**Handling test failures:** Always resolve failures introduced by your changes. Run the full suite and compare against the baseline — do not increase the failure count. If ambiguous, investigate via `git stash` or a worktree at the prior commit. If structural, flag it to the user before updating tests or reverting the change. Never leave new regressions unaddressed.

**Test capabilities:** Tests requiring Apple Intelligence/speech/location use `TestRequirements` — `try require(.appleIntelligence)` (XCTest) or `.requires(.appleIntelligence)` trait (Swift Testing).

**Key helpers:** `Tests/iClawTests/TestHelpers/E2ETestHelpers.swift` (SpyTool, FailingTool, `makeTestEngine()`, LLM stubs) and `TestRequirements.swift`.

### Preventing test hangs

The full suite must complete in <60 seconds. Core rules:

- **Always use `makeTestEngine()`** instead of constructing `ExecutionEngine` directly — it wires stub LLM responders, injects a test `LLMAdapter`, and installs mock location.
- **If calling tools directly** (not through `makeTestEngine()`), call `TestLocationSetup.install()` in `setUp()`, or `CLLocationManager` will hang.
- **Always provide `llmResponder`** when creating `ToolRouter` directly, or routing stage 5b will hit real Apple Intelligence. Use `makeStubRouterLLMResponder()`.
- **Reuse engines** across prompt loops — each new engine reloads 2 CoreML models.
- **Use `router.route()` for routing coverage** (fast) and only 1–2 full `engine.run()` calls for E2E validation.
- **Use chips for deterministic routing** — ML + follow-up detection are non-deterministic. Prefer `#weather`/`#calculator` or stub the router LLM.
- **Use ordinal references** ("the first article") for follow-up tests — keyword-based follow-up is classifier-dependent.
- **Stub `FeedbackTool`** — `FeedbackTool(llmResponder: nil)` falls back to `LLMAdapter.shared`.
- **Avoid `ScratchpadCache` collisions** — unique inputs (e.g., UUID prefix) for invocation-count asserts.
- **Never test against `.shared` singletons** — use `DatabaseManager(inMemory: true)`. Gate real-LLM tests with `.requires(.appleIntelligence)`.

## Localization

Strings extracted to `Sources/iClawCore/Resources/en.lproj/Localizable.strings` (+ `.stringsdict` for plurals). `Package.swift` declares `defaultLocalization: "en"`.

**What to localize:**
- SwiftUI view text (`Text()`, `Button()`, `Label()`, `Section()` auto-resolve)
- Non-SwiftUI string contexts (`.accessibilityLabel()`, `.help()`, AppKit APIs) — use `String(localized: "key", bundle: .iClawCore)`
- Plurals via `.stringsdict` and `String(format: String(localized: "key", bundle: .iClawCore), count)`

**What NOT to localize:**
- LLM prompts (BRAIN.md, SOUL.md, OutputFinalizer, Personalizer)
- `ToolIO.text` (rephrased by the LLM via Personalizer)
- Log messages, JSON/config keys, ML labels, tool names, enum raw values
- NLP routing data (SynonymMap.json, DomainRules.json)

## Out of Scope

**MCP (Model Context Protocol)** — evaluated and rejected: no auto-discovery, 4K token budget strain, existing Skill system covers the use case.
