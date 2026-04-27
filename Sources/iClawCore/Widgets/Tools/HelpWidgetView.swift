import SwiftUI

// MARK: - Help Overview Widget

/// Visual grid of tool categories with icons, descriptions, and tap-to-explore actions.
/// Shown in response to "what can you do?" — replaces text wall with interactive cards.
struct HelpOverviewWidgetView: View {
    let data: HelpOverviewWidgetData
    @Environment(\.parentMessageID) private var parentMessageID

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(data.categories) { category in
                    categoryCard(category)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 340)
    }

    private func categoryCard(_ category: HelpOverviewWidgetData.CategoryCard) -> some View {
        Button {
            // Drill into this category via the engine
            NotificationCenter.default.post(
                name: .toolTipTryAction,
                object: "#help \(category.chipName)"
            )
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: category.icon)
                        .symbolRenderingMode(.monochrome)
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text(category.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    if category.isExplored {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green.opacity(0.6))
                            .accessibilityLabel(Text("help_category_explored", bundle: .iClawCore))
                    }
                }

                Text(category.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        category.isExplored ? Color.clear : Color.accentColor.opacity(0.15),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(category.name))
        .accessibilityHint(Text("help_category_explore_hint", bundle: .iClawCore))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Help Category Widget

/// Tool list for a single category with descriptions and try-it buttons.
struct HelpCategoryWidgetView: View {
    let data: HelpCategoryWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Category header
            HStack(spacing: 6) {
                Image(systemName: data.categoryIcon)
                    .symbolRenderingMode(.monochrome)
                    .font(.callout)
                    .foregroundStyle(.tint)
                Text(data.categoryName)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)

            ForEach(data.tools) { tool in
                toolRow(tool)
            }
        }
        .padding(12)
        .frame(maxWidth: 340)
    }

    private func toolRow(_ tool: HelpCategoryWidgetData.ToolCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: tool.icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(tool.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }

            Text(tool.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NotificationCenter.default.post(
                    name: .toolTipTryAction,
                    object: tool.exampleQuery
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                    Text("help_try_example \(tool.exampleQuery)", bundle: .iClawCore)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.tint.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("help_try_tool \(tool.displayName)", bundle: .iClawCore))
            .accessibilityAddTraits(.isButton)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Help Tour Step Widget

/// A single step in the guided tour with step indicator and content.
struct HelpTourStepWidgetView: View {
    let data: HelpTourStepWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Step indicator
            HStack(spacing: 6) {
                Image(systemName: data.icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(data.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Spacer()
                Text("help_tour_step \(data.stepNumber) \(data.totalSteps)", bundle: .iClawCore)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityElement(children: .combine)

            Text(data.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Step dots
            HStack(spacing: 4) {
                ForEach(1...data.totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step == data.stepNumber ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .background(.tint.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.tint.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Help Limitations Widget

/// Honest limitations display with what iClaw can and cannot do.
struct HelpLimitationsWidgetView: View {
    let data: HelpLimitationsWidgetData

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Limitations
            VStack(alignment: .leading, spacing: 6) {
                Text("help_limitations_header", bundle: .iClawCore)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                ForEach(data.limitations) { limitation in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: limitation.icon)
                            .symbolRenderingMode(.monochrome)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(limitation.title)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text(limitation.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Divider()

            // Strengths
            VStack(alignment: .leading, spacing: 6) {
                Text("help_strengths_header", bundle: .iClawCore)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(data.strengths) { strength in
                        HStack(spacing: 4) {
                            Image(systemName: strength.icon)
                                .symbolRenderingMode(.monochrome)
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Text(strength.title)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 340)
        .background(.orange.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.orange.opacity(0.12), lineWidth: 0.5)
        )
    }
}
