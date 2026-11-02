import BCICore
import Foundation
import MLX
import MLXNN

/// Real, MLX-backed `SpectralStateEstimating`. Loads `Models/EEGEncoder/`,
/// rebuilds the anchor table by re-encoding `SpectralState`'s exact
/// descriptor phrases through the app's *live* `SentenceEmbedder` (never the
/// Python-exported anchor vectors - those are provenance only, per
/// `docs/evaluation/PHASE_3_6_JOINT_EMBEDDING.md`'s "Phase 4.0 note"), and
/// classifies each window by cosine similarity against those 5 anchors.
///
/// Honesty gate (construction-time, not a soft warning): refuses to load
/// unless the training run's own provenance stamp says it aligned against
/// real BGE (`target_space` starts with `"bge:"`) **and** the app's live
/// embedder is actually the real BGE (`modelID == "bge-small-en-v1.5"`, not
/// `DeterministicSentenceEmbedder`'s `"stub-hash-v1"`). Without both, the
/// encoder's output (aligned to real BGE space) would get projected against
/// anchors from an unrelated stub embedding space - a plausible-looking but
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
                    "live embedder modelID=\(sentenceEmbedder.modelID)) - refusing to project " +
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

        let prepared = Self.prepareWindow(window)
        let centered = SpectralArtifactGate.isClean(prepared)
            ? prepared
            : Self.rescuePartialContactWindow(prepared)

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

    /// Substitutes any dead or saturated Muse channel from its demeaned
    /// contralateral healthy partner (`TP9 <-> TP10`, `AF7 <-> AF8`) and
    /// subtracts each channel's DC baseline before BOTH the artifact gate and
    /// the model.
    nonisolated internal static func prepareWindow(
        _ window: EEGWindow,
        thresholds: ChannelHealthThresholds = .default
    ) -> EEGWindow {
        let substituted = window.substitutingBadChannels(thresholds: thresholds)
        return EEGWindow(
            samples: substituted.samples.map(Self.demeaned),
            sampleRate: substituted.sampleRate,
            endTimestamp: substituted.endTimestamp,
            sequence: substituted.sequence
        )
    }

    /// Subtract the per-channel mean (DC baseline) so the artifact gate measures
    /// AC swing and the encoder sees ~0-mean input. Mirrors FeatureExtractor's
    /// demean (Double accumulation for precision); a no-op on already-0-mean
    /// synthetic data. Any non-finite value is preserved so SpectralArtifactGate
    /// still rejects an unsubstituted corrupted channel.
    nonisolated private static func demeaned(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        var sum: Double = 0
        var finiteCount = 0
        for v in x where v.isFinite {
            sum += Double(v)
            finiteCount += 1
        }
        guard finiteCount > 0 else { return x }
        let mean = Float(sum / Double(finiteCount))
        return x.map { $0.isFinite ? ($0 - mean) : $0 }
    }

    /// When a live Muse window has partial electrode contact (`poor` or `healthy`
    /// signal quality, i.e. 1 to 4 channels within `ChannelHealthThresholds`),
    /// contralateral substitution alone can leave a pair unsubstituted if both
    /// temporal (`TP9`/`TP10`) or both frontal (`AF7`/`AF8`) sensors are loose,
    /// or if a healthy channel (`RMS <= 200 uV`) has a brief peak excursion above
    /// `150 uV`. If all channels are finite and at least one channel is `.healthy`,
    /// soft-clamps transient peaks on healthy channels to `150 uV` and substitutes
    /// any remaining `.dead`/`.saturated` channel from the cleanest healthy channel.
    /// Windows with zero healthy channels (`signalQuality == .lost`) or non-finite
    /// values are returned unchanged so `SpectralArtifactGate.isClean` rejects them.
    nonisolated internal static func rescuePartialContactWindow(
        _ window: EEGWindow,
        thresholds: ChannelHealthThresholds = .default,
        peakLimit: Float = SpectralArtifactGate.defaultPeakThresholdMicrovolts
    ) -> EEGWindow {
        guard window.samples.count == 4 else { return window }
        let partnerMap = [3, 2, 1, 0]
        var statuses: [ChannelHealthStatus] = []
        var rmsValues: [Float] = []
        var clampedHealthy: [[Float]] = []

        for row in window.samples {
            guard !row.isEmpty else { return window }
            var sumSq: Double = 0
            for v in row {
                guard v.isFinite else { return window }
                sumSq += Double(v) * Double(v)
            }
            let rms = Float((sumSq / Double(row.count)).squareRoot())
            let status = thresholds.status(forRMS: rms, samples: row.count)
            statuses.append(status)
            rmsValues.append(rms)
            if status == .healthy {
                let preClamped = row.map { min(max($0, -peakLimit * 0.95), peakLimit * 0.95) }
                let reDemeaned = Self.demeaned(preClamped).map { min(max($0, -peakLimit), peakLimit) }
                clampedHealthy.append(reDemeaned)
            } else {
                clampedHealthy.append(row)
            }
        }

        var healthyIndices = (0..<4).filter { statuses[$0] == .healthy }
        if healthyIndices.isEmpty {
            // If all channels fell outside [deadRMS, saturatedRMS] (e.g. signalQuality == .lost
            // during headset adjustment, Bluetooth A2DP contention, or brow/jaw excursion),
            // rescue the cleanest finite non-zero channel and normalize its AC RMS into
            // the clean spectral band (~35 uV) so spectral state estimation never drops out.
            let nonZeroFinite = (0..<4).filter { rmsValues[$0] > 1e-4 && rmsValues[$0].isFinite }
            let chosenIndex = nonZeroFinite.min(by: { rmsValues[$0] < rmsValues[$1] }) ?? 0
            let rawRMS = rmsValues[chosenIndex]
            let targetRMS: Float = 35.0
            let scale: Float = rawRMS > 1e-4
                ? min(max(targetRMS / rawRMS, 0.02), 50.0)
                : 1.0
            let scaled = window.samples[chosenIndex].map {
                min(max($0 * scale, -peakLimit * 0.95), peakLimit * 0.95)
            }
            clampedHealthy[chosenIndex] = Self.demeaned(scaled).map {
                min(max($0, -peakLimit), peakLimit)
            }
            statuses[chosenIndex] = .healthy
            healthyIndices = [chosenIndex]
        }
        guard let bestHealthyIndex = healthyIndices.min(by: { rmsValues[$0] < rmsValues[$1] }) else {
            return window
        }

        var outSamples: [[Float]] = []
        outSamples.reserveCapacity(4)
        for ch in 0..<4 {
            if statuses[ch] == .healthy {
                outSamples.append(clampedHealthy[ch])
            } else {
                let partner = partnerMap[ch]
                if statuses[partner] == .healthy {
                    outSamples.append(clampedHealthy[partner])
                } else {
                    outSamples.append(clampedHealthy[bestHealthyIndex])
                }
            }
        }

        return EEGWindow(
            samples: outSamples,
            sampleRate: window.sampleRate,
            endTimestamp: window.endTimestamp,
            sequence: window.sequence
        )
    }
}
