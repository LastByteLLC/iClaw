import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit

class ShareViewController: NSViewController {

    private let suiteName = "5QGXMKNW2A.com.geticlaw.iClaw"

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 280))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let extensionContext else { return }

        let items = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
        let providers = items.flatMap { $0.attachments ?? [] }

        let composeView = ShareComposeView(
            providers: providers,
            onSend: { [weak self] prompt in
                self?.writeAndComplete(providers: providers, prompt: prompt)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: ShareError.cancelled)
            }
        )

        let hostingView = NSHostingView(rootView: composeView)
        hostingView.frame = view.bounds
        hostingView.autoresizingMask = [.width, .height]
        view.addSubview(hostingView)
    }

    private func writeAndComplete(providers: [NSItemProvider], prompt: String?) {
        Task {
            await writeItems(providers: providers, prompt: prompt)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

#elseif canImport(UIKit)
import UIKit

class ShareViewController: UIViewController {

    private let suiteName = "5QGXMKNW2A.com.geticlaw.iClaw"

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let extensionContext else { return }

        let items = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
        let providers = items.flatMap { $0.attachments ?? [] }

        let composeView = ShareComposeView(
            providers: providers,
            onSend: { [weak self] prompt in
                self?.writeAndComplete(providers: providers, prompt: prompt)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: ShareError.cancelled)
            }
        )

        let hostingController = UIHostingController(rootView: composeView)
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)
    }

    private func writeAndComplete(providers: [NSItemProvider], prompt: String?) {
        Task {
            await writeItems(providers: providers, prompt: prompt)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

#endif

// MARK: - Shared Logic

enum ShareError: Error {
    case cancelled
    case noContainer
}

extension ShareViewController {

    /// Maximum file size accepted by the extension (50 MB).
    private static let maxFileSize: Int = 50 * 1024 * 1024

    /// Maximum inline text length stored in the manifest.
    private static let maxTextLength: Int = 10_000

    func writeItems(providers: [NSItemProvider], prompt: String?) async {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else { return }

        let inboxDir = container.appendingPathComponent("ShareHook/Inbox")

        for provider in providers {
            let itemID = UUID()
            let itemDir = inboxDir.appendingPathComponent(itemID.uuidString)
            try? FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

            var item: ShareHookItem?

            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                item = await extractURL(from: provider, id: itemID, prompt: prompt)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                item = await extractFile(from: provider, id: itemID, type: .image, dir: itemDir, prompt: prompt)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                item = await extractFile(from: provider, id: itemID, type: .file, dir: itemDir, prompt: prompt)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                item = await extractText(from: provider, id: itemID, prompt: prompt)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                item = await extractFile(from: provider, id: itemID, type: .file, dir: itemDir, prompt: prompt)
            }

            guard let item else {
                try? FileManager.default.removeItem(at: itemDir)
                continue
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(item) {
                let manifestURL = itemDir.appendingPathComponent("manifest.json")
                try? data.write(to: manifestURL, options: .atomic)
            }
        }

        // Notify the main app via distributed notification (push-based, faster than polling)
        // On iOS the iclaw:// URL scheme below activates the app and triggers processNow().
        #if canImport(AppKit)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.geticlaw.iClaw.shareHook"),
            object: nil
        )
        #endif

        // Activate the main app via URL scheme
        #if canImport(UIKit)
        if let url = URL(string: "iclaw://share") {
            await UIApplication.shared.open(url)
        }
        #elseif canImport(AppKit)
        if let url = URL(string: "iclaw://share") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Extractors

    private func extractURL(from provider: NSItemProvider, id: UUID, prompt: String?) async -> ShareHookItem? {
        guard let urlItem = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) else {
            return nil
        }
        let urlString: String
        if let url = urlItem as? URL {
            urlString = url.absoluteString
        } else if let str = urlItem as? String {
            urlString = str
        } else {
            return nil
        }
        // Skip file URLs — handle as file instead
        if urlString.hasPrefix("file://") {
            return await extractFile(from: provider, id: id, type: .file,
                                     dir: containerItemDir(for: id), prompt: prompt)
        }
        return ShareHookItem(
            id: id, timestamp: Date(), type: .url, prompt: prompt,
            url: urlString, text: nil, fileName: nil, fileExtension: nil
        )
    }

    private func extractText(from provider: NSItemProvider, id: UUID, prompt: String?) async -> ShareHookItem? {
        guard let textItem = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
              let text = textItem as? String else {
            return nil
        }
        let truncated = String(text.prefix(Self.maxTextLength))
        return ShareHookItem(
            id: id, timestamp: Date(), type: .text, prompt: prompt,
            url: nil, text: truncated, fileName: nil, fileExtension: nil
        )
    }

    private func extractFile(from provider: NSItemProvider, id: UUID, type: ShareHookItem.ShareType,
                             dir: URL, prompt: String?) async -> ShareHookItem? {
        let uti = type == .image ? UTType.image.identifier : UTType.fileURL.identifier
        guard let fileItem = try? await provider.loadItem(forTypeIdentifier: uti) else {
            // Fallback: try loading raw data
            if let dataItem = try? await provider.loadItem(forTypeIdentifier: UTType.data.identifier),
               let data = dataItem as? Data {
                guard data.count <= Self.maxFileSize else { return nil }
                let ext = provider.suggestedName.flatMap { URL(fileURLWithPath: $0).pathExtension } ?? "bin"
                let dest = dir.appendingPathComponent("content.data")
                try? data.write(to: dest, options: .atomic)
                return ShareHookItem(
                    id: id, timestamp: Date(), type: type, prompt: prompt,
                    url: nil, text: nil,
                    fileName: provider.suggestedName ?? "shared.\(ext)",
                    fileExtension: ext
                )
            }
            return nil
        }

        let sourceURL: URL
        if let url = fileItem as? URL {
            sourceURL = url
        } else if let data = fileItem as? Data {
            guard data.count <= Self.maxFileSize else { return nil }
            let ext = provider.suggestedName.flatMap { URL(fileURLWithPath: $0).pathExtension } ?? "bin"
            let dest = dir.appendingPathComponent("content.data")
            try? data.write(to: dest, options: .atomic)
            return ShareHookItem(
                id: id, timestamp: Date(), type: type, prompt: prompt,
                url: nil, text: nil,
                fileName: provider.suggestedName ?? "shared.\(ext)",
                fileExtension: ext
            )
        } else {
            return nil
        }

        // Check file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
           let size = attrs[.size] as? Int, size > Self.maxFileSize {
            return nil
        }

        let ext = sourceURL.pathExtension
        let dest = dir.appendingPathComponent("content.data")
        do {
            _ = sourceURL.startAccessingSecurityScopedResource()
            defer { sourceURL.stopAccessingSecurityScopedResource() }
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            return nil
        }

        return ShareHookItem(
            id: id, timestamp: Date(), type: type, prompt: prompt,
            url: nil, text: nil,
            fileName: sourceURL.lastPathComponent,
            fileExtension: ext.isEmpty ? nil : ext
        )
    }

    private func containerItemDir(for id: UUID) -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else {
            return FileManager.default.temporaryDirectory
        }
        return container
            .appendingPathComponent("ShareHook/Inbox")
            .appendingPathComponent(id.uuidString)
    }
}
