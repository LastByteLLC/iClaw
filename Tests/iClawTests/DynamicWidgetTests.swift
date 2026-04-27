import XCTest
import SwiftUI
import os
@testable import iClawCore

// MARK: - Data Model Tests

final class DynamicWidgetDataTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "star", title: "Test")),
            .stat(StatBlock(value: "42", label: "Answer")),
            .divider,
            .text(TextBlock(content: "Hello", style: .body)),
        ], tint: .blue)

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(DynamicWidgetData.self, from: encoded)
        XCTAssertEqual(decoded, data)
    }

    func testCodableRoundTripAllBlockTypes() throws {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "star", title: "Title", subtitle: "Sub", badge: "New")),
            .image(ImageBlock(url: "https://example.com/img.png", caption: "Photo")),
            .stat(StatBlock(value: "99", label: "Score", icon: "flame", unit: "pts")),
            .statRow(StatRowBlock(items: [
                StatBlock(value: "10", label: "A"),
                StatBlock(value: "20", label: "B"),
            ])),
            .keyValue(KeyValueBlock(pairs: [
                KeyValuePair(key: "Name", value: "Alice", icon: "person"),
            ])),
            .itemList(ItemListBlock(items: [
                ListItem(icon: "doc", title: "File", subtitle: "PDF", trailing: "2 MB", url: "https://example.com"),
            ])),
            .chipRow(ChipRowBlock(chips: [
                Chip(label: "Tag", icon: "tag", url: "https://example.com"),
            ])),
            .text(TextBlock(content: "Body text", style: .caption)),
            .divider,
            .table(TableBlock(headers: ["A", "B"], rows: [["1", "2"]], caption: "Table")),
            .progress(ProgressBlock(value: 0.75, label: "Loading", total: "75%")),
        ], tint: .green)

        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(DynamicWidgetData.self, from: encoded)
        XCTAssertEqual(decoded, data)
    }

    // MARK: - Validation

    func testValidationTruncatesBlocks() {
        var blocks: [WidgetBlock] = []
        for i in 0..<25 {
            blocks.append(.text(TextBlock(content: "Block \(i)")))
        }
        let data = DynamicWidgetData(blocks: blocks).validated()
        // maxBlocks (10) + 1 truncation notice
        XCTAssertEqual(data.blocks.count, 11)
        if case .text(let t) = data.blocks.last {
            XCTAssertTrue(t.content.contains("truncated"))
        } else {
            XCTFail("Last block should be truncation notice")
        }
    }

    func testValidationCapsListItems() {
        let items = (0..<20).map { ListItem(title: "Item \($0)") }
        let data = DynamicWidgetData(blocks: [
            .itemList(ItemListBlock(items: items))
        ]).validated()

        if case .itemList(let list) = data.blocks.first {
            // maxListItems (8) + 1 "N more" footer
            XCTAssertEqual(list.items.count, 9)
            XCTAssertTrue(list.items.last?.title.contains("more") == true)
        } else {
            XCTFail("Expected itemList block")
        }
    }

    func testValidationCapsTableRows() {
        let rows = (0..<15).map { ["Row number \($0) with enough content"] }
        let data = DynamicWidgetData(blocks: [
            .table(TableBlock(headers: ["Description"], rows: rows))
        ]).validated()

        if case .table(let tb) = data.blocks.first {
            XCTAssertEqual(tb.rows.count, 8)
        } else {
            XCTFail("Expected table block")
        }
    }

    func testValidationCapsChips() {
        let chips = (0..<20).map { Chip(label: "Chip number \($0)") }
        let data = DynamicWidgetData(blocks: [
            .chipRow(ChipRowBlock(chips: chips))
        ]).validated()

        if case .chipRow(let cr) = data.blocks.first {
            XCTAssertEqual(cr.chips.count, 8)
        } else {
            XCTFail("Expected chipRow block")
        }
    }

    func testValidationCapsStatRow() {
        // Start at 10 to avoid "0" placeholder filtering; use labels for content threshold
        let items = (10..<16).map { StatBlock(value: "\($0)", label: "Metric number \($0)") }
        let data = DynamicWidgetData(blocks: [
            .statRow(StatRowBlock(items: items))
        ]).validated()

        if case .statRow(let sr) = data.blocks.first {
            XCTAssertEqual(sr.items.count, 4)
        } else {
            XCTFail("Expected statRow block")
        }
    }

    func testValidationFiltersEmptyBlocks() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "star", title: "")),        // empty title
            .stat(StatBlock(value: "")),                           // empty value
            .text(TextBlock(content: "")),                         // empty content
            .keyValue(KeyValueBlock(pairs: [])),                   // empty pairs
            .itemList(ItemListBlock(items: [])),                   // empty items
            .header(HeaderBlock(icon: "star", title: "Valid Header Block")),   // kept
            .text(TextBlock(content: "This is enough text content to pass the quality filter threshold.")),
        ]).validated()

        XCTAssertEqual(data.blocks.count, 2)
    }

    func testValidationRejectsInvalidImageURL() {
        let data = DynamicWidgetData(blocks: [
            .image(ImageBlock(url: "")),                                   // empty — rejected
            .image(ImageBlock(url: "https://example.com/img.png")),        // placeholder — rejected
            .image(ImageBlock(url: "https://real-cdn.com/photo.jpg")),     // valid — kept
            .text(TextBlock(content: "This is enough descriptive text to satisfy the minimum content quality threshold.")),
        ]).validated()

        XCTAssertEqual(data.blocks.count, 2)
        if case .image(let img) = data.blocks.first {
            XCTAssertEqual(img.url, "https://real-cdn.com/photo.jpg")
        } else {
            XCTFail("Expected valid image block")
        }
    }

    // MARK: - Quality Filter

    func testQualityFilterRejectsHeaderOnly() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "star", title: "Just a Header")),
        ]).validated()
        XCTAssertTrue(data.blocks.isEmpty, "Widget with only a header should validate to empty")
    }

    func testQualityFilterKeepsHeaderPlusStat() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "globe", title: "Country Information Widget")),
            .stat(StatBlock(value: "214.3M", label: "Population (2023)")),
            .keyValue(KeyValueBlock(pairs: [KeyValuePair(key: "Capital", value: "Brasilia")])),
        ]).validated()
        XCTAssertEqual(data.blocks.count, 3, "Widget with header + stat + kv should be kept")
    }

    func testQualityFilterRemovesPlaceholderTable() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "table", title: "Data Table With Enough Characters")),
            .table(TableBlock(headers: ["Name", "Value"], rows: [
                ["N/A", "N/A"],
                ["Unknown", "-"],
                ["Not available", ""],
            ])),
            .text(TextBlock(content: "This is extra text content to meet the minimum character threshold for quality.")),
        ]).validated()
        // Table should be removed (all cells are placeholders), header + text remain
        let hasTable = data.blocks.contains { if case .table = $0 { return true }; return false }
        XCTAssertFalse(hasTable, "Table with all placeholder cells should be removed")
        XCTAssertFalse(data.blocks.isEmpty, "Other blocks should remain")
    }

    func testQualityFilterRemovesPlaceholderStats() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "chart.bar", title: "Statistics Dashboard Overview")),
            .stat(StatBlock(value: "N/A", label: "Revenue")),
            .stat(StatBlock(value: "42.5K", label: "Users active this month")),
        ]).validated()
        // "N/A" stat removed, "42.5K" stat kept
        let statCount = data.blocks.filter { if case .stat = $0 { return true }; return false }.count
        XCTAssertEqual(statCount, 1, "Only non-placeholder stat should remain")
    }

    func testQualityFilterRejectsLowContentWidget() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "star", title: "Hi")),
            .stat(StatBlock(value: "1", label: "X")),
        ]).validated()
        XCTAssertTrue(data.blocks.isEmpty, "Widget with < 50 chars total content should validate to empty")
    }

    func testSFSymbolFallback() {
        let validated = DynamicWidgetData.validatedSymbol("this.is.not.a.real.symbol.12345")
        // On macOS, invalid symbols fall back to questionmark.circle
        #if canImport(AppKit)
        XCTAssertEqual(validated, "questionmark.circle")
        #endif
    }

    // MARK: - Table Unit Hoisting

    func testHoistSuffixUnitsToHeader() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "car", title: "Top Speed Comparison For Supercars")),
            .table(TableBlock(headers: ["Car", "Top Speed"], rows: [
                ["Bugatti Chiron", "240 mph"],
                ["Koenigsegg Jesko", "311 mph"],
                ["McLaren Speedtail", "258 mph"],
            ])),
        ]).validated()

        if case .table(let tb) = data.blocks.last {
            XCTAssertEqual(tb.headers[1], "Top Speed (mph)")
            XCTAssertEqual(tb.rows[0][1], "240")
            XCTAssertEqual(tb.rows[1][1], "311")
            XCTAssertEqual(tb.rows[2][1], "258")
        } else {
            XCTFail("Expected table block after validation")
        }
    }

    func testNoHoistWhenMixedUnits() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "chart.bar", title: "Mixed Data Measurements Table")),
            .table(TableBlock(headers: ["Item", "Value"], rows: [
                ["Speed", "240 mph"],
                ["Weight", "3500 lbs"],
                ["Height", "48 inches"],
            ])),
        ]).validated()

        if case .table(let tb) = data.blocks.last {
            // No unit should be hoisted — all different
            XCTAssertEqual(tb.headers[1], "Value")
            XCTAssertEqual(tb.rows[0][1], "240 mph")
        } else {
            XCTFail("Expected table block after validation")
        }
    }

    func testHoistPrefixDollarSign() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "dollarsign.circle", title: "Price Comparison Table Items")),
            .table(TableBlock(headers: ["Product", "Price"], rows: [
                ["Widget A", "$10.99"],
                ["Widget B", "$24.50"],
                ["Widget C", "$7.25"],
            ])),
        ]).validated()

        if case .table(let tb) = data.blocks.last {
            XCTAssertEqual(tb.headers[1], "Price ($)")
            XCTAssertEqual(tb.rows[0][1], "10.99")
            XCTAssertEqual(tb.rows[1][1], "24.50")
            XCTAssertEqual(tb.rows[2][1], "7.25")
        } else {
            XCTFail("Expected table block after validation")
        }
    }

    // MARK: - Builder

    func testBuilderProducesCorrectSequence() {
        var b = DynamicWidgetBuilder(tint: .blue)
        b.header(icon: "cpu", title: "System Information Overview")
        b.keyValue([("CPU", "Apple M4 Max"), ("RAM", "32 GB Unified Memory")])
        b.divider()
        b.stat(value: "98%", label: "Overall Health Score")

        let data = b.build()
        XCTAssertEqual(data.tint, .blue)
        XCTAssertEqual(data.blocks.count, 4)
    }

    func testBuilderEmptyBuild() {
        let b = DynamicWidgetBuilder()
        let data = b.build()
        XCTAssertTrue(data.blocks.isEmpty)
        XCTAssertNil(data.tint)
    }

    // MARK: - Stat-as-Title Rejection

    func testStatWithNoDigitsAndManyWordsIsRejected() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "info.circle", title: "Nutrition Facts")),
            .stat(StatBlock(value: "Nutritional Comparison Overview Details", label: "Category")),
            .stat(StatBlock(value: "42", label: "Good Stat")),
            .keyValue(KeyValueBlock(pairs: [
                KeyValuePair(key: "Protein", value: "26g"),
                KeyValuePair(key: "Calories", value: "165 kcal"),
            ])),
        ], tint: .blue)
        let validated = data.validated()
        // The wordy stat without digits should be stripped, leaving only the numeric one
        let statCount = validated.blocks.filter { if case .stat = $0 { return true }; return false }.count
        XCTAssertEqual(statCount, 1)
    }

    func testStatWithDigitsIsKept() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "info.circle", title: "Test")),
            .stat(StatBlock(value: "$4.2 Trillion GDP", label: "Economy")),
        ], tint: nil)
        let validated = data.validated()
        let statCount = validated.blocks.filter { if case .stat = $0 { return true }; return false }.count
        XCTAssertEqual(statCount, 1)
    }

    // MARK: - StatRow-as-Header Rejection

    func testStatRowWithAllTextNoDigitsIsRejected() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "info.circle", title: "Test")),
            .statRow(StatRowBlock(items: [
                StatBlock(value: "Spec"),
                StatBlock(value: "Ford Mustang"),
                StatBlock(value: "Chevrolet Camaro"),
            ])),
            .keyValue(KeyValueBlock(pairs: [KeyValuePair(key: "Engine", value: "V8")])),
        ], tint: .blue)
        let validated = data.validated()
        let srCount = validated.blocks.filter { if case .statRow = $0 { return true }; return false }.count
        XCTAssertEqual(srCount, 0, "StatRow used as table header (no digits) should be rejected")
    }

    func testStatRowWithDigitsIsKept() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "info.circle", title: "Test")),
            .statRow(StatRowBlock(items: [
                StatBlock(value: "38.9M", label: "Population"),
                StatBlock(value: "$2.1T", label: "GDP"),
            ])),
        ], tint: nil)
        let validated = data.validated()
        let srCount = validated.blocks.filter { if case .statRow = $0 { return true }; return false }.count
        XCTAssertEqual(srCount, 1)
    }

    // MARK: - Markdown Stripping

    func testMarkdownStrippedFromStatValues() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "info.circle", title: "Test")),
            .stat(StatBlock(value: "*62 kWh*", label: "Battery")),
            .keyValue(KeyValueBlock(pairs: [KeyValuePair(key: "Type", value: "Lithium Ion")])),
        ], tint: nil)
        let validated = data.validated()
        // Find the stat block in validated output
        let statBlock = validated.blocks.first(where: { if case .stat = $0 { return true }; return false })
        if case .stat(let s) = statBlock {
            XCTAssertEqual(s.value, "62 kWh")
        } else {
            XCTFail("Expected stat block, got \(validated.blocks)")
        }
    }
}

// MARK: - Parser Tests

final class DynamicWidgetParserTests: XCTestCase {

    func testParseMultiBlock() {
        let text = """
        Some preamble.
        <dw>
        tint:green
        H|flag.fill|Brazil
        S|214.3M|Population (2023)
        KV|Growth Rate|0.52% annually
        KV|Language|Portuguese
        KV|Capital|Brasilia
        </dw>
        Some postamble.
        """

        let (cleaned, widget) = DynamicWidgetParser.parse(text)
        XCTAssertTrue(cleaned.contains("preamble"))
        XCTAssertTrue(cleaned.contains("postamble"))
        XCTAssertFalse(cleaned.contains("<dw>"))

        XCTAssertNotNil(widget)
        XCTAssertEqual(widget?.tint, .green)
        // header + stat + keyValue (3 KVs grouped)
        XCTAssertEqual(widget?.blocks.count, 3)

        if case .keyValue(let kv) = widget?.blocks[2] {
            XCTAssertEqual(kv.pairs.count, 3)
        } else {
            XCTFail("Expected grouped keyValue block")
        }
    }

    func testParseStripsBlock() {
        let text = "Here is info <dw>\nH|star|Title\nT|This is a sufficiently long text block for quality filtering\n</dw> and more."
        let (cleaned, widget) = DynamicWidgetParser.parse(text)
        XCTAssertEqual(cleaned, "Here is info  and more.")
        XCTAssertNotNil(widget)
    }

    func testParseMalformedReturnsNil() {
        // No closing tag
        let (cleaned, widget) = DynamicWidgetParser.parse("text <dw>\nH|star|Title\n")
        XCTAssertNil(widget)
        XCTAssertTrue(cleaned.contains("<dw>"))
    }

    func testParseEmptyBlockReturnsNil() {
        let (_, widget) = DynamicWidgetParser.parse("<dw>\n</dw>")
        XCTAssertNil(widget)
    }

    func testParseConsecutiveListItems() {
        let text = """
        <dw>
        L|First item with a detailed description|subtitle one
        L|Second item with more detailed info|subtitle two
        L|Third item also with enough content
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        XCTAssertEqual(widget?.blocks.count, 1)
        if case .itemList(let list) = widget?.blocks.first {
            XCTAssertEqual(list.items.count, 3)
        } else {
            XCTFail("Expected itemList block")
        }
    }

    func testParseConsecutiveChips() {
        let text = """
        <dw>
        T|Here is a descriptive paragraph with enough content to pass quality filtering
        C|Programming Languages|tag
        C|Software Development|tag|https://example.com
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        XCTAssertEqual(widget?.blocks.count, 2)
        if case .chipRow(let cr) = widget?.blocks.last {
            XCTAssertEqual(cr.chips.count, 2)
            XCTAssertEqual(cr.chips[1].url, "https://example.com")
        } else {
            XCTFail("Expected chipRow block")
        }
    }

    func testParsePipeEscaping() {
        let text = """
        <dw>
        KV|Full Name|Smith \\| Jones
        KV|Occupation|Software Engineer at Major Corporation
        KV|Location|San Francisco Bay Area California
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        if case .keyValue(let kv) = widget?.blocks.first {
            XCTAssertEqual(kv.pairs[0].value, "Smith | Jones")
        } else {
            XCTFail("Expected keyValue block with escaped pipe")
        }
    }

    func testParseTable() {
        let text = """
        <dw>
        TB|Product Name|Stock Level|Customer Rating
        TR|Premium Widget Alpha|150 units|4.5 stars
        TR|Deluxe Widget Beta|280 units|4.8 stars
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        XCTAssertEqual(widget?.blocks.count, 1)
        if case .table(let tb) = widget?.blocks.first {
            XCTAssertEqual(tb.headers, ["Product Name", "Stock Level", "Customer Rating"])
            XCTAssertEqual(tb.rows.count, 2)
        } else {
            XCTFail("Expected table block")
        }
    }

    func testParseStatRow() {
        let text = """
        <dw>
        H|car.fill|Tesla Model S Performance Specifications
        SR|350;Range;mi|3.1;0-60;s|162;Top Speed;mph
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        if case .statRow(let sr) = widget?.blocks.last {
            XCTAssertEqual(sr.items.count, 3)
            XCTAssertEqual(sr.items[0].value, "350")
            XCTAssertEqual(sr.items[0].label, "Range")
            XCTAssertEqual(sr.items[0].unit, "mi")
        } else {
            XCTFail("Expected statRow block")
        }
    }

    func testParseImage() {
        let text = """
        <dw>
        IMG|https://cdn.test.com/photo.jpg|A photo of the Grand Canyon National Park|150
        T|The Grand Canyon is one of the most spectacular natural wonders in the world
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        if case .image(let img) = widget?.blocks.first {
            XCTAssertEqual(img.url, "https://cdn.test.com/photo.jpg")
            XCTAssertEqual(img.caption, "A photo of the Grand Canyon National Park")
            XCTAssertEqual(img.maxHeight, 150)
        } else {
            XCTFail("Expected image block")
        }
    }

    func testParseProgress() {
        let text = """
        <dw>
        H|arrow.down.circle|Downloading System Update Package
        P|0.65|Loading|65%
        T|Estimated time remaining approximately fifteen minutes
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        if case .progress(let p) = widget?.blocks[1] {
            XCTAssertEqual(p.value, 0.65, accuracy: 0.001)
            XCTAssertEqual(p.label, "Loading")
            XCTAssertEqual(p.total, "65%")
        } else {
            XCTFail("Expected progress block")
        }
    }

    func testParseDivider() {
        let text = "<dw>\nH|star|Dashboard Overview Title\nD\nT|This is a detailed description with enough content to pass quality filtering\n</dw>"
        let (_, widget) = DynamicWidgetParser.parse(text)
        XCTAssertEqual(widget?.blocks.count, 3)
        XCTAssertEqual(widget?.blocks[1], .divider)
    }

    func testParseTextWithStyle() {
        let text = "<dw>\nT|This is a detailed note with enough content to satisfy quality requirements|footnote\n</dw>"
        let (_, widget) = DynamicWidgetParser.parse(text)
        if case .text(let t) = widget?.blocks.first {
            XCTAssertEqual(t.content, "This is a detailed note with enough content to satisfy quality requirements")
            XCTAssertEqual(t.style, .footnote)
        } else {
            XCTFail("Expected text block")
        }
    }

    func testParseNoTint() {
        let text = "<dw>\nH|star|Title\nT|This is a sufficiently long text block for quality filtering purposes\n</dw>"
        let (_, widget) = DynamicWidgetParser.parse(text)
        XCTAssertNil(widget?.tint)
    }

    func testFlushesAccumulatorsOnTypeChange() {
        let text = """
        <dw>
        KV|Country|United States of America
        KV|Population|331 million people
        L|New York City is the largest metropolitan area
        L|Los Angeles is the second largest city
        </dw>
        """
        let (_, widget) = DynamicWidgetParser.parse(text)
        XCTAssertEqual(widget?.blocks.count, 2)
        if case .keyValue(let kv) = widget?.blocks[0] {
            XCTAssertEqual(kv.pairs.count, 2)
        }
        if case .itemList(let list) = widget?.blocks[1] {
            XCTAssertEqual(list.items.count, 2)
        }
    }

    // MARK: - Icon Inference

    func testInferIconForCarTitle() {
        // "vs" triggers comparison icon first — test a non-comparison car title
        let icon = DynamicWidgetParser.inferIcon(for: "Tesla Model 3 Specifications")
        XCTAssertEqual(icon, "car.fill")
    }

    func testInferIconForCarComparisonUsesComparisonIcon() {
        // "vs" takes priority over car keywords — correct behavior
        let icon = DynamicWidgetParser.inferIcon(for: "Tesla Model 3 vs BMW i4")
        XCTAssertEqual(icon, "arrow.left.arrow.right")
    }

    func testInferIconForCountryTitle() {
        let icon = DynamicWidgetParser.inferIcon(for: "Canada Population and GDP")
        XCTAssertEqual(icon, "globe")
    }

    func testInferIconForComparisonTitle() {
        let icon = DynamicWidgetParser.inferIcon(for: "iPhone 16 vs Samsung S25")
        XCTAssertEqual(icon, "arrow.left.arrow.right")
    }

    func testInferIconFallsBackToInfoCircle() {
        let icon = DynamicWidgetParser.inferIcon(for: "Random Unknown Topic")
        XCTAssertEqual(icon, "info.circle")
    }

    func testHeaderWithoutIconGetsInferredIcon() {
        let text = "<dw>\nH|Tesla Model 3\nKV|Range|358 mi\nKV|Price|$42,990\n</dw>"
        let (_, widget) = DynamicWidgetParser.parse(text)
        if case .header(let h) = widget?.blocks.first {
            XCTAssertEqual(h.icon, "car.fill", "Header without explicit icon should get inferred car icon")
        } else {
            XCTFail("Expected header block")
        }
    }

    func testHeaderWithExplicitIconPreserved() {
        let text = "<dw>\nH|trophy.fill|Championship Results\nKV|Winner|Team A\n</dw>"
        let (_, widget) = DynamicWidgetParser.parse(text)
        if case .header(let h) = widget?.blocks.first {
            XCTAssertEqual(h.icon, "trophy.fill", "Explicit icon should be preserved")
        } else {
            XCTFail("Expected header block")
        }
    }

    // MARK: - Empty Block Guard

    func testEmptyWidgetBlocksReturnNil() {
        // Simulate what WidgetLayoutGenerator would see: parser returns widget with empty blocks
        let text = "<dw>\ntint:blue\n</dw>"
        let (_, widget) = DynamicWidgetParser.parse(text)
        // Parser may return a widget with empty blocks; validated() includes qualityFiltered()
        if let widget {
            let validated = widget.validated()
            XCTAssertTrue(validated.blocks.isEmpty,
                          "Widget with no content blocks should be filtered out by validated()")
        }
    }
}

// MARK: - View Compilation Tests

@MainActor
final class DynamicWidgetViewTests: XCTestCase {

    func testDynamicWidgetViewCompilesWithHeaderAndStat() throws {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "star", title: "Test")),
            .stat(StatBlock(value: "42", label: "Answer")),
        ], tint: .blue)
        let view = DynamicWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testDynamicWidgetViewCompilesWithItemList() throws {
        let data = DynamicWidgetData(blocks: [
            .itemList(ItemListBlock(items: [
                ListItem(icon: "doc", title: "File", subtitle: "PDF"),
                ListItem(title: "Another", trailing: "3 MB"),
            ])),
        ])
        let view = DynamicWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testDynamicWidgetViewCompilesWithImage() throws {
        let data = DynamicWidgetData(blocks: [
            .image(ImageBlock(url: "https://example.com/img.png", caption: "Photo")),
        ])
        let view = DynamicWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }

    func testDynamicWidgetViewCompilesWithEmptyBlocks() throws {
        let data = DynamicWidgetData(blocks: [])
        let view = DynamicWidgetView(data: data)
        let _ = view.body
        XCTAssertNotNil(view)
    }
}

// MARK: - WidgetOutput Integration

final class DynamicWidgetOutputTests: XCTestCase {

    func testFromLegacyDynamicWidget() {
        let data = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "star", title: "Test")),
        ])
        let output = WidgetOutput.fromLegacy(widgetType: "DynamicWidget", widgetData: data)
        if case .dynamic(let d) = output {
            XCTAssertEqual(d.blocks.count, 1)
        } else {
            XCTFail("Expected .dynamic case, got \(output)")
        }
    }

    func testWidgetOutputTypeString() {
        let data = DynamicWidgetData(blocks: [])
        let output = WidgetOutput.dynamic(data)
        XCTAssertEqual(output.widgetTypeString, "DynamicWidget")
    }

    func testWidgetOutputWidgetData() {
        let data = DynamicWidgetData(blocks: [
            .stat(StatBlock(value: "100")),
        ])
        let output = WidgetOutput.dynamic(data)
        XCTAssertNotNil(output.widgetData)
    }
}

// MARK: - WidgetLayoutGenerator Tests

final class WidgetLayoutGeneratorTests: XCTestCase {

    func testGeneratorWithMockLLM() async {
        let dwResponse = """
        <dw>
        tint:blue
        H|globe|Brazil — South American Republic
        S|214.3M|Population (2023 Census)
        KV|Capital|Brasilia, Federal District
        KV|Language|Portuguese (official)
        </dw>
        """
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in return dwResponse }))
        let result = await generator.generateLayout(
            ingredients: ["Brazil: Population 214.3 million. Capital: Brasilia, Federal District. Official language: Portuguese. Annual growth rate: 0.52%. Located in South America."],
            userPrompt: "Tell me about Brazil"
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.tint, .blue)
        // H + S + KV(2 pairs grouped) = 3 blocks (consecutive KV lines are auto-grouped)
        XCTAssertEqual(result?.blocks.count, 3)
    }

    func testGeneratorReturnsNilForShortIngredients() async {
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in return "" }))
        let result = await generator.generateLayout(
            ingredients: ["Short"],
            userPrompt: "test"
        )
        XCTAssertNil(result)
    }

    func testGeneratorReturnsNilWhenLLMReturnsNoBlock() async {
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in return "Just a plain text response with no DSL block." }))
        let result = await generator.generateLayout(
            ingredients: [String(repeating: "data ", count: 30)],
            userPrompt: "test"
        )
        XCTAssertNil(result)
    }

    func testGeneratorFiltersMetaIngredients() async {
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in return "<dw>\nH|star|Test\n</dw>" }))
        let result = await generator.generateLayout(
            ingredients: ["No tool is needed for this request.", "Will use FM Tool: Camera"],
            userPrompt: "test"
        )
        // Meta ingredients are filtered, combined length < 100
        XCTAssertNil(result)
    }

    func testLayoutGeneratorSkipsOversizedIngredients() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in
            callCount.withLock { $0 += 1 }
            return "<dw>\nH|star|Test\n</dw>"
        }))
        // 15000 chars / 4 = 3750 estimated tokens, well above the 2500 budget
        let hugeIngredient = String(repeating: "A", count: 15000)
        let result = await generator.generateLayout(
            ingredients: [hugeIngredient],
            userPrompt: "test"
        )
        XCTAssertNil(result, "Should return nil when prompt exceeds token budget")
        XCTAssertEqual(callCount.withLock { $0 }, 0, "LLM should not be called when prompt exceeds token budget")
    }

    func testGeneratorFiltersDisambiguationIngredients() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in
            callCount.withLock { $0 += 1 }
            return "<dw>\nH|star|Test\n</dw>"
        }))
        let result = await generator.generateLayout(
            ingredients: ["This request is ambiguous — it could involve: looking something up on Wikipedia, meta help. Ask the user to clarify what they'd like. Do NOT mention internal tool names."],
            userPrompt: "how does e-ink work?"
        )
        // Disambiguation meta-text should be filtered out, leaving nothing substantive
        XCTAssertNil(result, "Disambiguation ingredients should not trigger widget generation")
        XCTAssertEqual(callCount.withLock { $0 }, 0, "LLM should not be called for disambiguation text")
    }

    func testGeneratorFiltersErrorIngredients() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in
            callCount.withLock { $0 += 1 }
            return "<dw>\nH|star|Test\n</dw>"
        }))
        let result = await generator.generateLayout(
            ingredients: ["[ERROR] WikipediaSearch: No Wikipedia article found for 'ePaper technology work'."],
            userPrompt: "how does ePaper technology work?"
        )
        XCTAssertNil(result, "Error ingredients should not trigger widget generation")
        XCTAssertEqual(callCount.withLock { $0 }, 0, "LLM should not be called for error-only ingredients")
    }

    func testGeneratorFiltersNoSpecificToolIngredients() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in
            callCount.withLock { $0 += 1 }
            return "<dw>\nH|star|Test\n</dw>"
        }))
        let result = await generator.generateLayout(
            ingredients: ["No specific tool matches this request. Answer the user's question conversationally using your knowledge. Be helpful and direct. If you genuinely cannot answer, then ask a brief clarifying question."],
            userPrompt: "what is the meaning of life?"
        )
        XCTAssertNil(result, "Clarification ingredients should not trigger widget generation")
        XCTAssertEqual(callCount.withLock { $0 }, 0, "LLM should not be called for clarification text")
    }

    func testGeneratorPassesThroughRealDataWithErrorsSideBySide() async {
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in
            return "<dw>\ntint:blue\nH|globe|Brazil\nS|214.3M|Population\n</dw>"
        }))
        let result = await generator.generateLayout(
            ingredients: [
                "[ERROR] Some tool failed.",
                "This request is ambiguous — could involve: X, Y.",
                "Brazil: Population 214.3 million. Capital: Brasilia. Official language: Portuguese. Located in South America."
            ],
            userPrompt: "Tell me about Brazil"
        )
        // The real data ingredient survives filtering, so widget should be generated
        XCTAssertNotNil(result, "Real data ingredients should still produce widgets even when mixed with filtered meta-text")
    }

    func testLayoutGeneratorProceedsForSmallIngredients() async {
        let callCount = OSAllocatedUnfairLock(initialState: 0)
        let generator = WidgetLayoutGenerator(llmAdapter: LLMAdapter(testResponder: { _, _ in
            callCount.withLock { $0 += 1 }
            return "<dw>\ntint:blue\nH|star|Detailed Test Widget\nKV|Description|A comprehensive key-value pair with sufficient content\n</dw>"
        }))
        // ~200 chars of ingredients — prompt template (~700 tokens) + this should be well under 2500
        let smallIngredient = String(repeating: "Data point. ", count: 17)
        let result = await generator.generateLayout(
            ingredients: [smallIngredient],
            userPrompt: "test"
        )
        XCTAssertEqual(callCount.withLock { $0 }, 1, "LLM should be called for small ingredients within budget")
        XCTAssertNotNil(result, "Should return widget data for small ingredients")
    }
}

// MARK: - E2E Pipeline Tests

final class DynamicWidgetE2ETests: XCTestCase {

    /// Set the dynamic-widgets flag ONCE per class run, before any test methods.
    /// Previously this lived in per-instance `setUp` + `tearDown`, which race
    /// under `swift test --parallel`: when test A's tearDown removed the key
    /// while test B was mid-execution, B's engine saw `false` and skipped
    /// widget generation, producing a spurious failure. Class-level setUp with
    /// no teardown is race-free: the flag stays `true` for the whole test
    /// process and no other suite depends on its being `false`.
    override class func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: AppConfig.dynamicWidgetsEnabledKey)
    }

    override func setUp() async throws {
        await ScratchpadCache.shared.reset()
    }

    func testSpyToolWithDynamicWidget() async {
        let widgetData = DynamicWidgetData(blocks: [
            .header(HeaderBlock(icon: "cpu", title: "System Info")),
            .stat(StatBlock(value: "98%", label: "Health")),
        ], tint: .green)

        let spy = SpyTool(
            name: "TechSupport",
            schema: "tech support diagnostics",
            result: ToolIO(
                text: "System is healthy",
                outputWidget: "DynamicWidget",
                widgetData: widgetData
            )
        )

        let engine = makeTestEngine(tools: [spy])
        let result = await engine.run(input: "#TechSupport check system")

        XCTAssertEqual(result.widgetType, "DynamicWidget")
        XCTAssertNotNil(result.widgetData as? DynamicWidgetData)
    }

    func testLayoutGeneratorUsesResponseTextWhenIngredientsEmpty() async {
        // Conversational route: no tool, ingredients are all meta-prefixed.
        // The LLM response itself contains substantial structured info that
        // should be fed to the widget generator as a fallback.
        let dwResponse = """
        <dw>
        H|person.fill|Marie Curie — Pioneer in Radioactivity
        KV|Born|November 7, 1867 in Warsaw, Poland
        KV|Nationality|Polish-French dual nationality
        KV|Nobel Prizes|Physics (1903) and Chemistry (1911)
        </dw>
        """

        let engine = makeTestEngine(
            tools: [],
            engineLLMResponder: { prompt, _ in
                // Finalization call — return structured info about Marie Curie.
                // Must be varied text: the degeneration detector in cleanLLMResponse
                // strips responses whose 3-grams repeat four or more times.
                return """
                Marie Curie was a Polish-French physicist and chemist born in Warsaw in 1867. \
                She pioneered research on radioactivity and discovered polonium and radium. \
                Curie won the Nobel Prize in Physics in 1903 alongside Pierre Curie and Henri Becquerel, \
                then a second Nobel in Chemistry in 1911. She remains the only person to have won \
                Nobel Prizes in two distinct scientific disciplines.
                """
            },
            widgetLLMResponder: { prompt, _ in
                return dwResponse
            }
        )

        let result = await engine.run(input: "Tell me about Marie Curie")

        // Widget should be generated from the response text fallback
        XCTAssertEqual(result.widgetType, "DynamicWidget")
        if let data = result.widgetData as? DynamicWidgetData {
            XCTAssertFalse(data.blocks.isEmpty)
        } else {
            XCTFail("Expected DynamicWidgetData from response text fallback")
        }
    }

    func testLayoutGeneratorTriggersWhenNoToolWidget() async {
        let spy = SpyTool(
            name: "Research",
            schema: "research topic",
            result: ToolIO(text: String(repeating: "Brazil population data with extensive details about demographics and geography. ", count: 5))
        )

        let dwResponse = """
        <dw>
        H|globe|Brazil — South American Republic
        S|214.3M|Population (2023 Census)
        KV|Capital|Brasilia, Federal District
        KV|Official Language|Portuguese
        </dw>
        """

        let engine = makeTestEngine(
            tools: [spy],
            engineLLMResponder: makeStubLLMResponder(),
            widgetLLMResponder: { prompt, _ in
                return dwResponse
            }
        )

        let result = await engine.run(input: "#Research Brazil")

        // The layout generator should have been invoked and produced a widget
        XCTAssertEqual(result.widgetType, "DynamicWidget")
        if let data = result.widgetData as? DynamicWidgetData {
            XCTAssertFalse(data.blocks.isEmpty)
        } else {
            XCTFail("Expected DynamicWidgetData")
        }
    }
}
