import Foundation

/// Manifest describing a shared item written by the Share Extension.
///
/// The extension writes this as `manifest.json` inside
/// `{AppGroup}/ShareHook/Inbox/{uuid}/`. The main app's
/// `ShareHookManager` reads it to create a `FileAttachment`.
///
/// This type is intentionally duplicated from iClawCore so the
/// extension stays lightweight (no iClawCore dependency).
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
        case url
        case file
        case text
        case image
    }
}
