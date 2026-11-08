import XCTest
@testable import BCIBiofeedback

final class MIDIEventTests: XCTestCase {

    func testControlChangeBytes() {
        XCTAssertEqual(MIDIEvent.controlChange(channel: 0, controller: 1, value: 64).bytes, [0xB0, 0x01, 0x40])
        XCTAssertEqual(MIDIEvent.controlChange(channel: 15, controller: 74, value: 127).bytes, [0xBF, 0x4A, 0x7F])
    }

    func testNoteBytes() {
        XCTAssertEqual(MIDIEvent.noteOn(channel: 1, note: 60, velocity: 100).bytes, [0x91, 0x3C, 0x64])
        XCTAssertEqual(MIDIEvent.noteOff(channel: 1, note: 60).bytes, [0x81, 0x3C, 0x00])
    }

    func testOutOfRangeValuesAreMasked() {
        XCTAssertEqual(MIDIEvent.controlChange(channel: 16, controller: 200, value: 255).bytes, [0xB0, 0x48, 0x7F])
    }

    func testUMPWordIsMessageTypeTwoGroupZero() {
        let word = MIDIEvent.controlChange(channel: 0, controller: 1, value: 64).umpWord
        XCTAssertEqual(word, 0x20B0_0140)
        XCTAssertEqual(MIDIEvent.noteOn(channel: 2, note: 0x3C, velocity: 0x64).umpWord, 0x2092_3C64)
    }

    func testFourteenBitSplitsMSBThenLSB() {
        let events = MIDIEvent.controlChange14(channel: 0, controller: 1, value: 0x1FFF)   // 8191
        XCTAssertEqual(events, [
            .controlChange(channel: 0, controller: 1, value: 0x3F),
            .controlChange(channel: 0, controller: 33, value: 0x7F),
        ])
        XCTAssertEqual(MIDIEvent.controlChange14(channel: 0, controller: 1, value: 16383), [
            .controlChange(channel: 0, controller: 1, value: 127),
            .controlChange(channel: 0, controller: 33, value: 127),
        ])
        XCTAssertEqual(MIDIEvent.controlChange14(channel: 0, controller: 1, value: 0), [
            .controlChange(channel: 0, controller: 1, value: 0),
            .controlChange(channel: 0, controller: 33, value: 0),
        ])
    }

    func testFourteenBitClampsAndFallsBackAbove31() {
        XCTAssertEqual(MIDIEvent.controlChange14(channel: 0, controller: 1, value: 60000).first,
                       .controlChange(channel: 0, controller: 1, value: 127))
        XCTAssertEqual(MIDIEvent.controlChange14(channel: 3, controller: 74, value: 8192),
                       [.controlChange(channel: 3, controller: 74, value: 64)])
    }

    func testCodableRoundTrip() throws {
        let events: [MIDIEvent] = [.controlChange(channel: 0, controller: 1, value: 2), .noteOn(channel: 1, note: 60, velocity: 90), .noteOff(channel: 1, note: 60)]
        let decoded = try JSONDecoder().decode([MIDIEvent].self, from: JSONEncoder().encode(events))
        XCTAssertEqual(decoded, events)
    }
}
