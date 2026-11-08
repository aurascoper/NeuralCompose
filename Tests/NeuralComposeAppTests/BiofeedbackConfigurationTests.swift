import XCTest
import BCIBiofeedback
@testable import NeuralComposeApp

final class BiofeedbackConfigurationTests: XCTestCase {

    func testAbsentEnvironmentIsDisabled() {
        let configuration = BiofeedbackConfiguration.resolve(environment: [:])
        XCTAssertEqual(configuration, .disabled)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.tier, .off)
        XCTAssertEqual(configuration.badgeLabel, "")
        XCTAssertTrue(configuration.statusLines.isEmpty)
    }

    func testOSCFlagDefaultsToLoopback7000() {
        for value in ["1", "true", "loopback", " on "] {
            let configuration = BiofeedbackConfiguration.resolve(environment: ["NEURALCOMPOSE_BIOFEEDBACK_OSC": value])
            XCTAssertEqual(configuration.osc, BiofeedbackConfiguration.OSC(host: "127.0.0.1", port: 7000), value)
            XCTAssertEqual(configuration.tier, .loopback, value)
            XCTAssertTrue(configuration.isEnabled, value)
        }
    }

    func testBarePortStaysOnLoopback() {
        let configuration = BiofeedbackConfiguration.resolve(environment: ["NEURALCOMPOSE_BIOFEEDBACK_OSC": "7001"])
        XCTAssertEqual(configuration.osc, BiofeedbackConfiguration.OSC(host: "127.0.0.1", port: 7001))
        XCTAssertEqual(configuration.tier, .loopback)
        XCTAssertEqual(configuration.statusLines, ["Biofeedback out: OSC 127.0.0.1:7001 (loopback)"])
    }

    func testHostAndPortIsLAN() {
        let configuration = BiofeedbackConfiguration.resolve(environment: ["NEURALCOMPOSE_BIOFEEDBACK_OSC": "192.168.1.20:7000"])
        XCTAssertEqual(configuration.osc, BiofeedbackConfiguration.OSC(host: "192.168.1.20", port: 7000))
        XCTAssertEqual(configuration.tier, .lan)
        XCTAssertEqual(configuration.badgeLabel, "Biofeedback: OSC LAN")
        XCTAssertEqual(configuration.statusLines, ["Biofeedback out: OSC 192.168.1.20:7000 (LAN)"])
    }

    func testIPv6LiteralInBrackets() {
        let configuration = BiofeedbackConfiguration.resolve(environment: ["NEURALCOMPOSE_BIOFEEDBACK_OSC": "[::1]:7000"])
        XCTAssertEqual(configuration.osc, BiofeedbackConfiguration.OSC(host: "::1", port: 7000))
        XCTAssertEqual(configuration.tier, .loopback)
    }

    func testOffValuesAndMalformedValuesDisableOSC() {
        for value in ["0", "false", "off", "", "   ", "nonsense", "host:", ":7000", "host:notaport", "host:0", "0"] {
            let configuration = BiofeedbackConfiguration.resolve(environment: ["NEURALCOMPOSE_BIOFEEDBACK_OSC": value])
            XCTAssertNil(configuration.osc, "\"\(value)\" should not resolve to an OSC destination")
            XCTAssertFalse(configuration.isEnabled, value)
        }
    }

    func testMIDIOnlyTier() {
        let configuration = BiofeedbackConfiguration.resolve(environment: ["NEURALCOMPOSE_BIOFEEDBACK_MIDI": "1"])
        XCTAssertTrue(configuration.midi)
        XCTAssertNil(configuration.osc)
        XCTAssertEqual(configuration.tier, .midiOnly)
        XCTAssertEqual(configuration.badgeLabel, "Biofeedback: MIDI")
        XCTAssertEqual(configuration.statusLines, ["Biofeedback out: MIDI virtual source (in-machine)"])
    }

    func testMIDIPlusOSCLabels() {
        let configuration = BiofeedbackConfiguration.resolve(environment: [
            "NEURALCOMPOSE_BIOFEEDBACK_MIDI": "1",
            "NEURALCOMPOSE_BIOFEEDBACK_OSC": "1",
        ])
        XCTAssertEqual(configuration.tier, .loopback)
        XCTAssertEqual(configuration.badgeLabel, "Biofeedback: MIDI + OSC loopback")
        XCTAssertEqual(configuration.statusLines, [
            "Biofeedback out: MIDI virtual source (in-machine)",
            "Biofeedback out: OSC 127.0.0.1:7000 (loopback)",
        ])
    }

    func testRawEEGRequiresOSC() {
        let withoutOSC = BiofeedbackConfiguration.resolve(environment: [
            "NEURALCOMPOSE_BIOFEEDBACK_MIDI": "1",
            "NEURALCOMPOSE_BIOFEEDBACK_RAW_EEG": "1",
        ])
        XCTAssertFalse(withoutOSC.includeRawEEG, "MIDI cannot carry raw EEG; the flag is dropped")

        let withOSC = BiofeedbackConfiguration.resolve(environment: [
            "NEURALCOMPOSE_BIOFEEDBACK_OSC": "1",
            "NEURALCOMPOSE_BIOFEEDBACK_RAW_EEG": "1",
        ])
        XCTAssertTrue(withOSC.includeRawEEG)
        XCTAssertEqual(withOSC.statusLines.last, "Raw /muse/eeg re-broadcast ON")
    }

    func testPerChannelAndMappingsPath() {
        let configuration = BiofeedbackConfiguration.resolve(environment: [
            "NEURALCOMPOSE_BIOFEEDBACK_OSC": "1",
            "NEURALCOMPOSE_BIOFEEDBACK_PER_CHANNEL": "yes",
            "NEURALCOMPOSE_BIOFEEDBACK_MAPPINGS": "  ~/maps.json ",
        ])
        XCTAssertTrue(configuration.perChannel)
        XCTAssertEqual(configuration.mappingsPath, "~/maps.json")

        let blank = BiofeedbackConfiguration.resolve(environment: ["NEURALCOMPOSE_BIOFEEDBACK_MAPPINGS": "   "])
        XCTAssertNil(blank.mappingsPath)
    }

    func testLoadMappingsRoundTrip() throws {
        let mappings = [
            BiofeedbackMapping(feature: .bandAbsolute(.alpha, channel: nil), target: .midiControl(controller: 1, channel: 0, fourteenBit: false), inputLow: 0, inputHigh: 2, smoothingTau: 0.5),
            BiofeedbackMapping(feature: .blink, target: .midiNote(note: 60, channel: 0, velocity: 100, gate: 0.2), inputLow: 0, inputHigh: 1),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("biofeedback-mappings-\(UUID().uuidString).json")
        try JSONEncoder().encode(mappings).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try BiofeedbackConfiguration.loadMappings(at: url.path)
        XCTAssertEqual(loaded, mappings)
    }

    func testMakeBiofeedbackIsNilWhenDisabled() async {
        let coordinator = await AppContainer.makeBiofeedback(configuration: .disabled)
        XCTAssertNil(coordinator)
    }
}
