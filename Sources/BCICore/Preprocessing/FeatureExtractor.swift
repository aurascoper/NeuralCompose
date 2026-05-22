import Foundation

/// Cheap, deterministic features used by the mock classifier *and* exposed to
/// the metrics view so you can see what the pipeline is "seeing" without
/// needing a trained model.
///
/// The real Core ML classifier consumes the raw window directly — these
/// features exist for the mock path and for explainability.
public struct EEGFeatures: Sendable, Hashable {
    /// Per-channel RMS amplitude.
    public let rmsByChannel: [Float]
    /// Per-channel zero-crossing count.
    public let zeroCrossingsByChannel: [Int]
    /// Aggregated band energies, summed across channels.
    public let deltaEnergy: Float      // ~1-4 Hz
    public let thetaEnergy: Float      // ~4-8 Hz
    public let alphaEnergy: Float      // ~8-13 Hz
    public let betaEnergy: Float       // ~13-30 Hz
    /// "EMG-like" high-frequency energy, used by mock to detect jaw clenches.
    public let emgEnergy: Float        // ~25 Hz+

    public init(
        rmsByChannel: [Float],
        zeroCrossingsByChannel: [Int],
        deltaEnergy: Float,
        thetaEnergy: Float,
        alphaEnergy: Float,
        betaEnergy: Float,
        emgEnergy: Float
    ) {
        self.rmsByChannel = rmsByChannel
        self.zeroCrossingsByChannel = zeroCrossingsByChannel
        self.deltaEnergy = deltaEnergy
        self.thetaEnergy = thetaEnergy
        self.alphaEnergy = alphaEnergy
        self.betaEnergy = betaEnergy
        self.emgEnergy = emgEnergy
    }
}

public enum FeatureExtractor {

    public static func features(for window: EEGWindow) -> EEGFeatures {
        let rms  = window.samples.map(rmsOf)
        let zcs  = window.samples.map(zeroCrossingsOf)
        let bands = bandEnergies(window: window)
        return EEGFeatures(
            rmsByChannel: rms,
            zeroCrossingsByChannel: zcs,
            deltaEnergy: bands.delta,
            thetaEnergy: bands.theta,
            alphaEnergy: bands.alpha,
            betaEnergy: bands.beta,
            emgEnergy: bands.emg
        )
    }

    private static func rmsOf(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var acc: Double = 0
        for v in x { acc += Double(v) * Double(v) }
        return Float((acc / Double(x.count)).squareRoot())
    }

    private static func zeroCrossingsOf(_ x: [Float]) -> Int {
        guard x.count > 1 else { return 0 }
        var count = 0
        for i in 1..<x.count {
            if (x[i-1] >= 0) != (x[i] >= 0) { count += 1 }
        }
        return count
    }

    private struct Bands { let delta, theta, alpha, beta, emg: Float }

    /// Naive band energy via Goertzel-style proxy: not a real FFT, but for
    /// the mock path we don't need precision — just monotonic differentiation
    /// between EEG bands and high-frequency EMG. Good enough to drive a
    /// "muscle-vs-not" rule.
    private static func bandEnergies(window: EEGWindow) -> Bands {
        // Approximate band energy by RMS of a moving-average residual at
        // different lags. Lag = sampleRate / centerHz / 2.
        let sr = window.sampleRate
        let centers: [(name: String, hz: Double)] = [
            ("delta", 2.5), ("theta", 6.0), ("alpha", 10.0), ("beta", 20.0), ("emg", 40.0)
        ]
        var energies = [String: Float]()
        for c in centers {
            let lag = max(1, Int((sr / c.hz / 2.0).rounded()))
            var sum: Double = 0
            var n = 0
            for ch in window.samples {
                if ch.count <= lag { continue }
                for i in lag..<ch.count {
                    let d = Double(ch[i] - ch[i - lag])
                    sum += d * d
                    n += 1
                }
            }
            let e = n > 0 ? Float((sum / Double(n)).squareRoot()) : 0
            energies[c.name] = e
        }
        return Bands(
            delta: energies["delta"] ?? 0,
            theta: energies["theta"] ?? 0,
            alpha: energies["alpha"] ?? 0,
            beta:  energies["beta"]  ?? 0,
            emg:   energies["emg"]   ?? 0
        )
    }
}
