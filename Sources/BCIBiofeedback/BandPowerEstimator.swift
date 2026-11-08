import Foundation
import BCICore

/// Per-channel band powers for one window, in linear units (µV²).
///
/// `bels(_:)` is the Mind Monitor convention: the base-10 logarithm of
/// the band power, so 0 Bel is 1 µV² and each Bel is a factor of ten.
/// Mind Monitor's own absolute values are computed from its PSD scaling
/// and will not match these numerically; what matches is the unit, the
/// band edges and the address scheme, which is all a downstream patch
/// can depend on.
public struct BandPowers: Sendable, Hashable {
    public let power: [EEGBand: Float]

    public init(power: [EEGBand: Float]) {
        self.power = power
    }

    public subscript(band: EEGBand) -> Float {
        power[band] ?? 0
    }

    /// Sum of all band powers present.
    public var total: Float {
        power.values.reduce(0, +)
    }

    /// Fraction of total band power in `band`, 0 when the total is 0.
    public func relative(_ band: EEGBand) -> Float {
        let t = total
        return t > 0 ? self[band] / t : 0
    }

    /// log10 of the band power, floored so a silent channel reads as a
    /// large negative number instead of -inf.
    public func bels(_ band: EEGBand) -> Float {
        BandPowers.bels(self[band])
    }

    public static let powerFloor: Float = 1e-9

    public static func bels(_ linearPower: Float) -> Float {
        log10(max(linearPower, powerFloor))
    }
}

/// Welch-style single-segment periodogram band power estimator.
///
/// Pure Swift, deterministic, no Accelerate: the same bytes in give the
/// same floats out on every machine, which is what the replay fixtures
/// in `BCIBiofeedbackTests` and the golden-recording regression need.
/// If this ever shows up in a profile, a vDSP path can be added behind
/// the same signature with the fixtures as its acceptance test.
///
/// Method, per channel: subtract the mean (Muse carries an ~800 µV DC
/// offset), apply a Hann window, zero-pad to the next power of two, FFT,
/// one-sided PSD scaled by `2 / (fs * sum(w^2))` so that the integral of
/// the PSD equals the signal's mean-square value, then sum the PSD bins
/// inside each band's half-open range times the bin width. A pure
/// sinusoid of amplitude A therefore reports a band power of about A²/2.
///
/// This is a different estimator from `FeatureExtractor.bandEnergies`,
/// on purpose: that one is a lag-difference proxy summed over channels
/// for the mock classifier; this one is per channel and in physical
/// units, because it is what leaves the machine.
public struct BandPowerEstimator: Sendable {

    public let bands: [EEGBand]

    public init(bands: [EEGBand] = EEGBand.allCases) {
        self.bands = bands
    }

    /// Band powers for each channel of `window`. `channels` names the
    /// window's rows in order; rows beyond `channels.count` are ignored
    /// and channels beyond the row count are omitted from the result.
    public func powers(for window: EEGWindow, channels: [EEGChannel] = EEGChannel.allCases) -> [EEGChannel: BandPowers] {
        var result: [EEGChannel: BandPowers] = [:]
        for (index, channel) in channels.enumerated() where index < window.samples.count {
            result[channel] = powers(for: window.samples[index], sampleRate: window.sampleRate)
        }
        return result
    }

    /// Band powers for one channel's samples.
    public func powers(for samples: [Float], sampleRate: Double) -> BandPowers {
        guard samples.count >= 4, sampleRate > 0 else {
            return BandPowers(power: Dictionary(uniqueKeysWithValues: bands.map { ($0, 0) }))
        }

        // Demean.
        var mean = 0.0
        for v in samples { mean += Double(v) }
        mean /= Double(samples.count)

        // Hann window and its energy.
        let n = samples.count
        var windowed = [Double](repeating: 0, count: n)
        var windowEnergy = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n - 1))
            windowed[i] = (Double(samples[i]) - mean) * w
            windowEnergy += w * w
        }

        // Zero-pad to a power of two.
        var fftSize = 1
        while fftSize < n { fftSize <<= 1 }
        var re = windowed + [Double](repeating: 0, count: fftSize - n)
        var im = [Double](repeating: 0, count: fftSize)
        BandPowerEstimator.fft(&re, &im)

        // One-sided PSD, bins 1 ... fftSize/2 - 1 (DC and Nyquist excluded;
        // DC is zero after demeaning and no band reaches Nyquist).
        let binWidth = sampleRate / Double(fftSize)
        let scale = 2.0 / (sampleRate * windowEnergy)
        var power: [EEGBand: Float] = [:]
        for band in bands {
            var acc = 0.0
            let lowBin = Int((band.lowHz / binWidth).rounded(.up))
            let highBin = Int((band.highHz / binWidth).rounded(.up))   // exclusive
            let upper = min(highBin, fftSize / 2)
            if lowBin < upper {
                for k in max(lowBin, 1)..<upper {
                    acc += (re[k] * re[k] + im[k] * im[k]) * scale
                }
            }
            power[band] = Float(acc * binWidth)
        }
        return BandPowers(power: power)
    }

    /// In-place iterative radix-2 Cooley-Tukey FFT. `re.count` must be a
    /// power of two and equal to `im.count`.
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        precondition(n == im.count && n > 0 && (n & (n - 1)) == 0, "fft size must be a power of two")

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }

        // Butterflies.
        var length = 2
        while length <= n {
            let angle = -2.0 * Double.pi / Double(length)
            let wRe = cos(angle)
            let wIm = sin(angle)
            var start = 0
            while start < n {
                var curRe = 1.0
                var curIm = 0.0
                let half = length / 2
                for k in 0..<half {
                    let a = start + k
                    let b = a + half
                    let tRe = re[b] * curRe - im[b] * curIm
                    let tIm = re[b] * curIm + im[b] * curRe
                    re[b] = re[a] - tRe
                    im[b] = im[a] - tIm
                    re[a] += tRe
                    im[a] += tIm
                    let nextRe = curRe * wRe - curIm * wIm
                    curIm = curRe * wIm + curIm * wRe
                    curRe = nextRe
                }
                start += length
            }
            length <<= 1
        }
    }
}
