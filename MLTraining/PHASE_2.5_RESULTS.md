# Phase 2.5 — Intent Classifier Iterations

## TL;DR
Initial Phase 2 trained the 5-class intent classifier at **0.793 val-acc**.
Phase 2.5-v1 tried six configurations and plateaued at the same number due
to data volume + MaxEnt feature limits. Phase 2.5-v2 expanded the dataset
3.7× (2,885 → 10,787 examples), added an audit pass that relabeled 212
noisy mined examples, and reached **0.862 val-acc** — crossing the 0.85
target. v2 is the committed model.

## Phase 2.5-v2 (committed)

| Setting | Value |
|---|---|
| Total examples (post-dedupe + audit) | **10,787** |
| Per-class | tool_action 2,500, conv 2,358, meta 2,034, knowledge 2,010, refinement 1,885 |
| Train/val split | 85/15 stratified (9,167 / 1,620) |
| Feature preprocessing | `[lang]` prefix via `NLLanguageRecognizer.dominantLanguage` |
| Audit | 212 records flagged in `intent_data_c.jsonl`; 115 dropped, 97 relabeled |
| Caps | All classes capped at 2,500 |
| Model | MaxEnt (CreateML default), 247 KB |
| **Val acc** | **86.23%** |

### Per-class F1 (v2)

| Class | Precision | Recall | F1 | Support |
|---|---|---|---|---|
| conversation | 0.823 | 0.763 | 0.792 | 354 |
| knowledge | 0.917 | 0.921 | **0.919** | 302 |
| meta | 0.869 | 0.908 | 0.888 | 306 |
| refinement | 0.854 | 0.890 | 0.872 | 283 |
| tool_action | 0.853 | 0.851 | 0.852 | 375 |

## Iteration history (Phase 2.5-v1, kept for reference)

| # | Change | Val acc | Δ |
|---|---|---|---|
| 0 | Baseline (Phase 2 original) | 76.76% | — |
| 1 | Cap tool_action at 500 | 76.30% | −0.5 |
| 2 | + 450 hard-negative boundary examples | 78.18% | +1.9 |
| 3 | + 500 conversation-vs-meta disambiguators | 78.39% | +0.2 |
| 4 | Cap all classes at 500 | 77.17% | −1.2 (reverted) |
| 5 | **Add `[lang]` prefix features** | **79.31%** | **+0.9** ← v1 best |
| 6 | Cap conversation at 600 | 78.97% | −0.3 (reverted) |

## Phase 2.5-v2 deltas vs v1

| Metric | v1 | v2 | Δ |
|---|---|---|---|
| Val acc | 79.31% | 86.23% | +6.92 |
| Conversation F1 | 0.767 | 0.792 | +0.025 |
| Knowledge F1 | 0.797 | 0.919 | +0.122 |
| Meta F1 | 0.873 | 0.888 | +0.015 |
| Refinement F1 | 0.770 | 0.872 | +0.102 |
| Tool_action F1 | 0.770 | 0.852 | +0.082 |

## Production wiring (Phase 5+)

The classifier is now wired into the engine via flag-gated code paths.
Per-call dispatch:
- `≥0.85` confidence → act on classifier label.
- `0.60–0.85` → consult `LLMJudge` (one-word LLM second opinion, cached LRU).
- `<0.60` → fall through to legacy English heuristics (preserved as
  low-confidence fallback inside `isMetaQueryAsync` and
  `isSoftRefusalLadder`).

In the current build the four feature flags (`useClassifierResponseCleaning`,
`useClassifierIntentRouting`, `useClassifierUserFacts`, `useLLMJudge`)
are compile-time constants set to `true`, not runtime UserDefaults.

## End-to-end probe metrics (Cycles 6-10, 176 turns)

| State | Refusal | Meta-leak | Tom leak | Timeouts |
|---|---|---|---|---|
| Baseline (pre-Phase-5) | 14.8% | 5.7% | 4 | 5 |
| v1 model (flagged-on) | 0.6% | 0.6% | 0 | 5 |
| **v2 model (default ON)** | **0.0%** | **0.0%** | **0** | **5** |

## Artifacts (Phase 2.5-v2)

- `MLTraining/intent_data_{a,b,c,d,e,f,g,h,i,j}.jsonl` — 10,827 raw examples
  - a/b/c — original Phase 2 synthetic + mined
  - d/e — Phase 2.5-v1 hard negatives + boundaries
  - f/g/h/i/j — Phase 2.5-v2 expansion (1,500 each: tool_action / knowledge /
    conversation / refinement / meta)
- `MLTraining/intent_audit.jsonl` — 212 mislabel flags
- `MLTraining/merge_intent_data.py` — audit-aware merge with drop + relabel
- `MLTraining/ConversationIntentClassifier_MaxEnt.mlmodel` — v2 model
- `Sources/iClawCore/Resources/ConversationIntentClassifier_MaxEnt.mlmodelc` — installed
- `MLTraining/add_language_prefix.swift` — generic `[lang]` prefix injector
- `MLTraining/audit_intent.py` — audit script (preserved for re-runs)

## Levers remaining

1. **+1-2%** — Re-mine `intent_data_c.jsonl` from a cleaner source (the
   audit handled 212 entries but new noise will recur if the source is
   re-mined).
2. **+1-2%** — Hand-curate a fixed val set (currently stratified-random;
   per-class support varies 283–375).
3. **+4-8%** — Replace MaxEnt with a multilingual sentence transformer
   (LaBSE / MiniLM-L6). Only worth doing if telemetry shows the classifier
   is the production bottleneck.
4. **Apply same audit + expansion** to `FollowUpClassifier_MaxEnt.mlmodelc`
   and `ToolClassifier_MaxEnt_Merged.mlmodelc` — neither has been audited
   yet; both likely carry mined-data noise.
