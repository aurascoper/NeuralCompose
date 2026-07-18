#!/usr/bin/env swift

import Foundation
import CoreML

// Minimal CSV parsing
struct CSVRow {
    let fields: [String]
    subscript(_ index: Int) -> String {
        index < fields.count ? fields[index] : ""
    }
}

func parseCSV(_ contents: String) -> [[String]] {
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return lines.map { line in
        line.split(separator: ",").map(String.init)
    }
}

// Confusion matrix — 5 classes, matching the trained model's real CLASS_ORDER
// (Scripts/train-intent-classifier.py) and the raw label strings CalibrationRecorder
// actually writes to labels.csv. Previously this listed 7 labels including "artifact"/
// "none", which the model never predicts (they're pipeline-level, dropped from training
// via DROP_LABELS) and which just diluted the matrix with always-empty rows/columns.
class ConfusionMatrix {
    let labels: [String] = ["rest", "jaw_clench", "blink", "double_blink", "select"]
    var matrix: [[Int]] = Array(repeating: Array(repeating: 0, count: 5), count: 5)
    // Windows whose predicted/actual label falls outside the 5-label set
    // (e.g. no labels.csv row matched the window's sequence number) used to
    // be silently dropped here with no visible trace. Counting them lets
    // the caller reconcile "windows evaluated" against what the matrix
    // actually scored instead of an artificially clean-looking accuracy.
    private(set) var unmatchedCount = 0

    func add(predicted: String, actual: String) {
        guard let predIdx = labels.firstIndex(of: predicted),
              let actualIdx = labels.firstIndex(of: actual) else {
            unmatchedCount += 1
            return
        }
        matrix[predIdx][actualIdx] += 1
    }

    // Right-pads/aligns a Swift String to `width`. NOT `String(format: "%s", ...)` —
    // %s expects a C string pointer, not a Swift String/NSString bridged through
    // varargs; that's undefined behavior on Darwin and crashes at runtime (found
    // while verifying this script actually runs end-to-end against the real
    // classifier — pre-existing in the mock-classifier version too, just never
    // previously exercised far enough to hit it).
    private func pad(_ s: String, _ width: Int) -> String {
        s.count < width ? String(repeating: " ", count: width - s.count) + s : s
    }

    func print() {
        let colWidth = 10
        let header = "                 " + labels.map { pad($0, colWidth) }.joined()
        Swift.print(header)

        for (i, predLabel) in labels.enumerated() {
            let row = pad(predLabel, 16)
            let counts = matrix[i].map { String(format: "%\(colWidth)d", $0) }.joined()
            Swift.print(row + " " + counts)
        }

        Swift.print("\nPer-class Accuracy:")
        for (i, label) in labels.enumerated() {
            let correct = matrix[i][i]
            let total = matrix[i].reduce(0, +)
            let accuracy = total > 0 ? Double(correct) * 100.0 / Double(total) : 0.0
            Swift.print(pad(label, 9) + ": " + String(format: "%5.1f%% (%d/%d)", accuracy, correct, total))
        }

        let totalCorrect = (0..<labels.count).map { matrix[$0][$0] }.reduce(0, +)
        let totalCount = matrix.flatMap { $0 }.reduce(0, +)
        let overall = totalCount > 0 ? Double(totalCorrect) * 100.0 / Double(totalCount) : 0.0
        Swift.print(String(format: "\nOverall Accuracy: %.1f%%", overall))
    }
}

// Real Core ML intent classifier. This script isn't part of the SwiftPM package graph
// (it's invoked as a standalone `swift` script), so it can't `import BCIClassifier`
// directly — the loading/windowing/softmax logic below is deliberately a copy of
// Sources/BCIClassifier/CoreMLIntentClassifier.swift's, not a reinvention:
//   - a raw .mlpackage must be compiled via MLModel.compileModel(at:) before MLModel
//     can load it (Core ML wants a compiled .mlmodelc)
//   - input "eeg_window": Float32 MLMultiArray [1, 4, 512], channel-major, zero-padded
//     tail for short windows
//   - output "intent_logits": Float32 MLMultiArray [1, 5], raw logits — softmax is
//     applied here, not baked into the model
//   - class order rest/jawClench/singleBlink/doubleBlink/select, per
//     Scripts/train-intent-classifier.py's CLASS_ORDER
final class RealIntentClassifier {
    // Swift-side class order (matches the model's output index order) mapped to the
    // raw snake_case label strings CalibrationRecorder writes to labels.csv, so
    // predictions and ground truth share one label space in the confusion matrix.
    static let modelClassToRawLabel: [String] = ["rest", "jaw_clench", "blink", "double_blink", "select"]

    private let model: MLModel
    private let expectedChannels = 4
    private let expectedSamples = 512

    init(modelPackageURL: URL) throws {
        let loadURL: URL
        if modelPackageURL.pathExtension == "mlpackage" {
            loadURL = try MLModel.compileModel(at: modelPackageURL)
        } else {
            loadURL = modelPackageURL
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: loadURL, configuration: config)
    }

    /// channelSamples: one array per EEG channel, in TP9/AF7/AF8/TP10 order.
    func classify(channelSamples: [[Float]]) throws -> String {
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: expectedChannels), NSNumber(value: expectedSamples)],
            dataType: .float32
        )
        let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
        for ch in 0..<expectedChannels {
            let row = ch < channelSamples.count ? channelSamples[ch] : []
            let n = min(row.count, expectedSamples)
            for s in 0..<n { pointer[ch * expectedSamples + s] = row[s] }
            for s in n..<expectedSamples { pointer[ch * expectedSamples + s] = 0 }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["eeg_window": MLFeatureValue(multiArray: array)])
        let prediction = try model.prediction(from: provider)
        guard let output = prediction.featureValue(for: "intent_logits")?.multiArrayValue else {
            throw NSError(domain: "RealIntentClassifier", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "model output missing 'intent_logits'"])
        }

        // Softmax + argmax, mirroring CoreMLIntentClassifier.makePrediction exactly.
        var exps: [Float] = []
        exps.reserveCapacity(output.count)
        var sum: Float = 0
        for i in 0..<output.count {
            let e = expf(output[i].floatValue)
            exps.append(e)
            sum += e
        }
        if sum == 0 { sum = 1 }
        var bestIdx = 0
        var bestP: Float = -1
        for i in 0..<exps.count {
            let p = exps[i] / sum
            if p > bestP { bestP = p; bestIdx = i }
        }
        return bestIdx < Self.modelClassToRawLabel.count ? Self.modelClassToRawLabel[bestIdx] : "unknown"
    }
}

// Main evaluation
func evaluateSession(directory: String, modelURL: URL) throws {
    let dirURL = URL(fileURLWithPath: directory)
    let labelsURL = dirURL.appendingPathComponent("labels.csv")
    let eegURL = dirURL.appendingPathComponent("eeg.csv")

    guard FileManager.default.fileExists(atPath: labelsURL.path),
          FileManager.default.fileExists(atPath: eegURL.path) else {
        print("Error: labels.csv or eeg.csv not found in \(directory)")
        exit(1)
    }
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        print("Error: model not found at \(modelURL.path)")
        print("  (override with --model <path> or NEURALCOMPOSE_CLASSIFIER_MODEL)")
        exit(1)
    }

    let eegData = try String(contentsOf: eegURL, encoding: .utf8)
    let labelsData = try String(contentsOf: labelsURL, encoding: .utf8)

    let eegRows = parseCSV(eegData)
    let labelRows = parseCSV(labelsData)

    guard eegRows.count > 1 else {
        print("Error: eeg.csv is empty")
        exit(1)
    }
    guard labelRows.count > 1 else {
        print("Error: labels.csv is empty")
        exit(1)
    }

    let eegHeader = eegRows[0]
    let channelCount = eegHeader.count - 1 // -1 for timestamp
    var samples: [[Float]] = Array(repeating: [], count: channelCount)

    // Parse EEG data
    for row in eegRows.dropFirst() {
        for ch in 0..<channelCount {
            let value = Float(row[ch + 1]) ?? 0.0
            samples[ch].append(value)
        }
    }

    print("Loading \(modelURL.lastPathComponent)...")
    let classifier: RealIntentClassifier
    do {
        classifier = try RealIntentClassifier(modelPackageURL: modelURL)
    } catch {
        print("Error: failed to load model at \(modelURL.path): \(error.localizedDescription)")
        exit(1)
    }
    let confusion = ConfusionMatrix()

    // Process windows and classify — 512-sample window, 256-sample stride, matching
    // both CalibrationRecorder's own windowing and Scripts/train-intent-classifier.py.
    var windowIndex = 0
    let windowCount = min(1000, samples[0].count / 256) // Limit to 1000 windows for speed
    let windowSize = 512

    for w in 0..<windowCount {
        let start = w * 256
        let end = min(start + windowSize, samples[0].count)
        if end - start < windowSize / 2 { break }

        var channelSamples: [[Float]] = []
        for ch in 0..<min(channelCount, 4) {
            channelSamples.append(Array(samples[ch][start..<end]))
        }

        let predicted: String
        do {
            predicted = try classifier.classify(channelSamples: channelSamples)
        } catch {
            print("Error: inference failed on window \(w): \(error.localizedDescription)")
            exit(1)
        }

        // Find actual label from labels.csv
        var actual = "none"
        for row in labelRows.dropFirst() {
            if row.count >= 5, let seq = Int(row[1]), seq == w {
                actual = row[4]
                break
            }
        }

        confusion.add(predicted: predicted, actual: actual)
        windowIndex += 1
    }

    print("Evaluating Calibration Session")
    print("==============================")
    if let sessionID = labelsData.split(separator: ",").dropFirst().first.map(String.init) {
        print("Session: \(sessionID)")
    }
    print("Model: \(modelURL.path)")
    print("Windows evaluated: \(windowIndex)")
    if confusion.unmatchedCount > 0 {
        print("  WARNING: \(confusion.unmatchedCount) window(s) had a predicted/actual label outside " +
              "the 5-class set (e.g. no matching labels.csv row) and were excluded from the matrix below " +
              "— accuracy is computed only over the remaining \(windowIndex - confusion.unmatchedCount).")
    }
    print("")
    print("Confusion Matrix (rows=predicted, cols=actual):")
    confusion.print()
}

// CLI handling
if CommandLine.argc < 2 {
    print("Usage: swift evaluate-calibration.swift --session <path> [--model <path>]")
    exit(1)
}

var sessionPath: String?
var modelPath: String?
var i = 1
while i < CommandLine.argc {
    switch CommandLine.arguments[i] {
    case "--session" where i + 1 < Int(CommandLine.argc):
        sessionPath = CommandLine.arguments[i + 1]
        i += 2
    case "--model" where i + 1 < Int(CommandLine.argc):
        modelPath = CommandLine.arguments[i + 1]
        i += 2
    default:
        i += 1
    }
}

guard let path = sessionPath else {
    print("Error: --session argument required")
    exit(1)
}

// Model resolution order: --model flag, then NEURALCOMPOSE_CLASSIFIER_MODEL (mirrors
// the app's own override for the same relative-path-resolution problem — a bare `swift`
// script's CWD isn't guaranteed to be the repo root), then Models/IntentClassifier.mlpackage
// next to this script's own location.
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let defaultModelURL = repoRoot.appendingPathComponent("Models/IntentClassifier.mlpackage")
let resolvedModelURL: URL
if let modelPath {
    resolvedModelURL = URL(fileURLWithPath: modelPath)
} else if let envPath = ProcessInfo.processInfo.environment["NEURALCOMPOSE_CLASSIFIER_MODEL"] {
    resolvedModelURL = URL(fileURLWithPath: envPath)
} else {
    resolvedModelURL = defaultModelURL
}

do {
    try evaluateSession(directory: path, modelURL: resolvedModelURL)
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
