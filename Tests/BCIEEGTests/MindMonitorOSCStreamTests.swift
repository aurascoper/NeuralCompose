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

    /// A non-EEG message the decoder maps to `nil` (ignored, not a sample) —
    /// used to keep the packet link "alive" while `/muse/eeg` has stopped.
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
        let outcome = await withTimeout(seconds: 3) { await collectTask.value }
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
        let outcome = await withTimeout(seconds: 5) { await collectTask.value }
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

        let movement = (await withTimeout(seconds: 3) { await movementTask.value }) ?? nil
        _ = await withTimeout(seconds: 3) { await eegTask.value }
        await stream.stop()

        XCTAssertEqual(movement?.kind, .accel, "an accel packet must be yielded on the movement channel")
        let diag = stream.currentDiagnostics()
        XCTAssertGreaterThanOrEqual(diag.movementYielded, 1)
        XCTAssertGreaterThanOrEqual(diag.samplesYielded, 1)
        XCTAssertEqual(diag.packetsDropped, 0,
                       "H2: /muse/acc must not inflate packetsDropped — it's movement, not loss")
    }

    /// Races `operation` against a timeout, returning `nil` on timeout
    /// instead of hanging the test indefinitely if the watchdog regresses.
    private func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
