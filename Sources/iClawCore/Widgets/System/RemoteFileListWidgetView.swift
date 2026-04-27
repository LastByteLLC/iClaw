#if CONTINUITY_ENABLED
import SwiftUI

/// Widget displaying file search results from a remote device with Transfer buttons.
struct RemoteFileListWidgetView: View {
    let data: RemoteFileListWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Files from \(data.sourceDevice)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            if data.files.isEmpty {
                Text("No files found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ForEach(data.files) { file in
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if file.size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if file.isTransferring {
                                ProgressView()
                                    .scaleEffect(0.6)
                            } else {
                                Button {
                                    NotificationCenter.default.post(
                                        name: .remoteFileTransferRequested,
                                        object: file.path
                                    )
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                                .help(String(localized: "Transfer to this device", bundle: .iClawCore))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                .padding(.bottom, 6)
            }
        }
        .glassContainer()
    }
}

extension Notification.Name {
    static let remoteFileTransferRequested = Notification.Name("iClaw.remoteFileTransferRequested")
}
#endif
