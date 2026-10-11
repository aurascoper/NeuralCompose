import Foundation
import BCICore

/// `HypnagogicListening` conformer that reads the next wire line from a
/// `PeerBridgeConnection` instead of the microphone. See
/// `decision_registry.md` entry 9 and the fixed wire-format spec agreed with
/// the GPD-side Rust session before either side wrote code.
public struct TCPPeerListener: HypnagogicListening {
    public let isLive = true
    private let bridge: PeerBridgeConnection

    public init(bridge: PeerBridgeConnection) {
        self.bridge = bridge
    }

    /// No OS permission to request for a socket — always granted.
    public func requestAuthorization() async -> Bool { true }

    public func listen(timeout: TimeInterval) async throws -> String? {
        // Flush the previous turn's buffered speech chunks (if any) as one
        // wire line before waiting for the peer's next line. This is the
        // one place in the loop's control flow (confirmed in `run()`) where
        // a turn's speaking has always already finished — see
        // `PeerBridgeConnection.flushPendingSpeech`.
        try await bridge.flushPendingSpeech()
        guard let line = try await bridge.nextLine(timeout: timeout) else { return nil }
        let wire = try await bridge.decode(line)
        await bridge.recordHeardSeq(wire.seq)
        let text = wire.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Mirrors `HypnagogicListener.cancel()`'s "closes the mic" contract:
    /// this bridge's one open resource is the socket itself, so cancelling
    /// tears the whole connection down rather than just the in-flight read.
    /// Flushes any still-buffered speech first — otherwise the final turn's
    /// reply, spoken right before the loop stops, would never reach the
    /// wire at all (there is no further `listen()` call to flush it).
    public func cancel() async {
        try? await bridge.flushPendingSpeech()
        await bridge.close()
    }
}

/// `SpeechSynthesizing` conformer that writes the spoken text as a wire line
/// to a `PeerBridgeConnection` instead of voicing it locally. Prosody and
/// per-word grounding have no wire equivalent yet (this is the text-only
/// stage of the bridge) and fall back to plain `speak(_:)` via
/// `SpeechSynthesizing`'s default extension.
public struct TCPPeerSpeaker: SpeechSynthesizing {
    public let isLive = true
    public let voiceIdentifier = "tcp-peer-bridge"
    private let bridge: PeerBridgeConnection

    public init(bridge: PeerBridgeConnection) {
        self.bridge = bridge
    }

    /// Buffers `text` rather than sending it immediately — `speakChunks`
    /// calls this once per chunk for a multi-sentence reply, and the wire
    /// format needs exactly one line per turn. See
    /// `PeerBridgeConnection.appendSpokenChunk`/`flushPendingSpeech`.
    public func speak(_ text: String) async throws {
        await bridge.appendSpokenChunk(text)
    }

    /// Nothing to interrupt — chunks are buffered, not streamed. The shared
    /// bridge is flushed and torn down by the listener's `cancel()`, which
    /// the loop calls first on stop.
    public func stopSpeaking() async {}
}
