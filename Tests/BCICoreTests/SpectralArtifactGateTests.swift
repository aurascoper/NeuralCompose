import XCTest
@testable import BCICore

final class SpectralArtifactGateTests: XCTestCase {

    private func window(_ samples: [[Float]]) -> EEGWindow {
        EEGWindow(samples: samples, sampleRate: 256, endTimestamp: 0, sequence: 0)
    }

    func testCleanWindowPasses() {
        let w = window(Array(repeating: Array(repeating: Float(10.0), count: 512), count: 4))
        XCTAssertTrue(SpectralArtifactGate.isClean(w))
    }

    func testPlantedSampleJustOverThresholdRejects() {
        var samples = Array(repeating: Array(repeating: Float(10.0), count: 512), count: 4)
        samples[2][100] = 151.0
        XCTAssertFalse(SpectralArtifactGate.isClean(window(samples)))
    }

    func testPlantedSampleJustOverThresholdNegativeRejects() {
        var samples = Array(repeating: Array(repeating: Float(10.0), count: 512), count: 4)
        samples[0][0] = -151.0
        XCTAssertFalse(SpectralArtifactGate.isClean(window(samples)))
    }

    func testExactlyAtThresholdPasses() {
        var samples = Array(repeating: Array(repeating: Float(10.0), count: 512), count: 4)
        samples[1][50] = 150.0
        XCTAssertTrue(SpectralArtifactGate.isClean(window(samples)))
    }

    func testEmptyWindowRejects() {
        XCTAssertFalse(SpectralArtifactGate.isClean(window([])))
    }

    func testCustomThresholdIsRespected() {
        let w = window(Array(repeating: Array(repeating: Float(50.0), count: 512), count: 4))
        XCTAssertFalse(SpectralArtifactGate.isClean(w, thresholdMicrovolts: 10.0))
        XCTAssertTrue(SpectralArtifactGate.isClean(w, thresholdMicrovolts: 100.0))
    }
}
