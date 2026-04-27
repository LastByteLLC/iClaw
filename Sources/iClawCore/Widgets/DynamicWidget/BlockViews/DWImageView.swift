import SwiftUI
import os

struct DWImageView: View {
    let block: ImageBlock

    var body: some View {
        VStack(spacing: 4) {
            AsyncImage(url: URL(string: block.url)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: block.maxHeight ?? ImageBlock.defaultMaxHeight)
                        .clipShape(.rect(cornerRadius: 12))
                        .contentShape(.rect)
                        .onTapGesture { openQuickLook() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(block.caption ?? String(localized: "Photo", bundle: .iClawCore))
                        .accessibilityHint(String(localized: "Double-tap to open full size", bundle: .iClawCore))
                case .failure:
                    EmptyView()
                case .empty:
                    ProgressView()
                        .frame(height: 60)
                @unknown default:
                    EmptyView()
                }
            }

            if let caption = block.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Downloads the image to a temp file and opens it in Quick Look.
    private func openQuickLook() {
        guard let url = URL(string: block.url) else { return }
        Task.detached {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                // Derive file extension from MIME type or URL path
                let ext = Self.fileExtension(from: response, url: url)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                try data.write(to: tempURL)
                await MainActor.run {
                    #if canImport(AppKit)
                    QuickLookCoordinator.shared.preview(url: tempURL)
                    #endif
                }
            } catch {
                Log.ui.debug("Quick Look download failed: \(error.localizedDescription)")
            }
        }
    }

    /// Determines image file extension from HTTP response or URL path.
    private nonisolated static func fileExtension(from response: URLResponse, url: URL) -> String {
        if let mime = response.mimeType {
            switch mime {
            case "image/png": return "png"
            case "image/gif": return "gif"
            case "image/webp": return "webp"
            case "image/svg+xml": return "svg"
            default: break
            }
        }
        let pathExt = url.pathExtension.lowercased()
        if ["png", "gif", "webp", "svg"].contains(pathExt) {
            return pathExt
        }
        return "jpg"
    }
}
