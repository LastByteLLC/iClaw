# iClaw Token Budget

iClaw operates within a strict **4,000 token** context window (Apple Foundation Models on-device). Every prompt component has an explicit budget.

## Brain-Body-Soul Architecture

The prompt identity is split into three files, each serving a distinct purpose:

| Layer | File | Budget | Purpose |
|---|---|---|---|
| **Brain** | `Resources/BRAIN.md` | 100 tokens | Operational rules: data integrity, output constraints, tool usage |
| **Soul** | `Resources/SOUL.md` | 80 tokens | Personality: tone, style, behavioral traits |
| **User** | `UserProfileProvider` | 40 tokens | Persistent user context: name, preferences, usage patterns |

**Why separate them?**
- **Brain** is universal — every agent needs rules about hallucination, output format, and data handling. These rules were previously scattered across 12+ inline prompt strings in OutputFinalizer, ModelManager, and ExecutionEngine.
- **Soul** is configurable — users choose full/moderate/neutral/custom personality via Settings.
- **User** is learned — built deterministically from MeCardManager (identity), UserProfileManager (tool frequency, entity frequency), and ConversationState (detected preferences like unit system).

## Full Budget Breakdown

| Component | Tokens | Source |
|---|---|---|
| Brain (rules) | 100 | `BrainProvider.current` |
| Soul (personality) | 80 | `SoulProvider.current` |
| User (profile) | 40 | `UserProfileProvider.current()` |
| Conversation state | 400 | `ConversationState.asPromptContext()` |
| Tool schemas (FM, max 3) | 600 | Apple FoundationModels tool definitions |
| Retrieved data / ingredients | 2,000 | Tool results, recalled memories |
| Generation space | 780 | LLM output budget |
| **Total** | **4,000** | |

## Adaptive Budget

Not every turn uses all components. `AppConfig.TurnBudget` computes the actual cost of identity + state + schemas, and releases unused tokens to `availableForData`. A turn with no FM tools and minimal state might have 2,500+ tokens available for data.

## Token Estimation

`AppConfig.estimateTokens(for:)` uses the 4-chars-per-token heuristic. This is conservative for English text with Apple's tokenizer.

## Prompt Assembly

The final prompt sent to the LLM at finalization:

```
<brain>{BRAIN.md rules + FM override if applicable}</brain>
<soul>{SOUL.md personality}</soul>
<user>{UserProfileProvider context}</user>
<ctx>{Conversation state + compacted summary}</ctx>
<req>{User's request}</req>
<ki>
- {ingredient 1}
- {ingredient 2}
</ki>
```

Task-specific LLM calls (tool routing, argument extraction, widget layout, translation, greeting) use their own isolated prompts and do NOT inject Brain/Soul/User — they have dedicated role instructions.
