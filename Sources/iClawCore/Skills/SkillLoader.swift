import Foundation
import Observation

struct Skill: Codable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let systemPrompt: String
    let tools: [ToolDefinition]
    let examples: [String]
    var isBuiltIn: Bool = true
    let cacheDuration: CacheDuration?
    /// Optional `#handle` for explicit chip routing (e.g., `#crypto`). Must not collide with tool names.
    let handle: String?

    enum CodingKeys: String, CodingKey {
        case name, description, systemPrompt, tools, examples, isBuiltIn, cacheDuration, handle
    }

    init(name: String, description: String, systemPrompt: String, tools: [ToolDefinition], examples: [String], isBuiltIn: Bool = true, cacheDuration: CacheDuration? = nil, handle: String? = nil) {
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.examples = examples
        self.isBuiltIn = isBuiltIn
        self.cacheDuration = cacheDuration
        self.handle = handle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        tools = try container.decode([ToolDefinition].self, forKey: .tools)
        examples = try container.decode([String].self, forKey: .examples)
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? true
        cacheDuration = try container.decodeIfPresent(CacheDuration.self, forKey: .cacheDuration)
        handle = try container.decodeIfPresent(String.self, forKey: .handle)
    }
}

struct ToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: [String: String]
}

@MainActor
@Observable
class SkillLoader {
    static let shared = SkillLoader()

    var loadedSkills: [Skill] = []
    private let parser = SkillParser()
    private var loadingTask: Task<Void, Never>?

    var activeSkills: [Skill] {
        let disabled = SkillSettingsManager.shared.disabledSkillNames
        return loadedSkills.filter { !disabled.contains($0.name) }
    }

    /// Waits for initial skill loading to complete, then returns active skills.
    /// First call blocks until built-in skills are parsed (~50ms). Subsequent calls return immediately.
    func awaitActiveSkills() async -> [Skill] {
        await loadingTask?.value
        return activeSkills
    }

    private init() {
        loadingTask = Task {
            await loadBuiltInSkills()
            await loadImportedSkills()
        }
    }
    
    func loadBuiltInSkills() async {
        guard let skillsURL = Bundle.iClawCore.url(forResource: "Skills", withExtension: nil) else {
            Log.engine.debug("Resources/Skills directory not found in bundle.")
            return
        }

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: skillsURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "md" }

            // Parse all skills concurrently off the MainActor, then append results.
            // This avoids the deadlock where child tasks need MainActor to call loadSkill
            // while the parent is blocking MainActor waiting for the group to complete.
            let parsed = await withTaskGroup(of: Skill?.self) { group in
                for fileURL in fileURLs {
                    group.addTask {
                        do {
                            return try await self.parser.parseSkill(from: fileURL)
                        } catch {
                            Log.engine.debug("Error loading skill from \(fileURL): \(error)")
                            return nil
                        }
                    }
                }
                var results: [Skill] = []
                for await skill in group {
                    if let skill { results.append(skill) }
                }
                return results
            }

            // Append on MainActor (single batch, no child-task hops)
            for skill in parsed {
                loadedSkills.append(skill)
                Log.engine.debug("Loaded skill: \(skill.name) with \(skill.examples.count) examples.")
            }
        } catch {
            Log.engine.debug("Error listing skills directory: \(error)")
        }
    }

    func loadSkill(from url: URL) async throws {
        let skill = try await parser.parseSkill(from: url)
        loadedSkills.append(skill)
        Log.engine.debug("Loaded skill: \(skill.name) with \(skill.examples.count) examples.")
    }
    
    /// Returns all training examples for MLTextClassifier.
    func getAllTrainingData() -> [String: [String]] {
        var trainingData: [String: [String]] = [:]
        for skill in loadedSkills {
            trainingData[skill.name] = skill.examples
        }
        return trainingData
    }

    // MARK: - Imported Skills

    private func loadImportedSkills() async {
        let dir = SkillSettingsManager.importedSkillsDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            Log.tools.debug("Failed to enumerate imported skills directory at \(dir.path)")
            return
        }

        let builtInNames = Set(loadedSkills.filter(\.isBuiltIn).map { $0.name.lowercased() })

        // Use structured concurrency so all skills are loaded before returning.
        // Previous detached Task approach could race with activeSkills access.
        await withTaskGroup(of: Skill?.self) { group in
            for fileURL in fileURLs where fileURL.pathExtension == "md" {
                group.addTask { [parser] in
                    do {
                        var skill = try await parser.parseSkill(from: fileURL)
                        skill.isBuiltIn = false
                        if builtInNames.contains(skill.name.lowercased()) {
                            Log.engine.debug("Skipping imported skill '\(skill.name)': duplicates a built-in skill")
                            return nil
                        }
                        return skill
                    } catch {
                        Log.engine.debug("Error loading imported skill from \(fileURL): \(error)")
                        return nil
                    }
                }
            }
            for await skill in group {
                if let skill {
                    loadedSkills.append(skill)
                    Log.engine.debug("Loaded imported skill: \(skill.name)")
                }
            }
        }
    }

    func importSkill(from url: URL) async throws -> Skill {
        let dir = SkillSettingsManager.importedSkillsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let filename = url.lastPathComponent
        let destination = dir.appendingPathComponent(filename)

        // Copy file to App Support
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)

        // Parse skill
        var skill = try await parser.parseSkill(from: destination)
        skill.isBuiltIn = false

        // Reject if this duplicates a built-in skill
        let builtInNames = Set(loadedSkills.filter(\.isBuiltIn).map { $0.name.lowercased() })
        if builtInNames.contains(skill.name.lowercased()) {
            try? FileManager.default.removeItem(at: destination)
            Log.engine.debug("Rejected import of '\(skill.name)': duplicates a built-in skill")
            throw SkillImportError.duplicatesBuiltInSkill(skill.name)
        }

        loadedSkills.append(skill)

        // Update settings
        SkillSettingsManager.shared.importedSkills.append(
            ImportedSkillRecord(id: UUID(), name: skill.name, filename: filename, dateAdded: Date())
        )

        Log.engine.debug("Imported skill: \(skill.name)")
        return skill
    }

    func removeImportedSkill(name: String) {
        // Remove from loadedSkills
        loadedSkills.removeAll { $0.name == name && !$0.isBuiltIn }

        // Remove file
        if let record = SkillSettingsManager.shared.importedSkills.first(where: { $0.name == name }) {
            let filePath = SkillSettingsManager.importedSkillsDirectory.appendingPathComponent(record.filename)
            try? FileManager.default.removeItem(at: filePath)
        }

        // Remove from settings
        SkillSettingsManager.shared.importedSkills.removeAll { $0.name == name }

        Log.engine.debug("Removed imported skill: \(name)")
    }
}

// MARK: - Errors

enum SkillImportError: LocalizedError {
    case duplicatesBuiltInSkill(String)

    var errorDescription: String? {
        switch self {
        case .duplicatesBuiltInSkill(let name):
            "\"\(name)\" is already built into iClaw and can't be imported."
        }
    }
}
