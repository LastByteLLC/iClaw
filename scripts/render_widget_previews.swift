#!/usr/bin/env swift

// render_widget_previews.swift
// Renders DynamicWidget DSL samples to PNG images for visual review.
//
// This script is a standalone Swift executable that:
// 1. Reads DSL samples from a JSONL file
// 2. Parses each through DynamicWidgetParser
// 3. Renders via SwiftUI ImageRenderer at 340pt width (iClaw HUD size)
// 4. Saves PNGs to an output directory
//
// Usage:
//   swift render_widget_previews.swift [input.jsonl] [output_dir]
//
// Requires: macOS 26+, must be run from the iClaw project root
// (needs access to iClawCore module for DynamicWidgetParser/View)
//
// NOTE: This script cannot import iClawCore directly since it's a standalone
// swift file, not part of the SPM build. Instead, we parse the DSL ourselves
// using a minimal reimplementation and render with basic SwiftUI.

import SwiftUI
import AppKit
import Foundation

// MARK: - Minimal DSL Parser (standalone, no iClawCore dependency)

struct MiniWidget {
    var tint: String = "blue"
    var blocks: [MiniBlock] = []
}

enum MiniBlock {
    case header(icon: String, title: String, subtitle: String?)
    case stat(value: String, label: String)
    case statRow(items: [(value: String, label: String)])
    case keyValue(pairs: [(key: String, value: String)])
    case listItems(items: [(title: String, subtitle: String?, trailing: String?)])
    case table(headers: [String], rows: [[String]])
    case text(content: String, style: String)
    case divider
}

func parseDSL(_ raw: String) -> MiniWidget? {
    // Extract content between <dw> and </dw>
    guard let start = raw.range(of: "<dw>", options: .caseInsensitive),
          let end = raw.range(of: "</dw>", options: .caseInsensitive) else { return nil }

    let content = String(raw[start.upperBound..<end.lowerBound])
    let lines = content.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    var widget = MiniWidget()
    var kvAccum: [(String, String)] = []
    var listAccum: [(String, String?, String?)] = []
    var tableHeaders: [String] = []
    var tableRows: [[String]] = []

    func flushKV() {
        if !kvAccum.isEmpty { widget.blocks.append(.keyValue(pairs: kvAccum)); kvAccum = [] }
    }
    func flushList() {
        if !listAccum.isEmpty { widget.blocks.append(.listItems(items: listAccum)); listAccum = [] }
    }
    func flushTable() {
        if !tableHeaders.isEmpty { widget.blocks.append(.table(headers: tableHeaders, rows: tableRows)); tableHeaders = []; tableRows = [] }
    }

    for line in lines {
        if line.hasPrefix("tint:") {
            widget.tint = String(line.dropFirst(5))
            continue
        }

        let parts = line.components(separatedBy: "|")
        guard let type = parts.first else { continue }

        switch type {
        case "H":
            flushKV(); flushList(); flushTable()
            let icon = parts.count > 1 ? parts[1] : "info.circle"
            let title = parts.count > 2 ? parts[2] : ""
            let sub = parts.count > 3 ? parts[3] : nil
            widget.blocks.append(.header(icon: icon, title: title, subtitle: sub))

        case "S":
            flushKV(); flushList(); flushTable()
            let val = parts.count > 1 ? parts[1] : ""
            let lab = parts.count > 2 ? parts[2] : ""
            widget.blocks.append(.stat(value: val, label: lab))

        case "SR":
            flushKV(); flushList(); flushTable()
            var items: [(String, String)] = []
            for p in parts.dropFirst() {
                let sub = p.components(separatedBy: ";")
                if sub.count >= 2 { items.append((sub[0], sub[1])) }
            }
            widget.blocks.append(.statRow(items: items))

        case "KV":
            flushList(); flushTable()
            if parts.count >= 3 { kvAccum.append((parts[1], parts[2])) }

        case "L":
            flushKV(); flushTable()
            let title = parts.count > 1 ? parts[1] : ""
            let sub = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            let trail = parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil
            listAccum.append((title, sub, trail))

        case "TB":
            flushKV(); flushList(); flushTable()
            tableHeaders = Array(parts.dropFirst())

        case "TR":
            tableRows.append(Array(parts.dropFirst()))

        case "T":
            flushKV(); flushList(); flushTable()
            let text = parts.count > 1 ? parts[1] : ""
            let style = parts.count > 2 ? parts[2] : "caption"
            widget.blocks.append(.text(content: text, style: style))

        case "D":
            flushKV(); flushList(); flushTable()
            widget.blocks.append(.divider)

        default: break
        }
    }

    flushKV(); flushList(); flushTable()
    return widget.blocks.isEmpty ? nil : widget
}

// MARK: - SwiftUI Widget Renderer

func tintColor(_ name: String) -> Color {
    switch name.lowercased() {
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "red": return .red
    case "purple": return .purple
    case "yellow": return .yellow
    case "mint": return .mint
    case "indigo": return .indigo
    case "teal": return .teal
    default: return .blue
    }
}

struct WidgetPreview: View {
    let widget: MiniWidget
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(widget.blocks.enumerated()), id: \.offset) { idx, block in
                blockView(block)
                    .padding(.horizontal, 14)
                    .padding(.vertical, blockPadding(idx))
            }
        }
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        // ID label at bottom for reference
        .overlay(alignment: .bottomTrailing) {
            Text(id)
                .font(.system(size: 7))
                .foregroundStyle(.white.opacity(0.3))
                .padding(4)
        }
    }

    func blockPadding(_ idx: Int) -> CGFloat {
        idx == 0 ? 0 : 4
    }

    @ViewBuilder
    func blockView(_ block: MiniBlock) -> some View {
        switch block {
        case .header(let icon, let title, let subtitle):
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tintColor(widget.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    if let sub = subtitle {
                        Text(sub).font(.subheadline).foregroundStyle(.gray)
                    }
                }
                Spacer()
            }
            .padding(.bottom, 6)

        case .stat(let value, let label):
            VStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 36, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

        case .statRow(let items):
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 2) {
                        Text(item.0)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                        Text(item.1)
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)

        case .keyValue(let pairs):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    GridRow {
                        Text(pair.0)
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .gridColumnAlignment(.trailing)
                            .lineLimit(1)
                        Text(pair.1)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                    }
                }
            }

        case .listItems(let items):
            VStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.0).font(.callout).foregroundStyle(.white).lineLimit(2)
                            if let sub = item.1 {
                                Text(sub).font(.caption).foregroundStyle(.gray)
                            }
                        }
                        Spacer()
                        if let trail = item.2 {
                            Text(trail)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

        case .table(let headers, let rows):
            VStack(spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        Text(h)
                            .font(.caption.bold())
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { ridx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { cidx, cell in
                            Text(cell)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(cidx == 0 ? .white : .white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 3)
                    .background(ridx % 2 == 1 ? Color.white.opacity(0.03) : .clear)
                }
            }

        case .text(let content, _):
            Text(content)
                .font(.caption)
                .foregroundStyle(.gray)

        case .divider:
            Divider().background(Color.white.opacity(0.1)).padding(.vertical, 4)
        }
    }
}

// MARK: - Main

let args = CommandLine.arguments
let inputPath = args.count > 1 ? args[1] : "/tmp/iclaw_widget_review/dsl_samples.jsonl"
let outputDir = args.count > 2 ? args[2] : "/tmp/iclaw_widget_review/previews"

try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

guard let data = FileManager.default.contents(atPath: inputPath),
      let content = String(data: data, encoding: .utf8) else {
    print("ERROR: Cannot read \(inputPath)")
    exit(1)
}

let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
print("Rendering \(lines.count) widget previews to \(outputDir)/")

@MainActor
func renderAll() throws {
    var rendered = 0
    var failed = 0

    for (i, line) in lines.enumerated() {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = json["id"] as? String,
              let dsl = json["dsl"] as? String else {
            failed += 1
            continue
        }

        guard let widget = parseDSL(dsl) else {
            failed += 1
            continue
        }

        let view = WidgetPreview(widget: widget, id: id)
            .frame(width: 340)
            .padding(20)
            .background(Color(white: 0.05))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0

        if let image = renderer.nsImage {
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let png = rep.representation(using: .png, properties: [:])!
            let safeId = id.replacingOccurrences(of: ".jsonl", with: "").replacingOccurrences(of: "/", with: "_")
            let filename = "\(outputDir)/\(String(format: "%04d", i))_\(safeId).png"
            try png.write(to: URL(fileURLWithPath: filename))
            rendered += 1
        } else {
            failed += 1
        }

        if (i + 1) % 100 == 0 {
            print("  \(i + 1)/\(lines.count) rendered...")
        }
    }

    print("Done. \(rendered) rendered, \(failed) failed.")
    print("Preview directory: \(outputDir)/")
}

try MainActor.assumeIsolated {
    try renderAll()
}
