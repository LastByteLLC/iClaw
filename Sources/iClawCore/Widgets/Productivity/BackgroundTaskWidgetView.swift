import SwiftUI

struct BackgroundTaskWidgetView: View {
    let data: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Processing Request...")
                .font(.subheadline)
                .fontWeight(.medium)

            if let data {
                ProgressView(value: data, total: 1.0)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .padding()
        .frame(width: 200)
        .glassContainer()
    }
}
