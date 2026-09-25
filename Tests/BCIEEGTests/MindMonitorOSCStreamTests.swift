import XCTest
import Network
@testable import BCIEEG
@testable import BCICore

/// Integration test for `MindMonitorOSCStream`: a real UDP socket, loopback
/// only. Uses a fixed high port rather than an ephemeral one (port 0) —
/// `NWListener` doesn't expose the OS-assigned port synchronously enough to
/// make ephemeral-port discovery worth the extra plumbing for a single
/// local test target; the tradeoff is a small, accepted risk of collision
/// if something else on the machine happens to be using this exact port.
final class MindMonitorOSCStreamTests: XCTestCase {

    private let testPort: UInt16 = 57_182

    private func oscString(_ s: String) -> Data {
        var data = Data(s.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private func makeEEGPacket(_ floats: [Float]) -> Data {
        var data = oscString("/muse/eeg")
        data.append(oscString("," + String(repeating: "f", count: floats.count)))
        for f in floats {
            var bits = f.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// A `/muse/acc` message — decoded to a `MovementSample` (not an EEG sample),
    /// so it keeps the packet link "alive" for the stalled-`/muse/eeg` test while
    /// exercising the movement channel rather than a drop.
    private func makeAccPacket() -> Data {
        var data = oscString("/muse/acc")
        data.append(oscString(",fff"))
        for v: Float in [0.1, 0.2, 0.3] {
            var bits = v.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Sends `data` to `127.0.0.1:testPort` over UDP and waits briefly for
    /// the send to actually complete before returning — `NWConnection`'s
    /// send is itself async/callback-based.
    private func sendUDP(_ data: Data, port: UInt16) async {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp
        )
        connection.start(queue: .global())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
        // Give the listener a moment to actually receive before the test
        // moves on to assert; UDP delivery over loopback is fast but not
        // synchronous with the send callback completing.
        try? await Task.sleep(nanoseconds: 30_000_000)
        connection.cancel()
    }

    func testReceivesEEGSamplesOverUDP() async throws {
        let stream = MindMonitorOSCStream(port: testPort)
        let eegStream = try await stream.start()
        // Let the listener finish binding before sending.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let collectTask = Task { () -> [EEGSample] in
            var out: [EEGSample] = []
            for try await sample in eegStream {
                out.append(sample)
                if out.count == 2 { break }
            }
            return out
        }

        await sendUDP(makeEEGPacket([1, 2, 3, 4]), port: testPort)
        await sendUDP(makeEEGPacket([5, 6, 7, 8]), port: testPort)

        let received = try await collectTask.value
        await stream.stop()

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received[0].channels, [1, 2, 3, 4])
        XCTAssertEqual(received[1].channels, [5, 6, 7, 8])
        // Timestamps are arrival-relative and strictly increasing.
        XCTAssertGreaterThan(received[1].timestamp, received[0].timestamp)
    }

    func testDiagnosticsTrackPacketsAndDropsSeparately() async throws {
        let stream = MindMonitorOSCStream(port: testPort + 1)
        let eegStream = try await stream.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let collectTask = Task {
            var count = 0
            for try await _ in eegStream {
                count += 1
                if count == 1 { break }
            }
        }

        // One /muse/acc (now captured as MOVEMENT, not dropped — H2 fix), then
        // one valid EEG packet.
        await sendUDP(makeAccPacket(), port: testPort + 1)
        await sendUDP(makeEEGPacket([10, 20, 30, 40]), port: testPort + 1)

        _ = try await collectTask.value
        await stream.stop()

        let diagnostics = stream.currentDiagnostics()
        XCTAssertEqual(diagnostics.transport, "OSC (Mind Monitor)")
        XCTAssertGreaterThanOrEqual(diagnostics.packetsReceived, 2)
        XCTAssertGreaterThanOrEqual(diagnostics.movementYielded, 1) // the /muse/acc packet (movement)
        XCTAssertEqual(diagnostics.packetsDropped, 0) // nothing malformed (H2: acc is not a drop)
        XCTAssertGreaterThanOrEqual(diagnostics.samplesYielded, 1) // the /muse/eeg packet
        // packetsReceived counts datagrams; samplesYielded counts decoded
        // EEG samples — never the other way around for this fixture (one
        // datagram maps to at most one message here, no bundling).
        XCTAssertGreaterThanOrEqual(diagnostics.packetsReceived, diagnostics.samplesYielded)
        XCTAssertNotNil(diagnostics.lastHeartbeat)
        // F2: a heartbeat that just happened should read back as ~0s stale,
        // not nil and not some stale baked-in value.
        let staleness = try XCTUnwrap(diagnostics.secondsSinceLastHeartbeat)
        XCTAssertGreaterThanOrEqual(staleness, 0)
        XCTAssertLessThan(staleness, 1.0)
        // F1: bound port should always reflect the configured port, so the
        // privacy banner can show it without the listener needing to have
        // received anything yet.
        XCTAssertEqual(diagnostics.boundPort, testPort + 1)
    }

    /// Pins the "Sample timestamps monotonic (no out-of-order, no
    /// duplicates)" row of docs/testing/deployment-checklist.md — that row
    /// has no live/external check (EEGSample.timestamp is internal state,
    /// not observable from outside the process), so this test is the
    /// actual verification; Scripts/deployment-check.sh points here rather
    /// than attempting to fake an external check for it.
    ///
    /// Holds by construction today: `elapsedSeconds` is computed from
    /// `DispatchTime.now()` (monotonic) at the moment each datagram is
    /// processed, not from anything in the packet itself — so timestamps
    /// are ordered by processing order, not by network arrival order or
    /// any sender-side sequence number. This test exists so a future
    /// change (e.g. deriving timestamps from the OSC bundle's NTP timetag
    /// instead — see the TODO in MuseOSCDecoder.decodeBundleElements)
    /// can't silently break that guarantee.
    func testSampleTimestampsAreStrictlyMonotonic() async throws {
        let port = testPort + 3
        let stream = MindMonitorOSCStream(port: port)
        let eegStream = try await stream.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let sampleCount = 6
        let collectTask = Task { () -> [EEGSample] in
            var out: [EEGSample] = []
            for try await sample in eegStream {
                out.append(sample)
                if out.count == sampleCount { break }
            }
            return out
        }

        for i in 0..<sampleCount {
            await sendUDP(makeEEGPacket([Float(i), Float(i), Float(i), Float(i)]), port: port)
        }

        let received = try await collectTask.value
        await stream.stop()

        XCTAssertEqual(received.count, sampleCount)
        for i in 1..<received.count {
            XCTAssertGreaterThan(
                received[i].timestamp, received[i - 1].timestamp,
                "timestamp did not strictly increase at index \(i)"
            )
        }
        // No duplicates: strictly increasing already implies this, but
        // assert it directly since that's the literal checklist wording.
        XCTAssertEqual(Set(received.map(\.timestamp)).count, received.count)
    }

    func testStartingTwiceThrows() async throws {
        let stream = MindMonitorOSCStream(port: testPort + 2)
        _ = try await stream.start()
        do {
            _ = try await stream.start()
            XCTFail("expected the second start() to throw")
        } catch {
            // Expected — see MindMonitorOSCStream.start()'s doc comment.
        }
        await stream.stop()
    }

    /// The deferred "F3" test from the OSC transport review: proves a
    /// silently stalled link (packets simply stop, no NWConnection error)
    /// actually surfaces as a thrown stream error — which is what
    /// AppViewModel's retry/backoff/reconnecting-UI supervisor needs to
    /// react to. Before the staleTimeoutSec watchdog existed, this
    /// scenario produced no error and no completion at all; the stream
    /// just sat forever, and the supervisor never got a reason to react —
    /// exactly the same failure mode found live on the BrainFlow path
    /// (BrainFlowService's equivalent watchdog, same commit).
    func testStreamThrowsAfterPacketsStopArriving() async throws {
        let port = testPort + 4
        let stream = MindMonitorOSCStream(port: port, staleTimeoutSec: 1.0)
        let eegStream = try await stream.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // One real packet so lastHeartbeat is set from an actual arrival,
        // not just sessionStart — closer to the real "was streaming, then
        // stopped" scenario than "never received anything."
        await sendUDP(makeEEGPacket([1, 2, 3, 4]), port: port)

        let collectTask = Task { () -> Error? in
            do {
                for try await _ in eegStream {}
                return nil // stream finished cleanly — not what we expect here
            } catch {
                return error
            }
        }

        // Deliberately send nothing more. staleTimeoutSec is 1.0s; allow
        // up to 3s for the watchdog to fire and the stream to throw.
        let outcome = await value(of: collectTask, within: 3)
        await stream.stop()

        let thrown = try XCTUnwrap(
            outcome.flatMap { $0 },
            "watchdog did not fire within 3s — stream neither threw nor finished"
        )
        guard case BCIError.streamFailed(let reason) = thrown else {
            return XCTFail("expected BCIError.streamFailed, got \(thrown)")
        }
        XCTAssertTrue(reason.contains("no OSC packets"), "unexpected failure reason: \(reason)")
    }

    /// C1 regression: the watchdog must key off EEG-SAMPLE throughput, not raw
    /// packet arrival. Sends one EEG sample, then only non-EEG (`/muse/acc`)
    /// traffic continuously — the packet link stays "alive" but `/muse/eeg` has
    /// stopped, so the stream must still throw. Before C1 the packet heartbeat
    /// kept the watchdog green forever and this failure was invisible.
    func testStreamThrowsWhenEEGStopsButOtherTrafficContinues() async throws {
        let port = testPort + 5
        let stream = MindMonitorOSCStream(port: port, staleTimeoutSec: 1.0)
        let eegStream = try await stream.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Prime with a real EEG sample so lastSampleWallClock is set from an
        // actual sample — the "was streaming EEG, then it stopped" scenario.
        await sendUDP(makeEEGPacket([1, 2, 3, 4]), port: port)

        let collectTask = Task { () -> Error? in
            do {
                for try await _ in eegStream {}
                return nil
            } catch { return error }
        }

        // Keep the PACKET link alive with non-EEG traffic while EEG stays silent.
        // Captures only Sendable values (Data, UInt16) — no `self` — so the pump
        // is strict-concurrency clean. Fire-and-forget sends (cancel in callback).
        let acc = makeAccPacket()
        let pump = Task { [acc] in
            while !Task.isCancelled {
                let conn = NWConnection(
                    host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
                conn.start(queue: .global())
                conn.send(content: acc, completion: .contentProcessed { _ in conn.cancel() })
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        // staleTimeoutSec is 1.0s; the sample watchdog should fire ~2s in
        // despite the ongoing /muse/acc traffic. Allow up to 5s.
        let outcome = await value(of: collectTask, within: 5)
        pump.cancel()
        await stream.stop()

        let thrown = try XCTUnwrap(
            outcome.flatMap { $0 },
            "watchdog did not fire despite EEG stopping — sample-throughput watchdog regressed"
        )
        guard case BCIError.streamFailed(let reason) = thrown else {
            return XCTFail("expected BCIError.streamFailed, got \(thrown)")
        }
        XCTAssertTrue(reason.contains("EEG substream stalled"),
                      "expected an EEG-substream-stall reason, got: \(reason)")
    }

    /// C1 follow-up (PR #18 review): the supervisor reuses ONE stream instance
    /// across live retries via stop()/start(). The per-session watchdog reference
    /// must reset on each start(), or a retry inherits the prior attempt's stale
    /// sample time and the reconnect grace collapses to a single ~1s tick. Checked
    /// via the observable proxy — after a restart with no new traffic, lastHeartbeat
    /// (reset alongside lastSampleWallClock) reads nil, not the prior session's value.
    func testRestartResetsPerSessionWatchdogReference() async throws {
        let port = testPort + 6
        // Default 5s timeout so the watchdog can't fire during this quick check.
        let stream = MindMonitorOSCStream(port: port)
        let s1 = try await stream.start()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Consume one sample so the packet is DEFINITELY processed (heartbeat is
        // set inside handlePacket on receipt) before we read diagnostics — the
        // first packet also pays the connection-setup latency, so a fixed sleep
        // would be racy.
        let collect1 = Task { () -> EEGSample? in
            for try await sample in s1 { return sample }
            return nil
        }
        await sendUDP(makeEEGPacket([1, 2, 3, 4]), port: port)
        let got = try await collect1.value
        XCTAssertNotNil(got, "session 1 should receive its EEG sample")
        XCTAssertNotNil(stream.currentDiagnostics().lastHeartbeat,
                        "session 1 received a packet, so its heartbeat is set")
        await stream.stop()
        // Let the old listener release the port before the same instance rebinds.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Restart the SAME instance, exactly as the supervisor does across retries.
        // recordStarted() resets lastHeartbeat synchronously, before any packet,
        // so this assertion holds regardless of rebind timing.
        _ = try await stream.start()
        XCTAssertNil(stream.currentDiagnostics().lastHeartbeat,
                     "restart must reset the per-session watchdog reference — inheriting "
                     + "session 1's stale value would collapse the retry's grace to one tick")
        await stream.stop()
    }

    /// Accel/gyro must be yielded on the parallel movement channel and must NOT
    /// be counted as `packetsDropped` (OSC review finding H2 — non-EEG traffic
    /// was inflating a "packet loss" metric).
    func testMovementYieldedAndNotCountedAsDropped() async throws {
        let port = testPort + 7
        let stream = MindMonitorOSCStream(port: port)
        let eegStream = try await stream.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        let movementTask = Task { () -> MovementSample? in
            for await m in stream.movementStream { return m }
            return nil
        }
        let eegTask = Task { () -> EEGSample? in
            do { for try await s in eegStream { return s } } catch {}
            return nil
        }

        await sendUDP(makeAccPacket(), port: port)           // movement (/muse/acc)
        await sendUDP(makeEEGPacket([1, 2, 3, 4]), port: port) // eeg

        let movement = (await value(of: movementTask, within: 3)) ?? nil
        _ = await value(of: eegTask, within: 3)
        await stream.stop()

        XCTAssertEqual(movement?.kind, .accel, "an accel packet must be yielded on the movement channel")
        let diag = stream.currentDiagnostics()
        XCTAssertGreaterThanOrEqual(diag.movementYielded, 1)
        XCTAssertGreaterThanOrEqual(diag.samplesYielded, 1)
        XCTAssertEqual(diag.packetsDropped, 0,
                       "H2: /muse/acc must not inflate packetsDropped — it's movement, not loss")
    }

    /// PR #19 review finding 5: a TRUNCATED message at a known sample address
    /// (/muse/eeg with <4 floats) is real corruption and must count as a DROP
    /// (not be silently rebucketed as benign ignoredNonEEG). A genuinely
    /// non-sample address (/muse/batt) stays ignoredNonEEG.
    ///
    /// Regression note (2026-09-24): this test previously hung the xctest
    /// process. Three independent defects stacked:
    ///   1. The returned AsyncThrowingStream was discarded (`_ =`), so its
    ///      onTermination fired ~1 ms after start() and cancelled the
    ///      NWListener before the datagrams were sent — packetsReceived never
    ///      advanced and the poll below could never succeed.
    ///   2. The poll was raced with withTimeout's task-group helper: a group
    ///      waits for ALL its children, and the poller child swallowed its
    ///      own cancellation (`try? await Task.sleep` → CancellationError →
    ///      instant re-loop with no suspension), so once the 2 s timeout child
    ///      "won", the poller spun at ~97% CPU with unbounded allocation churn
    ///      (RSS oscillated 3.3–4.7 GB) until the process died under memory
    ///      pressure with no crash report.
    ///   3. Nothing bounded the overall wait: XCTest's async support waits
    ///      forever when the test body never returns.
    ///
    /// The rewrite keeps the stream alive, polls in a Task that CHECKS
    /// Task.isCancelled (so cancellation is honoured), and bounds the wait
    /// with XCTMultipleExpectations (`fulfillment(of:timeout:)`) — the test
    /// now FAILS inside its stated 2 s bound with a message instead of
    /// hanging the runner. The stream contract (onTermination tearing down
    /// the listener when the consumer drops the stream) is deliberate
    /// resource cleanup, not a defect; the behavioural question of what a
    /// discarded stream should mean is recorded in the Phase-2 notes, not
    /// changed here.
    func testTruncatedSampleAddressCountsAsDroppedNotIgnored() async throws {
        let port = testPort + 8
        let stream = MindMonitorOSCStream(port: port)
        // Retain the returned stream: discarding it cancels the listener via
        // onTermination before the datagrams below are ever delivered.
        let eegStream = try await stream.start()
        try? await Task.sleep(nanoseconds: 100_000_000)

        var truncatedEEG = oscString("/muse/eeg")   // only 2 floats — truncated
        truncatedEEG.append(oscString(",ff"))
        for v: Float in [1, 2] {
            var bits = v.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { truncatedEEG.append(contentsOf: $0) }
        }
        var batt = oscString("/muse/batt")           // genuinely non-sample
        batt.append(oscString(",f"))
        var b = Float(88).bitPattern.bigEndian
        withUnsafeBytes(of: &b) { batt.append(contentsOf: $0) }

        await sendUDP(truncatedEEG, port: port)
        await sendUDP(batt, port: port)

        // Bounded wait for BOTH datagrams to land in the diagnostics counter.
        // `received both datagrams` fulfils as soon as packetsReceived >= 2;
        // if the datagrams are lost, the wait times out at 2 s and the test
        // FAILS here with the message below — the stated bound, honoured.
        let bothDatagrams = expectation(description: "received both datagrams")
        let poller = Task {
            while !Task.isCancelled {
                if stream.currentDiagnostics().packetsReceived >= 2 {
                    bothDatagrams.fulfill()
                    return
                }
                // Sleep BETWEEN polls so a cancelled poller suspends and
                // exits instead of spinning (the pre-rewrite hang mechanism).
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { poller.cancel() }
        await fulfillment(of: [bothDatagrams], timeout: 2)
        // Keep the stream (and with it the listener, via onTermination) alive
        // until the wait has resolved; the local is otherwise unused, so the
        // optimizer may release it early. The stdlib overload is synchronous
        // and can't wrap the await, but its guarantee runs to this call site,
        // so an empty body placed after the await covers the whole wait.
        withExtendedLifetime(eegStream) {}

        await stream.stop()

        let diag = stream.currentDiagnostics()
        XCTAssertGreaterThanOrEqual(diag.packetsDropped, 1, "truncated /muse/eeg is real loss → dropped")
        XCTAssertGreaterThanOrEqual(diag.ignoredNonEEG, 1, "/muse/batt is benign → ignoredNonEEG")
        XCTAssertEqual(diag.samplesYielded, 0)
        XCTAssertEqual(diag.movementYielded, 0)
    }

    /// D-behavioural: a DISCARDED stream (consumer releases it) must report
    /// `.cancelled` in diagnostics — the whole point of `StreamListenerState`.
    /// Before it existed, a terminated listener and a quiet live one were
    /// indistinguishable (packetsReceived == 0 either way), which is exactly
    /// what made the discarded-stream bug expensive: datagrams went to a
    /// listener that had already torn itself down, and the counters said
    /// nothing. Keeping the drop-ends-subscription semantics (standard
    /// AsyncStream behaviour; the app consumes the stream) — this pins the
    /// OBSERVABILITY of it, not a change.
    func testDiscardedStreamReportsCancelledListener() async throws {
        let port = testPort + 9
        let stream = MindMonitorOSCStream(port: port)
        XCTAssertEqual(
            stream.currentDiagnostics().listenerState, .idle,
            "a fresh, never-started stream must read .idle"
        )

        do {
            _ = try await stream.start()   // deliberately discarded
        } catch {
            return XCTFail("start() unexpectedly threw: \(error)")
        }
        // onTermination fires shortly after the last reference drops; give
        // the teardown a bounded moment to land, then it must read cancelled.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            stream.currentDiagnostics().listenerState, .cancelled,
            "a discarded stream must report a cancelled listener — a quiet live listener must be distinguishable from a dead one"
        )
    }

    /// D-behavioural: a RETAINED stream must report `.ready` while alive, and
    /// `.cancelled` after an explicit `stop()` — so callers reading
    /// diagnostics between sessions can tell "waiting for the first packet"
    /// (ready, quiet) from "no subscription at all" (cancelled). `.ready` is
    /// the listener's own asynchronous report, so the test waits for it.
    func testRetainedStreamReportsReadyThenCancelledOnStop() async throws {
        let port = testPort + 10
        let stream = MindMonitorOSCStream(port: port)
        let eegStream = try await stream.start()
        let state = await listenerState(of: stream, reaching: .ready, within: 2)
        XCTAssertEqual(
            state, .ready,
            "a live, retained stream must report ready even with zero packets — quiet ≠ dead"
        )

        await stream.stop()
        XCTAssertEqual(
            stream.currentDiagnostics().listenerState, .cancelled,
            "stop() must move diagnostics to cancelled"
        )
        // The retained stream is never consumed; keep it alive past the stop()
        // assertion. `_ = eegStream` is not enough: it has no side effect, so
        // the optimizer may drop it and release the stream early.
        withExtendedLifetime(eegStream) {}
    }

    /// `.ready` must be OBSERVED from the listener, never asserted by
    /// start(). A second stream on a port the first already holds gets
    /// EADDRINUSE from Network.framework, so it must not read `.ready` even
    /// immediately after start() (it was, before start() stopped writing
    /// it), must settle on `.failed`, and a later stop() must not launder
    /// the failure into `.cancelled`.
    func testListenerThatCannotBindNeverReportsReady() async throws {
        let port = testPort + 11
        let holder = MindMonitorOSCStream(port: port)
        let holderStream = try await holder.start()
        let holderState = await listenerState(of: holder, reaching: .ready, within: 2)
        XCTAssertEqual(holderState, .ready, "precondition: the first stream must hold the port")

        let blocked = MindMonitorOSCStream(port: port)
        let blockedStream = try await blocked.start()
        XCTAssertNotEqual(
            blocked.currentDiagnostics().listenerState, .ready,
            "start() must not claim ready before the listener reports it"
        )
        let blockedState = await listenerState(of: blocked, reaching: .failed, within: 2)
        XCTAssertEqual(blockedState, .failed, "a bind collision must surface as .failed")

        await blocked.stop()
        XCTAssertEqual(
            blocked.currentDiagnostics().listenerState, .failed,
            "stop() after a failure must keep .failed — the failure is the actionable fact"
        )
        await holder.stop()
        withExtendedLifetime((holderStream, blockedStream)) {}
    }

    /// Pins how each Network.framework listener state reads in diagnostics,
    /// in particular `.waiting` (can't listen now, retrying on its own),
    /// which no live test can induce on demand: it reads as neither ready
    /// nor failed.
    func testListenerStateMapping() {
        let error = NWError.posix(.ENETDOWN)
        XCTAssertEqual(MindMonitorOSCStream.diagnosticState(for: .setup), .starting)
        XCTAssertEqual(MindMonitorOSCStream.diagnosticState(for: .waiting(error)), .waiting)
        XCTAssertEqual(MindMonitorOSCStream.diagnosticState(for: .ready), .ready)
        XCTAssertEqual(MindMonitorOSCStream.diagnosticState(for: .failed(error)), .failed)
        XCTAssertEqual(MindMonitorOSCStream.diagnosticState(for: .cancelled), .cancelled)
    }

    /// A callback from a listener that is no longer the stream's current one
    /// must not move the state. The write rule takes (state, source), so the
    /// test hands it a stale source directly; no race has to be scheduled.
    func testStaleListenerCallbackCannotRewriteState() async throws {
        let port = testPort + 12
        let stream = MindMonitorOSCStream(port: port)
        let eegStream = try await stream.start()
        let live = await listenerState(of: stream, reaching: .ready, within: 2)
        XCTAssertEqual(live, .ready, "precondition: the current listener reported ready")

        let stale = try NWListener(using: .udp)   // never started, never the stream's listener
        let error = NWError.posix(.EADDRINUSE)
        stream.recordListenerState(.failed(error), of: stale)
        stream.recordListenerState(.waiting(error), of: stale)
        stream.recordListenerCancelled(stale)
        XCTAssertEqual(
            stream.currentDiagnostics().listenerState, .ready,
            "a stale listener's callbacks must not rewrite the current session's state"
        )

        await stream.stop()
        withExtendedLifetime(eegStream) {}
    }

    /// Terminal states hold for a SESSION, not for the instance: the
    /// supervisor reuses one stream across its reconnect retries, so a
    /// `.failed` or `.cancelled` that survived stop()/start() would make
    /// diagnostics lie after every reconnect. Session 1 fails on an occupied
    /// port; once the port is freed, session 2 on the same instance must
    /// reach `.ready`. The occupier is a bare NWListener so the test can
    /// wait for its own `.cancelled` report instead of sleeping and hoping
    /// the port has been released.
    func testTerminalStateIsPerSessionRestartReachesReady() async throws {
        let port = testPort + 13
        let occupier = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
        let occupierReady = expectation(description: "occupier ready")
        let occupierCancelled = expectation(description: "occupier cancelled")
        occupier.newConnectionHandler = { $0.cancel() }
        occupier.stateUpdateHandler = { state in
            switch state {
            case .ready: occupierReady.fulfill()
            case .cancelled: occupierCancelled.fulfill()
            default: break
            }
        }
        occupier.start(queue: .global())
        await fulfillment(of: [occupierReady], timeout: 2)

        let stream = MindMonitorOSCStream(port: port)
        let session1 = try await stream.start()
        let failed = await listenerState(of: stream, reaching: .failed, within: 2)
        XCTAssertEqual(failed, .failed, "precondition: session 1 fails on the occupied port")
        await stream.stop()
        XCTAssertEqual(stream.currentDiagnostics().listenerState, .failed)
        withExtendedLifetime(session1) {}

        occupier.cancel()
        await fulfillment(of: [occupierCancelled], timeout: 2)

        let session2 = try await stream.start()
        let restarted = await listenerState(of: stream, reaching: .ready, within: 2)
        XCTAssertEqual(
            restarted, .ready,
            "session 1's terminal .failed must not carry into session 2 — reconnect diagnostics depend on it"
        )
        await stream.stop()
        withExtendedLifetime(session2) {}
    }

    /// Polls `stream`'s listener state until it reads `target`, `seconds`
    /// pass, or the task is cancelled (checked, so a cancelled poll exits
    /// instead of spinning), returning the last state read.
    private func listenerState(
        of stream: MindMonitorOSCStream, reaching target: StreamListenerState, within seconds: Double
    ) async -> StreamListenerState {
        let deadline = Date().addingTimeInterval(seconds)
        var state = stream.currentDiagnostics().listenerState
        while state != target, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
            state = stream.currentDiagnostics().listenerState
        }
        return state
    }

    /// `task`'s value, or `nil` if it doesn't finish within `seconds` — in
    /// which case `task` is cancelled and abandoned, never awaited, so this
    /// ALWAYS returns within `seconds` instead of hanging the test if the
    /// watchdog regresses.
    ///
    /// Regression note (C1 audit, 2026-09-24): this helper was built on
    /// `withTaskGroup` — and a task group waits for ALL its children. When
    /// the timeout child won and the operation child was itself awaiting an
    /// external `Task.value` (cancellation-insensitive: cancelling the
    /// awaiting task does not complete the await), the group could never
    /// exit and the test hung forever at 0% CPU inside XCTWaiter — a second,
    /// quieter sibling of the Phase-0 unbounded-wait defect, exposed live by
    /// the C1 wrong-port mutation on testMovementYieldedAndNotCountedAsDropped
    /// (movement channel has no watchdog, so nothing ever completed the
    /// abandoned await). Now the abandoning pattern — same shape as BCILLM's
    /// `withAbandoningTimeout`: unstructured tasks + a once-flag. It takes the
    /// Task rather than a closure because cancellation does not propagate
    /// through `await task.value`: a closure-based helper could only cancel
    /// its own wrapper, never the task actually holding the stream. Every
    /// caller's task iterates an AsyncStream, which does honour cancellation,
    /// so the loser really ends — including a `movementStream` consumer,
    /// which `stop()` alone never finishes (that stream outlives sessions).
    private func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        let once = TimeoutOnceFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let timer = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() {
                    task.cancel()
                    cont.resume(returning: nil)
                }
            }
            Task.detached {
                let value = await task.value
                if once.claim() {
                    timer.cancel()
                    cont.resume(returning: value)
                }
            }
        }
    }
}

/// Once-flag for `value(of:within:)`: whichever of (task, timer) finishes
/// first claims the right to resume the continuation; the loser's result is
/// dropped. `@unchecked Sendable` is correct, not a shortcut: `claimed` is
/// only touched under `lock`.
private final class TimeoutOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
