import Foundation

// MARK: - Help Overview Widget

/// Data for the help overview grid shown when users ask "what can you do?"
/// Displays tool categories as tappable cards with icons and descriptions.
public struct HelpOverviewWidgetData: Sendable {
    public let categories: [CategoryCard]
    public let exploredCategoryChips: Set<String>

    public struct CategoryCard: Sendable, Identifiable {
        public let id: String // chipName
        public let name: String
        public let chipName: String
        public let icon: String
        public let description: String
        public let isExplored: Bool
    }

    public init(categories: [CategoryCard], exploredCategoryChips: Set<String> = []) {
        self.categories = categories
        self.exploredCategoryChips = exploredCategoryChips
    }
}

// MARK: - Help Category Widget

/// Data for a single category's tool list shown when users drill into a category.
/// Each tool row has a description and try-it button.
public struct HelpCategoryWidgetData: Sendable {
    public let categoryName: String
    public let categoryIcon: String
    public let tools: [ToolCard]

    public struct ToolCard: Sendable, Identifiable {
        public let id: String // tool name
        public let name: String
        public let displayName: String
        public let icon: String
        public let description: String
        public let exampleQuery: String
    }

    public init(categoryName: String, categoryIcon: String, tools: [ToolCard]) {
        self.categoryName = categoryName
        self.categoryIcon = categoryIcon
        self.tools = tools
    }
}

// MARK: - Help Tour Step Widget

/// Data for a single guided tour step.
public struct HelpTourStepWidgetData: Sendable {
    public let stepNumber: Int
    public let totalSteps: Int
    public let title: String
    public let body: String
    public let icon: String

    public init(stepNumber: Int, totalSteps: Int, title: String, body: String, icon: String) {
        self.stepNumber = stepNumber
        self.totalSteps = totalSteps
        self.title = title
        self.body = body
        self.icon = icon
    }
}

// MARK: - Help Limitations Widget

/// Data for the "what can't you do?" response.
public struct HelpLimitationsWidgetData: Sendable {
    public let limitations: [Limitation]
    public let strengths: [Strength]

    public struct Limitation: Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let detail: String
        public let icon: String
    }

    public struct Strength: Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let icon: String
    }

    public init(limitations: [Limitation], strengths: [Strength]) {
        self.limitations = limitations
        self.strengths = strengths
    }
}
