import XCTest
@testable import BCILLM
@testable import BCICore

final class SpectralStateEstimatorFactoryTests: XCTestCase {

    func testMissingDirectoryFallsBackToStubWithNoWarning() async {
        let resolved = await SpectralStateEstimatorFactory.live(
            modelDirectory: URL(fileURLWithPath: "/nonexistent/SpectralStateEstimatorFactoryTests"),
            sentenceEmbedder: DeterministicSentenceEmbedder()
        )
        XCTAssertEqual(resolved.kind, .stub)
        XCTAssertNil(resolved.warning, "a missing directory is the expected default state, not a warning-worthy degradation")
        XCTAssertFalse(resolved.estimator.isLive)
    }

    func testStubEstimatorIsNeverLiveAndAlwaysReturnsNil() async {
        let estimator = StubSpectralStateEstimator()
        XCTAssertFalse(estimator.isLive)
        let window = EEGWindow(
            samples: Array(repeating: Array(repeating: Float(1.0), count: 512), count: 4),
            sampleRate: 256, endTimestamp: 0, sequence: 0
        )
        let result = await estimator.estimate(window: window)
        XCTAssertNil(result)
    }
}
