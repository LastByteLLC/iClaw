import Foundation

// MARK: - Extraction Args

public struct MessagesArgs: ToolArguments {
    public let recipient: String
    public let message: String
}

// MARK: - macOS: CoreTool with AppleScript (DMG) / sms: URL (MAS)

#if os(macOS)
import AppKit

public struct MessagesTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Messages"
    public let schema = "Send an iMessage: 'text John hey are you free tonight', 'send a message to 555-1234'."
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Send a message")

    public init() {}

    // MARK: - ExtractableCoreTool

    public typealias Args = MessagesArgs
    public static let extractionSchema: String = loadExtractionSchema(
        named: "Messages", fallback: #"{"recipient":"string","message":"string"}"#
    )

    // MARK: - Execute

    public func execute(args: MessagesArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        if CommunicationChannelResolver.isContactLookupQuestion(rawInput) {
            Log.tools.debug("MessagesTool self-refused: contact-info lookup question ('\(rawInput.prefix(60))') — not a send directive")
            return ToolIO(text: "", status: .error)
        }
        return await sendMessage(recipient: args.recipient, message: args.message)
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        if CommunicationChannelResolver.isContactLookupQuestion(input) {
            Log.tools.debug("MessagesTool self-refused: contact-info lookup question ('\(input.prefix(60))')")
            return ToolIO(text: "", status: .error)
        }
        // Best-effort: treat entire input as message body, no recipient
        return ToolIO(text: "I need a recipient. Try: 'text John hello'.", status: .error)
    }

    // MARK: - Core Logic

    private func sendMessage(recipient: String, message: String) async -> ToolIO {
        let recipient = recipient.trimmingCharacters(in: .whitespaces)
        let message = message.trimmingCharacters(in: .whitespaces)

        guard !recipient.isEmpty else {
            return ToolIO(text: "No recipient provided.", status: .error)
        }
        guard !message.isEmpty else {
            return ToolIO(text: "No message text provided.", status: .error)
        }

        let smsURL = buildSMSURL(recipient: recipient, body: message)

        #if MAS_BUILD
        // MAS: open sms: URL, user confirms in Messages.app
        if let url = smsURL {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
        }
        let widgetData = MessageComposeWidgetData(
            recipient: recipient, message: message, isSent: false, smsURL: smsURL
        )
        return ToolIO(
            text: "Opened Messages with your message to \(recipient). Please confirm and send.",
            status: .ok,
            outputWidget: "MessageComposeWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
        #else
        // DMG: try AppleScript first, fall back to sms: URL
        let sent = await sendViaAppleScript(recipient: recipient, message: message)

        let widgetData = MessageComposeWidgetData(
            recipient: recipient, message: message, isSent: sent, smsURL: sent ? nil : smsURL
        )
        let preview = message.count > 50 ? String(message.prefix(50)) + "…" : message
        let text = sent
            ? "Sent iMessage to \(recipient): \"\(preview)\""
            : "Couldn't send directly. Tap 'Open in Messages' to send manually."

        return ToolIO(
            text: text,
            status: .ok,
            outputWidget: "MessageComposeWidget",
            widgetData: widgetData,
            isVerifiedData: true
        )
        #endif
    }

    #if !MAS_BUILD
    private func sendViaAppleScript(recipient: String, message: String) async -> Bool {
        let safeRecipient = recipient
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let safeMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        let script = """
        tell application "Messages"
            send "\(safeMessage)" to participant "\(safeRecipient)"
        end tell
        """

        do {
            _ = try await UserScriptRunner.run(script)
            return true
        } catch {
            Log.engine.debug("AppleScript message send failed: \(error)")
            return false
        }
    }
    #endif

    private func buildSMSURL(recipient: String, body: String) -> URL? {
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        return URL(string: "sms:\(recipient)&body=\(encodedBody)")
    }
}

// MARK: - iOS: MFMessageComposeViewController

#elseif os(iOS)
import UIKit
import MessageUI

public struct MessagesTool: CoreTool, ExtractableCoreTool, Sendable {
    public let name = "Messages"
    public let schema = "Send an iMessage: 'text John hey are you free tonight', 'send a message to 555-1234'."
    public let isInternal = false
    public let category = CategoryEnum.offline
    public let consentPolicy = ActionConsentPolicy.requiresConsent(description: "Send a message")

    public init() {}

    public typealias Args = MessagesArgs
    public static let extractionSchema: String = loadExtractionSchema(
        named: "Messages", fallback: #"{"recipient":"string","message":"string"}"#
    )

    public func execute(args: MessagesArgs, rawInput: String, entities: ExtractedEntities?) async throws -> ToolIO {
        if CommunicationChannelResolver.isContactLookupQuestion(rawInput) {
            Log.tools.debug("MessagesTool self-refused: contact-info lookup question ('\(rawInput.prefix(60))') — not a send directive")
            return ToolIO(text: "", status: .error)
        }
        let recipient = args.recipient.trimmingCharacters(in: .whitespaces)
        let message = args.message.trimmingCharacters(in: .whitespaces)

        guard !recipient.isEmpty else { return ToolIO(text: "No recipient provided.", status: .error) }
        guard !message.isEmpty else { return ToolIO(text: "No message text provided.", status: .error) }
        guard MFMessageComposeViewController.canSendText() else {
            return ToolIO(text: "This device cannot send text messages.", status: .error)
        }

        let result: String = await withCheckedContinuation { continuation in
            Task { @MainActor in
                let coordinator = MessageComposeCoordinator(continuation: continuation)
                let composer = MFMessageComposeViewController()
                composer.recipients = [recipient]
                composer.body = message
                composer.messageComposeDelegate = coordinator
                objc_setAssociatedObject(composer, &MessageComposeCoordinator.associatedKey, coordinator, .OBJC_ASSOCIATION_RETAIN)

                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                    let rootVC = scene.keyWindow?.rootViewController else {
                    continuation.resume(returning: "Could not present message composer.")
                    return
                }
                var topVC = rootVC
                while let presented = topVC.presentedViewController { topVC = presented }
                topVC.present(composer, animated: true)
            }
        }

        let isSent = result.hasPrefix("Message sent")
        let widgetData = MessageComposeWidgetData(
            recipient: recipient, message: message, isSent: isSent
        )
        return ToolIO(
            text: result,
            status: isSent ? .ok : .error,
            outputWidget: "MessageComposeWidget",
            widgetData: widgetData,
            isVerifiedData: isSent
        )
    }

    public func execute(input: String, entities: ExtractedEntities? = nil) async throws -> ToolIO {
        if CommunicationChannelResolver.isContactLookupQuestion(input) {
            Log.tools.debug("MessagesTool self-refused: contact-info lookup question ('\(input.prefix(60))')")
            return ToolIO(text: "", status: .error)
        }
        return ToolIO(text: "I need a recipient. Try: 'text John hello'.", status: .error)
    }
}

@MainActor
private final class MessageComposeCoordinator: NSObject, MFMessageComposeViewControllerDelegate {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0
    private let continuation: CheckedContinuation<String, Never>
    private var hasResumed = false

    init(continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func messageComposeViewController(
        _ controller: MFMessageComposeViewController,
        didFinishWith result: MessageComposeResult
    ) {
        controller.dismiss(animated: true)
        guard !hasResumed else { return }
        hasResumed = true
        switch result {
        case .sent:
            let preview = (controller.body ?? "").prefix(50)
            let recipient = controller.recipients?.first ?? "recipient"
            continuation.resume(returning: "Message sent to \(recipient): \"\(preview)\"")
        case .cancelled:
            continuation.resume(returning: "Message cancelled by user.")
        case .failed:
            continuation.resume(returning: "Failed to send the message.")
        @unknown default:
            continuation.resume(returning: "Unknown result.")
        }
    }
}
#endif
