import XCTest
import MLX
@testable import BCILLM

/// Shape/unit-norm invariants for the Swift port of
/// `Scripts/train_joint_embedding.py`'s `SpectralEncoder`, against
/// random-init weights — no model file on disk needed.
///
/// Gated behind `NEURALCOMPOSE_MLX_XCODE_BUILT`, skipped by default: calling
/// `eval()` on an MLXArray built by a plain `swift build`/`swift test`
/// binary aborts the whole process (no compiled `default.metallib` outside
/// an Xcode-built binary — the same documented gap `MLXInitProbeTests`
/// warns about, confirmed by hand here too: an earlier, ungated version of
/// this test took down the entire suite). `MLXSentenceEmbedderTests`'
/// real-model test gates on a model-directory env var for the same reason;
/// this one needs no model directory (random weights), so it gates on a
/// dedicated flag instead. Only set this when running via
/// `Scripts/build-xcode-mlx.sh`'s output.
final class SpectralEncoderModelTests: XCTestCase {

    private func requireXcodeBuilt() throws {
        guard ProcessInfo.processInfo.environment["NEURALCOMPOSE_MLX_XCODE_BUILT"] != nil else {
            throw XCTSkip("NEURALCOMPOSE_MLX_XCODE_BUILT not set — eval() would abort a plain swift test binary")
        }
    }

    func testRandomInitProducesExpectedOutputShapeAndUnitNorm() throws {
        try requireXcodeBuilt()
        let model = SpectralEncoderModel(inChannels: 4, hidden: 64, outDim: 384)
        let flat = (0..<(512 * 4)).map { Float(sin(Double($0) * 0.01)) }
        let input = MLXArray(flat, [1, 512, 4])

        let output = model(input)
        eval(output)

        XCTAssertEqual(output.shape, [1, 384])

        let values = output.asArray(Float.self)
        XCTAssertEqual(values.count, 384)
        XCTAssertTrue(values.allSatisfy(\.isFinite))

        let normSquared = values.reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertEqual(normSquared.squareRoot(), 1.0, accuracy: 1e-3)
    }

    func testDifferentOutDimProducesMatchingShape() throws {
        try requireXcodeBuilt()
        let model = SpectralEncoderModel(inChannels: 4, hidden: 32, outDim: 128)
        let flat = (0..<(512 * 4)).map { Float(cos(Double($0) * 0.02)) }
        let input = MLXArray(flat, [1, 512, 4])

        let output = model(input)
        eval(output)

        XCTAssertEqual(output.shape, [1, 128])
        let normSquared = output.asArray(Float.self).reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertEqual(normSquared.squareRoot(), 1.0, accuracy: 1e-3)
    }
}
