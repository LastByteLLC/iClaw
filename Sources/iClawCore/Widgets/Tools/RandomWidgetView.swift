import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct RandomWidgetView: View {
    let data: RandomWidgetData
    @State private var currentData: RandomWidgetData?
    @State private var showCopyConfirmation = false

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()

    private var displayData: RandomWidgetData {
        currentData ?? data
    }

    /// Whether this is a standard d6 dice roll (shows die face SF Symbol).
    private var isDiceD6: Bool {
        let intent = displayData.intent ?? displayData.type.lowercased()
        let isDice = intent == "dice" || intent == "dice roll"
        let sides = displayData.sides ?? 6
        return isDice && sides == 6
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(displayData.type)
                .font(.caption)
                .foregroundStyle(.secondary)

            if (displayData.intent ?? displayData.type.lowercased()) == "color", let color = parseColor(displayData.result) {
                Circle()
                    .fill(color)
                    .frame(width: 48, height: 48)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                Text(displayData.result)
                    .font(.headline)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
            } else if isDiceD6, let value = Int(displayData.result), (1...6).contains(value) {
                Image(systemName: "die.face.\(value)")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 64)) // SF Symbol sizing — hero die face display
                    .foregroundStyle(.primary)
            } else {
                Text(displayData.result)
                    .font(.largeTitle.bold())
                    .fontDesign(.rounded)
                    .foregroundStyle(.primary)
            }

            if let details = displayData.details {
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                Button {
                    withAnimation(.snappy) {
                        currentData = regenerate()
                        showCopyConfirmation = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Generate again", bundle: .iClawCore))
                .accessibilityLabel(String(localized: "Generate again", bundle: .iClawCore))

                Button {
                    ClipboardHelper.copy(displayData.result)
                    withAnimation(.snappy) {
                        showCopyConfirmation = true
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(.snappy) {
                            showCopyConfirmation = false
                        }
                    }
                } label: {
                    Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.clipboard")
                        .font(.caption)
                        .foregroundStyle(showCopyConfirmation ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Copy to clipboard", bundle: .iClawCore))
                .accessibilityLabel(String(localized: "Copy to clipboard", bundle: .iClawCore))
            }
        }
        .padding()
        .frame(minWidth: 120, minHeight: 120)
        .glassContainer(cornerRadius: 20)
    }

    private func regenerate() -> RandomWidgetData {
        let d = displayData
        switch d.intent ?? d.type.lowercased() {
        case "coin", "coin flip":
            return RandomWidgetData(type: String(localized: "Coin Flip", bundle: .iClawCore), result: Bool.random() ? String(localized: "Heads", bundle: .iClawCore) : String(localized: "Tails", bundle: .iClawCore), intent: "coin")
        case "card", "card draw":
            let suits = ["♠️", "♥️", "♦️", "♣️"]
            let ranks = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
            return RandomWidgetData(type: String(localized: "Card Draw", bundle: .iClawCore), result: "\(ranks.randomElement() ?? "")\(suits.randomElement() ?? "")", intent: "card")
        case "dice", "dice roll":
            let sides = max(d.sides ?? 6, 1)
            let diceCount = max(d.count ?? 1, 1)
            if diceCount == 1 {
                return RandomWidgetData(type: String(localized: "Dice Roll", bundle: .iClawCore), result: "\(Int.random(in: 1...sides))", details: "d\(sides)", intent: "dice", sides: sides)
            } else {
                let rolls = (0..<diceCount).map { _ in Int.random(in: 1...sides) }
                let total = rolls.reduce(0, +)
                let result = rolls.map(String.init).joined(separator: ", ") + " (total: \(total))"
                return RandomWidgetData(type: String(localized: "Dice Roll", bundle: .iClawCore), result: result, details: "\(diceCount)d\(sides)", intent: "dice", sides: sides, count: diceCount)
            }
        case "date", "random date":
            let calendar = Calendar.current
            let now = Date()
            let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: now)!
            let oneYearAhead = calendar.date(byAdding: .year, value: 1, to: now)!
            let range = oneYearAgo.timeIntervalSince1970...oneYearAhead.timeIntervalSince1970
            let randomDate = Date(timeIntervalSince1970: Double.random(in: range))
            return RandomWidgetData(type: String(localized: "Random Date", bundle: .iClawCore), result: Self.longDateFormatter.string(from: randomDate), intent: "date")
        case "color", "random color":
            let r = Int.random(in: 0...255)
            let g = Int.random(in: 0...255)
            let b = Int.random(in: 0...255)
            return RandomWidgetData(type: String(localized: "Random Color", bundle: .iClawCore), result: String(format: "#%02X%02X%02X", r, g, b), details: "RGB(\(r), \(g), \(b))", intent: "color")
        default:
            let rawMin = d.min ?? 1
            let rawMax = d.max ?? 100
            let minVal = Swift.min(rawMin, rawMax)
            let maxVal = Swift.max(rawMin, rawMax)
            return RandomWidgetData(type: String(localized: "Random Number", bundle: .iClawCore), result: "\(Int.random(in: minVal...maxVal))", details: "\(minVal) to \(maxVal)", intent: "number", min: minVal, max: maxVal)
        }
    }

    private func parseColor(_ hex: String) -> Color? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned = String(cleaned.dropFirst()) }
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
