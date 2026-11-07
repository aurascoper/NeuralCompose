import XCTest
import BCICore
import BCIEEG
@testable import BCIBiofeedback

/// Behavioural pins for the mapper: shaping, smoothing, rate limiting,
/// MIDI quantisation, note gates and, above all, the four health
/// policies. Every test drives frames by hand so the expected outputs
/// can be derived on paper.
final class FeatureMapperTests: XCTestCase {

    private let alphaTP9 = BiofeedbackFeature.bandAbsolute(.alpha, channel: .tp9)

    private func oscValues(_ outputs: [BiofeedbackOutput], address: String) -> [Float] {
        outputs.compactMap { output -> Float? in
            guard let message = output.oscMessage, message.address == address else { return nil }
            return message.floatArguments.first
        }
    }

    private func ccValues(_ outputs: [BiofeedbackOutput]) -> [UInt8] {
        outputs.compactMap { output -> UInt8? in
            if case .controlChange(_, _, let value)? = output.midiEvent { return value }
            return nil
        }
    }

    // MARK: - Shaping

    func testLinearNormalisationAndClamp() {
        // Alpha in Bels; 1 Bel = 10 µV², 2 Bels = 100 µV².
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/alpha"), inputLow: 1, inputHigh: 2)
        var mapper = FeatureMapper(mappings: [mapping])

        let mid = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: Float(pow(10.0, 1.5)))))
        XCTAssertEqual(oscValues(mid, address: "/nc/alpha").first ?? -1, 0.5, accuracy: 1e-5)

        let above = mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(oscValues(above, address: "/nc/alpha").first, 1, "clamped high")

        let below = mapper.step(TestFrames.frame(at: 2, tp9: TestFrames.powers(alpha: 0.001)))
        XCTAssertEqual(oscValues(below, address: "/nc/alpha").first, 0, "clamped low")
    }

    func testLog10CurveOnLinearRatio() {
        // theta/beta ratio from 0.1 to 10 on a log curve: ratio 1 is the midpoint.
        let feature = BiofeedbackFeature.bandRatio(numerator: .theta, denominator: .beta, channel: .tp9)
        let mapping = BiofeedbackMapping(feature: feature, target: .osc(address: "/nc/tb"), inputLow: 0.1, inputHigh: 10, curve: .log10)
        var mapper = FeatureMapper(mappings: [mapping])
        let out = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(beta: 20, theta: 20)))
        XCTAssertEqual(oscValues(out, address: "/nc/tb").first ?? -1, 0.5, accuracy: 1e-5)
    }

    func testInvertedRangeIsAllowed() {
        // inputLow > inputHigh flips the direction: more alpha, smaller output.
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/inv"), inputLow: 2, inputHigh: 1)
        var mapper = FeatureMapper(mappings: [mapping])
        let out = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(oscValues(out, address: "/nc/inv").first, 0, "4 Bels is past the inverted range, clamps to 0")
    }

    // MARK: - Smoothing

    func testExponentialSmoothingFollowsTimeConstant() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/s"), inputLow: 1, inputHigh: 2, smoothingTau: 1.0)
        var mapper = FeatureMapper(mappings: [mapping])
        // First frame seeds the smoother at 0 (alpha = 10 µV² = 1 Bel).
        _ = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10)))
        // Step to 1.0 (100 µV²) one time constant later: 1 - e^-1 of the way.
        let out = mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 100)))
        XCTAssertEqual(oscValues(out, address: "/nc/s").first ?? -1, 1 - Float(exp(-1.0)), accuracy: 1e-5)
    }

    func testZeroTauIsNoSmoothing() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/s"), inputLow: 1, inputHigh: 2, smoothingTau: 0)
        var mapper = FeatureMapper(mappings: [mapping])
        _ = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10)))
        let out = mapper.step(TestFrames.frame(at: 0.1, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(oscValues(out, address: "/nc/s").first, 1)
    }

    // MARK: - Rate limiting

    func testMinIntervalSuppressesIntermediateTicks() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/r"), inputLow: 1, inputHigh: 2, minInterval: 0.1)
        var mapper = FeatureMapper(mappings: [mapping])
        var emitted = 0
        for i in 0..<10 {
            let t = Double(i) * 0.025   // 40 Hz frames
            emitted += oscValues(mapper.step(TestFrames.frame(at: t, tp9: TestFrames.powers(alpha: 30))), address: "/nc/r").count
        }
        // t = 0, 0.1, 0.2 pass; 0.225 is the last frame.
        XCTAssertEqual(emitted, 3)
    }

    // MARK: - MIDI

    func testControlChangeQuantisesAndEmitsOnlyOnChange() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .midiControl(controller: 1, channel: 0, fourteenBit: false), inputLow: 1, inputHigh: 2)
        var mapper = FeatureMapper(mappings: [mapping])
        let first = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: Float(pow(10.0, 1.25)))))
        XCTAssertEqual(ccValues(first), [32], "0.25 * 127 = 31.75 rounds to 32")
        let same = mapper.step(TestFrames.frame(at: 0.1, tp9: TestFrames.powers(alpha: Float(pow(10.0, 1.25)))))
        XCTAssertTrue(same.isEmpty, "unchanged quantised value is not re-sent")
        let changed = mapper.step(TestFrames.frame(at: 0.2, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(ccValues(changed), [127])
    }

    func testFourteenBitControlEmitsPair() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .midiControl(controller: 1, channel: 0, fourteenBit: true), inputLow: 1, inputHigh: 2)
        var mapper = FeatureMapper(mappings: [mapping])
        let out = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(out.compactMap(\.midiEvent), [
            .controlChange(channel: 0, controller: 1, value: 127),
            .controlChange(channel: 0, controller: 33, value: 127),
        ])
    }

    func testNoteGateOpensOnBlinkAndClosesAfterGate() {
        let mapping = BiofeedbackMapping(feature: .blink, target: .midiNote(note: 60, channel: 0, velocity: 100, gate: 0.2), inputLow: 0, inputHigh: 1)
        var mapper = FeatureMapper(mappings: [mapping])

        XCTAssertTrue(mapper.step(TestFrames.frame(at: 0)).isEmpty, "no blink, nothing")
        XCTAssertEqual(mapper.step(TestFrames.frame(at: 0.1, blink: true)).compactMap(\.midiEvent), [.noteOn(channel: 0, note: 60, velocity: 100)])
        XCTAssertTrue(mapper.step(TestFrames.frame(at: 0.15, blink: true)).isEmpty, "already open")
        XCTAssertTrue(mapper.step(TestFrames.frame(at: 0.2, blink: true)).isEmpty, "held while blink persists and gate not expired")
        XCTAssertEqual(mapper.step(TestFrames.frame(at: 0.35, blink: true)).compactMap(\.midiEvent), [.noteOff(channel: 0, note: 60)], "gate expired")
    }

    func testNoteGateClosesWhenEventClearsEarly() {
        let mapping = BiofeedbackMapping(feature: .jawClench, target: .midiNote(note: 62, channel: 0, velocity: 100, gate: 5), inputLow: 0, inputHigh: 1)
        var mapper = FeatureMapper(mappings: [mapping])
        XCTAssertEqual(mapper.step(TestFrames.frame(at: 0, jawClench: true)).compactMap(\.midiEvent), [.noteOn(channel: 0, note: 62, velocity: 100)])
        XCTAssertEqual(mapper.step(TestFrames.frame(at: 0.1, jawClench: false)).compactMap(\.midiEvent), [.noteOff(channel: 0, note: 62)])
    }

    // MARK: - Health policies

    func testHoldLastKeepsLastHealthyValueWhileChannelIsDead() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/h"), inputLow: 1, inputHigh: 2, healthPolicy: .holdLast)
        var mapper = FeatureMapper(mappings: [mapping])
        _ = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: Float(pow(10.0, 1.5)))))
        // TP9 goes dead and its "power" collapses; output must not follow.
        let dead = mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 0.01), health: [.tp9: .dead, .af7: .healthy, .af8: .healthy, .tp10: .healthy]))
        XCTAssertEqual(oscValues(dead, address: "/nc/h").first ?? -1, 0.5, accuracy: 1e-5)
        // Recovery resumes tracking.
        let back = mapper.step(TestFrames.frame(at: 2, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(oscValues(back, address: "/nc/h").first, 1)
    }

    func testHoldLastEmitsNothingBeforeFirstHealthyValue() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/h"), inputLow: 1, inputHigh: 2, healthPolicy: .holdLast)
        var mapper = FeatureMapper(mappings: [mapping])
        let out = mapper.step(TestFrames.frame(at: 0, health: TestFrames.health(af7: .healthy).merging([.tp9: .unknown]) { $1 }))
        XCTAssertTrue(out.isEmpty)
    }

    func testPassthroughFollowsTheArtifact() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/p"), inputLow: 1, inputHigh: 2, healthPolicy: .passthrough)
        var mapper = FeatureMapper(mappings: [mapping])
        _ = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: Float(pow(10.0, 1.5)))))
        let dead = mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 0.01), health: [.tp9: .dead]))
        XCTAssertEqual(oscValues(dead, address: "/nc/p").first, 0, "Mind Monitor behaviour, by explicit choice")
    }

    func testMuteEmitsNothingAndClosesOpenGate() {
        let osc = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/m"), inputLow: 1, inputHigh: 2, healthPolicy: .mute)
        let note = BiofeedbackMapping(feature: alphaTP9, target: .midiNote(note: 64, channel: 0, velocity: 90, gate: 10), inputLow: 1, inputHigh: 2, healthPolicy: .mute)
        var mapper = FeatureMapper(mappings: [osc, note])
        let healthy = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(oscValues(healthy, address: "/nc/m").first, 1)
        XCTAssertEqual(healthy.compactMap(\.midiEvent), [.noteOn(channel: 0, note: 64, velocity: 90)])
        let saturated = mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 10_000), health: [.tp9: .saturated]))
        XCTAssertTrue(oscValues(saturated, address: "/nc/m").isEmpty)
        XCTAssertEqual(saturated.compactMap(\.midiEvent), [.noteOff(channel: 0, note: 64)])
    }

    func testDecayToRestGlidesWithTimeConstant() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/d"), inputLow: 1, inputHigh: 2, healthPolicy: .decayToRest(rest: 0, tau: 1))
        var mapper = FeatureMapper(mappings: [mapping])
        _ = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10_000)))   // value 1 (clamped)
        let dead: [EEGChannel: ChannelHealthStatus] = [.tp9: .dead]
        let t0 = mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 10_000), health: dead))
        XCTAssertEqual(oscValues(t0, address: "/nc/d").first ?? -1, 1, accuracy: 1e-6, "decay starts at the first unhealthy tick")
        let t1 = mapper.step(TestFrames.frame(at: 2, tp9: TestFrames.powers(alpha: 10_000), health: dead))
        XCTAssertEqual(oscValues(t1, address: "/nc/d").first ?? -1, Float(exp(-1.0)), accuracy: 1e-5)
        let t3 = mapper.step(TestFrames.frame(at: 4, tp9: TestFrames.powers(alpha: 10_000), health: dead))
        XCTAssertEqual(oscValues(t3, address: "/nc/d").first ?? -1, Float(exp(-3.0)), accuracy: 1e-5)
        // Recovery jumps back to tracking with no smoothing configured.
        let back = mapper.step(TestFrames.frame(at: 5, tp9: TestFrames.powers(alpha: 10_000)))
        XCTAssertEqual(oscValues(back, address: "/nc/d").first, 1)
    }

    func testStaleCountsAsUnhealthy() {
        let mapping = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/nc/st"), inputLow: 1, inputHigh: 2, healthPolicy: .holdLast)
        var mapper = FeatureMapper(mappings: [mapping])
        _ = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10_000)))
        let stale = mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 1), health: [.tp9: .stale]))
        XCTAssertEqual(oscValues(stale, address: "/nc/st").first, 1, "held")
    }

    // MARK: - Mapping set management and determinism

    func testReplaceMappingsKeepsStateForSurvivingIds() {
        let keep = BiofeedbackMapping(feature: alphaTP9, target: .midiControl(controller: 1, channel: 0, fourteenBit: false), inputLow: 1, inputHigh: 2)
        let drop = BiofeedbackMapping(feature: alphaTP9, target: .midiControl(controller: 2, channel: 0, fourteenBit: false), inputLow: 1, inputHigh: 2)
        var mapper = FeatureMapper(mappings: [keep, drop])
        XCTAssertEqual(ccValues(mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10_000)))), [127, 127])
        mapper.replaceMappings([keep])
        XCTAssertTrue(mapper.step(TestFrames.frame(at: 1, tp9: TestFrames.powers(alpha: 10_000))).isEmpty, "kept mapping remembers its last value")
        mapper.replaceMappings([keep, drop])
        XCTAssertEqual(ccValues(mapper.step(TestFrames.frame(at: 2, tp9: TestFrames.powers(alpha: 10_000)))), [127], "re-added mapping starts fresh")
    }

    func testOutputsAreOrderedByMappingThenByTarget() {
        let a = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/a"), inputLow: 1, inputHigh: 2)
        let b = BiofeedbackMapping(feature: .blink, target: .midiNote(note: 60, channel: 0, velocity: 100, gate: 1), inputLow: 0, inputHigh: 1)
        let c = BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/c"), inputLow: 1, inputHigh: 2)
        var mapper = FeatureMapper(mappings: [a, b, c])
        let out = mapper.step(TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 10_000), blink: true))
        XCTAssertEqual(out, [
            .osc(OSCMessage(address: "/a", arguments: [.float(1)])),
            .midi(.noteOn(channel: 0, note: 60, velocity: 100)),
            .osc(OSCMessage(address: "/c", arguments: [.float(1)])),
        ])
    }

    func testSameInputSequenceGivesIdenticalOutputs() {
        let mappings = [
            BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/a"), inputLow: 1, inputHigh: 2, smoothingTau: 0.5),
            BiofeedbackMapping(feature: .bandRelative(.beta, channel: nil), target: .midiControl(controller: 7, channel: 0, fourteenBit: true), inputLow: 0, inputHigh: 1, smoothingTau: 0.3),
        ]
        func run() -> [BiofeedbackOutput] {
            var mapper = FeatureMapper(mappings: mappings)
            var all: [BiofeedbackOutput] = []
            for i in 0..<50 {
                let t = Double(i) * 0.1
                let alpha = 10 + 90 * Float(0.5 + 0.5 * sin(t))
                let health: [EEGChannel: ChannelHealthStatus] = i % 7 == 0 ? [.tp9: .dead] : TestFrames.allHealthy
                all += mapper.step(TestFrames.frame(at: t, tp9: TestFrames.powers(alpha: alpha, beta: Float(i)), health: health))
            }
            return all
        }
        XCTAssertEqual(run(), run())
    }

    func testMappingIsCodableRoundTrip() throws {
        let mappings = [
            BiofeedbackMapping(feature: alphaTP9, target: .osc(address: "/a"), inputLow: 1, inputHigh: 2, curve: .linear, smoothingTau: 0.5, minInterval: 0.1, healthPolicy: .holdLast),
            BiofeedbackMapping(feature: .blink, target: .midiNote(note: 60, channel: 1, velocity: 100, gate: 0.2), inputLow: 0, inputHigh: 1, healthPolicy: .mute),
            BiofeedbackMapping(feature: .bandRatio(numerator: .theta, denominator: .beta, channel: nil), target: .midiControl(controller: 1, channel: 0, fourteenBit: true), inputLow: 0.1, inputHigh: 10, curve: .log10, healthPolicy: .decayToRest(rest: 0.5, tau: 2)),
        ]
        let decoded = try JSONDecoder().decode([BiofeedbackMapping].self, from: JSONEncoder().encode(mappings))
        XCTAssertEqual(decoded, mappings)
    }
}
