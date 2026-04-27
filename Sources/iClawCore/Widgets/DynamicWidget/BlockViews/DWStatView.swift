import SwiftUI

struct DWStatView: View {
    let block: StatBlock

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(block.value)
                    .font(.title.weight(.thin))
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                if let unit = block.unit {
                    Text(unit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .contextMenu {
                Button {
                    let text = [block.value, block.unit].compactMap { $0 }.joined(separator: " ")
                    ClipboardHelper.copy(text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            if let label = block.label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
