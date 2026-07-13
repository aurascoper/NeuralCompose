import XCTest
@testable import BCILLM

final class MLXInitProbeTests: XCTestCase {

    /// Pure-logic coverage, independent of MLX hardware — always runs.
    /// `ProbeResult` is the wire format `MLXProbe --json` writes to stdout
    /// and `PredictorFactory` decodes back; a silent regression here (e.g.
    /// a field that stops round-tripping) would only show up as a mystery
    /// "probe failed, no parseable output" fallback on a real machine.
    func testProbeResultRoundTripsThroughJSONForEveryCase() throws {
        let cases: [ProbeResult] = [
            .success(ProbeMetrics(
                modelIdentifier: "Qwen2.5-0.5B-Instruct-4bit",
                modelLoadTime: 2.73,
                firstTokenLatency: 0.34,
                totalGenerateTime: 1.12,
                tokensPerSecond: 42.8,
                generatedText: "Please close your windows."
            )),
            .failed(reason: "predictorWeightsMissing"),
            .timeout,
            .crashed(signal: 6),
        ]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ProbeResult.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    // Deliberately NOT testing `MLXInitProbe.run(...)` directly here: it
    // makes a real, unprotected in-process MLX call, and under a bare
    // `swift test` binary (not Xcode-built) that can hard-crash the whole
    // test process the same way a direct `MLXNextWordPredictor.init()`
    // call always could — confirmed by hand, it took down this entire
    // suite when tried. That's exactly the risk `PredictorFactory`'s
    // subprocess isolation exists to contain: `MLXInitProbe.run` is meant
    // to be called either inside a disposable child process (the
    // `MLXProbe` binary) or from an Xcode-built context, never directly
    // from a shared process like this test runner. Real-model coverage of
    // the full safe path already exists in
    // `PredictorFactoryCrashSafetyTests`, which exercises
    // `PredictorFactory.live()` — the same `runInitProbeSubprocess` code
    // this redesign touches — through the subprocess boundary that makes
    // it safe to call from a test at all.
}
