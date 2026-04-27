/// Safari Web Extension Handler
///
/// Native messaging handler for the Safari Web Extension.
/// Connects to the running iClaw app via TLS on a well-known localhost port.
/// No App Group container access needed — avoids the macOS "access data from other apps" dialog.

import Foundation
import SafariServices
import Network

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    /// Well-known port matching BrowserBridge.wellKnownPort.
    private static let bridgePort: UInt16 = 19284

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard let message else {
            completeRequest(context, response: ["error": "No message received"])
            return
        }

        // Serialize the message to Data (Sendable) before crossing isolation boundaries
        guard let messageData = try? JSONSerialization.data(withJSONObject: message) else {
            completeRequest(context, response: ["error": "Invalid message format"])
            return
        }

        nonisolated(unsafe) let ctx = context
        forwardToIClaw(messageData: messageData) { responseData in
            let response: [String: Any]
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
                response = json
            } else {
                response = ["error": "Invalid response from iClaw"]
            }
            let item = NSExtensionItem()
            item.userInfo = [SFExtensionMessageKey: response]
            ctx.completeRequest(returningItems: [item])
        }
    }

    private func forwardToIClaw(messageData: Data, completion: @Sendable @escaping (Data) -> Void) {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: Self.bridgePort)!
        )

        // TLS with self-signed cert trust (localhost only)
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, verifyComplete in verifyComplete(true) },
            .global(qos: .userInitiated)
        )
        let params = NWParameters(tls: tlsOptions)
        let connection = NWConnection(to: endpoint, using: params)

        // Frame with 4-byte length prefix (same as native messaging protocol)
        let framed: Data = {
            var len = UInt32(messageData.count).littleEndian
            var d = Data(bytes: &len, count: 4)
            d.append(messageData)
            return d
        }()

        let errorResponse: @Sendable (String) -> Data = { msg in
            (try? JSONSerialization.data(withJSONObject: ["error": msg])) ?? Data()
        }

        let completionRef = completion

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: framed, completion: .contentProcessed { error in
                    if error != nil {
                        completionRef(errorResponse("Send failed"))
                        connection.cancel()
                        return
                    }
                    Self.readResponse(connection: connection, completion: completionRef, errorResponse: errorResponse)
                })
            case .failed:
                completionRef(errorResponse("Cannot connect to iClaw"))
                connection.cancel()
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        // Timeout after 10 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if connection.state != .cancelled {
                completionRef(errorResponse("Connection to iClaw timed out"))
                connection.cancel()
            }
        }
    }

    private static func readResponse(
        connection: NWConnection,
        completion: @Sendable @escaping (Data) -> Void,
        errorResponse: @Sendable @escaping (String) -> Data
    ) {
        // Read 4-byte length header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, _ in
            guard let header, header.count == 4 else {
                completion(errorResponse("No response from iClaw"))
                connection.cancel()
                return
            }

            let responseLength = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            guard responseLength > 0, responseLength < 1_048_576 else {
                completion(errorResponse("Invalid response length"))
                connection.cancel()
                return
            }

            // Read response body
            connection.receive(minimumIncompleteLength: Int(responseLength), maximumLength: Int(responseLength)) { body, _, _, _ in
                defer { connection.cancel() }
                completion(body ?? errorResponse("Empty response from iClaw"))
            }
        }
    }

    private func completeRequest(_ context: NSExtensionContext, response: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item])
    }
}
