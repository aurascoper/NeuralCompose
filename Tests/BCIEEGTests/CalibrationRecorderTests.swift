import XCTest
@testable import BCICore
@testable import BCIEEG

/// Covers `CalibrationRecorder.recordTransportEvent(_:at:detail:)` —
/// the metadata-logging half of the mid-session-disconnect watchdog
/// fix (the other half is `EEGChannelHealthProvider`'s `.stale`
/// support; see `EEGChannelHealthProviderTests`) — plus the sticky-label
/// live-backfill regression added 2026-07-17 below. Window/label
/// recording had no dedicated test coverage before that.
final class CalibrationRecorderTests: XCTestCase {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalibrationRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSessionWithNoTransportEventsReportsNotDegraded() async throws {
        let recorder = CalibrationRecorder()
        let dir = try makeTempDirectory()
        try await recorder.beginSession(to: dir, profile: .synthetic)
        await recorder.finishSession()

        let metadata = try await readMetadata(sessionDir: dir, recorder: recorder)
        XCTAssertEqual(metadata["transport_degraded"] as? Bool, false)
        XCTAssertEqual(metadata["transport_event_count"] as? Int, 0)
        XCTAssertEqual(metadata["transport"] as? String, "synthetic")

        let csv = try await readTransportEventsCSV(sessionDir: dir, recorder: recorder)
        // Header only — no event rows.
        XCTAssertEqual(csv.count, 1)
        XCTAssertEqual(csv[0], "session_id,t_wallclock_epoch,event,detail")
    }

    func testTransportLabelReflectsBrainFlowProfile() async throws {
        let recorder = CalibrationRecorder()
        let dir = try makeTempDirectory()
        try await recorder.beginSession(to: dir, profile: .museSNativeBLE)
        await recorder.finishSession()

        let metadata = try await readMetadata(sessionDir: dir, recorder: recorder)
        XCTAssertEqual(metadata["transport"] as? String, "brainflow")
    }

    func testStalledEventIsWrittenAndSummarized() async throws {
        let recorder = CalibrationRecorder()
        let dir = try makeTempDirectory()
        try await recorder.beginSession(to: dir, profile: .synthetic)

        // The detail string deliberately contains a comma — recordTransportEvent
        // must escape it so the CSV's 4-column shape survives.
        await recorder.recordTransportEvent(.stalled, at: 1_000.0, detail: "retry 1/3 after 1.0s, 0 samples this attempt")
        await recorder.finishSession()

        let metadata = try await readMetadata(sessionDir: dir, recorder: recorder)
        XCTAssertEqual(metadata["transport_degraded"] as? Bool, true)
        XCTAssertEqual(metadata["transport_event_count"] as? Int, 1)

        let csv = try await readTransportEventsCSV(sessionDir: dir, recorder: recorder)
        XCTAssertEqual(csv.count, 2)
        XCTAssertTrue(csv[1].contains(",stalled,"))
        XCTAssertTrue(csv[1].contains("1000.000000"))
        XCTAssertTrue(csv[1].hasSuffix("retry 1/3 after 1.0s; 0 samples this attempt"), "comma in detail should be escaped to a semicolon; got: \(csv[1])")
        XCTAssertEqual(csv[1].split(separator: ",", omittingEmptySubsequences: false).count, 4, "escaped detail must not add a stray CSV column")
    }

    func testFullLifecycleWritesEventsInOrderAndSurvivesCommaInDetail() async throws {
        let recorder = CalibrationRecorder()
        let dir = try makeTempDirectory()
        try await recorder.beginSession(to: dir, profile: .synthetic)

        await recorder.recordTransportEvent(.stalled, at: 100.0, detail: "retry 1/3, backoff 1s")
        await recorder.recordTransportEvent(.reconnected, at: 105.0, detail: "after 1 retry")
        await recorder.recordTransportEvent(.stalled, at: 200.0, detail: "retry 1/3, backoff 1s")
        await recorder.recordTransportEvent(.fellBackToSynthetic, at: 210.0, detail: "exhausted 3 retries")
        await recorder.finishSession()

        let metadata = try await readMetadata(sessionDir: dir, recorder: recorder)
        XCTAssertEqual(metadata["transport_degraded"] as? Bool, true)
        XCTAssertEqual(metadata["transport_event_count"] as? Int, 4)

        let csv = try await readTransportEventsCSV(sessionDir: dir, recorder: recorder)
        XCTAssertEqual(csv.count, 5) // header + 4 events
        // Commas inside `detail` must not corrupt the CSV column count.
        for row in csv.dropFirst() {
            XCTAssertEqual(row.split(separator: ",", omittingEmptySubsequences: false).count, 4)
        }
        // Events appear in the order they were recorded.
        XCTAssertTrue(csv[1].contains(",stalled,"))
        XCTAssertTrue(csv[2].contains(",reconnected,"))
        XCTAssertTrue(csv[3].contains(",stalled,"))
        XCTAssertTrue(csv[4].contains(",fellBackToSynthetic,"))
    }

    /// Regression for the bug found during the first real calibration
    /// session (2026-07-17): a long, uninterrupted sticky hold (e.g. a
    /// single 30s "rest" press-and-hold) starved almost all its windows to
    /// "none" because `startStickyLabel` creates the event with
    /// `tEnd == tStart`, and nothing updated `tEnd` while the hold was
    /// still in progress — only `endStickyLabel`, called when the *next*
    /// label starts, backfilled it. Short, frequently-tapped gestures
    /// (jaw-clench "tap 20x, 1-2s apart") were fine because each tap's
    /// `startStickyLabel` call itself invokes `endStickyLabel` first,
    /// backfilling the *previous* tap every couple of seconds — only a
    /// single long hold with no intervening taps exposed this.
    func testWindowsRecordedDuringOngoingStickyHoldResolveToThatLabelNotNone() async throws {
        let recorder = CalibrationRecorder()
        let dir = try makeTempDirectory()
        try await recorder.beginSession(to: dir, profile: .synthetic)

        await recorder.startStickyLabel(.rest, at: 0.0)

        // Simulate a 10s hold: windows arriving every 1s (matching the real
        // 2s-window/1s-stride convention), all recorded *while the sticky
        // is still active* — mirrors windows landing mid-hold in a real
        // 30s+ rest block, well before the user releases [r].
        for endTimestamp in stride(from: 2.0, through: 10.0, by: 1.0) {
            let window = EEGWindow(
                samples: [[0, 0]], sampleRate: 1.0, endTimestamp: endTimestamp, sequence: UInt64(endTimestamp)
            )
            await recorder.recordWindow(window)
        }

        await recorder.endStickyLabel(at: 11.0)
        await recorder.finishSession()

        let labels = try await readLabelsCSV(sessionDir: dir, recorder: recorder)
        let dataRows = labels.dropFirst() // drop header
        XCTAssertEqual(dataRows.count, 9, "one row per recordWindow call")
        let noneRows = dataRows.filter { $0.contains(",none,") }
        XCTAssertTrue(noneRows.isEmpty, "windows recorded mid-hold must resolve to \"rest\", not \"none\" — got: \(dataRows)")
        for row in dataRows {
            XCTAssertTrue(row.contains(",rest,"), "expected every mid-hold window labeled rest, got: \(row)")
        }
    }

    // MARK: - Helpers

    private func readLabelsCSV(sessionDir: URL, recorder: CalibrationRecorder) async throws -> [String] {
        let sessionID = await recorder.sessionID
        let url = sessionDir.appendingPathComponent(sessionID).appendingPathComponent("labels.csv")
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func readMetadata(sessionDir: URL, recorder: CalibrationRecorder) async throws -> [String: Any] {
        let sessionID = await recorder.sessionID
        let url = sessionDir.appendingPathComponent(sessionID).appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func readTransportEventsCSV(sessionDir: URL, recorder: CalibrationRecorder) async throws -> [String] {
        let sessionID = await recorder.sessionID
        let url = sessionDir.appendingPathComponent(sessionID).appendingPathComponent("transport_events.csv")
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
