import XCTest
import Network
@testable import BCICore
@testable import BCIPeerBridge

final class PeerBridgeConnectionTests: XCTestCase {

    /// Stands in for the GPD-side Rust binary: a bare `NWListener` that
    /// records every line it receives and can send one back. Lets this test
    /// exercise the real `TCPPeerListener`/`TCPPeerSpeaker` seams end-to-end
    /// over a real loopback socket, without the actual GPD device.
    private actor FakePeer {
        private var connection: NWConnection?
        private var buffer = Data()
        private(set) var receivedLines: [PeerWireLine] = []

        func accept(_ connection: NWConnection) {
            self.connection = connection
            connection.start(queue: .global())
            receiveNext()
        }

        private func receiveNext() {
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                Task { await self?.handleReceive(data) }
            }
        }

        private func handleReceive(_ data: Data?) {
            if let data, !data.isEmpty {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if !lineData.isEmpty, let line = try? JSONDecoder().decode(PeerWireLine.self, from: lineData) {
                        receivedLines.append(line)
                    }
                }
            }
            receiveNext()
        }

        func reply(seq: Int, text: String, inReplyTo: Int?) async throws {
            let line = PeerWireLine(session: "test-session", seq: seq, from: "gpd",
                                     text: text, monoMs: 0, inReplyTo: inReplyTo)
            var data = try JSONEncoder().encode(line)
            data.append(0x0A)
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                connection?.send(content: data, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }
    }

    private func startLoopbackListener(
        newConnection: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = newConnection
        // Written from `stateUpdateHandler` (a `@Sendable` callback) and read
        // after `fulfillment(of:)` returns, which happens-after that write —
        // safe in practice, but the compiler can't see that ordering, hence
        // `nonisolated(unsafe)` rather than a lock for a test-only helper.
        nonisolated(unsafe) var boundPort: UInt16?
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port?.rawValue
                ready.fulfill()
            }
        }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 2)
        guard let port = boundPort else {
            XCTFail("listener never bound a port")
            throw BCIError.peerConnectionFailed(reason: "test listener never bound a port")
        }
        return (listener, port)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Mirrors the GPD side's own "compiles clean, round-trip test passes"
    /// check: the Mac dials, sends the seed with `in_reply_to: nil`, hears a
    /// peer reply, and its next outgoing line answers that reply's `seq` —
    /// the exact `BridgeState` bookkeeping the GPD-side Rust session
    /// implemented independently. The seed is sent directly via `send(text:)`,
    /// bypassing `speak()`/the chunk buffer — exactly how
    /// `AppViewModel.connectPeerBridge` primes a real run (the Mac is always
    /// the dialer). Everything after that goes through `speak()` then
    /// `listen()`, never `speak()` alone, since `listen()` is what flushes.
    func testSeedThenTurnRoundTrip() async throws {
        let peer = FakePeer()
        let (listener, port) = try await startLoopbackListener { connection in
            Task { await peer.accept(connection) }
        }

        let bridge = PeerBridgeConnection(peerHost: "127.0.0.1", peerPort: port, session: "test-session")
        try await bridge.connect()
        let macListener = TCPPeerListener(bridge: bridge)
        let macSpeaker = TCPPeerSpeaker(bridge: bridge)

        try await bridge.send(text: "seed utterance")
        try await waitUntil(timeout: 2) { await peer.receivedLines.count == 1 }
        var lines = await peer.receivedLines
        XCTAssertEqual(lines[0].seq, 1)
        XCTAssertNil(lines[0].inReplyTo)
        XCTAssertEqual(lines[0].from, "mac")
        XCTAssertEqual(lines[0].text, "seed utterance")

        try await peer.reply(seq: 7, text: "peer reply", inReplyTo: 1)
        // The FIRST listen() call: its flush is the one exempt call (no
        // prior turn to report — the seed above bypassed the buffer), so
        // this only waits for the peer's line, it sends nothing.
        let heard = try await macListener.listen(timeout: 2)
        XCTAssertEqual(heard, "peer reply")

        try await macSpeaker.speak("mac's second turn")
        _ = try await macListener.listen(timeout: 0.2)
        try await waitUntil(timeout: 2) { await peer.receivedLines.count == 2 }
        lines = await peer.receivedLines
        XCTAssertEqual(lines[1].seq, 2)
        XCTAssertEqual(lines[1].inReplyTo, 7)

        await macListener.cancel()
        listener.cancel()
    }

    /// A listen call with nothing sent must return `nil`, not throw — the
    /// same nil-on-timeout contract `HypnagogicListener` uses for mic
    /// silence, so the loop's existing "nothing heard" cue path applies
    /// unchanged over the bridge.
    func testTimeoutReturnsNilWithoutThrowing() async throws {
        let (listener, port) = try await startLoopbackListener { connection in
            connection.start(queue: .global())
        }

        let bridge = PeerBridgeConnection(peerHost: "127.0.0.1", peerPort: port, session: "test-session")
        try await bridge.connect()
        let heard = try await bridge.nextLine(timeout: 0.2)
        XCTAssertNil(heard)

        await bridge.close()
        listener.cancel()
    }

    // MARK: - Chunking regression (the fix this file exists to pin down)

    /// Always returns the same fixed, multi-sentence text regardless of
    /// prompt/role — both poles produce identical candidates, which keeps
    /// `DialecticalDynamics.compete` out of its high-tension `.silent`
    /// stalemate branch deterministically (tension ≈ 0 for identical
    /// embeddings), so the turn reliably speaks rather than going silent.
    private struct FixedTextGenerator: TextGenerating {
        let isLive = false
        let modelIdentifier = "fixed-stub"
        let text: String
        func generate(prompt: String, maxTokens: Int, temperature: Double, cancellationID: UUID) async throws -> String {
            text
        }
    }

    /// Identical unit embedding for every input — see `FixedTextGenerator`.
    private struct UnitSentenceEmbedder: SentenceEmbedder {
        let modelID = "fixed-stub"
        let dimension = 1
        let version = "v1"
        func encode(_ texts: [String]) async throws -> [Embedding] {
            texts.map { _ in Embedding(values: [1.0], modelID: modelID, dimension: dimension, version: version, seed: 0) }
        }
    }

    /// Reproduces the defect a reviewer caught in the first version of this
    /// bridge: `HypnagogicDialecticLoop.speakChunks` calls `speaker.speak`
    /// once per chunk (it splits a reply on `. , ; … ! ?` for TTS pacing —
    /// `HypnagogicDialogueLoop.chunk`), so a multi-sentence reply used to
    /// reach the wire as several lines with several `seq`s instead of one —
    /// decoupling `in_reply_to` pairing from the GPD side's one-line-per-turn
    /// bookkeeping. This drives a real `HypnagogicDialecticLoop` (not a bare
    /// `speak()` call, which is what let the bug through the first time) and
    /// asserts the peer receives exactly one line for the whole turn.
    func testMultiSentenceReplyReachesWireAsOneLinePerTurn() async throws {
        let peer = FakePeer()
        let (listener, port) = try await startLoopbackListener { connection in
            Task { await peer.accept(connection) }
        }
        let bridge = PeerBridgeConnection(peerHost: "127.0.0.1", peerPort: port, session: "test-session")
        try await bridge.connect()

        let replyText = "Hello there. How are you? I am fine."
        let loop = HypnagogicDialecticLoop(
            listener: TCPPeerListener(bridge: bridge),
            generator: FixedTextGenerator(text: replyText),
            speaker: TCPPeerSpeaker(bridge: bridge),
            embedder: UnitSentenceEmbedder(),
            config: .init(listenTimeout: 1, interTurnDelayNanos: 10_000_000)
        )

        // The peer's "seed" turn — this test only cares about the Mac's
        // OUTGOING speaking path, so the exact heard text doesn't matter.
        try await peer.reply(seq: 1, text: "seed utterance", inReplyTo: nil)

        await loop.start()
        try await waitUntil(timeout: 2) { await peer.receivedLines.count >= 1 }
        // Settle window: long enough that, pre-fix, all 3 unbuffered chunk
        // sends would have already landed; short enough that it can't reach
        // the *next* turn's silence-cue line (listenTimeout is 1s above).
        try await Task.sleep(nanoseconds: 300_000_000)
        await loop.stop()
        listener.cancel()

        let lines = await peer.receivedLines
        XCTAssertEqual(lines.count, 1, "a multi-sentence reply must reach the wire as exactly one line per turn")
        XCTAssertEqual(lines.first?.text, replyText)
        XCTAssertEqual(lines.first?.seq, 1)
    }

    // MARK: - Silent-turn deadlock regression

    /// A silent turn — `candidateTexts.isEmpty` at
    /// `HypnagogicDialecticLoop.swift:323-324` (both role generators return
    /// empty text), routing into `logSilentTurn` (`:477-505`), which calls
    /// `speaker.speak` ZERO times unless `consecutiveSilence` has already
    /// reached `config.maxConsecutiveSilence` (set absurdly high below so
    /// that branch can't fire and contaminate this test with a spoken cue).
    /// Before the fix, `flushPendingSpeech` only sent when the buffer was
    /// non-empty, so this turn would flush nothing: the Mac's next
    /// `listen()` would then block waiting for the peer's reply to a line
    /// that was never sent — and the peer, waiting on exactly that line
    /// before it speaks its own next turn, blocks too. Both sides deadlock.
    /// This is precisely what Arm A's repetition-floor/drift-ceiling guard
    /// produces on its first intervention, not an edge case.
    func testSilentTurnStillEmitsOneEmptyLine() async throws {
        let peer = FakePeer()
        let (listener, port) = try await startLoopbackListener { connection in
            Task { await peer.accept(connection) }
        }
        let bridge = PeerBridgeConnection(peerHost: "127.0.0.1", peerPort: port, session: "test-session")
        try await bridge.connect()

        let loop = HypnagogicDialecticLoop(
            listener: TCPPeerListener(bridge: bridge),
            generator: FixedTextGenerator(text: ""),   // empty from both roles -> candidateTexts.isEmpty -> logSilentTurn
            speaker: TCPPeerSpeaker(bridge: bridge),
            embedder: UnitSentenceEmbedder(),
            config: .init(listenTimeout: 1, interTurnDelayNanos: 10_000_000, maxConsecutiveSilence: 1_000_000)
        )

        try await peer.reply(seq: 1, text: "seed utterance", inReplyTo: nil)

        await loop.start()
        try await waitUntil(timeout: 2) { await peer.receivedLines.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        await loop.stop()
        listener.cancel()

        let lines = await peer.receivedLines
        XCTAssertEqual(lines.count, 1, "a silent turn must still emit exactly one wire line, not zero")
        XCTAssertEqual(lines.first?.text, "", "a silent turn's line must carry empty text")
        XCTAssertEqual(lines.first?.seq, 1)
        XCTAssertEqual(lines.first?.inReplyTo, 1)
    }
}
