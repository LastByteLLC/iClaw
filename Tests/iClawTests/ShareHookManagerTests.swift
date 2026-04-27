import Foundation
import Testing
@testable import iClawCore

@Suite("ShareHookManager", .serialized)
struct ShareHookManagerTests {

    // MARK: - Helpers

    /// Creates a temp inbox directory for test isolation.
    private func makeTempInbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareHookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a ShareHookItem manifest (and optional content.data) to a new item dir.
    @discardableResult
    private func writeManifest(
        inbox: URL,
        type: String,
        url: String? = nil,
        text: String? = nil,
        fileName: String? = nil,
        fileExtension: String? = nil,
        prompt: String? = nil,
        contentData: Data? = nil
    ) throws -> UUID {
        let id = UUID()
        let itemDir = inbox.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        let manifest: [String: Any?] = [
            "id": id.uuidString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": type,
            "url": url,
            "text": text,
            "fileName": fileName,
            "fileExtension": fileExtension,
            "prompt": prompt
        ]
        // Filter nils for valid JSON
        let filtered = manifest.compactMapValues { $0 }
        let data = try JSONSerialization.data(withJSONObject: filtered)
        try data.write(to: itemDir.appendingPathComponent("manifest.json"))

        if let contentData {
            try contentData.write(to: itemDir.appendingPathComponent("content.data"))
        }
        return id
    }

    /// Clears any stale items, processes the inbox, then returns only the new items.
    private func processAndDrain(inbox: URL) async -> [ShareAttachmentBus.SharedItem] {
        await MainActor.run { ShareAttachmentBus.shared.pending.removeAll() }
        await ShareHookManager.processInbox(at: inbox)
        return await MainActor.run {
            let items = ShareAttachmentBus.shared.pending
            ShareAttachmentBus.shared.pending.removeAll()
            return items
        }
    }

    /// Cleans up a temp inbox directory.
    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Manifest Parsing

    @Test("Ingest URL item creates bus entry with URL string and prompt")
    func ingestURLItem() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        try writeManifest(
            inbox: inbox,
            type: "url",
            url: "https://example.com/article",
            prompt: "Summarize this"
        )

        let items = await processAndDrain(inbox: inbox)
        #expect(items.count == 1)
        #expect(items[0].url == "https://example.com/article")
        #expect(items[0].prompt == "Summarize this")
        #expect(items[0].attachment == nil)
    }

    @Test("Ingest text item creates FileAttachment pointing to .txt file")
    func ingestTextItem() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        try writeManifest(
            inbox: inbox,
            type: "text",
            text: "Hello, this is shared text content.",
            prompt: "What does this say?"
        )

        let items = await processAndDrain(inbox: inbox)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.attachment != nil)
        #expect(item.prompt == "What does this say?")

        if let attachment = item.attachment {
            #expect(attachment.fileCategory == .text)
            let content = try String(contentsOf: attachment.url, encoding: .utf8)
            #expect(content == "Hello, this is shared text content.")
        }
    }

    @Test("Ingest file item copies content.data and creates FileAttachment")
    func ingestFileItem() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        let fileContent = Data("PDF mock data".utf8)
        try writeManifest(
            inbox: inbox,
            type: "file",
            fileName: "report.pdf",
            fileExtension: "pdf",
            contentData: fileContent
        )

        let items = await processAndDrain(inbox: inbox)
        #expect(items.count == 1)
        let item = items[0]
        #expect(item.attachment != nil)
        #expect(item.attachment?.fileName == "report.pdf")

        if let attachment = item.attachment {
            let copied = try Data(contentsOf: attachment.url)
            #expect(copied == fileContent)
        }
    }

    @Test("Ingest image item copies content.data with image category")
    func ingestImageItem() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        let imageData = Data(repeating: 0xFF, count: 100)
        try writeManifest(
            inbox: inbox,
            type: "image",
            fileName: "photo.png",
            fileExtension: "png",
            contentData: imageData
        )

        let items = await processAndDrain(inbox: inbox)
        #expect(items.count == 1)
        #expect(items[0].attachment != nil)
        #expect(items[0].attachment?.fileName == "photo.png")
        #expect(items[0].attachment?.fileCategory == .image)
    }

    // MARK: - Edge Cases

    @Test("Empty inbox directory produces no bus entries")
    func emptyInboxIsNoOp() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        let items = await processAndDrain(inbox: inbox)
        #expect(items.isEmpty)
    }

    @Test("Malformed manifest JSON does not crash and directory is preserved")
    func malformedManifestSkipped() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        let itemDir = inbox.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)
        try Data("not valid json {{{".utf8).write(to: itemDir.appendingPathComponent("manifest.json"))

        let items = await processAndDrain(inbox: inbox)
        #expect(items.isEmpty)
        // Directory should still exist (error path doesn't delete)
        #expect(FileManager.default.fileExists(atPath: itemDir.path))
    }

    @Test("Processed items are deleted from inbox")
    func processedItemsDeleted() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        let id = try writeManifest(
            inbox: inbox,
            type: "url",
            url: "https://example.com"
        )

        let itemDir = inbox.appendingPathComponent(id.uuidString)
        #expect(FileManager.default.fileExists(atPath: itemDir.path))

        let items = await processAndDrain(inbox: inbox)
        #expect(!FileManager.default.fileExists(atPath: itemDir.path))
        #expect(items.count == 1)
    }

    @Test("File item without content.data produces no bus entry")
    func fileItemMissingContentData() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        try writeManifest(
            inbox: inbox,
            type: "file",
            fileName: "missing.pdf",
            fileExtension: "pdf"
        )

        let items = await processAndDrain(inbox: inbox)
        #expect(items.isEmpty)
    }

    @Test("URL item without url field produces no bus entry")
    func urlItemMissingURL() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        try writeManifest(
            inbox: inbox,
            type: "url"
        )

        let items = await processAndDrain(inbox: inbox)
        #expect(items.isEmpty)
    }

    @Test("Multiple items in inbox are all ingested")
    func multipleItems() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        try writeManifest(inbox: inbox, type: "url", url: "https://one.com")
        try writeManifest(inbox: inbox, type: "url", url: "https://two.com")
        try writeManifest(inbox: inbox, type: "text", text: "some notes")

        let items = await processAndDrain(inbox: inbox)
        #expect(items.count == 3)
    }

    @Test("Prompt is nil when not provided")
    func noPrompt() async throws {
        let inbox = try makeTempInbox()
        defer { cleanup(inbox) }

        try writeManifest(inbox: inbox, type: "url", url: "https://example.com")

        let items = await processAndDrain(inbox: inbox)
        #expect(items.count == 1)
        #expect(items[0].prompt == nil)
    }

    // MARK: - ShareAttachmentBus

    @Test("Bus post(url:) creates SharedItem with nil attachment")
    @MainActor
    func busPostURL() {
        let bus = ShareAttachmentBus()
        bus.post(url: "https://test.com", prompt: "check this")

        #expect(bus.pending.count == 1)
        #expect(bus.pending[0].url == "https://test.com")
        #expect(bus.pending[0].prompt == "check this")
        #expect(bus.pending[0].attachment == nil)
    }

    @Test("Bus post(attachment:) creates SharedItem with nil url")
    @MainActor
    func busPostAttachment() {
        let bus = ShareAttachmentBus()
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try? "test".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let attachment = FileAttachment(url: tempFile)
        bus.post(attachment: attachment, prompt: nil)

        #expect(bus.pending.count == 1)
        #expect(bus.pending[0].attachment != nil)
        #expect(bus.pending[0].url == nil)
        #expect(bus.pending[0].prompt == nil)
    }
}
