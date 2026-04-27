/// iClaw Native Messaging Host
///
/// Thin proxy between browser native messaging (stdin/stdout, length-prefixed JSON)
/// and the iClaw BrowserBridge (localhost TLS, same framing).
///
/// Chrome/Firefox spawn this process when the extension calls connectNative().
/// Safari uses its own app extension mechanism instead of this binary.

import Foundation
import Network

// MARK: - Configuration

/// Well-known port — must match `BrowserBridge.wellKnownPort` in iClawCore.
/// Duplicated here because iClawNativeHost is a standalone binary that
/// doesn't link iClawCore. If changing, update both locations.
let bridgePort: UInt16 = 19284

// Single-threaded proxy — suppress concurrency isolation for global state.
nonisolated(unsafe) var socketConnection: NWConnection?

// MARK: - TCP connection to iClaw

func connectToIClaw() -> Bool {
    let endpoint = NWEndpoint.hostPort(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: bridgePort)!
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

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var connected = false

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            connected = true
            semaphore.signal()
        case .failed, .cancelled:
            semaphore.signal()
        default:
            break
        }
    }

    connection.start(queue: .global())
    _ = semaphore.wait(timeout: .now() + 5)

    if connected {
        socketConnection = connection
        startReadingFromSocket(connection)
        return true
    }
    return false
}

// MARK: - Stdin → Socket (browser → iClaw)

/// Read length-prefixed messages from stdin and forward to the TCP socket.
func readStdinLoop() {
    while true {
        // Read 4-byte length header
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let headerRead = fread(&lengthBytes, 1, 4, stdin)
        guard headerRead == 4 else { break } // EOF or error

        let length = UInt32(lengthBytes[0])
            | (UInt32(lengthBytes[1]) << 8)
            | (UInt32(lengthBytes[2]) << 16)
            | (UInt32(lengthBytes[3]) << 24)

        guard length > 0, length < 1_048_576 else { continue } // Max 1MB

        // Read message body
        var body = [UInt8](repeating: 0, count: Int(length))
        let bodyRead = fread(&body, 1, Int(length), stdin)
        guard bodyRead == Int(length) else { break }

        // Forward to socket with same framing
        let data = Data(body)
        forwardToSocket(data)
    }

    // Stdin closed — exit
    exit(0)
}

func forwardToSocket(_ data: Data) {
    guard let conn = socketConnection else { return }

    // Frame with 4-byte length prefix
    var length = UInt32(data.count).littleEndian
    var framed = Data(bytes: &length, count: 4)
    framed.append(data)

    conn.send(content: framed, completion: .contentProcessed { error in
        if let error {
            fputs("[iClawNativeHost] Socket send error: \(error)\n", stderr)
        }
    })
}

// MARK: - Socket → Stdout (iClaw → browser)

/// Read length-prefixed messages from the socket and write to stdout.
func startReadingFromSocket(_ conn: NWConnection) {
    // Read 4-byte length header
    conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, _, isComplete, error in
        guard let content, content.count == 4 else {
            if isComplete || error != nil {
                fputs("[iClawNativeHost] Socket disconnected\n", stderr)
                exit(1)
            }
            startReadingFromSocket(conn)
            return
        }

        let length = content.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard length > 0, length < 1_048_576 else {
            startReadingFromSocket(conn)
            return
        }

        // Read message body
        conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, isComplete, error in
            if let body {
                writeToStdout(body)
            }
            if !isComplete && error == nil {
                startReadingFromSocket(conn)
            } else {
                exit(1)
            }
        }
    }
}

func writeToStdout(_ data: Data) {
    // Write 4-byte length header (native byte order = little-endian on ARM/x86)
    var length = UInt32(data.count).littleEndian
    fwrite(&length, 4, 1, stdout)
    // Write message body
    _ = data.withUnsafeBytes { ptr in
        fwrite(ptr.baseAddress, 1, data.count, stdout)
    }
    fflush(stdout)
}

// MARK: - Entry point

// Try to connect to the running iClaw app
guard connectToIClaw() else {
    // Send error back to the browser
    let error = #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"Cannot connect to iClaw app. Is it running?"},"id":null}"#
    writeToStdout(Data(error.utf8))
    exit(1)
}

// Start relaying stdin → socket on the main thread
readStdinLoop()
