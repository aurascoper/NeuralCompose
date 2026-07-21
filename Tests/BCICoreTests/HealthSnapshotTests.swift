import XCTest
@testable import BCICore

final class HealthSnapshotTests: XCTestCase {

    /// Convenience wrapper defaulting every input to a fully-live, healthy value,
    /// so each test perturbs exactly one axis.
    private func reasons(
        acquisition: String = "localMuse", expectedLive: Bool = true,
        estimator: String = "mlx", embedder: String = "coreml",
        predictor: String = "mlx", classifier: String = "coreML",
        wps: Double = 4, uptime: Double = 30,
        glossStuck: Bool = false, loopRunning: Bool = true, sinceTurn: Double? = 5
    ) -> [String] {
        HealthSnapshot.degradedReasons(
            acquisition: acquisition, expectedLive: expectedLive,
            estimatorKind: estimator, embedderKind: embedder,
            predictorKind: predictor, classifierKind: classifier,
            windowsPerSecond: wps, uptimeSeconds: uptime,
            glossStuck: glossStuck, loopRunning: loopRunning, secondsSinceLastTurn: sinceTurn)
    }

    func testFullyLiveIsHealthy() {
        XCTAssertEqual(reasons(), [])
    }

    func testSyntheticFallbackFlaggedOnlyWhenLiveExpected() {
        XCTAssertTrue(reasons(acquisition: "synthetic", expectedLive: true).contains("eeg-synthetic-fallback"))
        XCTAssertFalse(reasons(acquisition: "synthetic", expectedLive: false).contains("eeg-synthetic-fallback"),
                       "a deliberately-synthetic run is not a degradation")
    }

    func testStubBackendsEachFlagged() {
        XCTAssertTrue(reasons(estimator: "stub").contains("estimator-stub"))
        XCTAssertTrue(reasons(embedder: "stub").contains("embedder-stub"))
        XCTAssertTrue(reasons(predictor: "stub").contains("predictor-stub"))
        XCTAssertTrue(reasons(classifier: "mock").contains("classifier-mock"))
    }

    func testZeroThroughputOnlyAfterWarmupGrace() {
        XCTAssertFalse(reasons(wps: 0, uptime: 3).contains("eeg-zero-throughput"),
                       "a just-launched app hasn't produced its first window yet")
        XCTAssertTrue(reasons(wps: 0, uptime: 30).contains("eeg-zero-throughput"))
    }

    func testGlossStuckFlagged() {
        XCTAssertTrue(reasons(glossStuck: true).contains("gloss-nil-despite-live-estimator"))
    }

    func testNoTurnsFlaggedOnlyWhenRunningAndOverTimeout() {
        XCTAssertTrue(reasons(loopRunning: true, sinceTurn: 120).contains("loop-no-turns"))
        XCTAssertFalse(reasons(loopRunning: true, sinceTurn: 30).contains("loop-no-turns"))
        XCTAssertFalse(reasons(loopRunning: false, sinceTurn: 120).contains("loop-no-turns"),
                       "no turns is expected when the loop isn't running")
    }

    func testTonightsFailureIsFullyClassified() {
        // The exact live state that cost hours: synthetic fallback + stub
        // estimator + stub embedder + gloss nil — all should surface at once.
        let r = reasons(acquisition: "synthetic", estimator: "stub", embedder: "stub", glossStuck: true)
        XCTAssertTrue(r.contains("eeg-synthetic-fallback"))
        XCTAssertTrue(r.contains("estimator-stub"))
        XCTAssertTrue(r.contains("embedder-stub"))
        XCTAssertTrue(r.contains("gloss-nil-despite-live-estimator"))
    }

    func testCodableRoundTrips() throws {
        let snap = HealthSnapshot(
            timestamp: Date(timeIntervalSince1970: 1000), uptimeSeconds: 10,
            acquisition: "synthetic", transport: "none", signalQuality: "lost", windowsPerSecond: 0,
            estimatorKind: "stub", embedderKind: "coreml", predictorKind: "mlx", classifierKind: "coreML",
            fullyLive: false, substitutionSummary: "synthetic EEG",
            spectralState: nil, glossStuck: false,
            loopMode: "reflective", loopRunning: true, turnCount: 3, secondsSinceLastTurn: 2,
            degraded: ["eeg-synthetic-fallback", "estimator-stub"])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let round = try dec.decode(HealthSnapshot.self, from: enc.encode(snap))
        XCTAssertEqual(round, snap)
    }
}
