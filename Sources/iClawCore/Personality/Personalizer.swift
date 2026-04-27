import Foundation

/// Lightweight actor that rephrases status/error messages through the on-device LLM
/// using SOUL.md personality. Results are cached since the same messages recur.
actor Personalizer {
    static let shared = Personalizer()

    private var cache: [String: CacheEntry] = [:]
    private let adapter: LLMAdapter
    private let maxEntries = 100
    private let ttl: TimeInterval = 3600 // 1 hour

    private struct CacheEntry {
        let value: String
        let timestamp: Date
    }

    private init(adapter: LLMAdapter = .shared) {
        self.adapter = adapter
    }

    private var soulContent: String { SoulProvider.current }

    /// Rephrases a message with SOUL personality. Returns the original on LLM failure.
    func personalize(_ message: String) async -> String {
        let instructions = makeInstructions {
            Soul(soulContent)
            Directive(
                "Rephrase the following status/error message in your voice. Keep it SHORT (under 10 words). " +
                "Keep the core meaning and any specific details (paths, names, error codes). No emojis. No quotes. " +
                "Output ONLY the rephrased message."
            )
        }
        let prompt = "Message: \(message)"
        return await rephrase(message, cacheKey: message, instructions: instructions, prompt: prompt)
    }

    /// Rephrases an error into a human-understandable message that explains what went wrong
    /// and what the user can do to fix it.
    func personalizeError(_ message: String) async -> String {
        let instructions = makeInstructions {
            Soul(soulContent)
            Directive(
                "An error occurred. Rephrase this into a short, human-understandable error message (2-3 sentences max). " +
                "First sentence: what went wrong, in plain language. " +
                "Second sentence: what the user can do to fix it (be specific — name the setting, permission, or action). " +
                "Keep your personality but be genuinely helpful. No emojis. No quotes. No technical jargon. " +
                "Output ONLY the error message."
            )
        }
        let prompt = "Error: \(message)"
        return await rephrase(message, cacheKey: "error:\(message)", instructions: instructions, prompt: prompt)
    }

    /// Rephrases a message, calling back on MainActor when done.
    nonisolated func personalizeAsync(
        _ message: String,
        onComplete: @MainActor @Sendable @escaping (String) -> Void
    ) {
        Task {
            let result = await self.personalize(message)
            await onComplete(result)
        }
    }

    // MARK: - Private

    private func rephrase(
        _ fallback: String,
        cacheKey: String,
        instructions: iClawInstructions,
        prompt: String
    ) async -> String {
        if let entry = cache[cacheKey], Date().timeIntervalSince(entry.timestamp) < ttl {
            return entry.value
        }

        // Use the error profile when rephrasing an error (longer cap, 2-3 sentences).
        // Status messages use the tighter personalize profile (≤10 words).
        let profile: LLMCallProfile = cacheKey.hasPrefix("error:")
            ? .personalizeError
            : .personalize

        do {
            let result = try await adapter.generateWithInstructions(
                prompt: prompt, instructions: instructions, profile: profile
            )
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                cacheSet(cacheKey, value: trimmed)
                return trimmed
            }
        } catch {
            Log.engine.debug("Personalizer LLM failed: \(error)")
        }
        return fallback
    }

    private func cacheSet(_ key: String, value: String) {
        cache[key] = CacheEntry(value: value, timestamp: Date())
        if cache.count > maxEntries {
            if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                cache.removeValue(forKey: oldest)
            }
        }
    }
}
