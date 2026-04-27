# Contributing to iClaw

Thank you for your interest in contributing to iClaw. This guide covers the essentials for getting started, writing code, and submitting changes.

## Getting Started

### Prerequisites

- macOS 26 or later
- Xcode 26 or later (Swift 6.2 toolchain)
- Apple Silicon Mac (required for on-device Foundation Models)

### Building

```bash
make build        # Debug build
make run          # Debug build + launch
make release      # Release build
make run-release  # Release build + launch
```

The build system is Swift Package Manager, wrapped by a Makefile that handles icon compilation, bundle assembly, entitlements signing, and resource copying.

### Running Tests

```bash
make test                                           # All tests
swift test --parallel                               # All tests in parallel
swift test --filter iClawTests.RouterTests          # Single test class
swift test --filter iClawTests.RouterTests/testName # Single test method
```

All tests are parallel-safe. Each test uses isolated instances with no shared singletons.

## Code Conventions

- **Swift 6.2 strict concurrency** -- all shared state lives in actors.
- **Sendable everywhere** -- data types crossing concurrency boundaries must be `Sendable`.
- **Zero warnings** -- builds must produce zero warnings in iClaw source code.
- **No `print()`** -- use `Log.*` (`os.Logger`) with categories.
- **No cloud AI calls** -- inference runs entirely on-device via Apple Foundation Models.
- **Constants in AppConfig** -- magic numbers and strings belong in `AppConfig`, not inline.
- **Config in JSON** -- keywords, patterns, and URLs go in `Resources/Config/*.json`, loaded via `ConfigLoader`.
- **Dependency injection for testing** -- online tools accept `URLSession` via init. Use protocol-based DI for any external dependency.

## Pull Request Process

1. **Fork** the repository and create a feature branch from `main`.
2. **Build** cleanly: `make build` must succeed with zero warnings.
3. **Test** thoroughly: `make test` must pass. Add or update tests for your changes.
4. **Write E2E tests** for new features in `PipelineE2ETests.swift` using `makeTestEngine()` and SpyTools.
5. **Test prompt robustness** with at least 10 natural-language prompts if your change affects routing or tool behavior.
6. **Submit** a pull request against `main` with a clear description and test plan.

## Developing Tools

iClaw has two tool families:

### Core Tools

Implement the `CoreTool` protocol with `execute(input:entities:) async throws -> ToolIO`.

1. Create your tool in `Sources/iClawCore/Tools/`.
2. Conform to `CoreTool` and set `consentPolicy` (`.safe`, `.requiresConsent(description:)`, or `.destructive(description:)`).
3. Register in `ToolRegistry.swift` by adding to the `coreTools` array.
4. Add an entry to `Resources/Config/ToolManifest.json` with icon, slots, prefixes, and chipName.
5. For structured argument extraction, conform to `ExtractableCoreTool` and add a schema to `Resources/Config/ToolSchemas/`.

### FM Tools

Implement `FMToolDescriptor` with a `makeTool()` factory returning an Apple `FoundationModels.Tool`.

1. Create your descriptor in `Sources/iClawCore/Tools/FM/`.
2. Register in `ToolRegistry.fmTools`.
3. Add an entry to `ToolManifest.json`.

### ML Routing

If your tool needs ML-based routing (not just chip or synonym matching):

1. Add training examples (~2000) to `MLTraining/training_data_compound.json`.
2. Add validation examples (~30) to `MLTraining/validation_data_compound.json`.
3. Add the label to `Resources/Config/LabelRegistry.json`.
4. For compound domains, add action rules to `Resources/Config/DomainRules.json`.
5. Retrain: `cd MLTraining && swift TrainClassifier.swift`
6. Add test cases to `MLClassifierTests.swift` (target >70% accuracy for new labels).

### Design Principles

- **Compute, don't delegate** -- tools must return computed results. The LLM personalizes phrasing only.
- **Widgets are self-contained** -- carry all data needed to render.
- **Respect the 4K token budget** -- every prompt component has a budget in `AppConfig`.

## Reporting Issues

Use the GitHub issue templates for bug reports and feature requests. For security vulnerabilities, see `SECURITY.md`.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
