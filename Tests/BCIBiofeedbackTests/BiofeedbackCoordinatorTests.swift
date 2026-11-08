import XCTest
import BCICore
import BCIEEG
@testable import BCIBiofeedback

/// Drives the coordinator with hand-built windows, intents and IMU samples
/// through a `RecordingBiofeedbackSink` and asserts on what reached the
/// sink. No networking, no CoreMIDI.
final class BiofeedbackCoordinatorTests: XCTestCase {

    private let sampleRate = 256.0

    private func sinusoid(hz: Double, amplitude: Float, offset: Float = 800, count: Int = 256) -> [Float] {
        (0..<count).map { i in
            offset + amplitude * Float(sin(2.0 * Double.pi * hz * Double(i) / sampleRate))
        }
    }

    /// TP9 carries a 20 µV alpha sinusoid, the other three rows are flat
    /// (RMS 0, so `.dead` under the default thresholds).
    private func alphaOnTP9Window(at t: TimeInterval = 1, sequence: UInt64 = 0) -> EEGWindow {
        EEGWindow(
            samples: [
                sinusoid(hz: 10, amplitude: 20),
                [Float](repeating: 800, count: 256),
                [Float](repeating: 800, count: 256),
                [Float](repeating: 800, count: 256),
            ],
            sampleRate: sampleRate,
            endTimestamp: t,
            sequence: sequence
        )
    }

    private func address(_ outputs: [BiofeedbackOutput], _ address: String) -> [OSCMessage] {
        outputs.compactMap(\.oscMessage).filter { $0.address == address }
    }

    // MARK: - channelHealth

    func testChannelHealthFromRawWindow() {
        let window = EEGWindow(
            samples: [
                sinusoid(hz: 10, amplitude: 20),          // RMS ~14 µV: healthy
                [Float](repeating: 800, count: 256),      // RMS 0: dead
                sinusoid(hz: 10, amplitude: 400),         // RMS ~283 µV: saturated
                [1, Float.nan, 3] + [Float](repeating: 0, count: 253),   // non-finite: unknown
            ],
            sampleRate: sampleRate, endTimestamp: 2.5, sequence: 1
        )
        let states = BiofeedbackCoordinator.channelHealth(for: window)
        XCTAssertEqual(states.map(\.channel), EEGChannel.allCases)
        XCTAssertEqual(states.map(\.status), [.healthy, .dead, .saturated, .unknown])
        XCTAssertEqual(states[0].rms, 20 / Float(2).squareRoot(), accuracy: 0.2)
        XCTAssertEqual(states[3].rms, 0)
        XCTAssertTrue(states.allSatisfy { $0.timestamp == 2.5 && $0.samples == 256 })
    }

    func testChannelHealthIgnoresRowsBeyondChannelList() {
        let window = EEGWindow(samples: [sinusoid(hz: 10, amplitude: 20)], sampleRate: sampleRate, endTimestamp: 0, sequence: 0)
        XCTAssertEqual(BiofeedbackCoordinator.channelHealth(for: window).map(\.channel), [.tp9])
    }

    // MARK: - Window ticks

    func testWindowTickEmitsMirrorWithHealthAndPowers() async {
        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(sink: sink, options: .init(mirror: MindMonitorMirror(perChannel: true)))
        await coordinator.ingest(window: alphaOnTP9Window())
        let outputs = await sink.outputs

        let horseshoe = address(outputs, "/muse/elements/horseshoe").first?.floatArguments
        XCTAssertEqual(horseshoe, [1, 4, 4, 4], "TP9 healthy, three flat channels dead")

        let alpha = address(outputs, "/muse/elements/alpha_absolute").first?.floatArguments ?? []
        XCTAssertEqual(alpha.count, 4)
        XCTAssertEqual(alpha[0], log10(200), accuracy: 0.02, "A²/2 = 200 µV² on TP9")
        XCTAssertLessThan(alpha[1], -5, "flat channel sits at the power floor")

        XCTAssertTrue(address(outputs, "/muse/elements/blink").isEmpty, "window ticks never carry events")
        XCTAssertTrue(address(outputs, "/muse/eeg").isEmpty, "raw EEG is not derivable from a window")
        let count = await coordinator.windowCount
        XCTAssertEqual(count, 1)
    }

    func testProvidedHealthOverridesRawEstimate() async {
        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(sink: sink)
        let stale = EEGChannel.allCases.map { ChannelHealthState(channel: $0, status: .stale, rms: 10, samples: 256, timestamp: 1) }
        await coordinator.ingest(window: alphaOnTP9Window(), health: stale)
        let outputs = await sink.outputs
        XCTAssertEqual(address(outputs, "/muse/elements/horseshoe").first?.floatArguments, [4, 4, 4, 4])
    }

    func testContinuousMappingRunsOnWindowsOnly() async {
        let sink = RecordingBiofeedbackSink()
        let mappings = [
            BiofeedbackMapping(feature: .bandAbsolute(.alpha, channel: .tp9), target: .osc(address: "/nc/alpha"), inputLow: 1, inputHigh: 3),
            BiofeedbackMapping(feature: .blink, target: .midiNote(note: 60, channel: 0, velocity: 100, gate: 0.5), inputLow: 0, inputHigh: 1),
        ]
        let coordinator = BiofeedbackCoordinator(sink: sink, mappings: mappings, options: .init(mirror: nil))
        await coordinator.ingest(window: alphaOnTP9Window())
        let outputs = await sink.outputs
        let alpha = address(outputs, "/nc/alpha").first?.floatArguments.first
        XCTAssertEqual(alpha ?? -1, (log10(Float(200)) - 1) / 2, accuracy: 0.01)
        XCTAssertTrue(outputs.compactMap(\.midiEvent).isEmpty, "event mapping does not fire on a window tick")
        let all = await coordinator.mappings
        XCTAssertEqual(all.count, 2)
    }

    func testMirrorDisabledEmitsOnlyMappings() async {
        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(sink: sink, options: .init(mirror: nil))
        await coordinator.ingest(window: alphaOnTP9Window())
        let outputs = await sink.outputs
        XCTAssertTrue(outputs.isEmpty, "no mirror, no mappings, nothing emitted")
    }

    // MARK: - Intent ticks

    func testBlinkIntentEmitsEventMessageAndNoteGate() async {
        let sink = RecordingBiofeedbackSink()
        let note = BiofeedbackMapping(feature: .blink, target: .midiNote(note: 60, channel: 0, velocity: 100, gate: 0.5), inputLow: 0, inputHigh: 1)
        let coordinator = BiofeedbackCoordinator(sink: sink, mappings: [note])
        await coordinator.ingest(window: alphaOnTP9Window(at: 1))
        await sink.clear()

        await coordinator.note(intent: .singleBlink, at: 1.05)
        var outputs = await sink.outputs
        XCTAssertEqual(address(outputs, "/muse/elements/blink").first?.arguments, [OSCArgument.int32(1)])
        XCTAssertTrue(address(outputs, "/muse/elements/alpha_absolute").isEmpty, "event tick does not re-send bands")
        XCTAssertEqual(outputs.compactMap(\.midiEvent), [.noteOn(channel: 0, note: 60, velocity: 100)])
        await sink.clear()

        await coordinator.note(intent: .rest, at: 1.1)
        outputs = await sink.outputs
        XCTAssertTrue(address(outputs, "/muse/elements/blink").isEmpty)
        XCTAssertEqual(outputs.compactMap(\.midiEvent), [.noteOff(channel: 0, note: 60)], "rest closes the gate")
        let events = await coordinator.eventCount
        XCTAssertEqual(events, 1)
    }

    func testJawClenchAndSelectSemantics() async {
        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(sink: sink)
        await coordinator.note(intent: .jawClench, at: 0.5)
        var outputs = await sink.outputs
        XCTAssertEqual(address(outputs, "/muse/elements/jaw_clench").count, 1)
        XCTAssertTrue(address(outputs, "/muse/elements/blink").isEmpty)
        await sink.clear()

        await coordinator.note(intent: .select, at: 0.6)
        outputs = await sink.outputs
        XCTAssertTrue(outputs.isEmpty, "select is a composed FSM state, not a physiological event")
    }

    func testIntentBeforeAnyWindowStillEmitsEvents() async {
        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(sink: sink)
        await coordinator.note(intent: .doubleBlink, at: 0.1)
        let outputs = await sink.outputs
        XCTAssertEqual(address(outputs, "/muse/elements/blink").count, 1)
    }

    // MARK: - IMU and raw EEG

    func testMovementIsCachedIntoNextWindowFrame() async {
        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(sink: sink)
        await coordinator.ingest(movement: MovementSample(timestamp: 0.9, kind: .accel, x: 0.1, y: 0.2, z: 0.97))
        await coordinator.ingest(movement: MovementSample(timestamp: 0.95, kind: .gyro, x: -1, y: 2, z: -3))
        await coordinator.ingest(window: alphaOnTP9Window(at: 1))
        let outputs = await sink.outputs
        XCTAssertEqual(address(outputs, "/muse/acc").first?.floatArguments, [0.1, 0.2, 0.97])
        XCTAssertEqual(address(outputs, "/muse/gyro").first?.floatArguments, [-1, 2, -3])
    }

    func testRawEEGIsForwardedOnlyWhenEnabled() async {
        let sample = EEGSample(timestamp: 0.5, channels: [801, 802, 803, 804])

        let off = RecordingBiofeedbackSink()
        let disabled = BiofeedbackCoordinator(sink: off, options: .init(includeRawEEG: false))
        XCTAssertFalse(disabled.includesRawEEG)
        await disabled.ingest(sample: sample)
        let offOutputs = await off.outputs
        XCTAssertTrue(offOutputs.isEmpty)

        let on = RecordingBiofeedbackSink()
        let enabled = BiofeedbackCoordinator(sink: on, options: .init(includeRawEEG: true))
        XCTAssertTrue(enabled.includesRawEEG)
        await enabled.ingest(sample: sample)
        let onOutputs = await on.outputs
        XCTAssertEqual(address(onOutputs, "/muse/eeg").first?.floatArguments, [801, 802, 803, 804])
    }

    // MARK: - Mapping management

    func testReplaceMappingsResplitsByFeature() async {
        let sink = RecordingBiofeedbackSink()
        let coordinator = BiofeedbackCoordinator(sink: sink, options: .init(mirror: nil))
        let cc = BiofeedbackMapping(feature: .bandRelative(.alpha, channel: nil), target: .midiControl(controller: 1, channel: 0, fourteenBit: false), inputLow: 0, inputHigh: 1)
        let gate = BiofeedbackMapping(feature: .jawClench, target: .midiNote(note: 62, channel: 0, velocity: 90, gate: 1), inputLow: 0, inputHigh: 1)
        await coordinator.replaceMappings([cc, gate])

        await coordinator.ingest(window: alphaOnTP9Window(at: 1))
        var outputs = await sink.outputs
        XCTAssertEqual(outputs.count, 1)
        if case .midi(.controlChange(let channel, let controller, _))? = outputs.first {
            XCTAssertEqual(channel, 0)
            XCTAssertEqual(controller, 1)
        } else {
            XCTFail("expected a control change, got \(outputs)")
        }
        await sink.clear()

        await coordinator.note(intent: .jawClench, at: 1.05)
        outputs = await sink.outputs
        XCTAssertEqual(outputs.compactMap(\.midiEvent), [.noteOn(channel: 0, note: 62, velocity: 90)])
    }
}
