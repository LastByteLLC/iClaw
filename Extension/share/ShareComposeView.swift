import SwiftUI
import UniformTypeIdentifiers

/// Minimal compose view shown in the Share Extension sheet.
/// Displays a preview of the shared content with an optional prompt field.
struct ShareComposeView: View {
    let providers: [NSItemProvider]
    let onSend: (String?) -> Void
    let onCancel: () -> Void

    @State private var prompt = ""
    @State private var isSending = false
    @State private var contentDescription = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(String(localized: "Cancel", bundle: .main)) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text(String(localized: "Share to iClaw", bundle: .main))
                    .font(.headline)

                Spacer()

                Button(String(localized: "Send", bundle: .main)) {
                    isSending = true
                    onSend(prompt.isEmpty ? nil : prompt)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSending)
            }
            .padding()

            Divider()

            // Content preview
            HStack(spacing: 12) {
                contentIcon
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(contentTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)

                    if !contentDescription.isEmpty {
                        Text(contentDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding()
            .background(.fill.quaternary)

            Divider()

            // Prompt field
            TextField(
                String(localized: "Add a prompt…", bundle: .main),
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(3...6)
            .textFieldStyle(.plain)
            .padding()

            Spacer()
        }
        .frame(minWidth: 320, idealWidth: 360, minHeight: 200, idealHeight: 280)
        .task { await resolveContentDescription() }
    }

    // MARK: - Content Display

    private var contentTitle: String {
        if let name = providers.first?.suggestedName {
            return name
        }
        let count = providers.count
        if count == 1 {
            return itemTypeLabel(for: providers[0])
        }
        return "\(count) items"
    }

    @ViewBuilder
    private var contentIcon: some View {
        let provider = providers.first
        if provider?.hasItemConformingToTypeIdentifier(UTType.url.identifier) == true {
            Image(systemName: "link")
        } else if provider?.hasItemConformingToTypeIdentifier(UTType.image.identifier) == true {
            Image(systemName: "photo")
        } else if provider?.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) == true {
            Image(systemName: "doc.richtext")
        } else if provider?.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) == true {
            Image(systemName: "doc.text")
        } else if provider?.hasItemConformingToTypeIdentifier(UTType.audio.identifier) == true {
            Image(systemName: "waveform")
        } else {
            Image(systemName: "doc")
        }
    }

    private func itemTypeLabel(for provider: NSItemProvider) -> String {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return String(localized: "Web Link", bundle: .main)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return String(localized: "Image", bundle: .main)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return String(localized: "PDF Document", bundle: .main)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return String(localized: "Text", bundle: .main)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            return String(localized: "Audio", bundle: .main)
        } else {
            return String(localized: "File", bundle: .main)
        }
    }

    private func resolveContentDescription() async {
        guard let provider = providers.first else { return }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
            if let url = item as? URL {
                contentDescription = url.absoluteString
            } else if let str = item as? String {
                contentDescription = str
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                  let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
                  let text = item as? String {
            contentDescription = String(text.prefix(100))
        }
    }
}
