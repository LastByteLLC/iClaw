import Foundation
import os

/// Manages shared items received from the Share Extension.
///
/// The Share Extension writes a JSON manifest + optional file data to
/// `{AppGroup}/ShareHook/Inbox/{uuid}/`. This actor monitors that directory
/// and converts items into `FileAttachment` instances pushed to
/// `ShareAttachmentBus` for the UI to pick up.
///
/// ## Push-based monitoring
/// Three layers ensure timely and efficient inbox pickup:
/// 1. **Distributed notification** — the Share Extension posts `com.geticlaw.iClaw.shareHook`
///    via `DistributedNotificationCenter`; this manager reacts instantly.
/// 2. **DispatchSource** — file-system monitor on the inbox directory fires when entries
///    are added, as a second push signal (no extension-side changes needed).
/// 3. **Fallback poll** — 60s sweep catches anything the other two miss.
public actor ShareHookManager {
    public static let shared = ShareHookManager()

    /// App group suite shared with the Share Extension.
    static let suiteName = "5QGXMKNW2A.com.geticlaw.iClaw"

    /// Distributed notification name posted by the Share Extension after writing items.
    public static let distributedNotificationName = Notification.Name("com.geticlaw.iClaw.shareHook")

    /// Directory where the Share Extension drops items.
    private let inboxDir: URL

    private var isMonitoring = false
    private var monitorTask: Task<Void, Never>?
    private var dispatchSource: DispatchSourceFileSystemObject?

    private init() {
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.suiteName)
        inboxDir = (shared ?? FileManager.default.temporaryDirectory).appendingPathComponent("ShareHook/Inbox")
    }

    // MARK: - Start / Stop

    /// Starts monitoring the shared inbox for new items.
    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        try? FileManager.default.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        Log.tools.info("ShareHookManager: started monitoring \(self.inboxDir.path)")

        // Clean up stale items from prior sessions
        cleanupStaleItems()

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
        Log.tools.info("ShareHookManager: stopped monitoring")
    }

    /// Processes inbox immediately (called when the app receives iclaw:// URL).
    public func processNow() async {
        await Self.processInbox(at: inboxDir)
    }

    // MARK: - DispatchSource (file-system push)

    private func startDispatchSource() {
        let fd = open(inboxDir.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.tools.error("ShareHookManager: failed to open inbox directory for monitoring")
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

    // MARK: - Manifest (matches Extension/share/ShareHookItem.swift)

    struct ShareHookItem: Codable, Sendable {
        let id: UUID
        let timestamp: Date
        let type: ShareType
        let prompt: String?
        let url: String?
        let text: String?
        let fileName: String?
        let fileExtension: String?

        enum ShareType: String, Codable, Sendable {
            case url, file, text, image
        }
    }

    // MARK: - Ingestion

    static func processInbox(at inboxDir: URL) async {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: nil) else { return }

        let itemDirs = entries.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !itemDirs.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for itemDir in itemDirs {
            let manifestURL = itemDir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            do {
                let data = try Data(contentsOf: manifestURL)
                let item = try decoder.decode(ShareHookItem.self, from: data)

                switch item.type {
                case .url:
                    await handleURL(item)
                case .text:
                    await handleText(item, dir: itemDir)
                case .file, .image:
                    await handleFile(item, dir: itemDir)
                }

                // Remove processed item directory
                try fm.removeItem(at: itemDir)
                Log.tools.debug("ShareHook ingested item \(item.id) (\(item.type.rawValue))")
            } catch {
                Log.tools.error("ShareHook failed to process \(itemDir.lastPathComponent): \(error)")
            }
        }
    }

    private static func handleURL(_ item: ShareHookItem) async {
        guard let urlString = item.url else { return }
        await ShareAttachmentBus.shared.post(
            url: urlString,
            prompt: item.prompt
        )
    }

    private static func handleText(_ item: ShareHookItem, dir: URL) async {
        guard let text = item.text else { return }

        // Write text to a temp file so it can be treated as a FileAttachment
        let pasteDir = FileManager.default.temporaryDirectory.appendingPathComponent("iClaw-Paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: pasteDir, withIntermediateDirectories: true)

        let fileName = item.fileName ?? "shared-text.txt"
        let fileURL = pasteDir.appendingPathComponent(fileName)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)

        let attachment = FileAttachment(url: fileURL)
        await ShareAttachmentBus.shared.post(
            attachment: attachment,
            prompt: item.prompt
        )
    }

    private static func handleFile(_ item: ShareHookItem, dir: URL) async {
        let contentURL = dir.appendingPathComponent("content.data")
        guard FileManager.default.fileExists(atPath: contentURL.path) else { return }

        // Copy to iClaw-Paste with the original filename
        let pasteDir = FileManager.default.temporaryDirectory.appendingPathComponent("iClaw-Paste", isDirectory: true)
        try? FileManager.default.createDirectory(at: pasteDir, withIntermediateDirectories: true)

        let ext = item.fileExtension ?? "bin"
        let fileName = item.fileName ?? "shared-file.\(ext)"
        let destURL = pasteDir.appendingPathComponent(fileName)

        // Remove any existing file at destination
        try? FileManager.default.removeItem(at: destURL)

        do {
            try FileManager.default.copyItem(at: contentURL, to: destURL)
        } catch {
            Log.tools.error("ShareHook failed to copy file: \(error)")
            return
        }

        let attachment = FileAttachment(url: destURL)
        await ShareAttachmentBus.shared.post(
            attachment: attachment,
            prompt: item.prompt
        )
    }

    // MARK: - Cleanup

    /// Removes item directories older than 1 hour.
    private func cleanupStaleItems() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let cutoff = Date().addingTimeInterval(-3600)
        for entry in entries {
            if let values = try? entry.resourceValues(forKeys: [.creationDateKey]),
               let created = values.creationDate, created < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
}

// MARK: - ShareAttachmentBus

/// Observable bus that carries shared attachments from `ShareHookManager` to the UI.
/// Follows the same pattern as `MessageBus`.
@MainActor @Observable
public final class ShareAttachmentBus {
    public static let shared = ShareAttachmentBus()

    /// Pending shared attachments waiting to be picked up by ChatView.
    public var pending: [SharedItem] = []

    public struct SharedItem: Sendable {
        public let attachment: FileAttachment?
        public let url: String?
        public let prompt: String?
    }

    func post(attachment: FileAttachment, prompt: String?) {
        pending.append(SharedItem(attachment: attachment, url: nil, prompt: prompt))
    }

    func post(url: String, prompt: String?) {
        pending.append(SharedItem(attachment: nil, url: url, prompt: prompt))
    }
}
