import SwiftUI

/// Terms of Service acceptance overlay. Shown once before the user can interact.
@MainActor
struct TOSAcceptanceView: View {
    @AppStorage(AppConfig.hasAcceptedTOSKey) private var hasAcceptedTOS = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var t: Float = 0.0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        if !hasAcceptedTOS {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)

                VStack(spacing: 28) {
                    // Header
                    VStack(spacing: 12) {
                        ClawIcon.image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.blue, .purple, .pink],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .blue.opacity(0.3), radius: 10)

                        Text("Before we begin", bundle: .iClawCore)
                            .font(.title2.bold())
                            .fontDesign(.rounded)
                            .foregroundStyle(.primary)
                    }

                    // Body
                    VStack(alignment: .leading, spacing: 16) {
                        Text("iClaw uses on-device Apple Intelligence. AI can make mistakes.", bundle: .iClawCore)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("We only collect data you share using the #feedback tool.", bundle: .iClawCore)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal)

                    // TOS link
                    Link(destination: URL(string: AppConfig.tosURL)!) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                            Text("Read our Terms of Service", bundle: .iClawCore)
                                .font(.footnote)
                        }
                        .foregroundStyle(.blue)
                    }

                    // Accept button
                    Button {
                        withAnimation(reduceMotion ? nil : .spring()) {
                            hasAcceptedTOS = true
                        }
                    } label: {
                        Text("I Understand", bundle: .iClawCore)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor)
                                    .shadow(color: Color.accentColor.opacity(0.5), radius: 10, x: 0, y: 5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(32)
                .frame(width: 360)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(.ultraThinMaterial)

                        if #available(macOS 15.0, *) {
                            MeshGradient(
                                width: 3,
                                height: 3,
                                points: [
                                    [0, 0], [0.5, 0], [1, 0],
                                    [0, 0.5], [0.5 + 0.1 * sin(t), 0.5 + 0.1 * cos(t)], [1, 0.5],
                                    [0, 1], [0.5, 1], [1, 1]
                                ],
                                colors: [
                                    .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1),
                                    .indigo.opacity(0.1), .clear, .indigo.opacity(0.1),
                                    .blue.opacity(0.1), .purple.opacity(0.1), .blue.opacity(0.1)
                                ]
                            )
                            .onReceive(timer) { _ in
                                t += 0.1
                            }
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 24))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.white.opacity(0.2), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 40, x: 0, y: 20)
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                .accessibilityAddTraits(.isModal)
            }
        }
    }
}
