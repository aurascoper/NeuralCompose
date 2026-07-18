import XCTest
@testable import WorldModelDemo

final class MLMultiArrayBridgingTests: XCTestCase {
    func testFlatArrayRoundTrip() throws {
        let flat: [Float] = [1, 2, 3, 4, 5, 6]
        let array = try flat.toMultiArray(shape: [2, 3])
        XCTAssertEqual(array.toFloatArray(), flat)
    }

    func testBatchedArrayRoundTrip() throws {
        let batch: [[Float]] = [[1, 2], [3, 4], [5, 6]]
        let array = try batch.toBatchedMultiArray()
        let roundTripped = array.toBatchedFloatArrays(count: 3, dim: 2)
        XCTAssertEqual(roundTripped, batch)
    }
}
