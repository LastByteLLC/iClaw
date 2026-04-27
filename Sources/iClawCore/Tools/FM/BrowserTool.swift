#if os(macOS)
import Foundation
import FoundationModels

@Generable
struct BrowserInput: ConvertibleFromGeneratedContent {
    @Guide(description: """
        Action to perform: \
        'extract_page' (full text), 'extract_table' (table data), 'extract_list' (list items), \
        'extract_links' (all links), 'query' (CSS selector), \
        'snapshot' (list interactive elements with refs like @e0), \
        'click' (click element by ref), 'fill' (type into input by ref), \
        'scroll' (scroll page), 'submit' (submit form by ref), 'navigate' (go to URL)
        """)
    var action: String

    @Guide(description: "CSS selector for 'query', or element reference from a snapshot (e.g. '@e3') for click/fill/submit")
    var selector: String?

    @Guide(description: "Text to type into an input field. Required for 'fill' action.")
    var text: String?

    @Guide(description: "URL to navigate to. Required for 'navigate' action.")
    var url: String?

    @Guide(description: "Scroll direction: 'up', 'down', 'left', 'right', 'top', 'bottom'. Default: 'down'.")
    var direction: String?
}

/// Unified FM tool for all browser operations — extraction and interaction.
///
/// **Read-only actions** (work with pushed page content):
/// extract_page, extract_table, extract_list, extract_links, query
///
/// **Interactive actions** (require live BrowserBridge connection + user consent):
/// snapshot, click, fill, scroll, submit, navigate
///
/// Interactive workflow: snapshot → reason about element refs → click/fill → snapshot to verify.
/// Element refs (`@e0`, `@e1`, ...) are assigned by `buildSnapshot()` in the content script
/// and are stable until the next snapshot call or page navigation.
struct BrowserTool: Tool {
    typealias Arguments = BrowserInput
    typealias Output = String

    let name = "browser"
    let description = """
        Work with browser pages. Extract content (text, tables, lists, links) from pages sent \
        via the iClaw extension. When the extension is connected, also interact with pages: \
        call 'snapshot' to see interactive elements (buttons, links, inputs) with refs like @e0, \
        then 'click', 'fill', 'submit' to interact, or 'navigate' to go to a URL.
        """
    var parameters: GenerationSchema { Arguments.generationSchema }

    func call(arguments input: BrowserInput) async throws -> String {
        let context = await BrowserBridge.shared.lastBrowserContext

        switch input.action.lowercased() {

        // --- Extraction actions (work with pushed content) ---

        case "extract_page":
            return extractPage(context: context)

        case "extract_table":
            return extractTable(context: context, selector: input.selector)

        case "extract_list":
            return extractList(context: context)

        case "extract_links":
            return extractLinks(context: context)

        case "query":
            guard let selector = input.selector, !selector.isEmpty else {
                return "Error: 'query' action requires a CSS selector."
            }
            return querySelector(context: context, selector: selector)

        // --- Interactive actions (require live bridge) ---

        case "snapshot":
            return await performSnapshot()

        case "click":
            guard let ref = input.selector, !ref.isEmpty else {
                return "Error: 'click' requires a ref (e.g. '@e3') from a snapshot."
            }
            return await performClick(ref: ref)

        case "fill":
            guard let ref = input.selector, !ref.isEmpty else {
                return "Error: 'fill' requires a ref (e.g. '@e5') from a snapshot."
            }
            guard let text = input.text else {
                return "Error: 'fill' requires text to type."
            }
            return await performFill(ref: ref, text: text)

        case "scroll":
            return await performScroll(direction: input.direction ?? "down")

        case "submit":
            guard let ref = input.selector, !ref.isEmpty else {
                return "Error: 'submit' requires a ref to a form or element inside a form."
            }
            return await performSubmit(ref: ref)

        case "navigate":
            guard let url = input.url, !url.isEmpty else {
                return "Error: 'navigate' requires a URL."
            }
            return await performNavigate(url: url)

        default:
            return "Unknown action '\(input.action)'. Use: extract_page, extract_table, extract_list, extract_links, query, snapshot, click, fill, scroll, submit, navigate."
        }
    }

    // MARK: - Extraction (pushed content)

    private func extractPage(context: BrowserContext?) -> String {
        guard let context, context.hasContent else {
            return noContentMessage(context: context)
        }
        let text = ContentCompactor.compact(context.fullText ?? "", limit: AppConfig.retrievedDataChunks * 4)
        return "Page: \(context.title) (\(context.url))\n\n\(text)"
    }

    private func extractTable(context: BrowserContext?, selector: String?) -> String {
        guard let context, context.hasContent, let text = context.fullText else {
            return noContentMessage(context: context)
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var tableRows: [[String]] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("\t") {
                let cells = trimmed.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.count >= 2 { tableRows.append(cells) }
            } else if trimmed.contains("|") && trimmed.filter({ $0 == "|" }).count >= 2 {
                let cells = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if cells.count >= 2 { tableRows.append(cells) }
            }
        }

        if tableRows.isEmpty {
            let compacted = ContentCompactor.compact(text, limit: 6000)
            return "No clear table structure detected. Page content from \(context.title):\n\n\(compacted)"
        }

        var result = "Table from \(context.title) (\(tableRows.count) rows):\n\n"
        for row in tableRows.prefix(200) {
            result += row.joined(separator: " | ") + "\n"
        }
        if tableRows.count > 200 {
            result += "... (\(tableRows.count - 200) more rows)\n"
        }
        return result
    }

    private func extractList(context: BrowserContext?) -> String {
        guard let context, context.hasContent, let text = context.fullText else {
            return noContentMessage(context: context)
        }

        let lines = text.components(separatedBy: .newlines)
        var items: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("• ") || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                items.append(String(trimmed.dropFirst(2)))
            } else if let match = trimmed.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                items.append(String(trimmed[match.upperBound...]))
            }
        }

        if items.isEmpty {
            let compacted = ContentCompactor.compact(text, limit: 6000)
            return "No clear list structure detected. Page content from \(context.title):\n\n\(compacted)"
        }

        var result = "List from \(context.title) (\(items.count) items):\n\n"
        for (i, item) in items.prefix(100).enumerated() {
            result += "\(i + 1). \(item)\n"
        }
        if items.count > 100 {
            result += "... (\(items.count - 100) more items)\n"
        }
        return result
    }

    private func extractLinks(context: BrowserContext?) -> String {
        guard let context, context.hasContent, let text = context.fullText else {
            return noContentMessage(context: context)
        }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector?.matches(in: text, range: range) ?? []

        var links: [(text: String, url: String)] = []
        for match in matches {
            if let urlRange = Range(match.range, in: text), let url = match.url {
                let surrounding = String(text[urlRange])
                links.append((text: surrounding, url: url.absoluteString))
            }
        }

        if links.isEmpty {
            return "No links found on \(context.title)."
        }

        var result = "Links from \(context.title) (\(links.count) found):\n\n"
        for (i, link) in links.prefix(50).enumerated() {
            result += "\(i + 1). \(link.url)\n"
        }
        if links.count > 50 {
            result += "... (\(links.count - 50) more links)\n"
        }
        return result
    }

    private func querySelector(context: BrowserContext?, selector: String) -> String {
        guard let context, context.hasContent, let text = context.fullText else {
            return noContentMessage(context: context)
        }

        let compacted = ContentCompactor.compact(text, limit: 6000)
        return "Page content from \(context.title) for query '\(selector)':\n\n\(compacted)"
    }

    // MARK: - Interactive actions (live bridge)

    private func requireBridge() async -> BrowserBridge? {
        let bridge = BrowserBridge.shared
        guard await bridge.isConnected else { return nil }
        return bridge
    }

    private func performSnapshot() async -> String {
        guard let bridge = await requireBridge() else {
            return "Browser extension is not connected. Open Safari and enable the iClaw extension."
        }
        do {
            let response = try await bridge.snapshot()
            guard let dict = response.resultDict else {
                return response.errorMessage ?? "Failed to get page snapshot."
            }
            let title = dict["title"] as? String ?? ""
            let url = dict["url"] as? String ?? ""
            let count = dict["elementCount"] as? Int ?? 0
            let snapshot = dict["snapshot"] as? String ?? ""

            if snapshot.isEmpty {
                return "Page '\(title)' has no interactive elements."
            }
            return "Page: \(title) (\(url))\n\(count) interactive elements:\n\n\(snapshot)"
        } catch {
            return "Snapshot failed: \(error.localizedDescription)"
        }
    }

    private func performClick(ref: String) async -> String {
        guard let bridge = await requireBridge() else {
            return "Browser extension is not connected."
        }
        do {
            let response = try await bridge.click(ref: ref)
            guard let dict = response.resultDict else {
                return response.errorMessage ?? "Click failed."
            }
            if dict["success"] as? Bool == true {
                let text = dict["text"] as? String ?? ""
                return "Clicked \(ref)\(text.isEmpty ? "" : " (\"\(text)\")")."
            }
            return "Click failed: \(dict["error"] as? String ?? "unknown error")"
        } catch {
            return "Click failed: \(error.localizedDescription)"
        }
    }

    private func performFill(ref: String, text: String) async -> String {
        guard let bridge = await requireBridge() else {
            return "Browser extension is not connected."
        }
        do {
            let response = try await bridge.fill(ref: ref, text: text)
            guard let dict = response.resultDict else {
                return response.errorMessage ?? "Fill failed."
            }
            if dict["success"] as? Bool == true {
                return "Typed \"\(text.prefix(30))\" into \(ref)."
            }
            return "Fill failed: \(dict["error"] as? String ?? "unknown error")"
        } catch {
            return "Fill failed: \(error.localizedDescription)"
        }
    }

    private func performScroll(direction: String) async -> String {
        guard let bridge = await requireBridge() else {
            return "Browser extension is not connected."
        }
        do {
            let response = try await bridge.scroll(direction: direction)
            guard let dict = response.resultDict else {
                return response.errorMessage ?? "Scroll failed."
            }
            if dict["success"] as? Bool == true {
                return "Scrolled \(direction)."
            }
            return "Scroll failed: \(dict["error"] as? String ?? "unknown error")"
        } catch {
            return "Scroll failed: \(error.localizedDescription)"
        }
    }

    private func performSubmit(ref: String) async -> String {
        guard let bridge = await requireBridge() else {
            return "Browser extension is not connected."
        }
        do {
            let response = try await bridge.submit(ref: ref)
            guard let dict = response.resultDict else {
                return response.errorMessage ?? "Submit failed."
            }
            if dict["success"] as? Bool == true {
                let action = dict["action"] as? String ?? ""
                return "Form submitted\(action.isEmpty ? "" : " → \(action)")."
            }
            return "Submit failed: \(dict["error"] as? String ?? "unknown error")"
        } catch {
            return "Submit failed: \(error.localizedDescription)"
        }
    }

    private func performNavigate(url: String) async -> String {
        guard let bridge = await requireBridge() else {
            return "Browser extension is not connected."
        }
        do {
            let response = try await bridge.navigate(to: url)
            if response.isError {
                return "Navigation failed: \(response.errorMessage ?? "unknown error")"
            }
            return "Navigating to \(url)."
        } catch {
            return "Navigation failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func noContentMessage(context: BrowserContext?) -> String {
        if let context, !context.url.isEmpty {
            return "I can see you're on \(context.title) (\(context.url)), but I don't have the page content yet. Click 'Send Page to iClaw' in the Safari extension to send the full page."
        }
        return "No browser page content available. Open a page in Safari and click 'Send Page to iClaw' in the iClaw extension."
    }
}
#endif
