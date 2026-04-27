import Foundation

/// Resolves ambiguous communication intent ("send a message") to a specific
/// channel (iMessage, Email, etc.) based on keyword signals, input patterns,
/// and tool availability. Data-driven via `CommunicationChannels.json`.
///
/// Adding a new channel (Slack, WhatsApp, etc.) requires only a JSON entry
/// and a registered tool — no routing code changes.
public enum CommunicationChannelResolver {

    // MARK: - Types

    /// A communication channel loaded from config.
    public struct Channel: Decodable, Sendable {
        public let tool: String
        public let displayName: String
        public let icon: String
        public let chip: String
        public let keywords: [String]
        public let patterns: [String]
        public let mlLabels: [String]
    }

    /// Resolution outcome.
    public enum Resolution: Sendable {
        /// A single channel was definitively matched (keyword or pattern signal).
        case definitive(Channel)
        /// Multiple channels are available and no signal disambiguates them.
        /// The UI should present these as pill choices.
        case ambiguous([Channel])
        /// The routed tool/label is not a communication channel.
        case notCommunication
    }

    // MARK: - Loaded Config

    private static let channels: [Channel] = {
        ConfigLoader.load("CommunicationChannels", as: [Channel].self) ?? []
    }()

    /// All ML labels that belong to any communication channel.
    private static let allCommunicationLabels: Set<String> = {
        Set(channels.flatMap(\.mlLabels))
    }()

    /// All communication tool names.
    private static let allCommunicationToolNames: Set<String> = {
        Set(channels.map(\.tool))
    }()

    // MARK: - Public API

    /// Returns the channel matching a tool name or ML label, or nil if not a communication tool.
    public static func channels(matching nameOrLabel: String) -> Channel? {
        channels.first { $0.tool == nameOrLabel }
            ?? channels.first { $0.mlLabels.contains(nameOrLabel) }
    }

    /// Checks whether a routed tool name or ML label belongs to a communication channel.
    public static func isCommunicationTool(_ nameOrLabel: String) -> Bool {
        allCommunicationLabels.contains(nameOrLabel)
            || allCommunicationToolNames.contains(nameOrLabel)
    }

    /// Domain prefixes (the portion before `.` in compound ML labels) that
    /// belong to communication channels. Derived from each channel's mlLabels.
    private static let communicationDomains: Set<String> = {
        Set(channels.flatMap(\.mlLabels).compactMap { label in
            label.components(separatedBy: ".").first?.lowercased()
        })
    }()

    /// Returns true when the given domain token (e.g. "email", "messages")
    /// is the domain portion of any communication channel's ML labels.
    /// Used by ExecutionEngine to gate the channel-disambiguation branch so
    /// that non-communication queries with weak messaging-label overlap
    /// aren't hijacked into an iMessage/Email prompt.
    public static func isCommunicationDomain(_ domain: String) -> Bool {
        communicationDomains.contains(domain.lowercased())
    }

    /// Resolves a communication routing decision.
    ///
    /// - Parameters:
    ///   - input: The user's raw input string.
    ///   - routedToolOrLabel: The tool name or ML label that routing selected.
    ///   - availableToolNames: Names of all registered tools (core + FM).
    /// - Returns: `.definitive` if a single channel matches, `.ambiguous` if
    ///   the user needs to choose, `.notCommunication` if this isn't a messaging query.
    public static func resolve(
        input: String,
        routedToolOrLabel: String,
        availableToolNames: Set<String>
    ) -> Resolution {
        // 1. Is this a communication tool/label at all?
        guard isCommunicationTool(routedToolOrLabel) else {
            return .notCommunication
        }

        // 2. Filter to channels whose tool is actually registered
        let available = channels.filter { availableToolNames.contains($0.tool) }
        guard !available.isEmpty else { return .notCommunication }
        if available.count == 1 { return .definitive(available[0]) }

        // 3. Check for definitive keyword signals
        let lower = input.lowercased()
        let words = Set(lower.split(separator: " ").map(String.init))
        for channel in available {
            for keyword in channel.keywords {
                // Exact word match for short keywords, substring for multi-word
                if keyword.contains(" ") {
                    if lower.contains(keyword) { return .definitive(channel) }
                } else {
                    if words.contains(keyword.lowercased()) { return .definitive(channel) }
                }
            }
        }

        // 4. Check for pattern-based signals
        for channel in available {
            for pattern in channel.patterns {
                switch pattern {
                case "email_address":
                    if containsEmailAddress(input) { return .definitive(channel) }
                case "phone_number":
                    if containsPhoneNumber(input) { return .definitive(channel) }
                default:
                    break
                }
            }
        }

        // 5. No definitive signal — ambiguous
        return .ambiguous(available)
    }

    /// Multilingual communication-verb table. Loaded lazily from
    /// `Resources/Config/CommunicationVerbs.json`.
    private static let communicationVerbs: MultilingualKeywords? = MultilingualKeywords.load("CommunicationVerbs")

    /// Checks whether an input has strong communication intent (send/text/message/tell
    /// in any supported language) regardless of what tool the ML classifier selected.
    /// Used as a safety net when non-communication tools (shortcuts, calendar,
    /// reminders) are routed but the input clearly wants to send a message.
    ///
    /// Uses word-boundary matching because short communication keywords ("DM", "email",
    /// "text") otherwise substring-match inside unrelated proper nouns — e.g. "Fridman"
    /// triggers "DM" and misroutes podcast queries into Messages with a consent prompt.
    public static func hasCommunicationIntent(_ input: String) -> Bool {
        guard let kw = communicationVerbs else { return false }
        // "tell" is a communication verb, but "tell me about X" / "what is X"
        // / "who is X" are knowledge-seeking phrasings. Without this guard
        // the safety net misroutes "Tell me about the Boston Marathon" to
        // Messages, the protected-tool filter then drops it, and the LLM
        // refuses because the prior turn's unrelated tool data dominates
        // the conversational context.
        if isKnowledgeQueryPhrasing(input) { return false }
        return kw.containsAnyAsWord(intent: "send_action", in: input)
    }

    private static let knowledgeQueryRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\btell\s+me\s+(?:about|more\s+about)\b|\b(?:what|who|where|when|why|how)\s+(?:is|are|was|were|does|did)\b"#,
            options: [.caseInsensitive]
        )
    }()

    /// True when the input is shaped like a knowledge/lookup question
    /// ("tell me about …", "what is …", "who was …"). These phrasings
    /// intentionally use communication verbs ("tell") but are not requests
    /// to send a message.
    public static func isKnowledgeQueryPhrasing(_ input: String) -> Bool {
        let range = NSRange(input.startIndex..., in: input)
        return knowledgeQueryRegex.firstMatch(in: input, options: [], range: range) != nil
    }

    /// Resolves communication intent when the ML routed to a non-communication tool.
    /// Returns the appropriate channel or `.ambiguous` if multiple channels are available.
    public static func resolveFromIntent(
        input: String,
        availableToolNames: Set<String>
    ) -> Resolution {
        let available = channels.filter { availableToolNames.contains($0.tool) }
        guard !available.isEmpty else { return .notCommunication }
        if available.count == 1 { return .definitive(available[0]) }

        // Check for definitive signals even though ML picked wrong tool
        let lower = input.lowercased()
        let words = Set(lower.split(separator: " ").map(String.init))
        for channel in available {
            for keyword in channel.keywords {
                if keyword.contains(" ") {
                    if lower.contains(keyword) { return .definitive(channel) }
                } else {
                    if words.contains(keyword.lowercased()) { return .definitive(channel) }
                }
            }
        }
        for channel in available {
            for pattern in channel.patterns {
                switch pattern {
                case "email_address":
                    if containsEmailAddress(input) { return .definitive(channel) }
                case "phone_number":
                    if containsPhoneNumber(input) { return .definitive(channel) }
                default:
                    break
                }
            }
        }

        return .ambiguous(available)
    }

    // MARK: - Pattern Matchers

    private static let urlDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static let phoneDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)
    }()

    static func containsEmailAddress(_ input: String) -> Bool {
        let range = NSRange(input.startIndex..., in: input)
        let matches = urlDetector?.matches(in: input, options: [], range: range) ?? []
        return matches.contains { $0.url?.scheme == "mailto" }
    }

    static func containsPhoneNumber(_ input: String) -> Bool {
        let range = NSRange(input.startIndex..., in: input)
        let matches = phoneDetector?.matches(in: input, options: [], range: range) ?? []
        return !matches.isEmpty
    }

    // MARK: - Lookup-Question Detection
    //
    // "whats Shawn's email?" is a contact-info LOOKUP, not a send directive.
    // Without this guard the safety net happily routes the question to
    // Messages (because "email" matches `send_action` verbs), extracts
    // `{recipient: Shawn, message: "email"}`, and iMessages the literal
    // word "email" to the contact. Messages and Email tool `execute` paths
    // consult this to self-refuse when the input shape is a lookup.
    //
    // Signal: English possessive `'s` immediately followed by a contact-info
    // noun. English-only is fine here — other languages don't share the
    // `"email"/"mail"` keyword collision with communication verbs, so this
    // bug surface is English-specific.
    private static let lookupPossessivePattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\b(?:\w+)'s\s+(?:e-?mail|phone|number|address|contact(?:\s+info)?|info)\b"#,
            options: [.caseInsensitive]
        )
    }()

    /// True when the input looks like a possessive contact-info lookup
    /// ("Shawn's email", "John's phone number", "Sarah's contact info") —
    /// the inverse of a send directive. Messages/Email tools use this to
    /// self-refuse so the engine falls through to conversational BRAIN
    /// instead of fabricating a send or leaking contact data.
    public static func isContactLookupQuestion(_ input: String) -> Bool {
        let range = NSRange(input.startIndex..., in: input)
        return lookupPossessivePattern.firstMatch(in: input, options: [], range: range) != nil
    }
}
