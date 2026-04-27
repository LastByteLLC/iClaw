import SwiftUI

public struct ComputeWidgetView: View {
    public let data: ComputeWidgetData
    @State private var showCode = false
    @Environment(\.dismissWidget) var dismissWidget

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Query
            Text(data.query)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Result
            HStack {
                Text(data.result)
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.semibold)
                    .textSelection(.enabled)

                Spacer()

                Button {
                    ClipboardHelper.copy(data.result)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "Copy result", bundle: .iClawCore))
            }

            if data.truncated {
                Text("Output was truncated (exceeded 10KB)", bundle: .iClawCore)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            // Show Code disclosure
            DisclosureGroup(String(localized: "Show Code", bundle: .iClawCore), isExpanded: $showCode) {
                ScrollView(.horizontal) {
                    Text(data.code)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 100)
            }
            .font(.caption)
        }
        .padding(12)
        .glassContainer(hasShadow: false)
    }
}
