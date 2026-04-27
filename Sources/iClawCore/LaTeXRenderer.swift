import SwiftUI
@preconcurrency import SwiftMath
#if canImport(AppKit)
import AppKit

/// Renders LaTeX math expressions using SwiftMath's MTMathUILabel.
/// Bridges the AppKit MTMathUILabel into SwiftUI via NSViewRepresentable.
struct LaTeXView: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let textColor: NSColor

    init(_ latex: String, fontSize: CGFloat = 16, textColor: NSColor = .labelColor) {
        self.latex = latex
        self.fontSize = fontSize
        self.textColor = textColor
    }

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.textAlignment = .left
        label.labelMode = .text
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.fontSize = fontSize
        label.textColor = textColor
    }
}

// MARK: - LaTeX Detection

/// Detects and splits text containing LaTeX expressions into segments.
enum LaTeXDetector {

    /// A segment of text that is either plain text or a LaTeX expression.
    enum Segment: Equatable {
        case text(String)
        case latex(String)
    }

    /// Patterns that indicate LaTeX content (ordered by specificity).
    private static let patterns: [(open: String, close: String)] = [
        ("$$", "$$"),     // Display math
        ("\\[", "\\]"),   // Display math alt
        ("\\(", "\\)"),   // Inline math
    ]

    /// Returns true if the text contains any LaTeX delimiters with content.
    static func containsLaTeX(_ text: String) -> Bool {
        for (open, close) in patterns {
            if let openRange = text.range(of: open) {
                let afterOpen = text[openRange.upperBound...]
                if let closeRange = afterOpen.range(of: close) {
                    let content = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                    if !content.trimmingCharacters(in: .whitespaces).isEmpty {
                        return true
                    }
                }
            }
        }
        // Single-$ inline math, but reject currency pairs like "$100 ... $200".
        if let match = text.range(of: inlineDollarRegex, options: .regularExpression) {
            let inner = String(text[match]).dropFirst().dropLast()
            if !isLikelyCurrency(String(inner)) {
                return true
            }
        }
        return false
    }

    /// Regex for single-$ inline math. Compiled once via String ops to keep Swift Regex happy.
    static let inlineDollarRegex = #"(?<!\$)\$(?!\$)(.+?)(?<!\$)\$(?!\$)"#

    /// Heuristic: returns true if the captured content between two `$` signs looks like
    /// it spans two currency amounts ($701,980 ... $1,301,980) rather than inline math.
    /// Inline LaTeX rarely starts with a digit and contains commas + English prose.
    static func isLikelyCurrency(_ inner: String) -> Bool {
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return true }
        // LaTeX math typically starts with a letter, backslash, brace, or math operator.
        // Currency captures start with a digit (e.g. "$701,980.81, and total paid ").
        if CharacterSet.decimalDigits.contains(first) { return true }
        // Comma-separated number groups (e.g., "1,301") are a strong currency signal.
        if trimmed.contains(",") && trimmed.rangeOfCharacter(from: .letters) != nil {
            // Prose + numbers with commas — treat as currency, not math.
            return true
        }
        return false
    }

    /// Splits text into alternating plain text and LaTeX segments.
    static func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var remaining = text

        while !remaining.isEmpty {
            // Find the earliest delimiter match across all patterns
            var earliest: (open: String, close: String, range: Range<String.Index>)?
            for (open, close) in patterns {
                if let openRange = remaining.range(of: open) {
                    if earliest == nil || openRange.lowerBound < earliest!.range.lowerBound {
                        earliest = (open, close, openRange)
                    }
                }
            }

            // Also check single-$ inline math — but only accept if it doesn't look like currency.
            let dollarMatch: Range<String.Index>? = {
                var search = remaining.startIndex..<remaining.endIndex
                while let match = remaining.range(of: inlineDollarRegex, options: .regularExpression, range: search) {
                    let inner = String(remaining[match]).dropFirst().dropLast()
                    if !isLikelyCurrency(String(inner)) {
                        return match
                    }
                    search = match.upperBound..<remaining.endIndex
                }
                return nil
            }()

            // Determine which match comes first
            if let earlyDelim = earliest {
                let delimPos = earlyDelim.range.lowerBound
                let dollarPos = dollarMatch?.lowerBound

                if let dp = dollarPos, dp < delimPos {
                    // Single-$ match comes first
                    appendDollarMatch(remaining: &remaining, match: dollarMatch!, segments: &segments)
                    continue
                }

                // Delimiter match comes first
                let before = String(remaining[remaining.startIndex..<earlyDelim.range.lowerBound])
                if !before.isEmpty {
                    segments.append(.text(before))
                }

                let afterOpen = remaining[earlyDelim.range.upperBound...]
                if let closeRange = afterOpen.range(of: earlyDelim.close) {
                    let latexContent = String(afterOpen[afterOpen.startIndex..<closeRange.lowerBound])
                    if !latexContent.trimmingCharacters(in: .whitespaces).isEmpty {
                        segments.append(.latex(latexContent))
                    }
                    remaining = String(afterOpen[closeRange.upperBound...])
                } else {
                    // No closing delimiter — treat opening as plain text, advance past it
                    segments.append(.text(String(remaining[remaining.startIndex..<earlyDelim.range.upperBound])))
                    remaining = String(remaining[earlyDelim.range.upperBound...])
                }
            } else if let match = dollarMatch {
                appendDollarMatch(remaining: &remaining, match: match, segments: &segments)
            } else {
                // No more LaTeX — rest is plain text
                segments.append(.text(remaining))
                remaining = ""
            }
        }

        return segments
    }

    private static func appendDollarMatch(remaining: inout String, match: Range<String.Index>, segments: inout [Segment]) {
        let before = String(remaining[remaining.startIndex..<match.lowerBound])
        if !before.isEmpty {
            segments.append(.text(before))
        }
        let matched = String(remaining[match])
        let inner = String(matched.dropFirst().dropLast())
        segments.append(.latex(inner))
        remaining = String(remaining[match.upperBound...])
    }
}

/// A SwiftUI view that renders text with inline LaTeX expressions.
struct RichMathText: View {
    let segments: [LaTeXDetector.Segment]
    let fontSize: CGFloat

    init(_ text: String, fontSize: CGFloat = 14) {
        self.segments = LaTeXDetector.parse(text)
        self.fontSize = fontSize
    }

    var body: some View {
        if segments.count == 1, case .latex(let expr) = segments.first {
            // Single LaTeX expression — render as standalone
            LaTeXView(expr, fontSize: fontSize)
                .fixedSize()
        } else {
            // Mixed content — use HStack wrapping
            FlowLayout(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let str):
                        Text(str)
                            .font(.system(size: fontSize))
                    case .latex(let expr):
                        LaTeXView(expr, fontSize: fontSize)
                            .fixedSize()
                    }
                }
            }
        }
    }
}

/// Simple horizontal flow layout for mixed text + math content.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#endif
