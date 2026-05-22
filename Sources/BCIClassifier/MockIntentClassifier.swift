import Foundation
import BCICore

/// Deterministic, feature-driven mock classifier. Used:
///   • when `Models/IntentClassifier.mlmodelc` is missing,
///   • by unit tests so they can run on any machine,
///   • by the synthetic-mode demo so you see the carousel cycle and commit.
///
/// Strategy:
///   • RMS amplitude above `clenchThreshold` → `.jawClench`.
///   • High EMG band + sustained RMS → `.select` (corresponds to the
///     demo-burst trailing-edge pattern in SyntheticEEGStream).
///   • Strong alpha-band energy → `.singleBlink`.
///   • Otherwise → `.rest`.
///
/// Confidence is the fraction-of-max energy seen recently. This is enough to
/// drive the smoother through realistic transitions without requiring a real
/// model.
public final class MockIntentClassifier: IntentClassifying, @unchecked Sendable {

    public let isLive: Bool = false
    public let computeMode: ClassifierComputeMode = .cpuOnly

    public struct Config: Sendable {
        public var clenchThreshold: Float
        public var selectThreshold: Float
        public var blinkAlphaThreshold: Float
        public init(
            clenchThreshold: Float = 12.0,
            selectThreshold: Float = 30.0,
            blinkAlphaThreshold: Float = 7.0
        ) {
            self.clenchThreshold = clenchThreshold
            self.selectThreshold = selectThreshold
            self.blinkAlphaThreshold = blinkAlphaThreshold
        }
    }

    private let config: Config

    public init(config: Config = .init()) {
        self.config = config
    }

    public func classify(window: EEGWindow) async throws -> IntentPrediction {
        let features = FeatureExtractor.features(for: window)
        let avgRMS = features.rmsByChannel.reduce(0, +) / Float(max(features.rmsByChannel.count, 1))

        var intent: IntentClass = .rest
        var confidence: Float = 0.5
        var distribution: [IntentClass: Float] = [
            .rest:        0.6,
            .jawClench:   0.1,
            .singleBlink: 0.1,
            .doubleBlink: 0.1,
            .select:      0.1,
        ]

        // Selection: strong EMG + strong RMS = deliberate clench-and-hold.
        if features.emgEnergy > config.selectThreshold * 0.6 && avgRMS > config.selectThreshold {
            intent = .select
            confidence = min(0.95, 0.5 + features.emgEnergy / (config.selectThreshold * 2))
            distribution = [
                .rest: 0.05, .jawClench: 0.10, .singleBlink: 0.05,
                .doubleBlink: 0.05, .select: confidence
            ]
        } else if avgRMS > config.clenchThreshold {
            intent = .jawClench
            confidence = min(0.9, 0.4 + avgRMS / (config.selectThreshold * 1.5))
            distribution = [
                .rest: 0.10, .jawClench: confidence, .singleBlink: 0.05,
                .doubleBlink: 0.05, .select: 0.10
            ]
        } else if features.alphaEnergy > config.blinkAlphaThreshold {
            intent = .singleBlink
            confidence = min(0.8, 0.4 + features.alphaEnergy / 20)
            distribution = [
                .rest: 0.20, .jawClench: 0.05, .singleBlink: confidence,
                .doubleBlink: 0.10, .select: 0.05
            ]
        }
        // Normalize so distribution sums to ≈ 1.
        let sum = distribution.values.reduce(0, +)
        if sum > 0 {
            for k in distribution.keys { distribution[k] = (distribution[k] ?? 0) / sum }
        }

        return IntentPrediction(
            intent: intent,
            confidence: confidence,
            distribution: distribution,
            windowSequence: window.sequence,
            endTimestamp: window.endTimestamp
        )
    }
}
