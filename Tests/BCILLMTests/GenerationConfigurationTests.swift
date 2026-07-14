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

    // MARK: - Hardware-optional: real Gemma weights, if present locally

    /// Follows the same idiom as `MLXGenerationRegressionTests`: no-op if
    /// the model directory isn't present on this machine (Gemma weights
    /// aren't checked into the repo and are a manual download step — see
    /// `Models/README.md`).
    func testGemmaBackendProducesWellFormedGeneration() async throws {
        let modelDirectory = URL(fileURLWithPath: "Models/gemma-3n-E2B-it-lm-4bit")
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else { return }

        let predictor = try await MLXNextWordPredictor(
            modelDirectory: modelDirectory, configuration: .gemma
        )
        let output = try await predictor.generate(
            prompt: "Say the word no", maxTokens: 120, temperature: 0.7, cancellationID: UUID()
        )
        XCTAssertFalse(output.isEmpty)
    }
}
