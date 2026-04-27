import Foundation
import Testing
@testable import iClawCore

@Suite("ConversationalGate")
struct ConversationalGateTests {

    // MARK: - Helpers

    private static func empty() -> ExtractedEntities {
        ExtractedEntities(
            names: [], places: [], organizations: [],
            urls: [], phoneNumbers: [], emails: [],
            ocrText: nil, correctedInput: nil, detectedLanguage: nil
        )
    }

    private static func signals(
        _ input: String,
        replyPayload: String? = nil,
        entities: ExtractedEntities? = nil,
        chips: [String] = [],
        tickers: [String] = []
    ) -> ConversationalGate.Signals {
        ConversationalGate.Signals(
            input: input,
            replyPayload: replyPayload,
            entities: entities ?? Self.empty(),
            chipsPresent: chips,
            tickersPresent: tickers,
            priorTool: nil
        )
    }

    // MARK: - Conversational default (multilingual)

    @Test("Evidence-free inputs classify as conversational in any language")
    func evidenceFreeIsConversational() {
        // Longer than 2 tokens, no entities (populated by caller as empty),
        // no chip, no URL, no ticker, no numeric operator. The gate's decision
        // must not depend on the language of the surface text.
        let samples = [
            "I had a rough day",                  // en
            "Hoy tuve un día difícil",             // es
            "C'était une journée difficile",       // fr
            "Es war ein harter Tag",               // de
            "Oggi è stata una giornata dura",      // it
            "今日は大変な一日でした",                  // ja
            "Сегодня был трудный день",            // ru
            "she seems nice overall",              // declarative
            "he is a great actor",                 // declarative
        ]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text))
            #expect(d.kind == .conversational,
                    "input '\(text)' expected .conversational, got \(d.kind) (\(d.reason))")
        }
    }

    @Test("Very short evidence-free inputs classify as clarification regardless of language")
    func shortEvidenceFreeIsClarification() {
        // ≤2 substantive tokens, no entity/chip/ticker/numeric.
        // Greeting-like utterances fall here even though they aren't asking
        // a question — the engine will use this to answer conversationally
        // and offer a brief prompt, not route to a tool.
        let samples = ["hi", "hola", "bonjour", "ciao", "привет", "こんにちは", "你好", "salut"]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text))
            #expect(d.kind == .clarification,
                    "input '\(text)' expected .clarification, got \(d.kind)")
        }
    }

    // MARK: - Structural tool signals (language-neutral)

    @Test("Chips force toolSignal independent of language")
    func chipsAlwaysTool() {
        let samples = [
            "#weather Paris",
            "#weather Madrid mañana",
            "#weather 東京",
            "#calculator 2+2",
        ]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text, chips: ["weather"]))
            #expect(d.kind == .toolSignal)
            #expect(!d.candidateToolHints.isEmpty)
        }
    }

    @Test("URLs force toolSignal with WebFetch hint")
    func urlsAreWebFetch() {
        // The URL detector runs in InputPreprocessor; we stub the entities.
        let url = URL(string: "https://example.com")!
        let ents = ExtractedEntities(
            names: [], places: [], organizations: [],
            urls: [url], phoneNumbers: [], emails: [],
            ocrText: nil, correctedInput: nil, detectedLanguage: nil
        )
        let d = ConversationalGate.evaluate(Self.signals("check this https://example.com", entities: ents))
        #expect(d.kind == .toolSignal)
        #expect(d.candidateToolHints.contains("WebFetch"))
    }

    @Test("Numeric expressions across unicode operators force Calculator")
    func numericExpressions() {
        let samples = [
            "2+2",
            "237 * 182",
            "Calcula 2+2",
            "2+2を計算して",
            "√64",
            "sqrt(9)",
            "10 × 5",
            "10 ÷ 5",
        ]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text))
            #expect(d.kind == .toolSignal,
                    "input '\(text)' expected .toolSignal, got \(d.kind)")
            #expect(d.candidateToolHints.contains("Calculator"),
                    "input '\(text)' should hint Calculator, hints=\(d.candidateToolHints)")
        }
    }

    @Test("Standalone numbers are NOT numeric expressions")
    func standaloneNumberIsNotExpression() {
        // "42" alone is not an expression — no operator. Gate should not
        // blindly route a year, a count, or a single integer to Calculator.
        let samples = ["42", "2020 year", "call 911"]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text))
            #expect(d.kind != .toolSignal || !d.candidateToolHints.contains("Calculator"),
                    "input '\(text)' unexpectedly routed to Calculator")
        }
    }

    @Test("Ticker pattern routes to Stocks")
    func tickerRoutesStocks() {
        let d = ConversationalGate.evaluate(Self.signals("how's $AAPL doing", tickers: ["AAPL"]))
        #expect(d.kind == .toolSignal)
        #expect(d.candidateToolHints.contains("Stocks"))
    }

    @Test("Name + contact-attribute noun promotes Contacts into hints")
    func nameWithContactAttributePromotesContacts() {
        // 2026-04 regression: "whats Shawn's email?" hinted only [WikipediaSearch],
        // so when the safety net routed to Messages the protected-tool filter
        // had no positive signal for Contacts. Now the gate includes Contacts
        // alongside WikipediaSearch so Contacts.search can pass the filter.
        let ents = ExtractedEntities(
            names: ["Shawn"], places: [], organizations: [],
            urls: [], phoneNumbers: [], emails: [],
            ocrText: nil, correctedInput: nil, detectedLanguage: nil
        )
        let samples = [
            "whats Shawn's email?",
            "what is Shawn's phone number",
            "give me Shawn's address",
            "find Shawn's contact info",
        ]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text, entities: ents))
            #expect(d.candidateToolHints.contains("Contacts"),
                    "'\(text)' should hint Contacts, got \(d.candidateToolHints)")
        }
    }

    @Test("Name alone (no contact attribute) does NOT hint Contacts")
    func nameAloneNoContactsHint() {
        // Guardrail: a bare name without a contact-attribute noun should keep
        // WikipediaSearch-only hints. "who is Shawn" is a knowledge query.
        let ents = ExtractedEntities(
            names: ["Shawn"], places: [], organizations: [],
            urls: [], phoneNumbers: [], emails: [],
            ocrText: nil, correctedInput: nil, detectedLanguage: nil
        )
        let d = ConversationalGate.evaluate(Self.signals("who is Shawn Lemon?", entities: ents))
        #expect(!d.candidateToolHints.contains("Contacts"),
                "Bare 'who is X?' should not hint Contacts")
        #expect(d.candidateToolHints.contains("WikipediaSearch"))
    }

    @Test("Phone/email force Messages hint")
    func contactInfoMessages() {
        let ents = ExtractedEntities(
            names: [], places: [], organizations: [],
            urls: [], phoneNumbers: ["+1-555-1234"], emails: [],
            ocrText: nil, correctedInput: nil, detectedLanguage: nil
        )
        let d = ConversationalGate.evaluate(Self.signals("text +1-555-1234", entities: ents))
        #expect(d.kind == .toolSignal)
        #expect(d.candidateToolHints.contains("Messages"))
    }

    // MARK: - Entity / interrogative soft signals

    @Test("Named place yields Weather/Maps candidate scope")
    func placeYieldsWeatherMaps() {
        let ents = ExtractedEntities(
            names: [], places: ["Paris"], organizations: [],
            urls: [], phoneNumbers: [], emails: [],
            ocrText: nil, correctedInput: nil, detectedLanguage: nil
        )
        let d = ConversationalGate.evaluate(Self.signals("the weather for Paris", entities: ents))
        #expect(d.kind == .candidateScope)
        #expect(d.candidateToolHints.contains("Weather"))
        #expect(d.candidateToolHints.contains("Maps"))
    }

    @Test("Longer interrogatives yield WikipediaSearch/WebSearch")
    func interrogativeYieldsKnowledge() {
        // Punctuation check is Unicode-aware: ?, ¿, ？ all count.
        // Threshold: >3 substantive tokens. Short questions like "how are
        // you?" are small talk, handled by the conversational tests below.
        let samples = [
            "what is the theory of general relativity?",
            "¿cuál es la capital de Francia?",
            "who painted the Mona Lisa?",
        ]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text))
            #expect(d.kind == .candidateScope,
                    "input '\(text)' expected .candidateScope, got \(d.kind)")
            #expect(d.candidateToolHints.contains("WikipediaSearch"))
        }
    }

    @Test("Short interrogatives are conversational, not knowledge queries")
    func shortInterrogativesStayConversational() {
        // Small-talk questions carry no retrievable content — treat as
        // conversational so the finalizer uses the tool-free BRAIN and
        // strips the profile.
        let samples = [
            "how are you?",
            "what's up?",
            "¿cómo estás?",
            "ça va?",
            "who knows?",
        ]
        for text in samples {
            let d = ConversationalGate.evaluate(Self.signals(text))
            #expect(d.kind == .conversational || d.kind == .clarification,
                    "input '\(text)' expected .conversational or .clarification, got \(d.kind)")
        }
    }

    @Test("Named person alone does NOT hint Messages")
    func personalNameDoesNotHintMessages() {
        // This is the core regression: the prior router turned "tell me about
        // Marie Curie" into a Messages/Email pill. A person entity by itself
        // yields knowledge candidates only.
        let ents = ExtractedEntities(
            names: ["Marie Curie"], places: [], organizations: [],
            urls: [], phoneNumbers: [], emails: [],
            ocrText: nil, correctedInput: nil, detectedLanguage: nil
        )
        let d = ConversationalGate.evaluate(Self.signals("tell me about Marie Curie", entities: ents))
        #expect(d.kind == .candidateScope)
        #expect(!d.candidateToolHints.contains("Messages"))
        #expect(!d.candidateToolHints.contains("Automate"))
        #expect(d.candidateToolHints.contains("WikipediaSearch"))
    }

    // MARK: - Reply-prefix behavior

    @Test("Empty reply payload yields replyElaboration")
    func emptyReplyIsElaboration() {
        let d = ConversationalGate.evaluate(
            Self.signals("[Replying to: \"Q\" → \"A\"]", replyPayload: "")
        )
        #expect(d.kind == .replyElaboration)
    }

    @Test("Reply with payload evaluates the payload, not the quoted text")
    func replyWithPayloadIgnoresQuoted() {
        // If the classifier saw the quoted answer ("She's an actress..."),
        // it would misclassify (likely as Messages intent on declarative
        // text). With the payload-only view it sees just the user's actual
        // follow-up question.
        //
        // "when was she born?" is short (4 tokens, under the >4 bar for
        // interrogative knowledge queries) and has no entity — the real-
        // world flow would supply a priorTool and hit the follow-up
        // continuation branch. In this stubbed test (priorTool: nil) the
        // correct outcome is conversational — the LLM answers from context
        // provided to it, not via a new tool call.
        let d = ConversationalGate.evaluate(
            Self.signals(
                "[Replying to: \"Q\" → \"She's an actress, known for Euphoria.\"] when was she born?",
                replyPayload: "when was she born?"
            )
        )
        // Crucial: NOT Messages / toolSignal. Conversational is the target.
        #expect(d.kind == .conversational || d.kind == .clarification)
        #expect(!d.candidateToolHints.contains("Messages"))
        #expect(!d.candidateToolHints.contains("Automate"))
    }
}
