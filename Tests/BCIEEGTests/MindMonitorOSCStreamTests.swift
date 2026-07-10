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

        // One address this decoder doesn't map (dropped, not fatal), then
        // one valid EEG packet.
        var accPacket = oscString("/muse/acc")
        accPacket.append(oscString(",fff"))
        for v: Float in [0.1, 0.2, 0.3] {
            var bits = v.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { accPacket.append(contentsOf: $0) }
        }
        await sendUDP(accPacket, port: testPort + 1)
        await sendUDP(makeEEGPacket([10, 20, 30, 40]), port: testPort + 1)

        _ = try await collectTask.value
        await stream.stop()

        let diagnostics = stream.currentDiagnostics()
        XCTAssertEqual(diagnostics.transport, "OSC (Mind Monitor)")
        XCTAssertGreaterThanOrEqual(diagnostics.packetsReceived, 2)
        XCTAssertGreaterThanOrEqual(diagnostics.packetsDropped, 1) // the /muse/acc packet
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
}
