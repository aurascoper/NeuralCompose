import Foundation
import MLX
import MLXNN

/// Metrics from a successful spectral-encoder probe. No anchor/embedder
/// involvement here deliberately — this probe's only job is "does MLX/Metal
/// load and forward-pass without crashing," the same crash risk an LLM load
/// carries regardless of model size. `outputL2Norm` (should land at ~1.0,
/// since `SpectralEncoderModel` L2-normalizes its own output) is the
/// reviewer-visible sanity signal here, playing the role
/// `ProbeMetrics.generatedText` plays for the LLM probe.
public struct SpectralProbeMetrics: Sendable, Codable, Equatable {
    public let modelLoadTime: TimeInterval
    public let forwardPassLatency: TimeInterval
    public let outputDimension: Int
    public let outputL2Norm: Float

    public init(
        modelLoadTime: TimeInterval, forwardPassLatency: TimeInterval,
        outputDimension: Int, outputL2Norm: Float
    ) {
        self.modelLoadTime = modelLoadTime
        self.forwardPassLatency = forwardPassLatency
        self.outputDimension = outputDimension
        self.outputL2Norm = outputL2Norm
    }
}

/// See `SubprocessProbe.Outcome` for the full doc on the four cases.
public typealias SpectralProbeResult = SubprocessProbe.Outcome<SpectralProbeMetrics>

/// The single implementation both `SpectralProbe` (CLI) and
/// `SpectralStateEstimatorFactory`'s subprocess probe call into — mirrors
/// `MLXInitProbe`'s role exactly. Constructs the encoder for real (no
/// mocking) and runs one forward pass against a fixed, deterministic
/// synthetic window — not live data, since this tests the runtime/hardware
/// path, not signal validity.
public enum SpectralInitProbe {
    public static func run(modelDirectory: URL) async -> SpectralProbeResult {
        let initStart = Date()
        let config: SpectralEncoderConfig
        do {
            config = try SpectralEncoderConfig.load(from: modelDirectory)
        } catch {
            return .failed(reason: String(describing: error))
        }

        let model = SpectralEncoderModel(
            inChannels: config.inChannels, hidden: config.hidden, outDim: config.outDim
        )
        do {
            let safetensorURLs = try FileManager.default
                .contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "safetensors" }
            guard !safetensorURLs.isEmpty else {
                return .failed(reason: "no .safetensors files found in \(modelDirectory.path)")
            }
            var weights: [String: MLXArray] = [:]
            for url in safetensorURLs {
                for (key, value) in try loadArrays(url: url) {
                    weights[key] = value
                }
            }
            let parameters = ModuleParameters.unflattened(weights)
            try model.update(parameters: parameters, verify: [.all])
            eval(model)
        } catch {
            return .failed(reason: String(describing: error))
        }
        let modelLoadTime = Date().timeIntervalSince(initStart)

        // Deterministic synthetic window — fixed seeded pattern, not live
        // data. This probe validates the runtime/hardware path, not signal
        // content.
        var flat = [Float](repeating: 0, count: config.windowSamples * config.inChannels)
        for i in 0..<flat.count {
            flat[i] = Float(sin(Double(i) * 0.01))
        }
        let input = MLXArray(flat, [1, config.windowSamples, config.inChannels])

        let forwardStart = Date()
        let output = model(input)
        eval(output)
        let forwardPassLatency = Date().timeIntervalSince(forwardStart)

        let values = output.asArray(Float.self)
        var sumSquares: Float = 0
        for value in values { sumSquares += value * value }

        return .success(SpectralProbeMetrics(
            modelLoadTime: modelLoadTime,
            forwardPassLatency: forwardPassLatency,
            outputDimension: values.count,
            outputL2Norm: sumSquares.squareRoot()
        ))
    }
}
