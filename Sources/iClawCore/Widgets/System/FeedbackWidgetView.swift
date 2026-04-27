import SwiftUI

/// Widget for the interactive feedback review flow.
struct FeedbackWidgetView: View {
    let data: FeedbackWidgetData

    var body: some View {
        content(data)
            .glassContainer()
    }

    @ViewBuilder
    private func content(_ fd: FeedbackWidgetData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch fd.phase {
            case .review:
                reviewPhase(fd)
            case .sending:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Sending feedback...", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            case .sent:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Feedback sent. Thank you!", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .padding()
            case .cancelled:
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Feedback cancelled.", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func reviewPhase(_ fd: FeedbackWidgetData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Summary
            Text(fd.summary)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(6)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            // Suggested follow-up questions as chips
            if !fd.suggestedQuestions.isEmpty {
                Text("Suggested follow-ups:", bundle: .iClawCore)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fd.suggestedQuestions, id: \.self) { question in
                        Text(question)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 12)
            }

            // Rate iClaw button
            Button {
                #if os(macOS)
                if let url = URL(string: "macappstore://apps.apple.com/app/id\(AppConfig.appStoreID)?action=write-review") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("Rate iClaw on the App Store", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.yellow.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .accessibilityLabel(String(localized: "Rate iClaw on the App Store", bundle: .iClawCore))

            // Action buttons
            HStack(spacing: 10) {
                Button {
                    FeedbackActionBus.shared.post(action: .clarify, feedbackID: fd.feedbackID)
                } label: {
                    Label(String(localized: "Clarify", bundle: .iClawCore), systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    FeedbackActionBus.shared.post(action: .cancel, feedbackID: fd.feedbackID)
                } label: {
                    Text("Cancel", bundle: .iClawCore)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    FeedbackActionBus.shared.post(action: .send, feedbackID: fd.feedbackID)
                } label: {
                    Label(String(localized: "Send", bundle: .iClawCore), systemImage: "paperplane.fill")
                        .fixedSize()
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

/// Simple flow layout for wrapping chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
