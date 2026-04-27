#!/usr/bin/env swift

// train_classifier.swift
// Unified MaxEnt text classifier trainer for iClaw CoreML models.
//
// Usage:
//   swift train_classifier.swift tool                # Tool routing classifier
//   swift train_classifier.swift followup            # Follow-up turn classifier
//   swift train_classifier.swift toxicity            # Toxicity classifier
//
// After training, compile and install:
//   xcrun coremlcompiler compile <model>.mlmodel /tmp/mlmodel_output/
//   cp -R /tmp/mlmodel_output/<model>.mlmodelc ../Sources/iClawCore/Resources/

import CreateML
import Foundation
import TabularData

// MARK: - Configuration

struct ClassifierConfig {
    let name: String
    let trainingData: String
    let validationData: String
    let outputModel: String
    let installPath: String
}

let baseDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let configs: [String: ClassifierConfig] = [
    "tool": ClassifierConfig(
        name: "Tool Routing Classifier",
        trainingData: "\(baseDir)/training_data_compound.json",
        validationData: "\(baseDir)/validation_data_compound.json",
        outputModel: "\(baseDir)/ToolClassifier_MaxEnt.mlmodel",
        installPath: "../Sources/iClawCore/Resources/ToolClassifier_MaxEnt_Merged.mlmodelc"
    ),
    "followup": ClassifierConfig(
        name: "Follow-Up Classifier",
        trainingData: "\(baseDir)/followup_training.json",
        validationData: "\(baseDir)/followup_validation.json",
        outputModel: "\(baseDir)/FollowUpClassifier_MaxEnt.mlmodel",
        installPath: "../Sources/iClawCore/Resources/FollowUpClassifier_MaxEnt.mlmodelc"
    ),
    "toxicity": ClassifierConfig(
        name: "Toxicity Classifier",
        trainingData: "\(baseDir)/toxicity_training_data.json",
        validationData: "\(baseDir)/toxicity_training_data.json",
        outputModel: "\(baseDir)/ToxicityClassifier_MaxEnt.mlmodel",
        installPath: "../Sources/iClawCore/Resources/ToxicityClassifier_MaxEnt.mlmodelc"
    ),
    "pathology": ClassifierConfig(
        name: "Response Pathology Classifier",
        trainingData: "\(baseDir)/pathology_training.json",
        validationData: "\(baseDir)/pathology_validation.json",
        outputModel: "\(baseDir)/ResponsePathologyClassifier_MaxEnt.mlmodel",
        installPath: "../Sources/iClawCore/Resources/ResponsePathologyClassifier_MaxEnt.mlmodelc"
    ),
    "intent": ClassifierConfig(
        name: "Conversation Intent Classifier",
        trainingData: "\(baseDir)/intent_training.json",
        validationData: "\(baseDir)/intent_validation.json",
        outputModel: "\(baseDir)/ConversationIntentClassifier_MaxEnt.mlmodel",
        installPath: "../Sources/iClawCore/Resources/ConversationIntentClassifier_MaxEnt.mlmodelc"
    ),
    "userfact": ClassifierConfig(
        name: "User Fact Classifier",
        trainingData: "\(baseDir)/userfact_training.json",
        validationData: "\(baseDir)/userfact_validation.json",
        outputModel: "\(baseDir)/UserFactClassifier_MaxEnt.mlmodel",
        installPath: "../Sources/iClawCore/Resources/UserFactClassifier_MaxEnt.mlmodelc"
    ),
]

// MARK: - Helpers

func formatBytes(_ bytes: Int64) -> String {
    let kb = Double(bytes) / 1024.0
    return kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.1f MB", kb / 1024.0)
}

func fileSize(atPath path: String) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
    if isDir.boolValue {
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 { total += size }
        }
        return total
    }
    return ((try? fm.attributesOfItem(atPath: path))?[.size] as? Int64) ?? 0
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2, let config = configs[args[1].lowercased()] else {
    print("Usage: swift train_classifier.swift <tool|followup|toxicity>")
    print("Available classifiers:")
    for (key, cfg) in configs.sorted(by: { $0.key < $1.key }) {
        print("  \(key.padding(toLength: 10, withPad: " ", startingAt: 0)) — \(cfg.name)")
    }
    exit(1)
}

let separator = String(repeating: "=", count: 70)
print(separator)
print(config.name)
print(separator)
print()

print("Loading training data: \(config.trainingData)")
let trainingDF = try DataFrame(contentsOfJSONFile: URL(fileURLWithPath: config.trainingData))
print("  Samples: \(trainingDF.rows.count)")

print("Loading validation data: \(config.validationData)")
let validationDF = try DataFrame(contentsOfJSONFile: URL(fileURLWithPath: config.validationData))
print("  Samples: \(validationDF.rows.count)")

// Label distribution
var counts: [String: Int] = [:]
for i in 0..<trainingDF.rows.count {
    if let label = trainingDF.rows[i]["label"] as? String {
        counts[label, default: 0] += 1
    }
}
print("\nLabels (\(counts.count) unique):")
for (label, count) in counts.sorted(by: { $0.value > $1.value }).prefix(20) {
    print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) \(count)")
}
if counts.count > 20 { print("  ... and \(counts.count - 20) more") }

// Train
print("\n\(String(repeating: "-", count: 70))")
print("Training MaxEnt classifier...")
let startTime = Date()

let params = MLTextClassifier.ModelParameters(algorithm: .maxEnt(revision: nil))
let classifier = try MLTextClassifier(
    trainingData: trainingDF, textColumn: "text", labelColumn: "label", parameters: params
)

let elapsed = Date().timeIntervalSince(startTime)
let trainAcc = (1.0 - classifier.trainingMetrics.classificationError) * 100.0
let valMetrics = classifier.evaluation(on: validationDF, textColumn: "text", labelColumn: "label")
let valAcc = (1.0 - valMetrics.classificationError) * 100.0

try classifier.write(to: URL(fileURLWithPath: config.outputModel))
let size = fileSize(atPath: config.outputModel)

print()
print("  Time:       \(String(format: "%.2f", elapsed))s")
print("  Train acc:  \(String(format: "%.2f", trainAcc))%")
print("  Val acc:    \(String(format: "%.2f", valAcc))%")
print("  Model size: \(formatBytes(size))")
print("  Saved:      \(config.outputModel)")

// Per-class precision/recall and confusion matrix.
// Predict on each validation row manually so we can build both tables
// without depending on CreateML's internal metric DataFrames (which have
// changed shape between OS releases).
func predict(_ text: String) -> String {
    do {
        return try classifier.prediction(from: text)
    } catch {
        return "__error__"
    }
}

// Gather (true, predicted) pairs.
var truePred: [(true_: String, pred: String)] = []
for row in validationDF.rows {
    guard let text = row["text"] as? String,
          let label = row["label"] as? String else { continue }
    truePred.append((true_: label, pred: predict(text)))
}

// Collect distinct labels in sorted order for stable table layout.
let labelsInData: [String] = {
    var s = Set<String>()
    for (t, p) in truePred { s.insert(t); s.insert(p) }
    return s.sorted()
}()

print("\n  Per-class precision/recall:")
print("  " + String(repeating: "-", count: 62))
print("  " + "label".padding(toLength: 22, withPad: " ", startingAt: 0) +
      "precision".padding(toLength: 12, withPad: " ", startingAt: 0) +
      "recall".padding(toLength: 10, withPad: " ", startingAt: 0) +
      "F1".padding(toLength: 8, withPad: " ", startingAt: 0) +
      "support")
print("  " + String(repeating: "-", count: 62))
for lbl in labelsInData {
    let tp = truePred.filter { $0.true_ == lbl && $0.pred == lbl }.count
    let fp = truePred.filter { $0.true_ != lbl && $0.pred == lbl }.count
    let fn = truePred.filter { $0.true_ == lbl && $0.pred != lbl }.count
    let support = tp + fn
    let precision = tp + fp == 0 ? 0.0 : Double(tp) / Double(tp + fp)
    let recall = support == 0 ? 0.0 : Double(tp) / Double(support)
    let f1 = (precision + recall) == 0 ? 0.0 : 2 * precision * recall / (precision + recall)
    print("  " + lbl.padding(toLength: 22, withPad: " ", startingAt: 0) +
          String(format: "%.3f", precision).padding(toLength: 12, withPad: " ", startingAt: 0) +
          String(format: "%.3f", recall).padding(toLength: 10, withPad: " ", startingAt: 0) +
          String(format: "%.3f", f1).padding(toLength: 8, withPad: " ", startingAt: 0) +
          "\(support)")
}

// Confusion matrix (rows=true, cols=predicted). Only print if ≤8 classes
// to keep output scannable.
if labelsInData.count <= 8 {
    print("\n  Confusion matrix (rows=true, cols=predicted):")
    let colHeader = "              " + labelsInData.map { $0.prefix(10).padding(toLength: 10, withPad: " ", startingAt: 0) }.joined(separator: " ")
    print("  " + colHeader)
    for trueLbl in labelsInData {
        let row = labelsInData.map { predLbl -> String in
            let count = truePred.filter { $0.true_ == trueLbl && $0.pred == predLbl }.count
            return "\(count)".padding(toLength: 10, withPad: " ", startingAt: 0)
        }
        print("  " + trueLbl.prefix(12).padding(toLength: 14, withPad: " ", startingAt: 0) + row.joined(separator: " "))
    }
}

print("\n\(separator)")
print("Compile and install:")
print("  xcrun coremlcompiler compile \(config.outputModel) /tmp/mlmodel_output/")
print("  cp -R /tmp/mlmodel_output/\(URL(fileURLWithPath: config.outputModel).deletingPathExtension().lastPathComponent).mlmodelc \(config.installPath)")
print(separator)
