import XCTest
@testable import BCICore
@testable import BCIEEG
@testable import BCIClassifier

/// Regression test for the full offline pipeline — playback -> windowing ->
/// features -> classifier -> channel health — run against the project's
/// golden recording (see Recordings/golden/README.md).
///
/// This is deliberately NOT a live-hardware test. It exercises exactly the
/// deterministic stages: `PlaybackEEGStream` in `.normalized` timing (see
/// `PlaybackTiming`) resamples the recording onto an exact 256 Hz grid, so
/// the same recording produces the exact same sample sequence on every run
/// regardless of the original BLE acquisition's jitter. Everything
/// downstream of that (`EEGWindowing`, `FeatureExtractor`,
/// `MockIntentClassifier`, `EEGChannelHealthProvider`) is a pure function of
/// that sample sequence — no randomness, no wall-clock dependence.
///
/// The golden recording itself (raw EEG) is NOT committed to git — this
/// project is privacy-first and Recordings/ is deliberately gitignored (see
/// Scripts/record-golden.sh). Only the small derived `reference_pipeline.json`
/// artifact is committed. If the golden recording isn't present locally
/// (e.g. a fresh checkout, or CI without the fixture deliberately made
/// available), the test skips rather than fails.
///
/// To regenerate the reference after a deliberate DSP/classifier change:
///
///     NEURALCOMPOSE_REGENERATE_REFERENCE=1 swift test --filter GoldenRecordingRegressionTests
///
/// then inspect the diff on Tests/BCIEEGTests/Fixtures/reference_pipeline.json
/// and commit it if the change is expected.
@MainActor
final class GoldenRecordingRegressionTests: XCTestCase {

    // MARK: - Reference schema

    struct ChannelSummary: Codable, Equatable {
        let name: String
        let rms: Float
        let clipPercent: Float
        let healthStatus: String
    }

    struct WindowSpotCheck: Codable, Equatable {
        let label: String   // "first" / "middle" / "last"
        let sequence: UInt64
        let intent: String
        let confidence: Float
        let alphaEnergy: Float
        let betaEnergy: Float
        let emgEnergy: Float
    }

    /// Numeric 3D-workspace scene state at a fraction of the way through the
    /// recording — the Phase 3 "compare scene state, not screenshots" check.
    /// Node brightness/edge intensity are pure functions of the sample
    /// sequence and the most recent classifier prediction as of that point,
    /// both of which are themselves deterministic — see the class doc.
    struct SceneCheckpoint: Codable, Equatable {
        let label: String   // "25%" / "50%" / "75%" / "100%"
        let nodeBrightness: [String: Float]  // electrode id -> emission intensity
        let edgeIntensity: Float
        let edgeTintDescription: String      // quantized "r,g,b", stable for JSON diffing
    }

    struct PipelineReference: Codable, Equatable {
        let sampleRate: Double
        let sampleCount: Int
        let durationSeconds: Double
        let channels: [ChannelSummary]
        let windowCount: Int
        let intentCounts: [String: Int]
        let meanConfidence: Float
        let windowSpotChecks: [WindowSpotCheck]
        let sceneCheckpoints: [SceneCheckpoint]
    }

    // MARK: - Paths

    /// Walk up from this test file to the repo root (Tests/BCIEEGTests/<this file> -> repo root).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var referenceFileURL: URL {
        repoRoot.appendingPathComponent("Tests/BCIEEGTests/Fixtures/reference_pipeline.json")
    }

    /// Wrap an `AsyncStream<Element>` in an `AsyncThrowingStream`, matching
    /// the identical helper in `NeuralWorkspaceViewTests` / the production
    /// `NeuralWorkspaceRepresentable` adapter.
    private static func throwingStream<Element: Sendable>(
        from stream: AsyncStream<Element>
    ) -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream<Element, any Error> { continuation in
            let task = Task {
                for await element in stream {
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The golden recording is intentionally not committed (see class doc).
    /// Find the newest `*.eeg.csv` under Recordings/golden/, if any.
    private func findGoldenRecording() -> URL? {
        let dir = repoRoot.appendingPathComponent("Recordings/golden")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let csvs = files.filter { $0.pathExtension == "csv" && $0.lastPathComponent.contains(".eeg.") }
        return csvs.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    // MARK: - Test

    func testPipelineMatchesReferenceForGoldenRecording() async throws {
        guard let goldenPath = findGoldenRecording() else {
            throw XCTSkip("No golden recording under Recordings/golden/ — skipping (see Recordings/golden/README.md).")
        }

        let regenerate = ProcessInfo.processInfo.environment["NEURALCOMPOSE_REGENERATE_REFERENCE"] == "1"

        // Timing tolerance: the whole point of .instant pacing is that this
        // shouldn't take anywhere near the recording's real duration (~5min
        // for the golden recording). A generous ceiling catches a pacing
        // regression (e.g. someone flips .instant back to .realtime) without
        // being a flaky wall-clock-sensitive assertion on CI hardware.
        let start = DispatchTime.now()
        let reference = try await computePipelineReference(csvPath: goldenPath.path)
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertLessThan(
            elapsedSeconds, 30.0,
            "pipeline replay took \(elapsedSeconds)s — instant pacing should keep this well under real-time"
        )

        if regenerate {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(reference)
            try FileManager.default.createDirectory(
                at: referenceFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: referenceFileURL)
            throw XCTSkip("Regenerated \(referenceFileURL.path) — inspect the diff and commit if expected.")
        }

        guard let expectedData = try? Data(contentsOf: referenceFileURL) else {
            throw XCTSkip(
                "No committed reference at \(referenceFileURL.path). "
                + "Run with NEURALCOMPOSE_REGENERATE_REFERENCE=1 to generate it."
            )
        }
        let expected = try JSONDecoder().decode(PipelineReference.self, from: expectedData)

        // Structural / exact fields.
        XCTAssertEqual(reference.sampleRate, expected.sampleRate)
        XCTAssertEqual(reference.sampleCount, expected.sampleCount)
        XCTAssertEqual(reference.windowCount, expected.windowCount)
        XCTAssertEqual(reference.intentCounts, expected.intentCounts, "classifier intent distribution changed")
        XCTAssertEqual(reference.channels.map(\.name), expected.channels.map(\.name))
        XCTAssertEqual(reference.channels.map(\.healthStatus), expected.channels.map(\.healthStatus))

        // Numeric fields with small tolerances (deterministic pipeline, but
        // leave headroom for cross-platform float differences).
        XCTAssertEqual(reference.durationSeconds, expected.durationSeconds, accuracy: 0.01)
        XCTAssertEqual(reference.meanConfidence, expected.meanConfidence, accuracy: 0.01)
        for (r, e) in zip(reference.channels, expected.channels) {
            XCTAssertEqual(r.rms, e.rms, accuracy: max(0.5, e.rms * 0.02), "channel \(r.name) RMS drifted")
            XCTAssertEqual(r.clipPercent, e.clipPercent, accuracy: 0.5, "channel \(r.name) clip% drifted")
        }
        XCTAssertEqual(reference.windowSpotChecks.count, expected.windowSpotChecks.count)
        for (r, e) in zip(reference.windowSpotChecks, expected.windowSpotChecks) {
            XCTAssertEqual(r.label, e.label)
            XCTAssertEqual(r.intent, e.intent, "\(r.label) window intent changed")
            XCTAssertEqual(r.confidence, e.confidence, accuracy: 0.02, "\(r.label) window confidence drifted")
            XCTAssertEqual(r.alphaEnergy, e.alphaEnergy, accuracy: max(0.1, e.alphaEnergy * 0.05), "\(r.label) alpha drifted")
            XCTAssertEqual(r.betaEnergy, e.betaEnergy, accuracy: max(0.1, e.betaEnergy * 0.05), "\(r.label) beta drifted")
        }

        XCTAssertEqual(reference.sceneCheckpoints.count, expected.sceneCheckpoints.count)
        for (r, e) in zip(reference.sceneCheckpoints, expected.sceneCheckpoints) {
            XCTAssertEqual(r.label, e.label)
            XCTAssertEqual(r.edgeTintDescription, e.edgeTintDescription, "\(r.label) edge tint changed")
            XCTAssertEqual(r.edgeIntensity, e.edgeIntensity, accuracy: 0.05, "\(r.label) edge intensity drifted")
            for (id, expectedBrightness) in e.nodeBrightness {
                let actual = r.nodeBrightness[id] ?? -1
                XCTAssertEqual(actual, expectedBrightness, accuracy: 0.05, "\(r.label) \(id) brightness drifted")
            }
        }
    }

    // MARK: - Pipeline

    private func computePipelineReference(csvPath: String) async throws -> PipelineReference {
        let normalizedRate = 256.0
        let playback = PlaybackEEGStream(
            path: csvPath,
            timing: .normalized(sampleRate: normalizedRate),
            pacing: .instant
        )
        let playbackStream = try await playback.start()

        var samples: [EEGSample] = []
        for try await sample in playbackStream { samples.append(sample) }
        XCTAssertFalse(samples.isEmpty, "playback produced no samples")

        let channelCount = playback.channelCount
        let channelNames = ["TP9", "AF7", "AF8", "TP10"]

        // Windowing + features + classifier: strictly sequential, pure
        // functions of the sample sequence — the source of determinism.
        let windowing = EEGWindowing(config: EEGWindowingConfig(
            windowSeconds: 2.0, strideSeconds: 1.0,
            sampleRate: normalizedRate, channelCount: channelCount
        ))
        let classifier = MockIntentClassifier()

        var intentCounts: [String: Int] = [:]
        var confidenceSum: Float = 0
        var windowCount = 0
        var spotChecks: [(sequence: UInt64, prediction: IntentPrediction, features: EEGFeatures)] = []
        // Sample index (into `samples`) each window was produced at, paired
        // with its prediction — the "most recent prediction as of sample N"
        // lookup the 3D-workspace replay below needs.
        var windowRecords: [(sampleIndex: Int, prediction: IntentPrediction)] = []

        for (i, sample) in samples.enumerated() {
            guard let window = try await windowing.ingest(sample) else { continue }
            let features = FeatureExtractor.features(for: window)
            let prediction = try await classifier.classify(window: window)
            windowCount += 1
            confidenceSum += prediction.confidence
            intentCounts[String(describing: prediction.intent), default: 0] += 1
            spotChecks.append((window.sequence, prediction, features))
            windowRecords.append((sampleIndex: i, prediction: prediction))
        }
        XCTAssertFalse(spotChecks.isEmpty, "no windows were produced from the golden recording")

        // Channel health: feed the same resampled samples through the real
        // AsyncStream-based provider (matches production wiring), then wait
        // for the drain task to finish consuming before querying — same
        // pattern as EEGChannelHealthProviderTests.
        let (healthInputStream, continuation) = AsyncStream<EEGSample>.makeStream()
        let healthProvider = EEGChannelHealthProvider(
            stream: healthInputStream,
            channelCount: channelCount,
            channelLabels: channelNames,
            sampleRate: normalizedRate,
            ringSeconds: max(4.0, Double(samples.count) / normalizedRate)
        )
        for sample in samples { continuation.yield(sample) }
        continuation.finish()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let healthStates = await healthProvider.currentChannelHealth(
            windowSeconds: Double(samples.count) / normalizedRate
        )

        // Overall per-channel RMS / clipping directly from the resampled
        // signal (independent of the health provider's ring, for a
        // second, simpler numeric signal in the reference).
        var channelSummaries: [ChannelSummary] = []
        for ch in 0..<channelCount {
            var sumSq: Double = 0
            var clipped = 0
            for sample in samples {
                let v = sample.channels[ch]
                sumSq += Double(v) * Double(v)
                if abs(v) >= 999.0 { clipped += 1 }
            }
            let rms = Float((sumSq / Double(samples.count)).squareRoot())
            let clipPercent = Float(clipped) / Float(samples.count) * 100.0
            let name = ch < channelNames.count ? channelNames[ch] : "ch\(ch)"
            let status = healthStates.first { $0.channel.label == name }?.status
            channelSummaries.append(ChannelSummary(
                name: name, rms: rms, clipPercent: clipPercent,
                healthStatus: status.map(String.init(describing:)) ?? "unknown"
            ))
        }

        func spotCheck(_ label: String, _ entry: (sequence: UInt64, prediction: IntentPrediction, features: EEGFeatures)) -> WindowSpotCheck {
            WindowSpotCheck(
                label: label,
                sequence: entry.sequence,
                intent: String(describing: entry.prediction.intent),
                confidence: entry.prediction.confidence,
                alphaEnergy: entry.features.alphaEnergy,
                betaEnergy: entry.features.betaEnergy,
                emgEnergy: entry.features.emgEnergy
            )
        }
        let mid = spotChecks[spotChecks.count / 2]
        let windowSpotChecks = [
            spotCheck("first", spotChecks.first!),
            spotCheck("middle", mid),
            spotCheck("last", spotChecks.last!),
        ]

        let sceneCheckpoints = try await computeSceneCheckpoints(samples: samples, windowRecords: windowRecords)

        return PipelineReference(
            sampleRate: normalizedRate,
            sampleCount: samples.count,
            durationSeconds: samples.last!.timestamp - samples.first!.timestamp,
            channels: channelSummaries,
            windowCount: windowCount,
            intentCounts: intentCounts,
            meanConfidence: windowCount > 0 ? confidenceSum / Float(windowCount) : 0,
            windowSpotChecks: windowSpotChecks,
            sceneCheckpoints: sceneCheckpoints
        )
    }

    /// Replay `samples` through a real `NeuralWorkspaceView` and snapshot its
    /// node/edge material state at four points through the recording — the
    /// Phase 3 "compare numeric scene state, not screenshots" check. At each
    /// checkpoint, the workspace has ingested every sample up to that point
    /// (so its ring buffers reflect "as of here in the recording") and has
    /// been given the single most recent classifier prediction available by
    /// that point (matching what a live viewer would see).
    private func computeSceneCheckpoints(
        samples: [EEGSample],
        windowRecords: [(sampleIndex: Int, prediction: IntentPrediction)]
    ) async throws -> [GoldenRecordingRegressionTests.SceneCheckpoint] {
        let workspace = NeuralWorkspaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let checkpoints: [(label: String, fraction: Double)] = [
            ("25%", 0.25), ("50%", 0.50), ("75%", 0.75), ("100%", 1.0),
        ]

        var results: [SceneCheckpoint] = []
        var sampleCursor = 0
        var windowCursor = 0
        for (label, fraction) in checkpoints {
            let targetIndex = min(samples.count - 1, Int(Double(samples.count - 1) * fraction))
            while sampleCursor <= targetIndex {
                workspace.ingest(samples[sampleCursor])
                sampleCursor += 1
            }
            // Advance to the last window record at or before targetIndex,
            // and feed exactly that one prediction if it's new since the
            // last checkpoint.
            var latestForCheckpoint: IntentPrediction?
            while windowCursor < windowRecords.count, windowRecords[windowCursor].sampleIndex <= targetIndex {
                latestForCheckpoint = windowRecords[windowCursor].prediction
                windowCursor += 1
            }
            if let prediction = latestForCheckpoint {
                let (stream, continuation) = AsyncStream<IntentPrediction>.makeStream()
                workspace.subscribeClassifier(to: Self.throwingStream(from: stream))
                continuation.yield(prediction)
                continuation.finish()
                try? await Task.sleep(nanoseconds: 20_000_000) // let the drain task consume it
            }
            workspace.testableTriggerRecompute()

            var brightness: [String: Float] = [:]
            for id in ["TP9", "AF7", "AF8", "TP10"] {
                brightness[id] = workspace.testableEmissionIntensity(for: id) ?? -1
            }
            let edgeIntensity = workspace.testableEdgeEmissionIntensity() ?? -1
            let tint = workspace.testableEdgeTintColor()?.usingColorSpace(.deviceRGB)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            tint?.getRed(&r, green: &g, blue: &b, alpha: &a)
            let tintDescription = String(format: "%.2f,%.2f,%.2f", r, g, b)

            results.append(SceneCheckpoint(
                label: label, nodeBrightness: brightness,
                edgeIntensity: edgeIntensity, edgeTintDescription: tintDescription
            ))
        }
        return results
    }
}
