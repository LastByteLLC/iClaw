import SwiftUI

/// Horizontally scrollable follow-up suggestion pills shown below mode messages.
/// Tapping a pill triggers a new query within the active mode.
struct ModeSuggestionPills: View {
    let suggestions: [String]
    let tintColor: Color
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(tintColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(tintColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Runs this as a new query", bundle: .iClawCore))
                }
            }
        }
    }
}
