import Foundation
import Observation

// MARK: - Data Models

struct ImportedSkillRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let filename: String
    let dateAdded: Date
}

struct CustomFeedRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let url: String
}

// MARK: - Skill Settings Manager

@MainActor
@Observable
class SkillSettingsManager {
    static let shared = SkillSettingsManager()

    private static let disabledSkillsKey = "iClaw_disabledSkills"
    private static let importedSkillsKey = "iClaw_importedSkills"
    private static let customFeedsKey = "iClaw_customFeeds"
    private static let disabledFeedsKey = "iClaw_disabledFeeds"
    private static let disabledToolsKey = "iClaw_disabledTools"

    var disabledSkillNames: Set<String> {
        didSet { persist(disabledSkillNames, forKey: Self.disabledSkillsKey) }
    }

    var importedSkills: [ImportedSkillRecord] {
        didSet { persist(importedSkills, forKey: Self.importedSkillsKey) }
    }

    var customFeeds: [CustomFeedRecord] {
        didSet { persist(customFeeds, forKey: Self.customFeedsKey) }
    }

    var disabledFeedURLs: Set<String> {
        didSet { persist(disabledFeedURLs, forKey: Self.disabledFeedsKey) }
    }

    /// Core tools disabled by the user (e.g., "Email", "Podcast").
    /// Filtered in ToolRegistry.coreTools. Changes take effect after restart.
    var disabledToolNames: Set<String> {
        didSet { persist(disabledToolNames, forKey: Self.disabledToolsKey) }
    }

    /// Tools that cannot be disabled (essential infrastructure).
    static let undisableableTools: Set<String> = ["Help", "Feedback"]

    /// Check if a tool is disabled by the user.
    func isToolDisabled(_ name: String) -> Bool {
        disabledToolNames.contains(name)
    }

    private init() {
        self.disabledSkillNames = Self.load(forKey: Self.disabledSkillsKey) ?? []
        self.importedSkills = Self.load(forKey: Self.importedSkillsKey) ?? []
        self.customFeeds = Self.load(forKey: Self.customFeedsKey) ?? []
        self.disabledFeedURLs = Self.load(forKey: Self.disabledFeedsKey) ?? []
        self.disabledToolNames = Self.load(forKey: Self.disabledToolsKey) ?? []
    }

    // MARK: - Persistence

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - App Support Directory

    static var importedSkillsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("iClaw/Skills")
    }
}
