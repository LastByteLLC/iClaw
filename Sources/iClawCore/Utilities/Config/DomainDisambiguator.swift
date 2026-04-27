import Foundation

/// Resolves ambiguous compound labels within a domain using keyword signals.
///
/// When the ML classifier returns a compound label with low confidence but the domain
/// is clear, this disambiguator applies lightweight keyword matching to select the
/// correct action. Loaded from `Resources/Config/DomainRules.json`.
public enum DomainDisambiguator {

    /// A single action rule within a domain.
    struct ActionRule: Codable {
        let action: String
        let signals: [String]
    }

    /// Domain → [ActionRule]. Loaded once from DomainRules.json.
    /// Keys are lowercased at load time so lookups are case-insensitive.
    private static let rules: [String: [ActionRule]] = {
        guard let raw = ConfigLoader.load("DomainRules", as: [String: [ActionRule]].self) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.map { ($0.key.lowercased(), $0.value) })
    }()

    /// Resolves the best compound label for a domain given the user's input.
    ///
    /// - Parameters:
    ///   - domain: The domain prefix (e.g., "email", "calendar")
    ///   - input: The user's raw input text
    /// - Returns: The full compound label (e.g., "email.read") if a match is found,
    ///            or nil if no action signals matched.
    public static func resolve(domain: String, input: String) -> String? {
        let key = domain.lowercased()
        guard let domainRules = rules[key] else { return nil }

        let lower = input.lowercased()

        // Score each action by how many of its signals appear in the input.
        // Use longest-match-first to avoid "read" matching inside "read file".
        var best: (action: String, score: Int) = ("", 0)
        for rule in domainRules {
            let score = rule.signals.count(where: { lower.contains($0) })
            if score > best.score {
                best = (rule.action, score)
            }
        }

        guard best.score > 0 else { return nil }
        return "\(key).\(best.action)"
    }

    /// Returns the default action for a domain (first rule listed).
    /// Used when no signals match but the domain is confident.
    public static func defaultAction(for domain: String) -> String? {
        let key = domain.lowercased()
        guard let domainRules = rules[key], let first = domainRules.first else {
            return nil
        }
        return "\(key).\(first.action)"
    }
}
