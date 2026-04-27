import Foundation

/// Strips Markdown formatting from text for TTS consumption.
public enum MarkdownStripper {

    // Pre-compiled regex patterns
    private static let headerRegex = try! NSRegularExpression(pattern: #"(?m)^#{1,6}\s+"#)
    private static let boldStarRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let boldUnderRegex = try! NSRegularExpression(pattern: #"__(.+?)__"#)
    private static let italicStarRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
    private static let italicUnderRegex = try! NSRegularExpression(pattern: #"(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"`(.+?)`"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[(.+?)\]\(.+?\)"#)
    private static let dollarRegex = try! NSRegularExpression(pattern: #"(?<!\$)\$(?!\$)(.+?)(?<!\$)\$(?!\$)"#)
    private static let strikethroughRegex = try! NSRegularExpression(pattern: #"~~(.+?)~~"#)
    private static let codeBlockRegex = try! NSRegularExpression(pattern: #"```[\w]*\n?([\s\S]*?)```"#)
    private static let bulletRegex = try! NSRegularExpression(pattern: #"(?m)^[\-\*]\s+"#)

    private static func apply(_ regex: NSRegularExpression, to text: String, template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    public static func plainText(from markdown: String) -> String {
        var text = markdown

        // Strip headers: "# Title" → "Title"
        text = apply(headerRegex, to: text, template: "")

        // Strip bold: **text** or __text__ → text
        text = apply(boldStarRegex, to: text, template: "$1")
        text = apply(boldUnderRegex, to: text, template: "$1")

        // Strip italic: *text* or _text_ → text
        text = apply(italicStarRegex, to: text, template: "$1")
        text = apply(italicUnderRegex, to: text, template: "$1")

        // Strip inline code: `code` → code
        text = apply(inlineCodeRegex, to: text, template: "$1")

        // Strip links: [text](url) → text
        text = apply(linkRegex, to: text, template: "$1")

        // Strip LaTeX delimiters: \( \) \[ \] $$ $
        text = text.replacingOccurrences(of: "\\(", with: "")
        text = text.replacingOccurrences(of: "\\)", with: "")
        text = text.replacingOccurrences(of: "\\[", with: "")
        text = text.replacingOccurrences(of: "\\]", with: "")
        text = text.replacingOccurrences(of: "$$", with: "")
        text = apply(dollarRegex, to: text, template: "$1")

        // Strip strikethrough: ~~text~~ → text
        text = apply(strikethroughRegex, to: text, template: "$1")

        // Strip code blocks: ```...``` → content
        text = apply(codeBlockRegex, to: text, template: "$1")

        // Strip bullet points: "- " or "* " at line start
        text = apply(bulletRegex, to: text, template: "")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
