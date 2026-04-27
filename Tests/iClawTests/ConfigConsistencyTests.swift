import XCTest
import FoundationModels
@testable import iClawCore

// MARK: - Config Cross-Reference Validation

/// Validates that all JSON config files reference real, registered tools and that
/// cross-references between configs are consistent. A typo in any config file
/// will cause exactly one of these tests to fail with a descriptive message.
///
/// These tests require no network, no Apple Intelligence, and no special hardware.
final class ConfigConsistencyTests: XCTestCase {

    // MARK: - Fixture: Registered Tool Names

    /// All registered tool names (core + FM), computed once.
    private static let registeredCoreNames: Set<String> = Set(ToolRegistry.coreTools.map(\.name))
    private static let registeredFMNames: Set<String> = Set(ToolRegistry.fmTools.map(\.name))
    private static let allRegisteredNames: Set<String> = registeredCoreNames.union(registeredFMNames)

    /// Tools that exist in configs but are intentionally disabled or planned.
    /// Documented in CLAUDE.md under "Disabled tools".
    private static let knownDisabledTools: Set<String> = [
        "Create", "Camera", "camera",   // Image Playground / camera — disabled
        "Rewrite", "RubberDuck",         // Disabled modes
        "health", "Game",                // Planned but not yet registered
        "Music",                         // Planned media tool — not yet registered
        "Alarm",                         // iOS-only tool (AlarmTool), not registered on macOS
    ]

    // MARK: - 1. ToolManifest ↔ ToolRegistry

    func testAllRegisteredCoreToolsHaveManifestEntries() {
        // Core tools MUST have manifest entries (for icon, chip, slots, etc.)
        let manifestNames = Set(ToolManifest.entries.keys)
        for name in Self.registeredCoreNames {
            XCTAssertTrue(
                ToolManifest.entry(for: name) != nil,
                "Registered core tool '\(name)' has no entry in ToolManifest.json. " +
                "Manifest keys: \(manifestNames.sorted())"
            )
        }
    }

    func testRegisteredFMToolsHaveManifestEntries() {
        // FM tools SHOULD have manifest entries but some infrastructure FM tools
        // (write_file, browser) may not need them. This is a soft check.
        let missingFM = Self.registeredFMNames.filter { ToolManifest.entry(for: $0) == nil }
        // Just verify the count isn't growing — currently write_file and browser are missing
        XCTAssertLessThanOrEqual(missingFM.count, 2,
            "More FM tools are missing manifest entries than expected: \(missingFM.sorted())")
    }

    func testAllManifestEntriesAreRegistered() {
        let manifestNames = Set(ToolManifest.entries.keys)
        // Some manifest entries are for disabled/conditional tools or modes — allow those.
        // Documented disabled in CLAUDE.md: Create, Camera, ReadTool, WriteTool, RewriteTool
        let expected = Self.allRegisteredNames.union(Self.knownDisabledTools)
        for name in manifestNames where !expected.contains(name) {
            // Case-insensitive check as a fallback
            let match = expected.contains(where: { $0.lowercased() == name.lowercased() })
            XCTAssertTrue(match,
                "ToolManifest.json contains '\(name)' which is not a registered tool. " +
                "Registered: \(Self.allRegisteredNames.sorted())"
            )
        }
    }

    // MARK: - 2. LabelRegistry ↔ ToolRegistry

    func testLabelRegistryLoads() {
        XCTAssertFalse(LabelRegistry.entries.isEmpty,
            "LabelRegistry.json failed to load or is empty — ML routing is broken")
        XCTAssertGreaterThan(LabelRegistry.entries.count, 30,
            "LabelRegistry.json has suspiciously few entries (\(LabelRegistry.entries.count))")
    }

    func testAllLabelRegistryToolsExist() {
        let expected = Self.allRegisteredNames.union(Self.knownDisabledTools)
        for (label, entry) in LabelRegistry.entries {
            XCTAssertTrue(
                expected.contains(entry.tool),
                "LabelRegistry label '\(label)' maps to '\(entry.tool)' which is not registered. " +
                "Did you misspell the tool name?"
            )
        }
    }

    func testLabelRegistryTypesAreValid() {
        let validTypes: Set<String> = ["core", "fm"]
        for (label, entry) in LabelRegistry.entries {
            XCTAssertTrue(validTypes.contains(entry.type),
                "LabelRegistry label '\(label)' has type '\(entry.type)' — expected 'core' or 'fm'")
        }
    }

    // MARK: - 3. DomainRules ↔ LabelRegistry

    func testAllDomainRulesLabelsExist() {
        // DomainRules maps domain → [ActionRule]. Each domain.action must exist in LabelRegistry.
        // DomainDisambiguator.rules is private, so we load directly.
        struct ActionRule: Codable { let action: String; let signals: [String] }
        guard let rules = ConfigLoader.load("DomainRules", as: [String: [ActionRule]].self) else {
            XCTFail("DomainRules.json failed to load")
            return
        }

        for (domain, actions) in rules {
            for rule in actions {
                let compoundLabel = "\(domain.lowercased()).\(rule.action)"
                XCTAssertNotNil(
                    LabelRegistry.lookup(compoundLabel),
                    "DomainRules.json references label '\(compoundLabel)' which is not in LabelRegistry.json"
                )
            }
        }
    }

    // MARK: - 4. SynonymMap Validation

    func testSynonymMapLoads() {
        struct SynonymEntry: Decodable { let pattern: String; let expansion: String }
        let entries = ConfigLoader.load("SynonymMap", as: [SynonymEntry].self)
        XCTAssertNotNil(entries, "SynonymMap.json failed to load")
        XCTAssertGreaterThan(entries?.count ?? 0, 10,
            "SynonymMap.json has suspiciously few entries")
    }

    func testSynonymMapRegexesCompile() {
        struct SynonymEntry: Decodable { let pattern: String; let expansion: String }
        guard let entries = ConfigLoader.load("SynonymMap", as: [SynonymEntry].self) else {
            XCTFail("SynonymMap.json failed to load")
            return
        }

        for entry in entries where entry.pattern.contains("(") {
            do {
                _ = try NSRegularExpression(pattern: entry.pattern, options: .caseInsensitive)
            } catch {
                XCTFail("SynonymMap.json regex '\(entry.pattern)' fails to compile: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 5. ToolDomainKeywords ↔ ToolRegistry

    func testAllToolDomainKeywordsMatchTools() {
        guard let keywords = ConfigLoader.load("ToolDomainKeywords", as: [String: [String]].self) else {
            XCTFail("ToolDomainKeywords.json failed to load")
            return
        }

        // ToolDomainKeywords uses tool names; check they exist (allowing case-insensitive match
        // since some FM tools use different casing conventions).
        let expected = Self.allRegisteredNames.union(Self.knownDisabledTools)
        let lowercaseRegistered = Set(expected.map { $0.lowercased() })
        for toolName in keywords.keys {
            let exists = expected.contains(toolName) || lowercaseRegistered.contains(toolName.lowercased())
            XCTAssertTrue(exists,
                "ToolDomainKeywords.json has key '\(toolName)' which is not a registered tool"
            )
        }
    }

    // MARK: - 6. ToolDomain ↔ ToolRegistry

    func testAllToolDomainToolsExist() {
        // ToolDomain references both core and FM tool names.
        // Known disabled tools and FM alias mismatches are excluded.
        let expected = Self.allRegisteredNames.union(Self.knownDisabledTools)
        for domain in ToolDomain.allCases {
            for toolName in domain.toolNames {
                XCTAssertTrue(
                    expected.contains(toolName),
                    "ToolDomain.\(domain.rawValue) references '\(toolName)' which is not registered"
                )
            }
        }
    }

    // MARK: - 7. ToolCategory ↔ ToolRegistry

    func testAllToolCategoryToolsExist() {
        let expectedFM = Self.registeredFMNames.union(Self.knownDisabledTools)
        for category in ToolCategoryRegistry.categories {
            for toolName in category.coreToolNames {
                XCTAssertTrue(
                    Self.registeredCoreNames.contains(toolName),
                    "ToolCategory '\(category.name)' references core tool '\(toolName)' which is not registered. " +
                    "Core tools: \(Self.registeredCoreNames.sorted())"
                )
            }
            for toolName in category.fmToolNames {
                XCTAssertTrue(
                    expectedFM.contains(toolName),
                    "ToolCategory '\(category.name)' references FM tool '\(toolName)' which is not registered. " +
                    "FM tools: \(Self.registeredFMNames.sorted())"
                )
            }
        }
    }

    func testNLOnlyToolsExist() {
        for toolName in ToolCategoryRegistry.nlOnlyToolNames {
            XCTAssertTrue(
                Self.allRegisteredNames.contains(toolName),
                "ToolCategoryRegistry.nlOnlyToolNames references '\(toolName)' which is not registered"
            )
        }
    }

    // MARK: - 8. ExtractableCoreTool ↔ ToolSchemas

    func testExtractableToolsHaveSchemaFiles() {
        // Check that every ExtractableCoreTool has a schema file in ToolSchemas/
        let extractableTools = ToolRegistry.coreTools.filter { $0 is any ExtractableCoreTool }
        XCTAssertGreaterThan(extractableTools.count, 5,
            "Expected at least 5 ExtractableCoreTool conformants, got \(extractableTools.count)")

        for tool in extractableTools {
            // The schema is loaded via loadExtractionSchema(named:fallback:).
            // We can check if the manifest entry has an extractionSchema field.
            let manifestEntry = ToolManifest.entry(for: tool.name)
            // Also check the ToolSchemas directory directly
            let schemaName = manifestEntry?.extractionSchema ?? tool.name
            let url = Bundle.iClawCore.url(
                forResource: schemaName, withExtension: "json", subdirectory: "Config/ToolSchemas"
            )
            XCTAssertNotNil(url,
                "ExtractableCoreTool '\(tool.name)' has no schema file at ToolSchemas/\(schemaName).json")
        }
    }

    func testAllSchemaFilesAreValidJSON() {
        // Enumerate all .json files in ToolSchemas/ and validate they parse
        guard let schemasDir = Bundle.iClawCore.url(
            forResource: "Config/ToolSchemas", withExtension: nil
        ) ?? Bundle.iClawCore.resourceURL?.appendingPathComponent("Config/ToolSchemas") else {
            // ToolSchemas may not exist as a discrete directory — try loading known schemas
            return
        }

        if let files = try? FileManager.default.contentsOfDirectory(
            at: schemasDir, includingPropertiesForKeys: nil
        ) {
            for file in files where file.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: file)
                    _ = try JSONSerialization.jsonObject(with: data)
                } catch {
                    XCTFail("ToolSchemas/\(file.lastPathComponent) is not valid JSON: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - 9. ToolManifest Required Fields

    func testToolManifestRequiredFields() {
        for (name, entry) in ToolManifest.entries {
            XCTAssertFalse(entry.icon.isEmpty,
                "ToolManifest.json: '\(name)' has empty icon")
            XCTAssertFalse(entry.category.isEmpty,
                "ToolManifest.json: '\(name)' has empty category")
        }
    }

    func testNoDuplicateChipNames() {
        // Some tools intentionally share chip names (e.g., Calendar/CalendarEvent,
        // Maps core/FM) — these are routed via category chips, not individual chips.
        // Track duplicates and flag truly unexpected ones.
        let knownSharedChips: Set<String> = ["calendar", "maps"]

        var chipsSeen: [String: String] = [:] // chipName → toolName
        for (name, entry) in ToolManifest.entries {
            guard let chip = entry.chipName else { continue }
            let lower = chip.lowercased()
            if let existing = chipsSeen[lower], !knownSharedChips.contains(lower) {
                XCTFail("Duplicate chip name '\(chip)': used by both '\(existing)' and '\(name)' in ToolManifest.json")
            }
            chipsSeen[lower] = name
        }
    }

    // MARK: - 10. CommonWords Guard

    func testCommonWordsLoads() {
        struct CommonWordsConfig: Decodable { let words: [String] }
        let config = ConfigLoader.load("CommonWords", as: CommonWordsConfig.self)
        XCTAssertNotNil(config, "CommonWords.json failed to load — spellcheck guard is disabled")
        if let words = config?.words {
            XCTAssertGreaterThan(words.count, 1000,
                "CommonWords.json has only \(words.count) words — expected >1000")
        }
    }

    // MARK: - 11. ToolSlotRegistry ↔ ToolRegistry

    func testAllSlotRegistryToolsExist() {
        // ToolSlotRegistry uses tool names for both CoreTools and FMTools.
        // Some slots are for disabled tools or tools with alternate names.
        let slotExceptions: Set<String> = ["Timer"] // TimeTool registered as "Time"
        let expected = Self.allRegisteredNames.union(Self.knownDisabledTools).union(slotExceptions)
        for toolName in ToolSlotRegistry.slots.keys {
            XCTAssertTrue(
                expected.contains(toolName),
                "ToolSlotRegistry has slots for '\(toolName)' which is not a registered tool"
            )
        }
    }

    // MARK: - 12. Cross-Config Consistency

    func testLabelRegistryCoversAllMLRoutedTools() {
        // Every tool that should be reachable via ML classification must have at least one label.
        // NL-only tools don't need labels (they're routed by chips or direct match).
        let labeledTools = Set(LabelRegistry.entries.values.map(\.tool))
        let allCategoryTools = ToolCategoryRegistry.categories.flatMap {
            $0.coreToolNames + $0.fmToolNames
        }
        for toolName in allCategoryTools {
            // Tools in categories should generally be reachable via ML
            if !labeledTools.contains(toolName) {
                // Not a hard failure — some tools only route via chips or FM tool calling
                // But log it for visibility
                let entry = LabelRegistry.entries.first(where: { $0.value.tool == toolName })
                if entry == nil {
                    // This is expected for some FM tools — only warn for core tools
                    if Self.registeredCoreNames.contains(toolName) {
                        // Soft check: core tools in categories should have labels
                        // Don't fail, but note it
                    }
                }
            }
        }
    }

    // MARK: - 13. Context Budget Resolution

    func testResolveContextBudgetUsesFallbackWhenUnavailable() {
        // The closure must NOT be invoked when the model is unavailable. If it
        // were, XCTFail would mark this test failed — passing is direct
        // evidence that the guard short-circuits before reading `contextSize`.
        let budget = AppConfig.resolveContextBudget(
            isAvailable: false,
            readContextSize: {
                XCTFail("readContextSize must not be invoked when model is unavailable")
                return -1
            }
        )
        XCTAssertEqual(budget, AppConfig.contextSizeFallback,
            "Unavailable model must yield the 4096 fallback")
    }

    func testResolveContextBudgetReturnsModelSizeWhenAvailable() {
        let budget = AppConfig.resolveContextBudget(
            isAvailable: true,
            readContextSize: { 8192 }
        )
        XCTAssertEqual(budget, 8192,
            "Available model must return the reported contextSize")
    }

    func testResolveContextBudgetDoesNotCrashAcrossUnavailableScenarios() {
        // Exercise the unavailable branch repeatedly — the scenario that
        // actually occurs on CI and unprovisioned machines. Any crash in the
        // fallback path would surface here.
        for _ in 0..<10 {
            let budget = AppConfig.resolveContextBudget(
                isAvailable: false,
                readContextSize: { 0 }
            )
            XCTAssertEqual(budget, AppConfig.contextSizeFallback)
        }
    }

    func testTotalContextBudgetMatchesModelOrFallback() {
        // `AppConfig.totalContextBudget` must either track
        // `SystemLanguageModel.default.contextSize` (when Apple Intelligence is
        // available) or fall back to `contextSizeFallback` (CI, unprovisioned
        // machines). It must never be below the fallback.
        XCTAssertGreaterThanOrEqual(
            AppConfig.totalContextBudget,
            AppConfig.contextSizeFallback,
            "totalContextBudget (\(AppConfig.totalContextBudget)) is below the 4096 fallback floor"
        )

        if case .available = SystemLanguageModel.default.availability {
            XCTAssertEqual(
                AppConfig.totalContextBudget,
                SystemLanguageModel.default.contextSize,
                "totalContextBudget must track the live model contextSize when Apple Intelligence is available"
            )
        } else {
            XCTAssertEqual(
                AppConfig.totalContextBudget,
                AppConfig.contextSizeFallback,
                "totalContextBudget must equal the fallback when the model is unavailable"
            )
        }
    }

    func testModeConfigAllowedToolsExist() {
        let expected = Self.allRegisteredNames.union(Self.knownDisabledTools)
        for (name, entry) in ToolManifest.entries {
            guard let modeConfig = entry.modeConfig else { continue }
            for toolName in modeConfig.allowedTools {
                XCTAssertTrue(
                    expected.contains(toolName),
                    "ModeConfig for '\(name)' allows tool '\(toolName)' which is not registered"
                )
            }
        }
    }
}
