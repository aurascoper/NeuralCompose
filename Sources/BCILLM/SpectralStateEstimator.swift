import BCICore
import Foundation
import MLX
import MLXNN

/// Real, MLX-backed `SpectralStateEstimating`. Loads `Models/EEGEncoder/`,
/// rebuilds the anchor table by re-encoding `SpectralState`'s exact
/// descriptor phrases through the app's *live* `SentenceEmbedder` (never the
/// Python-exported anchor vectors — those are provenance only, per
/// `docs/evaluation/PHASE_3_6_JOINT_EMBEDDING.md`'s "Phase 4.0 note"), and
/// classifies each window by cosine similarity against those 5 anchors.
///
/// Honesty gate (construction-time, not a soft warning): refuses to load
/// unless the training run's own provenance stamp says it aligned against
/// real BGE (`target_space` starts with `"bge:"`) **and** the app's live
/// embedder is actually the real BGE (`modelID == "bge-small-en-v1.5"`, not
/// `DeterministicSentenceEmbedder`'s `"stub-hash-v1"`). Without both, the
/// encoder's output (aligned to real BGE space) would get projected against
/// anchors from an unrelated stub embedding space — a plausible-looking but
/// content-free argmax. Mirrors the Python side's own `build_anchors`
/// refusal to fabricate the text space, extended end-to-end into the
/// runtime.
public actor SpectralStateEstimator: SpectralStateEstimating {
    public nonisolated let isLive: Bool = true

    private let model: SpectralEncoderModel
    private let config: SpectralEncoderConfig
    private let anchors: [(state: SpectralState, values: [Float])]

    public init(modelDirectory: URL, sentenceEmbedder: any SentenceEmbedder) async throws {
        let config = try SpectralEncoderConfig.load(from: modelDirectory)

        guard config.isRealAnchorSpace, sentenceEmbedder.modelID == "bge-small-en-v1.5" else {
            throw BCIError.embedderMetadataInvalid(
                path: modelDirectory.path,
                reason: "untrusted anchor space (target_space=\(config.targetSpace), " +
                    "live embedder modelID=\(sentenceEmbedder.modelID)) — refusing to project " +
                    "spectral embeddings against a mismatched text space"
            )
        }

        let model = SpectralEncoderModel(
            inChannels: config.inChannels, hidden: config.hidden, outDim: config.outDim
        )

        let safetensorURLs: [URL]
        do {
            safetensorURLs = try FileManager.default
                .contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "safetensors" }
        } catch {
            throw BCIError.embedderLoadFailed(path: modelDirectory.path, underlying: error.localizedDescription)
        }
        guard !safetensorURLs.isEmpty else {
            throw BCIError.embedderModelMissing(
                path: modelDirectory.appendingPathComponent("*.safetensors").path
            )
        }
        do {
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
            throw BCIError.embedderLoadFailed(path: modelDirectory.path, underlying: error.localizedDescription)
        }

        let anchorEmbeddings = try await sentenceEmbedder.encode(config.descriptors)
        guard anchorEmbeddings.count == SpectralState.allCases.count else {
            throw BCIError.embedderOutputShapeUnexpected(
                expected: "\(SpectralState.allCases.count)", actual: "\(anchorEmbeddings.count)"
            )
        }

        self.model = model
        self.config = config
        self.anchors = Array(zip(SpectralState.allCases, anchorEmbeddings.map(\.values)))
    }

    public func estimate(window: EEGWindow) async -> SpectralState? {
        guard window.samples.count == config.inChannels,
              window.samples.first?.count == config.windowSamples else {
            return nil
        }

        // Subtract each channel's DC baseline before BOTH the artifact gate and
        // the model. Real EEG over OSC / Mind Monitor carries a large per-channel
        // offset (~800uV) that DC-free synthetic/processed training data never
        // had: left in, every raw sample exceeds SpectralArtifactGate's 150uV
        // peak threshold, so isClean rejects every window and the gloss is pinned
        // nil regardless of electrode contact; and the ~0-mean-trained encoder
        // (eeg_spectral.py band powers use scipy detrend="constant") would see
        // out-of-distribution input. This is the model-path site the 17cd373
        // amplitude-metric demean (signalQuality / FeatureExtractor / channel
        // health) did not cover.
        let centered = EEGWindow(
            samples: window.samples.map(Self.demeaned),
            sampleRate: window.sampleRate,
            endTimestamp: window.endTimestamp,
            sequence: window.sequence
        )

        guard SpectralArtifactGate.isClean(centered) else {
            return nil
        }

        // channel-major [channels][samples] -> channels-last [1, samples, channels].
        var flat = [Float]()
        flat.reserveCapacity(config.windowSamples * config.inChannels)
        for sampleIndex in 0..<config.windowSamples {
            for channelIndex in 0..<config.inChannels {
                flat.append(centered.samples[channelIndex][sampleIndex])
            }
        }
        let input = MLXArray(flat, [1, config.windowSamples, config.inChannels])
        let output = model(input)
        eval(output)
        let values = output.asArray(Float.self)
        guard values.count == config.outDim else { return nil }

        var bestState: SpectralState?
        var bestScore = -Float.infinity
        for anchor in anchors where anchor.values.count == values.count {
            var dot: Float = 0
            for i in 0..<values.count { dot += values[i] * anchor.values[i] }
            if dot > bestScore {
                bestScore = dot
                bestState = anchor.state
            }
        }
        return bestState
    }

    /// Subtract the per-channel mean (DC baseline) so the artifact gate measures
    /// AC swing and the encoder sees ~0-mean input. Mirrors FeatureExtractor's
    /// demean (Double accumulation for precision); a no-op on already-0-mean
    /// synthetic data.
    private static func demeaned(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        var sum: Double = 0
        for v in x { sum += Double(v) }
        let mean = Float(sum / Double(x.count))
        return x.map { $0 - mean }
    }
}
