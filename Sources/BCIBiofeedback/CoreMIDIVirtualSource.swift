#if canImport(CoreMIDI)
import Foundation
import CoreMIDI

/// A CoreMIDI virtual source that other apps see as a MIDI input port
/// named "NeuralCompose Biofeedback". Ableton Live, Logic, Reaper and
/// Bitwig list it in their MIDI preferences with nothing else to set up;
/// no IAC bus, no third-party driver. Not a network transport: MIDI stays
/// inside the machine (Network MIDI sessions are a separate macOS feature
/// this type never enables).
///
/// Sends MIDI 1.0 channel-voice events wrapped as Universal MIDI Packets
/// through `MIDIReceivedEventList`, the non-deprecated path on macOS 11+.
/// One event per list, which keeps the fixed-size `MIDIEventList` Swift
/// imports well within capacity.
///
/// `@unchecked Sendable` invariant: `client` and `source` are created
/// once in `init`, never reassigned, and `MIDIReceivedEventList` is
/// documented as callable from any thread. No other state.
public final class CoreMIDIVirtualSource: BiofeedbackSink, @unchecked Sendable {

    public enum Error: Swift.Error, Equatable {
        case clientCreateFailed(OSStatus)
        case sourceCreateFailed(OSStatus)
    }

    public let name: String
    private let client: MIDIClientRef
    private let source: MIDIEndpointRef

    public init(name: String = "NeuralCompose Biofeedback") throws {
        self.name = name

        var client = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("NeuralCompose" as CFString, &client, nil)
        guard clientStatus == noErr else { throw Error.clientCreateFailed(clientStatus) }

        var source = MIDIEndpointRef()
        let sourceStatus = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard sourceStatus == noErr else {
            MIDIClientDispose(client)
            throw Error.sourceCreateFailed(sourceStatus)
        }

        self.client = client
        self.source = source
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIClientDispose(client)
    }

    public func emit(_ outputs: [BiofeedbackOutput]) async {
        for event in outputs.compactMap(\.midiEvent) {
            send(event)
        }
    }

    private func send(_ event: MIDIEvent) {
        var word = event.umpWord
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        _ = MIDIReceivedEventList(source, &list)
    }
}
#endif
