#!/usr/bin/env swift

// ClassifierBenchmark.swift
// Headless benchmark for the ML tool classifier.
// Runs predictions against validation + stress test data, reports accuracy,
// exports misroutes for retraining. No Apple Foundation Models needed.
//
// Usage: swift ClassifierBenchmark.swift [--stress-dir /path/to/stress/dir]
// Run from the MLTraining/ directory.

import CoreML
import Foundation
import NaturalLanguage

// MARK: - Configuration

// Resolve repo paths from this file's location: MLTraining/ClassifierBenchmark.swift
// → MLTraining/  →  <repo root>/Sources/iClawCore/Resources/...
let baseDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let modelDir = "\(repoRoot)/Sources/iClawCore/Resources/ToolClassifier_MaxEnt_Merged.mlmodelc"
let validationPath = "\(baseDir)/validation_data_compound.json"
let stressBaseDir = "/tmp/iclaw_live_stress"

// Minimum accuracy thresholds
let overallThreshold = 0.90
let perLabelThreshold = 0.70
let perLabelMinSamples = 10

// MARK: - Data Types

struct TestEntry: Codable {
    let text: String
    let label: String
}

struct MisrouteEntry: Codable {
    let text: String
    let expected_label: String
    let actual_label: String
    let confidence: Double
}

struct LabelMetrics {
    var correct = 0
    var total = 0
    var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
}

struct ConfusionPair: Hashable {
    let expected: String
    let predicted: String
}

// MARK: - Parse Arguments

var stressDir: String? = nil
let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--stress-dir"), idx + 1 < args.count {
    stressDir = args[idx + 1]
}

// Auto-detect latest stress test if not specified
if stressDir == nil {
    let fm = FileManager.default
    if let contents = try? fm.contentsOfDirectory(atPath: stressBaseDir) {
        let sorted = contents.sorted().reversed()
        // Find first directory that has validated_prompts.json
        for dir in sorted {
            let path = "\(stressBaseDir)/\(dir)/validated_prompts.json"
            if fm.fileExists(atPath: path) {
                stressDir = "\(stressBaseDir)/\(dir)"
                break
            }
        }
    }
}

// MARK: - Load Model

let separator = String(repeating: "=", count: 70)
print(separator)
print("ML Classifier Benchmark")
print(separator)
print()

let modelURL = URL(fileURLWithPath: modelDir)
guard let mlModel = try? MLModel(contentsOf: modelURL) else {
    print("ERROR: Failed to load model from \(modelDir)")
    exit(1)
}
guard let nlModel = try? NLModel(mlModel: mlModel) else {
    print("ERROR: Failed to create NLModel")
    exit(1)
}
print("Model loaded: \(modelDir)")

// MARK: - Load Test Data

func loadJSON<T: Decodable>(_ path: String, as type: T.Type) -> T? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

var testEntries: [TestEntry] = []
var sources: [String] = []

// 1. Validation data (always included)
if let validation = loadJSON(validationPath, as: [TestEntry].self) {
    testEntries.append(contentsOf: validation)
    sources.append("validation_data.json: \(validation.count) entries")
}

// 2. Stress test validated prompts (correctly routed in stress test)
if let dir = stressDir {
    let validatedPath = "\(dir)/validated_prompts.json"
    if let validated = loadJSON(validatedPath, as: [TestEntry].self) {
        // Deduplicate against existing
        let existing = Set(testEntries.map { $0.text.lowercased() })
        let newEntries = validated.filter { !existing.contains($0.text.lowercased()) }
        testEntries.append(contentsOf: newEntries)
        sources.append("stress validated: \(newEntries.count) entries (from \(dir))")
    }

    // 3. Stress test misroutes — test these too to measure how many we'd now get right
    let misroutePath = "\(dir)/misroutes.json"
    struct StressMisroute: Codable {
        let text: String
        let expected_label: String
        let actual_label: String
        let routing_score: Int
    }
    if let misroutes = loadJSON(misroutePath, as: [StressMisroute].self) {
        let existing = Set(testEntries.map { $0.text.lowercased() })
        let newEntries = misroutes
            .filter { !existing.contains($0.text.lowercased()) }
            .map { TestEntry(text: $0.text, label: $0.expected_label) }
        testEntries.append(contentsOf: newEntries)
        sources.append("stress misroutes: \(newEntries.count) entries")
    }
}

print("Test corpus: \(testEntries.count) entries from \(sources.count) sources")
for s in sources { print("  - \(s)") }
print()

guard !testEntries.isEmpty else {
    print("ERROR: No test data found")
    exit(1)
}

// MARK: - Run Predictions

var overallCorrect = 0
var perLabel: [String: LabelMetrics] = [:]
var misroutes: [MisrouteEntry] = []
var confusionMatrix: [ConfusionPair: Int] = [:]

let startTime = Date()

for entry in testEntries {
    let predicted = nlModel.predictedLabel(for: entry.text) ?? "none"
    let hypotheses = nlModel.predictedLabelHypotheses(for: entry.text, maximumCount: 1)
    let confidence = hypotheses[predicted] ?? 0.0

    // Case-insensitive label comparison (training data has mixed case)
    let isCorrect = predicted.lowercased() == entry.label.lowercased()

    if isCorrect {
        overallCorrect += 1
    } else {
        misroutes.append(MisrouteEntry(
            text: entry.text,
            expected_label: entry.label,
            actual_label: predicted,
            confidence: confidence
        ))
        let pair = ConfusionPair(expected: entry.label, predicted: predicted)
        confusionMatrix[pair, default: 0] += 1
    }

    perLabel[entry.label, default: LabelMetrics()].total += 1
    if isCorrect {
        perLabel[entry.label, default: LabelMetrics()].correct += 1
    }
}

let elapsed = Date().timeIntervalSince(startTime)

// MARK: - Report Results

let overallAccuracy = Double(overallCorrect) / Double(testEntries.count)

print(String(repeating: "-", count: 70))
print("Results")
print(String(repeating: "-", count: 70))
print()
let accPct = String(format: "%.2f", overallAccuracy * 100)
let elapsedStr = String(format: "%.2f", elapsed)
print("  Overall accuracy:   \(accPct)% (\(overallCorrect)/\(testEntries.count))")
print("  Misroutes:          \(misroutes.count)")
print("  Benchmark time:     \(elapsedStr)s")
print()

// Per-label breakdown (worst first)
print("Per-label accuracy (worst first):")
let sortedLabels = perLabel.sorted { $0.value.accuracy < $1.value.accuracy }
var belowThreshold: [String] = []

for (label, metrics) in sortedLabels {
    let marker: String
    if metrics.total >= perLabelMinSamples && metrics.accuracy < perLabelThreshold {
        marker = " ← BELOW THRESHOLD"
        belowThreshold.append(label)
    } else if metrics.total < perLabelMinSamples {
        marker = " (low N)"
    } else {
        marker = ""
    }
    let pct = String(format: "%.1f", metrics.accuracy * 100)
    let padLabel = label.padding(toLength: 20, withPad: " ", startingAt: 0)
    print("  \(padLabel)  \(metrics.correct)/\(metrics.total)  (\(pct)%)\(marker)")
}
print()

// Top confused pairs
if !confusionMatrix.isEmpty {
    print("Top confused pairs:")
    let sortedConfusion = confusionMatrix.sorted { $0.value > $1.value }
    for (pair, count) in sortedConfusion.prefix(15) {
        print("  \(count)x  \(pair.expected) → \(pair.predicted)")
    }
    print()
}

// MARK: - Export Misroutes

let outputDir = "\(baseDir)/benchmark_results"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

// Misroutes
let misrouteData = try! encoder.encode(misroutes)
try! misrouteData.write(to: URL(fileURLWithPath: "\(outputDir)/benchmark_misroutes.json"))

// Summary
struct BenchmarkSummary: Codable {
    let timestamp: String
    let totalEntries: Int
    let overallAccuracy: Double
    let misrouteCount: Int
    let belowThresholdLabels: [String]
    let passesThreshold: Bool
}

let summary = BenchmarkSummary(
    timestamp: ISO8601DateFormatter().string(from: Date()),
    totalEntries: testEntries.count,
    overallAccuracy: overallAccuracy,
    misrouteCount: misroutes.count,
    belowThresholdLabels: belowThreshold,
    passesThreshold: overallAccuracy >= overallThreshold && belowThreshold.isEmpty
)
let summaryData = try! encoder.encode(summary)
try! summaryData.write(to: URL(fileURLWithPath: "\(outputDir)/benchmark_summary.json"))

print("Results exported to: \(outputDir)/")
print()

// MARK: - Pass/Fail

print(separator)
let overallPct = String(format: "%.1f", overallAccuracy * 100)
let thresholdPct = String(format: "%.0f", overallThreshold * 100)
let labelThresholdPct = String(format: "%.0f", perLabelThreshold * 100)
if summary.passesThreshold {
    print("PASS: Overall \(overallPct)% >= \(thresholdPct)%, no labels below \(labelThresholdPct)%")
    exit(0)
} else {
    if overallAccuracy < overallThreshold {
        print("FAIL: Overall \(overallPct)% < \(thresholdPct)%")
    }
    if !belowThreshold.isEmpty {
        print("FAIL: Labels below threshold: \(belowThreshold.joined(separator: ", "))")
    }
    exit(1)
}
