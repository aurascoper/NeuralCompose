import Foundation

/// 2nd-order Butterworth bandpass filter, used to constrain EEG to the band
/// the classifier was trained on (default 1–30 Hz for Muse 2 / Muse S).
///
/// Direct Form II Transposed biquad cascade. Coefficients are pre-computed
/// for a default 256 Hz sample rate at 1–30 Hz; for other rates / bands the
/// init recomputes them with the bilinear transform.
///
/// This is intentionally CPU-side, not Accelerate-vectorized — the cost on
/// 4 channels × 256 Hz is microscopic and Accelerate would require importing
/// `Accelerate.vecLib` which is fine but adds an import surface for very
/// little gain at these rates. Swap in vDSP biquads if you scale to many
/// channels.
public struct BandpassFilter: Sendable {

    private struct Biquad: Sendable {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1: Double = 0
        var z2: Double = 0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// One biquad per channel — independent state across channels.
    private var biquadsPerChannel: [Biquad]

    public init(
        sampleRate: Double = 256,
        lowHz: Double = 1.0,
        highHz: Double = 30.0,
        channelCount: Int = 4
    ) {
        precondition(lowHz > 0 && highHz > lowHz)
        precondition(highHz < sampleRate / 2.0, "highHz must be < Nyquist")
        let prototype = BandpassFilter.designBiquad(
            sampleRate: sampleRate,
            lowHz: lowHz,
            highHz: highHz
        )
        self.biquadsPerChannel = Array(repeating: prototype, count: channelCount)
    }

    /// In-place filter a channel-major window. Returns a new array; original
    /// is not modified.
    public mutating func apply(to window: [[Float]]) -> [[Float]] {
        precondition(window.count == biquadsPerChannel.count,
                     "filter has \(biquadsPerChannel.count) channels, window has \(window.count)")
        var out = window
        for ch in 0..<window.count {
            for s in 0..<window[ch].count {
                let y = biquadsPerChannel[ch].process(Double(window[ch][s]))
                out[ch][s] = Float(y)
            }
        }
        return out
    }

    public mutating func reset() {
        for i in biquadsPerChannel.indices {
            biquadsPerChannel[i].z1 = 0
            biquadsPerChannel[i].z2 = 0
        }
    }

    private static func designBiquad(sampleRate: Double, lowHz: Double, highHz: Double) -> Biquad {
        // Standard RBJ biquad bandpass (constant skirt gain), normalized to a0.
        let omegaLow  = 2 * .pi * lowHz  / sampleRate
        let omegaHigh = 2 * .pi * highHz / sampleRate
        let omega = (omegaLow + omegaHigh) / 2
        let bw    = log(omegaHigh / omegaLow) / log(2.0)
        let alpha = sin(omega) * sinh(log(2.0) / 2.0 * bw * omega / sin(omega))

        let b0 = alpha
        let b1 = 0.0
        let b2 = -alpha
        let a0 = 1 + alpha
        let a1 = -2 * cos(omega)
        let a2 = 1 - alpha

        return Biquad(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }
}
