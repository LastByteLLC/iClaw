import SwiftUI

/// Data model for the Terms of Service widget card.
public struct TOSWidgetData: Sendable {
    public init() {}
}

/// Terms of Service acceptance card displayed inline in the chat thread.
/// Blocks the greeting sequence until the user accepts.
struct TOSWidgetView: View {
    @AppStorage(AppConfig.hasAcceptedTOSKey) private var hasAcceptedTOS = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 10) {
                ClawIcon.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue, .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .blue.opacity(0.3), radius: 8)

                Text("Before we begin", bundle: .iClawCore)
                    .font(.title3.bold())
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)
            }

            // Body
            VStack(alignment: .leading, spacing: 12) {
                Text("iClaw uses on-device Apple Intelligence. AI can make mistakes.", bundle: .iClawCore)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("We only collect data you share using the #feedback tool.", bundle: .iClawCore)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            // TOS link
            if let tosURL = URL(string: AppConfig.tosURL) {
                Link(destination: tosURL) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                        Text("Read our Terms of Service", bundle: .iClawCore)
                            .font(.footnote)
                    }
                    .foregroundStyle(.blue)
                }
            }

            // Accept button
            Button {
                withAnimation(.spring()) {
                    hasAcceptedTOS = true
                }
            } label: {
                Text("I Understand", bundle: .iClawCore)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                            .shadow(color: Color.accentColor.opacity(0.4), radius: 8, x: 0, y: 4)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .glassContainer()
        .frame(maxWidth: 340)
        .accessibilityAddTraits(.isModal)
    }
}
