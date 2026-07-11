import XCTest
@testable import BCILLM

/// `PredictorFactory.live()`'s real MLX path can fail in a way that is
/// **not** a catchable Swift `Error` — the underlying Metal/metallib load
/// can abort the whole process before `MLXNextWordPredictor.init`'s own
/// `do/catch` ever runs (confirmed by hand: a direct call used to crash
/// this very test process with "MLX error: Failed to load the default
/// metallib"). `live()` now probes that risk in a disposable child
/// process first and falls back to the stub if the probe doesn't
/// cleanly succeed — so this test's only job is confirming the whole
/// suite (i.e. *this test process*) survives calling it, regardless of
/// which way the underlying MLX load actually goes on the machine
/// running the test.
final class PredictorFactoryCrashSafetyTests: XCTestCase {

    func testLiveNeverCrashesTheCallingProcessEvenAgainstARealModelDirectory() async {
        // If Models/Qwen2.5-0.5B-Instruct-4bit isn't present on this
        // machine, this exercises the plain "no directory" path — still
        // valid coverage, just not the specific crash this test exists
        // to guard against. The interesting assertion either way is
        // simply that this line returns instead of aborting the process.
        let resolved = await PredictorFactory.live()
        XCTAssertTrue(resolved.kind == .mlx || resolved.kind == .stub)
        // Whichever kind it resolved to, the other two facets of the
        // seam must still be usable — the rest of the app (embeddings,
        // free-form generation) depends on them regardless of degraded
        // mode.
        _ = resolved.embeddingProvider
        _ = resolved.generator
    }

    func testLiveFallsBackToStubWhenPointedAtANonexistentDirectory() async {
        let resolved = await PredictorFactory.live(
            modelDirectory: URL(fileURLWithPath: "/nonexistent/PredictorFactoryCrashSafetyTests")
        )
        XCTAssertEqual(resolved.kind, .stub)
        XCTAssertNil(resolved.warning, "a missing directory is the expected default state, not a warning-worthy degradation")
    }
}
