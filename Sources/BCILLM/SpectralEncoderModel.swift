import MLX
import MLXNN

/// Exact Swift/MLX port of `Scripts/train_joint_embedding.py`'s
/// `SpectralEncoder` — a tiny 1D-conv encoder projecting a windowed,
/// channels-last EEG buffer `[batch, samples, channels]` down to a
/// unit-norm `[batch, outDim]` embedding. Conv kernel/stride/padding values
/// and the temporal mean-pool (not flatten) are copied verbatim from the
/// Python source; weight keys after Python's `tree_flatten`
/// (`conv1.weight/bias`, `conv2.weight/bias`, ...) match
/// `ModuleParameters.unflattened` directly, so loading needs no key
/// remapping.
final class SpectralEncoderModel: Module, UnaryLayer {
    let conv1: Conv1d
    let conv2: Conv1d
    let conv3: Conv1d
    let proj: Linear

    init(inChannels: Int, hidden: Int, outDim: Int) {
        conv1 = Conv1d(inputChannels: inChannels, outputChannels: 32, kernelSize: 7, stride: 2, padding: 3)
        conv2 = Conv1d(inputChannels: 32, outputChannels: hidden, kernelSize: 5, stride: 2, padding: 2)
        conv3 = Conv1d(inputChannels: hidden, outputChannels: hidden, kernelSize: 3, stride: 2, padding: 1)
        proj = Linear(hidden, outDim)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var y = relu(conv1(x))
        y = relu(conv2(y))
        y = relu(conv3(y))
        y = mean(y, axis: 1)   // temporal mean-pool over the sequence dimension, NOT flatten
        y = proj(y)
        let norm = sqrt(sum(y * y, axis: -1, keepDims: true))
        return y / (norm + 1e-8)
    }
}
