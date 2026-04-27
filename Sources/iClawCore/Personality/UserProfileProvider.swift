import Foundation

/// Deterministic provider for persistent user context (~40 tokens).
/// Consolidates MeCardManager (identity), UserProfileManager (usage patterns),
/// and ConversationState preferences into a compact prompt injection.
/// No LLM calls — all data is pre-computed.
enum UserProfileProvider {

    /// Returns the current user context string for prompt injection.
    /// Must be called from an async context (crosses actor boundaries).
    /// Skips MeCard (Contacts) access in test environments to avoid CoreData XPC timeouts.
    static func current() async -> String {
        var parts: [String] = []

        // Skip Contacts access in test environment (xctest can't reach AddressBook XPC)
        let isTest = Bundle.main.bundleIdentifier?.hasPrefix("com.apple.dt.xctest") ?? false
        if !isTest {
            let me = await MeCardManager.shared
            let name = await me.userName
            if !name.isEmpty { parts.append("User: \(name)") }
            if let email = await me.userEmail { parts.append("Email: \(email)") }
        }

        // Usage patterns from UserProfileManager
        if let profile = await UserProfileManager.shared.profileContext() {
            parts.append(profile)
        }

        return parts.joined(separator: ". ")
    }

    /// Injects conversation-detected preferences (e.g., unit_system=metric)
    /// into the user context. Called with the current ConversationState.
    static func current(with preferences: [String: String]) async -> String {
        var base = await current()
        if !preferences.isEmpty {
            let prefs = preferences.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            if !base.isEmpty { base += ". " }
            base += prefs
        }
        return base
    }
}
