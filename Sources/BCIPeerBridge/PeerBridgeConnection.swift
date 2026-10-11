import Foundation
import Network
import BCICore

/// Shared TCP peer connection for the two-machine hypnagogic dialectic bridge
/// (`decision_registry.md` entry 9). Owns the socket, the outgoing `seq`
/// counter, and the last-heard peer `seq`, so every outgoing line's
/// `in_reply_to` answers the turn this side actually heard — mirroring the
/// GPD-side Rust binary's `BridgeState`. `TCPPeerListener` and
/// `TCPPeerSpeaker` both hold a reference to one instance of this actor;
/// this is the first seam in this codebase where a `HypnagogicListening`
/// and `SpeechSynthesizing` conformer share state.
///
/// This machine is always the dialer (the GPD side listens on its tailnet
/// address; the Mac dials in), so there is no accept path here — only
/// `connect()`.
public actor PeerBridgeConnection {
    public let session: String
    private let connection: NWConnection
    private var outgoingSeq = 0
    private var lastPeerSeq: Int?
    private var lineBuffer = Data()
    private var pendingLines: [String] = []
    private var listenContinuation: CheckedContinuation<String?, any Error>?
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var listenTimeoutTask: Task<Void, Never>?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Chunks from the loop's `speakChunks` (it splits each reply on
    /// `. , ; … ! ?` for TTS pacing — see `HypnagogicDialogueLoop.chunk`),
    /// buffered here instead of sent immediately. Flushed as exactly ONE
    /// wire line by `flushPendingSpeech()`, so `seq`/`in_reply_to` mean
    /// "turn," never "chunk" (a chunked turn would otherwise desync the
    /// GPD side's own one-line-per-turn bookkeeping).
    private var pendingSpeechChunks: [String] = []
    /// False until `flushPendingSpeech()` has run once. Protocol invariant:
    /// every turn emits exactly one wire line, including a silent one
    /// (`text: ""`) — `HypnagogicDialecticLoop.runTurn` calls `logSilentTurn`
    /// with NO `speaker.speak()` call at all when both role generators
    /// return empty text or the competition resolves to `.silent`
    /// (`HypnagogicDialecticLoop.swift:323-324, 458-459`). Without this,
    /// a silent turn would flush nothing, and the next `listen()` would
    /// block waiting for a peer that is itself waiting on this side's
    /// line — both sides deadlocked, which Arm A's guard produces by
    /// design on its first intervention. The one call that must NOT send
    /// is the very first flush (there is no prior turn to report — the
    /// seed line is sent directly via `send(text:)`, bypassing the
    /// buffer); every flush after that sends unconditionally, joined
    /// buffer or empty string.
    private var hasFlushedBefore = false

    public init(peerHost: String, peerPort: UInt16, session: String) {
        self.session = session
        self.connection = NWConnection(
            host: NWEndpoint.Host(peerHost),
            port: NWEndpoint.Port(rawValue: peerPort) ?? 7373,
            using: .tcp
        )
    }

    /// Dials the peer and suspends until the connection is ready, or throws.
    public func connect() async throws {
        guard connectContinuation == nil else {
            throw BCIError.peerConnectionFailed(reason: "connect() already in progress")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connectContinuation = cont
            connection.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleStateUpdate(state) }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connectContinuation?.resume()
            connectContinuation = nil
            receiveNext()
        case .failed(let error):
            let bciError = BCIError.peerConnectionFailed(reason: error.localizedDescription)
            connectContinuation?.resume(throwing: bciError)
            connectContinuation = nil
            failPendingListen(bciError)
        case .cancelled:
            failPendingListen(BCIError.cancelled)
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            lineBuffer.append(data)
            drainLines()
        }
        if let error {
            failPendingListen(BCIError.peerConnectionFailed(reason: error.localizedDescription))
            return
        }
        if isComplete {
            failPendingListen(BCIError.peerConnectionFailed(reason: "peer closed the connection"))
            return
        }
        receiveNext()
    }

    private func drainLines() {
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            pendingLines.append(String(decoding: lineData, as: UTF8.self))
        }
        deliverPendingLineIfWaiting()
    }

    private func deliverPendingLineIfWaiting() {
        guard let cont = listenContinuation, !pendingLines.isEmpty else { return }
        listenContinuation = nil
        listenTimeoutTask?.cancel()
        listenTimeoutTask = nil
        cont.resume(returning: pendingLines.removeFirst())
    }

    private func failPendingListen(_ error: any Error) {
        guard let cont = listenContinuation else { return }
        listenContinuation = nil
        listenTimeoutTask?.cancel()
        listenTimeoutTask = nil
        cont.resume(throwing: error)
    }

    /// Returns the next already-buffered wire line, or waits for the next one
    /// to arrive, up to `timeout`. Returns `nil` on timeout — the same
    /// nil-on-timeout contract `HypnagogicListener.listen` uses for silence,
    /// so the loop's existing "nothing heard" cue path applies unchanged.
    public func nextLine(timeout: TimeInterval) async throws -> String? {
        guard listenContinuation == nil else {
            throw BCIError.peerConnectionFailed(reason: "a listen call is already in progress")
        }
        if !pendingLines.isEmpty {
            return pendingLines.removeFirst()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, any Error>) in
            listenContinuation = cont
            listenTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                await self?.resolveTimeout()
            }
        }
    }

    private func resolveTimeout() {
        guard let cont = listenContinuation else { return }
        listenContinuation = nil
        listenTimeoutTask = nil
        cont.resume(returning: nil)
    }

    /// Records a decoded peer line's `seq` so the next outgoing line's
    /// `in_reply_to` answers it.
    public func recordHeardSeq(_ seq: Int) {
        lastPeerSeq = seq
    }

    /// Buffers one chunk of a reply (see `pendingSpeechChunks`'s doc
    /// comment); does not touch the wire.
    public func appendSpokenChunk(_ text: String) {
        pendingSpeechChunks.append(text)
    }

    /// Sends every buffered chunk as exactly one wire line (rejoined with a
    /// single space — `HypnagogicDialogueLoop.chunk` trims each chunk, so the
    /// original inter-chunk whitespace isn't recoverable; a single space is
    /// the closest reconstruction and never affects token-set measures like
    /// the GPD side's Jaccard repetition check), then clears the buffer.
    /// Sends `text: ""` when the buffer is empty — see `hasFlushedBefore`'s
    /// doc comment for why a silent turn still has to emit a line, and why
    /// only the very first call is exempt. Called by `TCPPeerListener` right
    /// before it waits for the next peer line, and on `cancel()`, so a
    /// turn's outcome (spoken or silent) always reaches the wire before
    /// this side either listens again or tears the connection down.
    public func flushPendingSpeech() async throws {
        guard hasFlushedBefore else {
            hasFlushedBefore = true
            return
        }
        let text = pendingSpeechChunks.joined(separator: " ")
        pendingSpeechChunks.removeAll()
        try await send(text: text)
    }

    public func decode(_ line: String) throws -> PeerWireLine {
        guard let data = line.data(using: .utf8) else {
            throw BCIError.peerConnectionFailed(reason: "non-UTF-8 wire line")
        }
        return try decoder.decode(PeerWireLine.self, from: data)
    }

    /// Encodes and writes one wire line for `text`: the next outgoing `seq`,
    /// and `in_reply_to` set to the last peer `seq` heard so far (`nil`
    /// before anything has been heard — exactly the seed turn's shape, since
    /// this side is always the dialer that opens with the seed utterance).
    public func send(text: String) async throws {
        outgoingSeq += 1
        let line = PeerWireLine(
            session: session, seq: outgoingSeq, from: "mac", text: text,
            monoMs: DispatchTime.now().uptimeNanoseconds / 1_000_000,
            inReplyTo: lastPeerSeq
        )
        var data = try encoder.encode(line)
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: BCIError.peerConnectionFailed(reason: error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Aborts any in-flight `nextLine` (resuming it with `nil`) and closes
    /// the socket. Safe to call when idle.
    public func close() {
        listenTimeoutTask?.cancel()
        listenTimeoutTask = nil
        if let cont = listenContinuation {
            listenContinuation = nil
            cont.resume(returning: nil)
        }
        connection.cancel()
    }
}
