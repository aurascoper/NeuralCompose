import XCTest
@testable import BCICore
@testable import BCIEEG
@testable import BCIClassifier
@testable import BCILLM
@testable import BCIVoice
@testable import NeuralComposeApp

final class AdaptiveGenerationRulesTests: XCTestCase {

    func testHealthyAndNilMatchRawDefault() {
        XCTAssertEqual(SignalQualityGenerationRules.adaptation(for: nil), .raw)
        XCTAssertEqual(SignalQualityGenerationRules.adaptation(for: .healthy), .raw)
    }

    func testPoorSimplifiesModerately() {
        let a = SignalQualityGenerationRules.adaptation(for: .poor)
        XCTAssertEqual(a.maxCandidates, 3)
        XCTAssertEqual(a.temperature, 0.5)
        XCTAssertFalse(a.styleInstruction.isEmpty)
    }

    func testLostSimplifiesStrongly() {
        let a = SignalQualityGenerationRules.adaptation(for: .lost)
        XCTAssertEqual(a.maxCandidates, 2)
        XCTAssertEqual(a.temperature, 0.3)
        XCTAssertFalse(a.styleInstruction.isEmpty)
    }

    /// `.lost` should never be *less* conservative than `.poor` - a
    /// worse-quality signal must not unlock a wider or hotter candidate set.
    func testLostIsAtLeastAsConservativeAsPoor() {
        let poor = SignalQualityGenerationRules.adaptation(for: .poor)
        let lost = SignalQualityGenerationRules.adaptation(for: .lost)
        XCTAssertLessThanOrEqual(lost.maxCandidates, poor.maxCandidates)
        XCTAssertLessThanOrEqual(lost.temperature, poor.temperature)
    }

    func testSignalQualityAndCalibrationMetricsSubtractMuseDCOffsetAndRejectNaN() {
        // 1. 4 channels with +820 uV Muse DC offset + 20 uV AC wave -> healthy (4 in range)
        let n = 256
        let healthyChannel: [Float] = (0..<n).map { i in
            let ac: Float = (i % 2 == 0) ? 20.0 : -20.0
            return 820.0 + ac
        }
        let healthyWindow = EEGWindow(
            samples: [healthyChannel, healthyChannel, healthyChannel, healthyChannel],
            sampleRate: 256,
            endTimestamp: 1.0,
            sequence: 1
        )
        XCTAssertEqual(AppViewModel.signalQuality(of: healthyWindow), .healthy)
        let metrics = AppViewModel.computeCalibrationMetrics(
            window: healthyWindow,
            channelLabels: ["TP9", "AF7", "AF8", "TP10"]
        )
        XCTAssertEqual(metrics.channelCount, 4)
        for i in 0..<4 {
            XCTAssertEqual(metrics.rms[i], 20.0, accuracy: 0.1)
            XCTAssertEqual(metrics.peak[i], 20.0, accuracy: 0.1)
        }

        // 2. Flat +820 uV DC on 3 channels (0 uV AC -> dead) and 1 channel with NaN -> .lost
        let flatDCChannel = Array(repeating: Float(820.0), count: n)
        var nanChannel = healthyChannel
        nanChannel[10] = .nan
        let lostWindow = EEGWindow(
            samples: [flatDCChannel, nanChannel, flatDCChannel, flatDCChannel],
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 2
        )
        XCTAssertEqual(AppViewModel.signalQuality(of: lostWindow), .lost)
        let lostMetrics = AppViewModel.computeCalibrationMetrics(
            window: lostWindow,
            channelLabels: ["TP9", "AF7", "AF8", "TP10"]
        )
        XCTAssertEqual(lostMetrics.rms[0], 0.0, accuracy: 0.01)
        XCTAssertEqual(lostMetrics.rms[2], 0.0, accuracy: 0.01)
        XCTAssertEqual(lostMetrics.rms[3], 0.0, accuracy: 0.01)
    }

    func testSignalQualityUsesDeadRMS2uVFloorMatchingChannelHealthThresholds() {
        // SyntheticEEGStream resting channels hover around 3.5-5.0 uV RMS.
        // With deadRMS = 2.0 uV (matching ChannelHealthThresholds.default),
        // a 3.5 uV AC signal on all 4 channels must be classified as .healthy,
        // whereas 1.0 uV (< 2.0 uV) is classified as .lost.
        let n = 256
        let quietHealthyChannel: [Float] = (0..<n).map { i in
            815.0 + ((i % 2 == 0) ? 3.5 : -3.5)
        }
        let quietHealthyWindow = EEGWindow(
            samples: Array(repeating: quietHealthyChannel, count: 4),
            sampleRate: 256,
            endTimestamp: 1.0,
            sequence: 1
        )
        XCTAssertEqual(AppViewModel.signalQuality(of: quietHealthyWindow), .healthy)

        let deadChannel: [Float] = (0..<n).map { i in
            815.0 + ((i % 2 == 0) ? 1.0 : -1.0)
        }
        let deadWindow = EEGWindow(
            samples: Array(repeating: deadChannel, count: 4),
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 2
        )
        XCTAssertEqual(AppViewModel.signalQuality(of: deadWindow), .lost)
    }

    func testIsGlossStuckDetectsNilAndZeroVarianceStalledStates() {
        let dummyState = SpectralState.highCognitiveLoad
        // 1. Nil state after warmup on MLX with windows flowing -> stuck
        XCTAssertTrue(AppViewModel.isGlossStuck(
            estimatorKind: "mlx",
            spectralState: nil,
            windowsPerSecond: 1.0,
            uptimeSeconds: 15.0,
            consecutiveIdenticalWindows: 0
        ))
        // 2. Non-nil state with normal variance (few consecutive identical windows) -> not stuck
        XCTAssertFalse(AppViewModel.isGlossStuck(
            estimatorKind: "mlx",
            spectralState: dummyState,
            windowsPerSecond: 1.0,
            uptimeSeconds: 30.0,
            consecutiveIdenticalWindows: 12,
            maxZeroVarianceWindows: 600
        ))
        // 3. Non-nil state pinned identically across >= maxZeroVarianceWindows -> stuck
        XCTAssertTrue(AppViewModel.isGlossStuck(
            estimatorKind: "mlx",
            spectralState: dummyState,
            windowsPerSecond: 1.0,
            uptimeSeconds: 1200.0,
            consecutiveIdenticalWindows: 600,
            maxZeroVarianceWindows: 600
        ))
        // 4. Stub estimator is never flagged as glossStuck
        XCTAssertFalse(AppViewModel.isGlossStuck(
            estimatorKind: "stub",
            spectralState: nil,
            windowsPerSecond: 1.0,
            uptimeSeconds: 1200.0,
            consecutiveIdenticalWindows: 999
        ))
    }

    func testPreprocessWindowSubstitutesBadChannelBeforeDownstreamConsumers() {
        let n = 512
        let dc: Float = 820.0
        let deadTP9 = Array(repeating: dc, count: n)
        let healthyChannel: [Float] = (0..<n).map { i in
            dc + ((i % 2 == 0) ? 25.0 : -25.0)
        }
        let rawWindow = EEGWindow(
            samples: [deadTP9, healthyChannel, healthyChannel, healthyChannel],
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 3
        )
        let cleaned = AppViewModel.preprocessWindow(rawWindow)
        // TP9 was dead (0 uV AC) and TP10 was healthy (+/-25 uV AC), so TP9 is now +/-25 uV AC.
        XCTAssertEqual(cleaned.samples[0][0], 25.0, accuracy: 1e-3)
        XCTAssertEqual(cleaned.samples[0][1], -25.0, accuracy: 1e-3)
    }

    @MainActor
    func testAppViewModelRecordWindowEvaluationAndHealthSnapshotTrackZeroVarianceAndReset() async {
        let predictorResolved = await PredictorFactory.live(modelDirectory: URL(fileURLWithPath: "/nonexistent"))
        let spectralResolved = SpectralStateEstimatorFactory.Resolved(
            estimator: StubSpectralStateEstimator(),
            kind: .mlx,
            warning: nil
        )
        let container = AppContainer(
            streamResolved: EEGStreamFactory.makeSynthetic(),
            classifierResolved: ClassifierFactory.live(),
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
        let vm = AppViewModel(container: container)
        XCTAssertEqual(vm.consecutiveIdenticalSpectralWindows, 0)
        XCTAssertNil(vm.detectedSpectralState)

        let firstState = SpectralState.allCases[0]
        let secondState = SpectralState.allCases[1]

        for _ in 0..<599 {
            vm.recordWindowEvaluation(quality: .healthy, spectral: firstState)
        }
        XCTAssertEqual(vm.consecutiveIdenticalSpectralWindows, 599)
        XCTAssertEqual(vm.detectedSpectralState, firstState)
        let snapAt599 = await vm.assembleHealthSnapshot(
            now: Date(),
            uptime: 600.0,
            windowsPerSecond: 1.0,
            expectedLive: false
        )
        XCTAssertFalse(snapAt599.glossStuck)

        // 600th identical window trips the zero-variance glossStuck detector in assembleHealthSnapshot.
        vm.recordWindowEvaluation(quality: .healthy, spectral: firstState)
        XCTAssertEqual(vm.consecutiveIdenticalSpectralWindows, 600)
        let snapAt600 = await vm.assembleHealthSnapshot(
            now: Date(),
            uptime: 600.0,
            windowsPerSecond: 1.0,
            expectedLive: false
        )
        XCTAssertTrue(snapAt600.glossStuck)
        XCTAssertEqual(snapAt600.spectralState, firstState.badgeLabel)
        XCTAssertEqual(snapAt600.signalQuality, "healthy")

        // Transitioning to a different SpectralState resets consecutiveIdenticalSpectralWindows to 1
        // and clears glossStuck on the next health snapshot.
        vm.recordWindowEvaluation(quality: .healthy, spectral: secondState)
        XCTAssertEqual(vm.consecutiveIdenticalSpectralWindows, 1)
        XCTAssertEqual(vm.detectedSpectralState, secondState)
        let snapAt601 = await vm.assembleHealthSnapshot(
            now: Date(),
            uptime: 601.0,
            windowsPerSecond: 1.0,
            expectedLive: false
        )
        XCTAssertFalse(snapAt601.glossStuck)
        XCTAssertEqual(snapAt601.spectralState, secondState.badgeLabel)

        // Nil spectral state resets consecutiveIdenticalSpectralWindows to 0.
        vm.recordWindowEvaluation(quality: .poor, spectral: nil)
        XCTAssertEqual(vm.consecutiveIdenticalSpectralWindows, 0)
        XCTAssertNil(vm.detectedSpectralState)
    }
}
