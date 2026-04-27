import Foundation

enum FeedRegistry {
    @MainActor
    static var activeFeeds: [NewsTool.RSSFeed] {
        let disabled = SkillSettingsManager.shared.disabledFeedURLs
        let builtIn = NewsTool.builtInFeeds.filter { !disabled.contains($0.url) }
        let custom = SkillSettingsManager.shared.customFeeds.map {
            NewsTool.RSSFeed(name: $0.name, url: $0.url, categories: [], iconDomain: nil)
        }.filter { !disabled.contains($0.url) }
        return builtIn + custom
    }
}
