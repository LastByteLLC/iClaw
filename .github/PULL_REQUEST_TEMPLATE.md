## Summary

<!-- Describe what this PR does and why. Link any related issues. -->

## Test Plan

<!-- Describe how you tested these changes. Include specific test commands and prompt examples if applicable. -->

- [ ] Tested with `make build` (zero warnings)
- [ ] Tested with `make test` (all tests pass)
- [ ] Added/updated E2E tests in `PipelineE2ETests.swift` (if applicable)
- [ ] Tested with at least 10 natural-language prompts (if tool/routing changes)

## Checklist

- [ ] Code builds cleanly with zero warnings
- [ ] All existing tests pass
- [ ] New tests added for new functionality
- [ ] Swift 6.2 strict concurrency rules followed (actors for shared state, Sendable types)
- [ ] No `print()` statements (use `Log.*` instead)
- [ ] Constants added to `AppConfig` (no magic numbers/strings)
- [ ] Config data in `Resources/Config/*.json` (no hardcoded keywords/patterns)
- [ ] Tool registered in `ToolRegistry` and `ToolManifest.json` (if adding a tool)
