# ML Training

MaxEnt CoreML classifiers powering iClaw's tool routing, follow-up detection,
toxicity, response pathology, conversational intent, and user-fact memory.

## Installed classifiers

Compiled models live in `Sources/iClawCore/Resources/`:

| Model | Labels | Examples | Val acc | Purpose |
|---|---|---|---|---|
| `ToolClassifier_MaxEnt_Merged.mlmodelc` | 45 compound | ~90K | — | Tool routing (`ToolRouter`) |
| `FollowUpClassifier_MaxEnt.mlmodelc` | 6 turn-relation | ~22K | — | Follow-up detection |
| `ToxicityClassifier_MaxEnt.mlmodel` | 2 | small | — | Toxicity gate |
| `ResponsePathologyClassifier_MaxEnt.mlmodelc` | 6 | 1,507 | 89% | Refusal / meta-leak / empty-stub detection |
| `ConversationIntentClassifier_MaxEnt.mlmodelc` | 5 | 10,787 | 86% | Intent: tool / knowledge / conversation / refinement / meta |
| `UserFactClassifier_MaxEnt.mlmodelc` | 7 | 2,696 | 81% | Life-fact persistence (name / age / dietary / family / location / work / preference) |

## Sample data layout

Each classifier has ONE consolidated source file (JSONL, one `{text, label}` per line):

| Source | Trainer config | Train / val output |
|---|---|---|
| `intent_data.jsonl` | `intent` | `intent_training.json` / `intent_validation.json` |
| `pathology_data.jsonl` | `pathology` | `pathology_training.json` / `pathology_validation.json` |
| `userfact_data.jsonl` | `userfact` | `userfact_training.json` / `userfact_validation.json` |
| `training_data_compound.json` (legacy schema) | `tool` | uses `validation_data_compound.json` directly |
| `followup_training.json` (legacy schema) | `followup` | uses `followup_validation.json` directly |
| `toxicity_training_data.json` (legacy schema) | `toxicity` | self-validated |

To grow a dataset, append new `{"text": "...", "label": "..."}` lines to the
corresponding `*_data.jsonl` file. Then run the matching merge script + trainer.

## Scripts

- `train_classifier.swift` — unified trainer. `xcrun swift train_classifier.swift tool|followup|toxicity|pathology|intent|userfact`
- `merge_intent_data.py` / `merge_pathology_data.py` / `merge_userfact_data.py` — read source `.jsonl`, dedupe, apply per-class caps + audit, stratified 85/15 split into the training/validation pair
- `add_language_prefix.swift` — prepends `[lang]` tag to each example using `NLLanguageRecognizer.dominantLanguage`. Run with `xcrun swift add_language_prefix.swift <intent|userfact>` and copy `*_lp.json` over the originals before training to enable language-conditioned features
- `audit_intent.py` — flags mislabeled / ambiguous / low-quality entries into `intent_audit.jsonl`; the merge script applies them automatically
- `GenerateFollowUpData.swift` — generator for follow-up training data from templates
- `ClassifierBenchmark.swift` — held-out-set accuracy benchmarks
- `benchmark_results/` — historical benchmark output
- `english_matching_audit.md` — Phase-0 audit of English heuristics replaced by the new classifiers
- `PHASE_2.5_RESULTS.md` — intent classifier iteration history (76% → 86% val-acc)

## Compound label format

Tool classifier labels use `domain.action`, e.g. `email.read`, `math.arithmetic`, `search.web`.

- **`Sources/iClawCore/Resources/Config/LabelRegistry.json`** — maps labels → tool names + type + `requiresConsent` flag
- **`Sources/iClawCore/Resources/Config/DomainRules.json`** — keyword signals for disambiguating within a domain (e.g. "check inbox" → `email.read`, "mortgage" → `math.arithmetic`, "miles to km" → `math.conversion`)
- **`DomainDisambiguator`** (in `Sources/iClawCore/Pipeline/`) — resolves ambiguous labels when the top-2 ML results share a domain

## Retraining the tool classifier

When adding a tool that needs ML-based routing:

1. Add ~2000 training examples to `training_data_compound.json` with a compound `domain.action` label.
2. Add ~30 validation examples to `validation_data_compound.json`.
3. Add the label to `Sources/iClawCore/Resources/Config/LabelRegistry.json` with tool name, type, and `requiresConsent`.
4. If the label is in a compound domain, add action rules to `Sources/iClawCore/Resources/Config/DomainRules.json`.
5. Train: `cd MLTraining && swift train_classifier.swift tool`
6. Compile: `xcrun coremlcompiler compile MLTraining/ToolClassifier_MaxEnt.mlmodel /tmp/mlmodel_output/`
7. Install: `cp -R /tmp/mlmodel_output/*.mlmodelc ../Sources/iClawCore/Resources/ToolClassifier_MaxEnt_Merged.mlmodelc`
8. Add 10 test cases to `Tests/iClawTests/MLClassifierTests.swift` using compound label names.
9. Verify: `swift test --filter MLClassifier` — overall >90%, new label >70%.

## Retraining the follow-up classifier

When modifying follow-up detection:

1. Edit templates in `GenerateFollowUpData.swift`.
2. Regenerate: `swift GenerateFollowUpData.swift`
3. Train: `swift train_classifier.swift followup`
4. Compile + install to `Sources/iClawCore/Resources/FollowUpClassifier_MaxEnt.mlmodelc`
5. Verify: `swift test --filter FollowUpClassifier` — overall ≥85%.

Six follow-up outcomes: `continuation`, `refinement`, `retry`, `drill_down`, `pivot`, `meta`.

## Retraining the toxicity classifier

```
swift train_classifier.swift toxicity
```

Install to `Sources/iClawCore/Resources/`.

## Benchmarks

```
swift ClassifierBenchmark.swift
```

Results land in `benchmark_results/`. Compare against the last run before landing a change.
