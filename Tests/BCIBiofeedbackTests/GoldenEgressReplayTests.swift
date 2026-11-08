import XCTest
import BCICore
import BCIEEG
@testable import BCIBiofeedback

/// Replays the golden recording through the egress exactly as the app
/// would drive it (PlaybackEEGStream in `.normalized` timing, 2 s windows
/// at 1 s stride, `BiofeedbackCoordinator` with the Mind Monitor mirror
/// and a fixed mapping set) and pins what came out.
///
/// Two layers of pinning. Hard-coded pins in this file record the
/// structural facts and three spot windows that were measured when the
/// egress was first run against the recording (2026-11-07, M4, Swift 6.0);
/// they fail loudly if the estimator or the health thresholds move. The
/// committed fixture `Fixtures/golden_egress_v1.json` records every window
/// and is compared with tolerances, the same discipline as
/// `GoldenRecordingRegressionTests` (ADR-002, Principle 3): deterministic
/// replay before live validation.
///
/// Raw EEG is never written: the fixture holds Bels, health codes and the
/// OSC/MIDI the mapper produced. If the recording is absent the test skips.
///
/// Regenerate after a deliberate change:
///
///     NEURALCOMPOSE_REGENERATE_REFERENCE=1 swift test --filter GoldenEgressReplayTests
final class GoldenEgressReplayTests: XCTestCase {

    // MARK: - Fixture schema

    struct WindowRecord: Codable, Equatable {
        let sequence: UInt64
        let timestamp: Double
        /// Mind Monitor horseshoe codes in TP9, AF7, AF8, TP10 order.
        let horseshoe: [Float]
        /// Channel label to [delta, theta, alpha, beta, gamma] in Bels,
        /// rounded to 4 decimals.
        let bels: [String: [Float]]
        /// Mapper OSC outputs, address to float arguments, rounded.
        let osc: [String: [Float]]
        /// Mapper MIDI outputs as classic status/data1/data2 bytes.
        let midi: [[UInt8]]
    }

    struct EgressReference: Codable, Equatable {
        let version: Int
        let recording: String
        let sampleRate: Double
        let sampleCount: Int
        let durationSeconds: Double
        let windowSeconds: Double
        let strideSeconds: Double
        let windowCount: Int
        let mirrorPerChannel: Bool
        let mappings: [BiofeedbackMapping]
        /// Channel label to status raw value to window count.
        let healthCounts: [String: [String: Int]]
        let windows: [WindowRecord]
    }

    // MARK: - Fixed mapping set

    /// Stable ids so the fixture's `mappings` array is byte-stable across
    /// regenerations.
    static let mappings: [BiofeedbackMapping] = [
        BiofeedbackMapping(
            id: UUID(uuidString: "0B10FEED-0000-4000-8000-000000000001")!,
            feature: .bandAbsolute(.alpha, channel: .tp9),
            target: .osc(address: "/nc/alpha_tp9"),
            inputLow: 0, inputHigh: 3, smoothingTau: 0.5, healthPolicy: .holdLast
        ),
        BiofeedbackMapping(
            id: UUID(uuidString: "0B10FEED-0000-4000-8000-000000000002")!,
            feature: .bandRatio(numerator: .theta, denominator: .beta, channel: nil),
            target: .midiControl(controller: 1, channel: 0, fourteenBit: false),
            inputLow: 0.1, inputHigh: 10, curve: .log10, smoothingTau: 1.0, healthPolicy: .decayToRest(rest: 0.5, tau: 2)
        ),
        BiofeedbackMapping(
            id: UUID(uuidString: "0B10FEED-0000-4000-8000-000000000003")!,
            feature: .bandRelative(.alpha, channel: nil),
            target: .midiControl(controller: 7, channel: 0, fourteenBit: true),
            inputLow: 0, inputHigh: 1, smoothingTau: 0.3, healthPolicy: .mute
        ),
        BiofeedbackMapping(
            id: UUID(uuidString: "0B10FEED-0000-4000-8000-000000000004")!,
            feature: .channelQuality(.af7),
            target: .osc(address: "/nc/quality_af7"),
            inputLow: 0, inputHigh: 1, healthPolicy: .passthrough
        ),
    ]

    // MARK: - Hard pins (measured 2026-11-07 on the M4, Swift 6.0)

    /// Per-channel `BiofeedbackCoordinator.channelHealth` tallies over the
    /// 303 windows, reflecting the electrode-lift segments in the golden
    /// protocol.
    static let expectedHealthCounts: [EEGChannel: (healthy: Int, saturated: Int)] = [
        .tp9: (263, 40), .af7: (283, 20), .af8: (276, 27), .tp10: (280, 23),
    ]

    struct SpotPin {
        let sequence: UInt64
        let status: [ChannelHealthStatus]
        let rms: [Float]
        let alphaBels: [Float]
    }

    static let spotPins: [SpotPin] = [
        SpotPin(sequence: 0,
                status: [.healthy, .healthy, .healthy, .healthy],
                rms: [10.218, 145.106, 16.396, 19.931],
                alphaBels: [0.8000, 1.1127, 0.9060, 1.4781]),
        SpotPin(sequence: 151,
                status: [.healthy, .healthy, .healthy, .healthy],
                rms: [51.690, 78.681, 14.693, 60.175],
                alphaBels: [2.2308, 2.1196, 0.4415, 2.3850]),
        SpotPin(sequence: 302,
                status: [.healthy, .saturated, .healthy, .healthy],
                rms: [95.360, 677.181, 15.174, 43.829],
                alphaBels: [1.8229, 2.4503, -0.0162, 0.6969]),
    ]

    static let expectedWindowCount = 303
    static let expectedSampleCount = 77_966
    static let expectedDurationSeconds = 304.55078125

    // MARK: - Paths

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var referenceFileURL: URL {
        repoRoot.appendingPathComponent("Tests/BCIBiofeedbackTests/Fixtures/golden_egress_v1.json")
    }

    private func findGoldenRecording() -> URL? {
        let dir = repoRoot.appendingPathComponent("Recordings/golden")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let csvs = files.filter { $0.pathExtension == "csv" && $0.lastPathComponent.contains(".eeg.") }
        return csvs.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    // MARK: - Test

    func testEgressMatchesReferenceForGoldenRecording() async throws {
        guard let golden = findGoldenRecording() else {
            throw XCTSkip("No golden recording under Recordings/golden/; skipping (see Recordings/golden/README.md).")
        }
        let regenerate = ProcessInfo.processInfo.environment["NEURALCOMPOSE_REGENERATE_REFERENCE"] == "1"

        let start = DispatchTime.now()
        let (reference, rmsBySequence) = try await replay(csvPath: golden.path, recordingName: golden.lastPathComponent)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertLessThan(elapsed, 30, "egress replay took \(elapsed)s; instant pacing should keep this well under real time")

        // Hard pins first, so a drift is named even when no fixture exists.
        if golden.lastPathComponent.hasPrefix("golden_20260710-141352") {
            XCTAssertEqual(reference.windowCount, Self.expectedWindowCount)
            XCTAssertEqual(reference.sampleCount, Self.expectedSampleCount)
            XCTAssertEqual(reference.durationSeconds, Self.expectedDurationSeconds, accuracy: 0.01)
            for (channel, expected) in Self.expectedHealthCounts {
                let counts = reference.healthCounts[channel.label] ?? [:]
                XCTAssertEqual(counts[ChannelHealthStatus.healthy.rawValue] ?? 0, expected.healthy, "\(channel.label) healthy windows")
                XCTAssertEqual(counts[ChannelHealthStatus.saturated.rawValue] ?? 0, expected.saturated, "\(channel.label) saturated windows")
                XCTAssertEqual(counts[ChannelHealthStatus.dead.rawValue] ?? 0, 0, "\(channel.label) should never read dead in the golden recording")
            }
            for pin in Self.spotPins {
                guard let record = reference.windows.first(where: { $0.sequence == pin.sequence }) else {
                    XCTFail("window \(pin.sequence) missing from replay")
                    continue
                }
                let horseshoe = pin.status.map(MindMonitorMirror.horseshoe)
                XCTAssertEqual(record.horseshoe, horseshoe, "window \(pin.sequence) health")
                for (index, channel) in EEGChannel.allCases.enumerated() {
                    let alpha = record.bels[channel.label]?[2] ?? -99
                    XCTAssertEqual(alpha, pin.alphaBels[index], accuracy: 0.01, "window \(pin.sequence) \(channel.label) alpha Bels")
                    let rms = rmsBySequence[pin.sequence]?[index] ?? -1
                    XCTAssertEqual(rms, pin.rms[index], accuracy: max(0.05, pin.rms[index] * 0.002), "window \(pin.sequence) \(channel.label) RMS")
                }
            }
        }

        if regenerate {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(at: referenceFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(reference).write(to: referenceFileURL)
            throw XCTSkip("Regenerated \(referenceFileURL.path); inspect the diff and commit if expected.")
        }

        guard let expectedData = try? Data(contentsOf: referenceFileURL) else {
            throw XCTSkip("No committed reference at \(referenceFileURL.path). Run with NEURALCOMPOSE_REGENERATE_REFERENCE=1 to generate it.")
        }
        let expected = try JSONDecoder().decode(EgressReference.self, from: expectedData)

        XCTAssertEqual(reference.version, expected.version)
        XCTAssertEqual(reference.recording, expected.recording, "fixture was generated from a different recording")
        XCTAssertEqual(reference.sampleCount, expected.sampleCount)
        XCTAssertEqual(reference.windowCount, expected.windowCount)
        XCTAssertEqual(reference.mappings, expected.mappings, "mapping set changed; regenerate deliberately")
        XCTAssertEqual(reference.healthCounts, expected.healthCounts, "per-channel health tallies changed")
        XCTAssertEqual(reference.durationSeconds, expected.durationSeconds, accuracy: 0.01)
        XCTAssertEqual(reference.windows.count, expected.windows.count)

        for (actual, stored) in zip(reference.windows, expected.windows) {
            XCTAssertEqual(actual.sequence, stored.sequence)
            XCTAssertEqual(actual.horseshoe, stored.horseshoe, "window \(actual.sequence) horseshoe")
            XCTAssertEqual(actual.midi, stored.midi, "window \(actual.sequence) MIDI")
            XCTAssertEqual(Set(actual.osc.keys), Set(stored.osc.keys), "window \(actual.sequence) OSC addresses")
            for (address, values) in stored.osc {
                let got = actual.osc[address] ?? []
                XCTAssertEqual(got.count, values.count, "window \(actual.sequence) \(address) arity")
                for (g, v) in zip(got, values) {
                    XCTAssertEqual(g, v, accuracy: 2e-3, "window \(actual.sequence) \(address)")
                }
            }
            for (label, values) in stored.bels {
                let got = actual.bels[label] ?? []
                XCTAssertEqual(got.count, values.count)
                for (g, v) in zip(got, values) {
                    XCTAssertEqual(g, v, accuracy: 1e-3, "window \(actual.sequence) \(label) Bels")
                }
            }
        }
    }

    // MARK: - Replay

    /// Runs the recording through the coordinator and collects one record
    /// per window plus the demeaned RMS per channel (for the spot pins).
    private func replay(csvPath: String, recordingName: String) async throws -> (EgressReference, [UInt64: [Float]]) {
        let sampleRate = 256.0
        let windowSeconds = 2.0
        let strideSeconds = 1.0

        let playback = PlaybackEEGStream(path: csvPath, timing: .normalized(sampleRate: sampleRate), pacing: .instant)
        let stream = try await playback.start()
        var samples: [EEGSample] = []
        for try await sample in stream { samples.append(sample) }
        XCTAssertFalse(samples.isEmpty, "playback produced no samples")

        let windowing = EEGWindowing(config: EEGWindowingConfig(
            windowSeconds: windowSeconds, strideSeconds: strideSeconds,
            sampleRate: sampleRate, channelCount: playback.channelCount
        ))

        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(
            sink: sink,
            mappings: Self.mappings,
            options: .init(mirror: MindMonitorMirror(perChannel: true))
        )

        var records: [WindowRecord] = []
        var rmsBySequence: [UInt64: [Float]] = [:]
        var healthCounts: [String: [String: Int]] = [:]

        for sample in samples {
            guard let window = try await windowing.ingest(sample) else { continue }

            let health = BiofeedbackCoordinator.channelHealth(for: window)
            for state in health {
                healthCounts[state.channel.label, default: [:]][state.status.rawValue, default: 0] += 1
            }
            rmsBySequence[window.sequence] = health.map(\.rms)

            await sink.clear()
            await coordinator.ingest(window: window)
            let outputs = await sink.outputs
            records.append(Self.record(for: window, outputs: outputs))
        }

        let reference = EgressReference(
            version: 1,
            recording: recordingName,
            sampleRate: sampleRate,
            sampleCount: samples.count,
            // Span from first to last resampled timestamp, i.e. (n - 1) / fs
            // on the normalized grid; this is the figure the pins record.
            durationSeconds: (samples.last?.timestamp ?? 0) - (samples.first?.timestamp ?? 0),
            windowSeconds: windowSeconds,
            strideSeconds: strideSeconds,
            windowCount: records.count,
            mirrorPerChannel: true,
            mappings: Self.mappings,
            healthCounts: healthCounts,
            windows: records
        )
        return (reference, rmsBySequence)
    }

    private static func record(for window: EEGWindow, outputs: [BiofeedbackOutput]) -> WindowRecord {
        var horseshoe: [Float] = []
        var bels: [String: [Float]] = [:]
        var osc: [String: [Float]] = [:]
        var midi: [[UInt8]] = []

        // Mirror band messages arrive in EEGBand.allCases order with four
        // floats each (perChannel), so transpose into per-channel vectors.
        var perBand: [EEGBand: [Float]] = [:]
        for output in outputs {
            switch output {
            case .midi(let event):
                midi.append(event.bytes)
            case .osc(let message):
                if message.address == MindMonitorMirror.horseshoeAddress {
                    horseshoe = message.floatArguments
                } else if let band = EEGBand.allCases.first(where: { $0.mindMonitorAbsoluteAddress == message.address }) {
                    perBand[band] = message.floatArguments
                } else if message.address.hasPrefix("/nc/") {
                    osc[message.address] = message.floatArguments.map(round4)
                }
            }
        }
        for (index, channel) in MindMonitorMirror.channelOrder.enumerated() {
            bels[channel.label] = EEGBand.allCases.map { band in
                round4(perBand[band]?[index] ?? BandPowers.bels(0))
            }
        }
        return WindowRecord(sequence: window.sequence, timestamp: window.endTimestamp, horseshoe: horseshoe, bels: bels, osc: osc, midi: midi)
    }

    private static func round4(_ value: Float) -> Float {
        (value * 10_000).rounded() / 10_000
    }
}
