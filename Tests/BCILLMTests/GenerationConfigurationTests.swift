import XCTest
@testable import BCILLM

final class GenerationConfigurationTests: XCTestCase {

    // MARK: - Pure-logic coverage, always runs

    func testQwenPresetUsesChatMLEndOfTurnToken() {
        XCTAssertEqual(GenerationConfiguration.qwen.extraEOSTokens, ["<|im_end|>"])
    }

    func testGemmaPresetUsesGemmaEndOfTurnToken() {
        XCTAssertEqual(GenerationConfiguration.gemma.extraEOSTokens, ["<end_of_turn>"])
    }

    func testBackendConfigurationMatchesItsPreset() {
        XCTAssertEqual(MLXBackend.qwen.configuration, .qwen)
        XCTAssertEqual(MLXBackend.gemma.configuration, .gemma)
    }

    func testMLXBackendRawValueRoundTrips() {
        for backend in MLXBackend.allCases {
            XCTAssertEqual(MLXBackend(rawValue: backend.rawValue), backend)
        }
    }

    /// `PredictorFactory`'s env-var resolution and `MLXProbe`'s `--backend`
    /// flag both rely on `MLXBackend(rawValue:) ?? .qwen` to fall back to a
    /// known-good backend on unset/garbage input, rather than trapping —
    /// this pins that `nil`-on-garbage contract without needing to mutate
    /// `ProcessInfo.environment` from a test (shared, not test-isolated).
    func testMLXBackendRawValueRejectsUnknownInput() {
        XCTAssertNil(MLXBackend(rawValue: "phi"))
        XCTAssertNil(MLXBackend(rawValue: ""))
        XCTAssertNil(MLXBackend(rawValue: "Qwen"))  // rawValue lookup is case-sensitive by design; callers lowercase first
    }

    // Deliberately NOT testing `MLXNextWordPredictor(modelDirectory:
    // configuration: .gemma)` directly here, even guarded by a
    // `FileManager.fileExists` no-op check: once real Gemma weights are
    // present on disk (as they now are), that guard no longer skips, and a
    // direct in-process construction hits the same uncatchable "Failed to
    // load the default metallib" crash documented in
    // `MLXInitProbeTests.swift` — confirmed by hand, it took down this
    // entire suite when tried. Same reasoning as that file: real-model
    // coverage belongs behind the subprocess boundary
    // (`PredictorFactoryCrashSafetyTests`/`MLXGenerationRegressionTests`,
    // via `PredictorFactory.live()`) or an Xcode-built context (`MLXProbe
    // --backend gemma`, `GenerationEval`), never a direct call from a
    // shared process like this test runner.
}
