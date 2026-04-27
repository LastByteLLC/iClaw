import Foundation
import AppIntents

// MARK: - Extraction Args

public struct EmailArgs: ToolArguments {
    public let recipient: String?
    public let subject: String
    public let body: String
}

// MARK: - EmailTool

/// Composes an email via mailto: URL and shows a preview widget.
/// If the mailto URL cannot be constructed, the widget offers a "Copy" fallback.
public struct EmailTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Email"
    public let schema = "Send an email: 'email John about the meeting tomorrow', 'draft an email with subject hello'."
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Send an email")

    public init() {}

    // MARK: - ExtractableCoreTool

    public typealias Args = EmailArgs
    public static let extractionSchema: String = loadExtractionSchema(
        named: "Email", fallback: #"{"recipient":"string?","subject":"string","body":"string"}"#
    )

    // MARK: - Structured Execute

    public func execute(args: EmailArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        await timed {
            if CommunicationChannelResolver.isContactLookupQuestion(rawInput) {
                Log.tools.debug("EmailTool self-refused: contact-info lookup question ('\(rawInput.prefix(60))') — not a send directive")
                return ToolIO(text: "", status: .error)
            }
            return await composeEmail(recipient: args.recipient, subject: args.subject, body: args.body)
        }
    }

    // MARK: - Raw Execute

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        await timed {
            if CommunicationChannelResolver.isContactLookupQuestion(input) {
                Log.tools.debug("EmailTool self-refused: contact-info lookup question ('\(input.prefix(60))')")
                return ToolIO(text: "", status: .error)
            }
            return await composeEmail(recipient: nil, subject: "New Message from iClaw", body: input)
        }
    }

    // MARK: - Core Logic

    @MainActor
    private func composeEmail(recipient: String?, subject: String, body: String) -> ToolIO {
        let mailtoURL = buildMailtoURL(recipient: recipient, subject: subject, body: body)

        if let url = mailtoURL {
            URLOpener.open(url)
        }

        let widgetData = EmailComposeWidgetData(
            recipient: recipient,
            subject: subject,
            body: body,
            mailtoURL: mailtoURL
        )

        let text: String
        if mailtoURL != nil {
            text = "Email draft opened with subject: '\(subject)'"
        } else {
            text = "Couldn't open your mail app. Use the Copy button to grab the email content."
        }

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "EmailComposeWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
    }

    private func buildMailtoURL(recipient: String?, subject: String, body: String) -> URL? {
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let to = recipient?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(to)?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}

// MARK: - AppIntent

public struct EmailIntent: AppIntent {
    public static var title: LocalizedStringResource { "Send Email" }
    public static var description: IntentDescription? { IntentDescription("Sends an email using the iClaw EmailTool.") }

    @Parameter(title: "Subject")
    public var subject: String

    @Parameter(title: "Body")
    public var body: String

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tool = EmailTool()
        let result = try await tool.execute(input: "\(subject)\n\(body)")
        return .result(value: result.text)
    }
}
