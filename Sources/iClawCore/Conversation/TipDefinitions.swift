import SwiftUI
import TipKit

// MARK: - First Interaction Tips

struct ChipDiscoveryTip: Tip {
    var title: Text { Text("Tool Chips") }
    var message: Text? { Text("Type # to browse all available tools, or just ask naturally.") }
    var image: Image? { Image(systemName: "number") }

    @Parameter
    static var hasTypedChip: Bool = false

    var rules: [Rule] {
        #Rule(Self.$hasTypedChip) { $0 == false }
    }
}

struct MicDiscoveryTip: Tip {
    var title: Text { Text("Voice Input") }
    var message: Text? { Text("Tap the mic to speak your request instead of typing.") }
    var image: Image? { Image(systemName: "mic") }

    static let messagesSent = Tips.Event(id: "micTipMessagesSent")
    static let micUsed = Tips.Event(id: "micUsed")

    var rules: [Rule] {
        #Rule(Self.messagesSent) { $0.donations.count >= 3 }
        #Rule(Self.micUsed) { $0.donations.count == 0 }
    }
}

// MARK: - Tool Use Tips

struct ContextPillTip: Tip {
    var title: Text { Text("Follow-Up Context") }
    var message: Text? { Text("Tap to anchor \u{2014} follow-up questions will route to the same tool.") }
    var image: Image? { Image(systemName: "pin") }

    static let toolUsed = Tips.Event(id: "contextPillToolUsed")

    var rules: [Rule] {
        #Rule(Self.toolUsed) { $0.donations.count >= 1 }
    }
}

struct FollowUpTip: Tip {
    var title: Text { Text("Ask a Follow-Up") }
    var message: Text? { Text("While the pill is active, ask a related question \u{2014} I'll know the context.") }
    var image: Image? { Image(systemName: "bubble.left.and.bubble.right") }

    static let toolUsed = Tips.Event(id: "followUpToolUsed")
    static let followUpDetected = Tips.Event(id: "followUpDetected")

    var rules: [Rule] {
        #Rule(Self.toolUsed) { $0.donations.count >= 5 }
        #Rule(Self.followUpDetected) { $0.donations.count == 0 }
    }
}

// MARK: - Feature Discovery Tips

struct PasteDiscoveryTip: Tip {
    var title: Text { Text("Paste Files") }
    var message: Text? { Text("Paste files or images \u{2014} I'll suggest what to do with them.") }
    var image: Image? { Image(systemName: "doc.on.clipboard") }

    static let messagesSent = Tips.Event(id: "pasteMessagesSent")
    static let filesPasted = Tips.Event(id: "filesPasted")

    var rules: [Rule] {
        #Rule(Self.messagesSent) { $0.donations.count >= 10 }
        #Rule(Self.filesPasted) { $0.donations.count == 0 }
    }
}

struct TickerDiscoveryTip: Tip {
    var title: Text { Text("Stock Quotes") }
    var message: Text? { Text("Type $AAPL to get a stock quote instantly.") }
    var image: Image? { Image(systemName: "chart.line.uptrend.xyaxis") }

    static let toolUsed = Tips.Event(id: "tickerToolUsed")

    var rules: [Rule] {
        #Rule(Self.toolUsed) { $0.donations.count >= 3 }
    }
}

struct SkillsDiscoveryTip: Tip {
    var title: Text { Text("Teach Me New Tricks") }
    var message: Text? { Text("Drop AgentSkills.io files into ~/Documents/AgentSkills to add capabilities.") }
    var image: Image? { Image(systemName: "puzzlepiece.extension") }

    static let toolUsed = Tips.Event(id: "skillsToolUsed")

    var rules: [Rule] {
        #Rule(Self.toolUsed) { $0.donations.count >= 20 }
    }
}

struct PersonalityTip: Tip {
    var title: Text { Text("Customize Personality") }
    var message: Text? { Text("Adjust my personality in Settings \u{2014} from sassy to neutral.") }
    var image: Image? { Image(systemName: "theatermasks") }

    static let messagesSent = Tips.Event(id: "personalityMessagesSent")

    var rules: [Rule] {
        #Rule(Self.messagesSent) { $0.donations.count >= 30 }
    }
}

// MARK: - Help Discovery Tips

struct HelpDiscoveryTip: Tip {
    var title: Text { Text("help_tip_discovery_title", bundle: .iClawCore) }
    var message: Text? { Text("help_tip_discovery_message", bundle: .iClawCore) }
    var image: Image? { Image(systemName: "questionmark.circle") }

    static let errorEncountered = Tips.Event(id: "helpErrorEncountered")

    var rules: [Rule] {
        #Rule(Self.errorEncountered) { $0.donations.count >= 2 }
    }
}

struct ModeDiscoveryTip: Tip {
    var title: Text { Text("help_tip_modes_title", bundle: .iClawCore) }
    var message: Text? { Text("help_tip_modes_message", bundle: .iClawCore) }
    var image: Image? { Image(systemName: "arrow.triangle.2.circlepath") }

    static let toolUsed = Tips.Event(id: "modeDiscoveryToolUsed")

    var rules: [Rule] {
        #Rule(Self.toolUsed) { $0.donations.count >= 8 }
    }
}

struct TourDiscoveryTip: Tip {
    var title: Text { Text("help_tip_tour_title", bundle: .iClawCore) }
    var message: Text? { Text("help_tip_tour_message", bundle: .iClawCore) }
    var image: Image? { Image(systemName: "map") }

    static let messagesSent = Tips.Event(id: "tourMessagesSent")

    var rules: [Rule] {
        #Rule(Self.messagesSent) { $0.donations.count >= 5 && $0.donations.count <= 10 }
    }
}

// MARK: - Widget Tips

struct WidgetFlagTip: Tip {
    var title: Text { Text("Report Bad Layouts") }
    var message: Text? { Text("Tap the flag icon to report a widget that doesn't look right.") }
    var image: Image? { Image(systemName: "flag") }

    static let widgetShown = Tips.Event(id: "widgetShown")

    var rules: [Rule] {
        #Rule(Self.widgetShown) { $0.donations.count >= 1 }
    }
}

struct CalculatorExplainTip: Tip {
    var title: Text { Text("Step-by-Step Math") }
    var message: Text? { Text("Tap Explain on calculator results to see the math rendered beautifully.") }
    var image: Image? { Image(systemName: "function") }

    static let toolUsed = Tips.Event(id: "calcToolUsed")

    var rules: [Rule] {
        #Rule(Self.toolUsed) { $0.donations.count >= 2 }
    }
}

// MARK: - Convenience Donation Functions

/// Centralized donation functions so callers don't need to know which tip owns each event.
enum TipDonations {
    /// Call when any tool executes successfully.
    static func donateToolUsed() async {
        await ContextPillTip.toolUsed.donate()
        await FollowUpTip.toolUsed.donate()
        await TickerDiscoveryTip.toolUsed.donate()
        await SkillsDiscoveryTip.toolUsed.donate()
        await CalculatorExplainTip.toolUsed.donate()
        await ModeDiscoveryTip.toolUsed.donate()
    }

    /// Call when the user sends a message (for progressive tips).
    static func donateMessageSent() async {
        await MicDiscoveryTip.messagesSent.donate()
        await PasteDiscoveryTip.messagesSent.donate()
        await PersonalityTip.messagesSent.donate()
        await TourDiscoveryTip.messagesSent.donate()
    }

    /// Call when a tool encounters an error.
    static func donateErrorEncountered() async {
        await HelpDiscoveryTip.errorEncountered.donate()
    }

    /// Call when the user types a `#` chip.
    static func donateChipTyped() {
        ChipDiscoveryTip.hasTypedChip = true
    }

    /// Call when the user records via the mic.
    static func donateMicUsed() async {
        await MicDiscoveryTip.micUsed.donate()
    }

    /// Call when the user pastes files.
    static func donateFilesPasted() async {
        await PasteDiscoveryTip.filesPasted.donate()
    }

    /// Call when a follow-up is detected.
    static func donateFollowUpDetected() async {
        await FollowUpTip.followUpDetected.donate()
    }

    /// Call when a widget is shown.
    static func donateWidgetShown() async {
        await WidgetFlagTip.widgetShown.donate()
    }
}
