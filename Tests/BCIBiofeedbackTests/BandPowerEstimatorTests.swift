import XCTest
import BCICore
@testable import BCIBiofeedback

/// Physical-unit checks on the periodogram. A sinusoid of amplitude A has
/// mean-square A²/2; with the `2 / (fs * sum(w²))` Hann scaling the band
/// containing it must report that figure, and every other band must be
/// close to zero. These numbers were cross-checked against an
/// independent reimplementation before the tolerances were set.
final class BandPowerEstimatorTests: XCTestCase {

    private let sampleRate = 256.0

    private func sinusoid(hz: Double, amplitude: Float, offset: Float = 800, count: Int = 256) -> [Float] {
        (0..<count).map { i in
            offset + amplitude * Float(sin(2.0 * Double.pi * hz * Double(i) / sampleRate))
        }
    }

    func testTenHertzSinusoidLandsInAlphaWithAmplitudeSquaredOverTwo() {
        let powers = BandPowerEstimator().powers(for: sinusoid(hz: 10, amplitude: 20), sampleRate: sampleRate)
        XCTAssertEqual(powers[.alpha], 200, accuracy: 4, "A²/2 for A = 20 µV")
        for band in EEGBand.allCases where band != .alpha {
            XCTAssertLessThan(powers[band], 1, "\(band) should carry almost no power")
        }
    }

    func testOffBinFrequencyStaysInsideItsBand() {
        // 10.3 Hz is not bin-centred; Hann leakage must stay within alpha.
        let powers = BandPowerEstimator().powers(for: sinusoid(hz: 10.3, amplitude: 20), sampleRate: sampleRate)
        XCTAssertEqual(powers[.alpha], 200, accuracy: 6)
        XCTAssertLessThan(powers[.theta] + powers[.beta], 1)
    }

    func testSixHertzSinusoidLandsInTheta() {
        let powers = BandPowerEstimator().powers(for: sinusoid(hz: 6, amplitude: 10), sampleRate: sampleRate)
        XCTAssertEqual(powers[.theta], 50, accuracy: 1.5)
        XCTAssertLessThan(powers[.alpha], 0.5)
    }

    func testDCOffsetIsRemoved() {
        let powers = BandPowerEstimator().powers(for: [Float](repeating: 812.5, count: 256), sampleRate: sampleRate)
        XCTAssertEqual(powers.total, 0, accuracy: 1e-6)
    }

    func testNonPowerOfTwoWindowIsZeroPadded() {
        let powers = BandPowerEstimator().powers(for: sinusoid(hz: 10, amplitude: 20, count: 200), sampleRate: sampleRate)
        XCTAssertEqual(powers[.alpha], 200, accuracy: 12, "zero padding keeps scale within a few percent")
    }

    func testTooShortWindowYieldsZeros() {
        let powers = BandPowerEstimator().powers(for: [1, 2, 3], sampleRate: sampleRate)
        XCTAssertEqual(powers.total, 0)
        XCTAssertEqual(powers.power.count, EEGBand.allCases.count)
    }

    func testWindowMapsRowsToChannelsInOrder() {
        let window = EEGWindow(
            samples: [
                sinusoid(hz: 10, amplitude: 20),
                sinusoid(hz: 20, amplitude: 20),
                sinusoid(hz: 6, amplitude: 20),
                sinusoid(hz: 35, amplitude: 20),
            ],
            sampleRate: sampleRate,
            endTimestamp: 1,
            sequence: 0
        )
        let powers = BandPowerEstimator().powers(for: window)
        XCTAssertEqual(powers[.tp9]?[.alpha] ?? 0, 200, accuracy: 4)
        XCTAssertEqual(powers[.af7]?[.beta] ?? 0, 200, accuracy: 4)
        XCTAssertEqual(powers[.af8]?[.theta] ?? 0, 200, accuracy: 4)
        XCTAssertEqual(powers[.tp10]?[.gamma] ?? 0, 200, accuracy: 4)
    }

    func testFewerRowsThanChannelsOmitsMissingChannels() {
        let window = EEGWindow(samples: [sinusoid(hz: 10, amplitude: 20)], sampleRate: sampleRate, endTimestamp: 1, sequence: 0)
        let powers = BandPowerEstimator().powers(for: window)
        XCTAssertEqual(Set(powers.keys), [.tp9])
    }

    func testBelsAndRelative() {
        let powers = BandPowers(power: [.alpha: 100, .beta: 10, .theta: 0])
        XCTAssertEqual(powers.bels(.alpha), 2, accuracy: 1e-6)
        XCTAssertEqual(powers.bels(.beta), 1, accuracy: 1e-6)
        XCTAssertEqual(powers.bels(.theta), log10(BandPowers.powerFloor), accuracy: 1e-6, "floored, not -inf")
        XCTAssertEqual(powers.relative(.alpha), 100.0 / 110.0, accuracy: 1e-6)
        XCTAssertEqual(powers.relative(.delta), 0)
    }

    func testFFTMatchesNaiveDFTOnRandomInput() {
        var generator = SystemRandomNumberGenerator()
        let n = 64
        let input = (0..<n).map { _ in Double.random(in: -1...1, using: &generator) }
        var re = input
        var im = [Double](repeating: 0, count: n)
        BandPowerEstimator.fft(&re, &im)
        for k in 0..<n {
            var sumRe = 0.0
            var sumIm = 0.0
            for t in 0..<n {
                let angle = -2.0 * Double.pi * Double(k * t) / Double(n)
                sumRe += input[t] * cos(angle)
                sumIm += input[t] * sin(angle)
            }
            XCTAssertEqual(re[k], sumRe, accuracy: 1e-9)
            XCTAssertEqual(im[k], sumIm, accuracy: 1e-9)
        }
    }
}
