import Foundation
import os

/// Manages the MailKit extension hook — receives incoming email notifications
/// from the Mail extension and stores compact summaries for contextual awareness.
///
/// Communication uses a shared UserDefaults suite (app group) for the consent toggle
/// and a shared directory for message ingestion. The MailKit .appex extension writes
/// JSON message files; this manager watches for and ingests them.
///
/// ## Push-based monitoring
/// Three layers ensure timely and efficient inbox pickup:
/// 1. **Distributed notification** — the Mail extension posts `com.geticlaw.iClaw.mailHook`
///    via `DistributedNotificationCenter`; this manager reacts instantly.
/// 2. **DispatchSource** — file-system monitor on the inbox directory fires when files
///    are added, as a second push signal (no extension-side changes needed).
/// 3. **Fallback poll** — 60s sweep catches anything the other two miss (e.g., crashed
///    extension, sandbox edge case).
public actor MailHookManager {
    public static let shared = MailHookManager()

    /// App group suite for shared settings with the Mail extension.
    public static let suiteName = "5QGXMKNW2A.com.geticlaw.iClaw"

    /// UserDefaults key for the consent toggle.
    public static let enabledKey = "mailHookEnabled"

    /// Distributed notification name posted by the Mail extension after writing a message file.
    public static let distributedNotificationName = Notification.Name("com.geticlaw.iClaw.mailHook")

    /// Directory where the Mail extension drops incoming message JSON files.
    private let inboxDir: URL

    private var isMonitoring = false
    private var monitorTask: Task<Void, Never>?
    private var dispatchSource: DispatchSourceFileSystemObject?

    private init() {
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.suiteName)
        inboxDir = (shared ?? FileManager.default.temporaryDirectory).appendingPathComponent("MailHook/Inbox")
    }

    // MARK: - Consent

    /// Whether the user has consented to receiving email notifications.
    public var isEnabled: Bool {
        UserDefaults(suiteName: Self.suiteName)?.bool(forKey: Self.enabledKey) ?? false
    }

    // MARK: - Start / Stop

    /// Starts monitoring the shared inbox directory for new message files.
    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)

        Log.tools.info("MailHookManager: started monitoring \(self.inboxDir.path)")

        startDispatchSource()
        startDistributedNotification()

        // Degraded fallback poll — 60s sweep for robustness
        monitorTask = Task { [inboxDir] in
            // Process once immediately for any items from prior sessions
            await Self.processInbox(at: inboxDir)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await Self.processInbox(at: inboxDir)
            }
        }
    }

    /// Stops monitoring.
    public func stop() {
        isMonitoring = false
        monitorTask?.cancel()
        monitorTask = nil
        stopDispatchSource()
        stopDistributedNotification()
        Log.tools.info("MailHookManager: stopped monitoring")
    }

    // MARK: - DispatchSource (file-system push)

    private func startDispatchSource() {
        let fd = open(inboxDir.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.tools.error("MailHookManager: failed to open inbox directory for monitoring")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [inboxDir] in
            Task { await Self.processInbox(at: inboxDir) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dispatchSource = source
    }

    private func stopDispatchSource() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    // MARK: - Distributed Notification (cross-process push)

    private nonisolated func startDistributedNotification() {
        let inboxDir = self.inboxDir
        DistributedNotificationCenter.default().addObserver(
            forName: Self.distributedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { await Self.processInbox(at: inboxDir) }
        }
    }

    private nonisolated func stopDistributedNotification() {
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: Self.distributedNotificationName,
            object: nil
        )
    }

    // MARK: - Message Ingestion

    /// A lightweight email record written by the Mail extension.
    struct IncomingEmail: Codable, Sendable {
        let subject: String
        let sender: String
        let dateSent: Date
        let bodySnippet: String
    }

    /// Process any pending message files in the shared inbox.
    private static func processInbox(at inboxDir: URL) async {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil) else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard !jsonFiles.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in jsonFiles {
            do {
                let data = try Data(contentsOf: file)
                let email = try decoder.decode(IncomingEmail.self, from: data)
                let compacted = ContentCompactor.compact(email.bodySnippet, limit: AppConfig.emailBodySnippetLimit)

                Log.tools.debug("MailHook ingested: \(email.subject) from \(email.sender)")

                // Store as a memory for RAG retrieval
                let content = "Email from \(email.sender): \(email.subject). \(compacted)"
                let memory = Memory(
                    role: "email",
                    content: content,
                    created_at: email.dateSent,
                    is_important: false
                )
                _ = try await DatabaseManager.shared.saveMemory(memory)

                // Remove processed file
                try fm.removeItem(at: file)
            } catch {
                Log.tools.error("MailHook failed to process \(file.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Stats

    /// Number of emails ingested (stored with role "email").
    public func ingestedCount() async -> Int {
        do {
            return try await DatabaseManager.shared.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories WHERE role = 'email'") ?? 0
            }
        } catch {
            return 0
        }
    }
}
