import Foundation
import BCIEEG

/// One thing the egress wants delivered. Transports pick the cases they
/// can carry and ignore the rest: an OSC sender drops `.midi`, a MIDI
/// source drops `.osc`. A sink that records everything (tests, the
/// replay fixture) keeps both.
public enum BiofeedbackOutput: Sendable, Equatable {
    case osc(OSCMessage)
    case midi(MIDIEvent)

    public var oscMessage: OSCMessage? {
        if case .osc(let message) = self { return message }
        return nil
    }

    public var midiEvent: MIDIEvent? {
        if case .midi(let event) = self { return event }
        return nil
    }
}
