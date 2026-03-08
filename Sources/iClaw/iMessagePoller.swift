import Foundation
import SQLite3

@MainActor
class iMessagePoller {
    static let shared = iMessagePoller()

    private let dbPath = NSString("~/Library/Messages/chat.db").expandingTildeInPath
    private let triggerPrefix = "hey claw"
    private var lastMessageROWID: Int64 = 0
    private var pollTimer: Timer?
    private var ownerIdentifiers: [String] = []
    private var sentReplies: Set<String> = []  // Track agent replies to avoid feedback loops
    private var processedTexts: Set<String> = []  // Deduplicate self-chat mirror messages

    private init() {
        // Build owner identifiers from MeCard (phone + email)
        let me = MeCardManager.shared
        if let phone = me.userPhone {
            ownerIdentifiers.append(phone)
            // Normalize: strip spaces/dashes, keep +country code
            let normalized = phone.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            if normalized != phone {
                ownerIdentifiers.append(normalized)
            }
        }
        if let email = me.userEmail {
            ownerIdentifiers.append(email)
        }

        // Seed lastMessageROWID to current max so we don't process old messages
        seedLastROWID()
    }

    func start() {
        guard pollTimer == nil else { return }
        print("[iMessagePoller] Starting — watching for '\(triggerPrefix)' from \(ownerIdentifiers)")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        print("[iMessagePoller] Stopped")
    }

    private func seedLastROWID() {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        let sql = "SELECT MAX(ROWID) FROM message"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                lastMessageROWID = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        print("[iMessagePoller] Seeded at ROWID \(lastMessageROWID)")
    }

    private func poll() {
        guard let db = openDB() else {
            print("[iMessagePoller] Cannot open chat.db — Full Disk Access required")
            return
        }
        defer { sqlite3_close(db) }

        // Query new messages since last check
        // Include is_from_me flag to handle "message to self" case
        let sql = """
            SELECT m.ROWID, m.text, h.id, m.is_from_me
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.ROWID > ?
            AND m.text IS NOT NULL
            ORDER BY m.ROWID ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[iMessagePoller] SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, lastMessageROWID)

        var newMessages: [(rowid: Int64, text: String, sender: String, isFromMe: Bool)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let sender = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let isFromMe = sqlite3_column_int(stmt, 3) == 1
            newMessages.append((rowid, text, sender, isFromMe))
        }

        for msg in newMessages {
            lastMessageROWID = msg.rowid

            let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Skip if this is a reply the agent sent (feedback loop prevention)
            if sentReplies.contains(trimmed) {
                sentReplies.remove(trimmed)
                print("[iMessagePoller] Skipping own reply: '\(trimmed.prefix(50))'")
                continue
            }

            // Deduplicate: self-chat creates two rows for the same message
            let dedupeKey = "\(trimmed.lowercased())"
            if processedTexts.contains(dedupeKey) {
                processedTexts.remove(dedupeKey)
                print("[iMessagePoller] Skipping duplicate: '\(trimmed.prefix(50))'")
                continue
            }

            print("[iMessagePoller] New message — ROWID: \(msg.rowid), from_me: \(msg.isFromMe), sender: '\(msg.sender)', text: '\(trimmed.prefix(50))'")

            // Must start with trigger prefix
            guard trimmed.lowercased().hasPrefix(triggerPrefix) else { continue }

            // Strip the trigger prefix to get the actual prompt
            let prompt = String(trimmed.dropFirst(triggerPrefix.count))
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !prompt.isEmpty else { continue }

            // Mark this text so the mirror message gets skipped
            processedTexts.insert(dedupeKey)

            print("[iMessagePoller] Received: \(prompt)")

            // Show in UI with sender info
            let senderLabel = msg.sender.isEmpty ? "You (iMessage)" : "iMessage (\(msg.sender))"
            MessageBus.shared.post(role: "user", content: "[\(senderLabel)] \(prompt)")

            processMessage(prompt: prompt, replyTo: msg.sender)
        }
    }

    private func processMessage(prompt: String, replyTo sender: String) {
        Task { @MainActor in
            do {
                let recentMemories = try await DatabaseManager.shared.searchMemories(query: prompt, limit: 5)
                let response = try await ModelManager.shared.generateResponse(prompt: prompt, history: recentMemories)

                // Save to memory
                let userMemory = Memory(id: nil, role: "user", content: prompt, embedding: nil, created_at: Date(), is_important: false)
                _ = try await DatabaseManager.shared.saveMemory(userMemory)
                let agentMemory = Memory(id: nil, role: "agent", content: response, embedding: nil, created_at: Date(), is_important: false)
                _ = try await DatabaseManager.shared.saveMemory(agentMemory)

                // Show response in UI
                MessageBus.shared.post(role: "agent", content: response)

                // Track this reply so the poller skips it when it appears in chat.db
                self.sentReplies.insert(response)

                // Reply via iMessage using AppleScript
                let replyTarget = sender.isEmpty ? (MeCardManager.shared.userPhone ?? MeCardManager.shared.userEmail ?? "") : sender
                let safeTo = replyTarget.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let safeContent = response.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                tell application "Messages"
                    send "\(safeContent)" to participant "\(safeTo)"
                end tell
                """
                if let appleScript = NSAppleScript(source: script) {
                    var scriptError: NSDictionary?
                    appleScript.executeAndReturnError(&scriptError)
                    if let scriptError = scriptError {
                        print("[iMessagePoller] AppleScript error: \(scriptError)")
                    }
                }
                print("[iMessagePoller] Replied: \(response)")
            } catch {
                print("[iMessagePoller] Error processing message: \(error)")
            }
        }
    }

    private func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(dbPath, &db, flags, nil) == SQLITE_OK {
            return db
        }
        return nil
    }
}
