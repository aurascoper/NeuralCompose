import XCTest
@testable import BCICore

final class BandpassFilterTests: XCTestCase {

    func testFilterPreservesShape() {
        var f = BandpassFilter(sampleRate: 256, lowHz: 1, highHz: 30, channelCount: 2)
        let n = 256
        var window: [[Float]] = [
            (0..<n).map { Float(sin(2 * .pi * 10 * Double($0) / 256)) },
            (0..<n).map { Float(cos(2 * .pi * 10 * Double($0) / 256)) }
        ]
        let filtered = f.apply(to: window)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].count, n)
        XCTAssertEqual(filtered[1].count, n)
        // The in-band 10 Hz tone should not be obliterated.
        let rmsIn  = sqrt(window[0].map { Double($0 * $0) }.reduce(0, +) / Double(n))
        let rmsOut = sqrt(filtered[0].map { Double($0 * $0) }.reduce(0, +) / Double(n))
        XCTAssertGreaterThan(rmsOut, rmsIn * 0.1, "in-band tone should pass with non-trivial energy")
    }

    func testDCComponentAttenuated() {
        var f = BandpassFilter(sampleRate: 256, lowHz: 1, highHz: 30, channelCount: 1)
        var dc: [[Float]] = [Array(repeating: 1.0, count: 1024)]
        // Process twice to let the IIR settle.
        dc = f.apply(to: dc)
        dc = f.apply(to: dc)
        let tail = Array(dc[0].suffix(256))
        let rmsTail = sqrt(tail.map { Double($0 * $0) }.reduce(0, +) / Double(tail.count))
        XCTAssertLessThan(rmsTail, 0.05, "DC should be attenuated to near zero after bandpass")
    }
}
