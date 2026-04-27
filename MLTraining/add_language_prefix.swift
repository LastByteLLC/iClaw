#!/usr/bin/env swift

// add_language_prefix.swift
//
// Prepends a detected-language tag to every training/validation example so
// the MaxEnt classifier can learn language-conditioned patterns without a
// global language parameter. Works on multilingual datasets.
//
// Input:  <base>_training.json / <base>_validation.json (written by a
//         matching merge script).
// Output: <base>_training_lp.json / <base>_validation_lp.json
//
// Run:    xcrun swift add_language_prefix.swift [base]
//         Defaults base to "intent" for back-compat.

import Foundation
import NaturalLanguage

let baseDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

struct Row: Codable {
    let text: String
    let label: String
}

func detectLanguagePrefix(for text: String) -> String {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    // Use the top hypothesis regardless of confidence; short strings need
    // a prefix too. Fall back to "un" (unknown) if recognizer returns nil.
    if let lang = recognizer.dominantLanguage {
        return lang.rawValue
    }
    return "un"
}

func transform(path input: String, output: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: input))
    let rows = try JSONDecoder().decode([Row].self, from: data)
    let transformed: [Row] = rows.map { row in
        let lang = detectLanguagePrefix(for: row.text)
        return Row(text: "[\(lang)] \(row.text)", label: row.label)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    let outData = try encoder.encode(transformed)
    try outData.write(to: URL(fileURLWithPath: output))
    print("  \(input) -> \(output) (\(transformed.count) rows)")

    // Report distribution of detected languages for sanity
    var counts: [String: Int] = [:]
    for r in transformed {
        let prefix = String(r.text.prefix(while: { $0 != " " }))
        counts[prefix, default: 0] += 1
    }
    let sorted = counts.sorted { $0.value > $1.value }
    print("  Language distribution:")
    for (lang, n) in sorted {
        print("    \(lang.padding(toLength: 10, withPad: " ", startingAt: 0)) \(n)")
    }
}

let base: String = {
    let args = CommandLine.arguments
    return args.count >= 2 ? args[1] : "intent"
}()

print("Prepending [lang] prefix to '\(base)' training data...")
try transform(
    path: "\(baseDir)/\(base)_training.json",
    output: "\(baseDir)/\(base)_training_lp.json"
)
try transform(
    path: "\(baseDir)/\(base)_validation.json",
    output: "\(baseDir)/\(base)_validation_lp.json"
)
print("Done.")
