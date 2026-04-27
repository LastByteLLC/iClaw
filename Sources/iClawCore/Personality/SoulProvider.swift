import Foundation
import os

/// Centralized provider for the active SOUL personality content.
/// Reads the base SOUL.md and applies the user's personality setting from Settings.
enum SoulProvider {
    /// Resolution order mirrors `BrainProvider.resolveContent`:
    ///   1. `UserDefaults["prompt.soul.path"]` — absolute path (meta-harness override)
    ///   2. Bundled `SOUL.md`
    ///   3. Inline fallback
    private static let baseSoulContent: String = {
        if let path = UserDefaults.standard.string(forKey: "prompt.soul.path"),
           !path.isEmpty,
           let content = try? String(contentsOfFile: path, encoding: .utf8) {
            return content
        }
        if let url = Bundle.iClawCore.url(forResource: "SOUL", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return "Terse. Sassy. Direct."
    }()

    /// Thread-safe cache protected by OSAllocatedUnfairLock.
    private static let cache = OSAllocatedUnfairLock<(level: String, content: String)?>(initialState: nil)

    /// Returns the active personality content, respecting the user's Settings > Personality choice.
    static var current: String {
        let level = UserDefaults.standard.string(forKey: AppConfig.personalityLevelKey) ?? "full"
        return cache.withLock { cached in
            if let cached, cached.level == level {
                return cached.content
            }
            let result: String
            switch level {
            case "moderate":
                result = baseSoulContent + "\n\n**Override:** Keep the brevity and directness but soften the sass. Be helpful without being abrasive."
            case "neutral":
                result = "Concise and helpful. No personality flavor — straightforward, accurate."
            case "custom":
                let custom = UserDefaults.standard.string(forKey: AppConfig.customPersonalityKey) ?? ""
                result = custom.isEmpty ? baseSoulContent : custom
            default:
                result = baseSoulContent
            }
            cached = (level: level, content: result)
            return result
        }
    }
}
