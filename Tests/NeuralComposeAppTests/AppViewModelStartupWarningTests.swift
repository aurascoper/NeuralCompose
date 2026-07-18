import XCTest
@testable import NeuralComposeApp
@testable import BCIEEG
@testable import BCICore
@testable import BCIClassifier
@testable import BCILLM
@testable import BCIVoice

/// Regression test for the privacy-banner severity fix: a one-time startup
/// substitution notice (classifier/predictor fell back at launch) must land
/// in `startupWarning`, never in `lastError` — `PrivacyIndicatorView` keys
/// its red "hard error" styling off `lastError` alone, and conflating the
/// two made a correctly-handled stand-in look like an active failure.
@MainActor
final class AppViewModelStartupWarningTests: XCTestCase {

    func testPredictorSubstitutionWarningRoutesToStartupWarningNotLastError() async throws {
        // Point PredictorFactory at a directory that exists (passes the
        // fileExists guard, so it actually attempts resolution) but isn't a
        // real model. `locateMLXProbeBinary()` looks for a sibling of
        // `CommandLine.arguments.first` — in an XCTest run that's the test
        // runner binary, never a sibling `MLXProbe` — so this deterministically
        // fails with a real, non-nil warning, without spawning any subprocess
        // or touching real MLX/metallib at all.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("startup-warning-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let predictorResolved = await PredictorFactory.live(modelDirectory: tempDir)
        XCTAssertNotNil(predictorResolved.warning, "sanity check: this path should produce a warning")
        XCTAssertEqual(predictorResolved.kind, .stub)

        let classifierResolved = ClassifierFactory.live()
        XCTAssertNil(classifierResolved.warning, "sanity check: isolate the predictor warning path")

        let container = AppContainer(
            streamResolved: EEGStreamFactory.makeSynthetic(),
            classifierResolved: classifierResolved,
            predictorResolved: predictorResolved,
            voiceOutputResolved: VoiceOutputFactory.live(),
            voiceInputResolved: VoiceInputFactory.live(overrideAvailability: false),
            voiceCommandResolved: VoiceCommandFactory.live(overrideAvailability: false),
            metrics: MetricsCollector(),
            windowingConfig: EEGWindowingConfig(
                windowSeconds: 2.0, strideSeconds: 1.0, sampleRate: 256, channelCount: 4
            )
        )
        let viewModel = AppViewModel(container: container)

        XCTAssertEqual(viewModel.startupWarning, predictorResolved.warning)
        XCTAssertNil(viewModel.lastError, "startup substitution notices must never populate lastError")
    }

    /// Regression test for a real bug: `spectralEstimatorResolved.warning`
    /// was never read anywhere in `AppViewModel`, even though the factory
    /// can populate it with a real, descriptive failure message (probe
    /// crash/timeout/init failure) — unlike every sibling subsystem
    /// (classifier/predictor/voice), whose equivalent warning does surface.
    func testSpectralEstimatorWarningRoutesToStartupWarning() async throws {
        let classifierResolved = ClassifierFactory.live()
        XCTAssertNil(classifierResolved.warning, "sanity check: isolate the spectral warning path")
        let predictorResolved = await PredictorFactory.live(modelDirectory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertNil(predictorResolved.warning, "sanity check: a genuinely-missing directory resolves to stub with no warning")

        let spectralResolved = SpectralStateEstimatorFactory.Resolved(
            estimator: StubSpectralStateEstimator(),
            kind: .stub,
            warning: "Spectral probe crashed (signal 11); using stub estimator."
        )

        let container = AppContainer(
            streamResolved: EEGStreamFactory.makeSynthetic(),
            classifierResolved: classifierResolved,
            predictorResolved: predictorResolved,
            voiceOutputResolved: VoiceOutputFactory.live(),
            voiceInputResolved: VoiceInputFactory.live(overrideAvailability: false),
            voiceCommandResolved: VoiceCommandFactory.live(overrideAvailability: false),
            metrics: MetricsCollector(),
            windowingConfig: EEGWindowingConfig(
                windowSeconds: 2.0, strideSeconds: 1.0, sampleRate: 256, channelCount: 4
            ),
            spectralEstimatorResolved: spectralResolved
        )
        let viewModel = AppViewModel(container: container)

        XCTAssertEqual(viewModel.startupWarning, spectralResolved.warning)
        XCTAssertNil(viewModel.lastError, "startup substitution notices must never populate lastError")
    }
}
