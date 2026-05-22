#!/usr/bin/env swift

import Foundation

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

// Confusion matrix
class ConfusionMatrix {
    let labels: [String] = ["rest", "blink", "double_blink", "jaw_clench", "select", "artifact", "none"]
    var matrix: [[Int]] = Array(repeating: Array(repeating: 0, count: 7), count: 7)

    func add(predicted: String, actual: String) {
        guard let predIdx = labels.firstIndex(of: predicted),
              let actualIdx = labels.firstIndex(of: actual) else { return }
        matrix[predIdx][actualIdx] += 1
    }

    func print() {
        let colWidth = 10
        let header = "                 " + labels.map { String(format: "%\(colWidth)s", $0) }.joined()
        Swift.print(header)

        for (i, predLabel) in labels.enumerated() {
            let row = String(format: "%16s", predLabel)
            let counts = matrix[i].map { String(format: "%\(colWidth)d", $0) }.joined()
            Swift.print(row + " " + counts)
        }

        Swift.print("\nPer-class Accuracy:")
        for (i, label) in labels.enumerated() {
            let correct = matrix[i][i]
            let total = matrix[i].reduce(0, +)
            let accuracy = total > 0 ? Double(correct) * 100.0 / Double(total) : 0.0
            Swift.print(String(format: "%9s: %5.1f%% (%d/%d)", label, accuracy, correct, total))
        }

        let totalCorrect = (0..<labels.count).map { matrix[$0][$0] }.reduce(0, +)
        let totalCount = matrix.flatMap { $0 }.reduce(0, +)
        let overall = totalCount > 0 ? Double(totalCorrect) * 100.0 / Double(totalCount) : 0.0
        Swift.print(String(format: "\nOverall Accuracy: %.1f%%", overall))
    }
}

// Mock classifier for testing
class MockIntentClassifier {
    func classify(samples: [Float]) -> String {
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        if rms < 1.0 { return "none" }
        if rms < 5.0 { return "rest" }
        if rms < 15.0 { return "blink" }
        if rms < 25.0 { return "jaw_clench" }
        return "artifact"
    }
}

// Main evaluation
func evaluateSession(directory: String) throws {
    let dirURL = URL(fileURLWithPath: directory)
    let labelsURL = dirURL.appendingPathComponent("labels.csv")
    let eegURL = dirURL.appendingPathComponent("eeg.csv")

    guard FileManager.default.fileExists(atPath: labelsURL.path),
          FileManager.default.fileExists(atPath: eegURL.path) else {
        print("Error: labels.csv or eeg.csv not found in \(directory)")
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
        let timestamp = Double(row[0]) ?? 0.0
        for ch in 0..<channelCount {
            let value = Float(row[ch + 1]) ?? 0.0
            samples[ch].append(value)
        }
    }

    let classifier = MockIntentClassifier()
    let confusion = ConfusionMatrix()

    // Process windows and classify
    var windowIndex = 0
    let windowCount = min(1000, samples[0].count / 256) // Limit to 1000 windows for speed
    let windowSize = 512

    for w in 0..<windowCount {
        let start = w * 256
        let end = min(start + windowSize, samples[0].count)
        if end - start < windowSize / 2 { break }

        var windowSamples: [Float] = []
        for ch in 0..<min(channelCount, 4) {
            windowSamples.append(contentsOf: samples[ch][start..<end])
        }

        let predicted = classifier.classify(samples: windowSamples)

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
    print("Windows evaluated: \(windowIndex)\n")
    print("Confusion Matrix (rows=predicted, cols=actual):")
    confusion.print()
}

// CLI handling
if CommandLine.argc < 2 {
    print("Usage: swift evaluate-calibration.swift --session <path>")
    exit(1)
}

var sessionPath: String?
var i = 1
while i < CommandLine.argc {
    if CommandLine.arguments[i] == "--session" && i + 1 < CommandLine.argc {
        sessionPath = CommandLine.arguments[i + 1]
        i += 2
    } else {
        i += 1
    }
}

guard let path = sessionPath else {
    print("Error: --session argument required")
    exit(1)
}

do {
    try evaluateSession(directory: path)
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
