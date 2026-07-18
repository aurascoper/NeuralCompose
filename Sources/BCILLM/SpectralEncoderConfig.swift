import BCICore
import Foundation

/// Decodes the shape/provenance metadata `Scripts/train_joint_embedding.py`
/// writes alongside `encoder.safetensors` — never hardcoded, same
/// "metadata, never guessed" discipline `MLXSentenceEmbedder` uses for
/// pooling config. Fields pulled from `config.json`:
/// `in_channels, window_samples, sample_rate, out_dim, hidden`. From
/// `metadata.json`: `target_space` (provenance stamp — `"bge:<model>"` for
/// a real run, `"random-fallback (NOT bge)"` if `--allow-fake-anchors` was
/// used) and `descriptors` (must byte-match `SpectralState.descriptor` for
/// every case, in order — the anchor table is rebuilt from these strings
/// through the app's live embedder, not loaded from Python-exported
/// vectors).
struct SpectralEncoderConfig: Sendable {
    let inChannels: Int
    let windowSamples: Int
    let sampleRate: Double
    let outDim: Int
    let hidden: Int
    let targetSpace: String
    let descriptors: [String]

    private struct ConfigJSON: Decodable {
        let in_channels: Int
        let window_samples: Int
        let sample_rate: Double
        let out_dim: Int
        let hidden: Int
    }

    private struct MetadataJSON: Decodable {
        let target_space: String
        let descriptors: [String]
    }

    static func load(from directory: URL) throws -> SpectralEncoderConfig {
        let configURL = directory.appendingPathComponent("config.json")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw BCIError.embedderModelMissing(path: configURL.path)
        }
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw BCIError.embedderModelMissing(path: metadataURL.path)
        }

        let config: ConfigJSON
        do {
            config = try JSONDecoder().decode(ConfigJSON.self, from: Data(contentsOf: configURL))
        } catch {
            throw BCIError.embedderMetadataInvalid(path: configURL.path, reason: error.localizedDescription)
        }

        let metadata: MetadataJSON
        do {
            metadata = try JSONDecoder().decode(MetadataJSON.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw BCIError.embedderMetadataInvalid(path: metadataURL.path, reason: error.localizedDescription)
        }

        guard metadata.descriptors.count == SpectralState.allCases.count,
              zip(metadata.descriptors, SpectralState.allCases).allSatisfy({ $0 == $1.descriptor }) else {
            throw BCIError.embedderMetadataInvalid(
                path: metadataURL.path,
                reason: "descriptors do not match SpectralState.allCases verbatim/in-order"
            )
        }

        return SpectralEncoderConfig(
            inChannels: config.in_channels,
            windowSamples: config.window_samples,
            sampleRate: config.sample_rate,
            outDim: config.out_dim,
            hidden: config.hidden,
            targetSpace: metadata.target_space,
            descriptors: metadata.descriptors
        )
    }

    /// The training-side honesty stamp: `true` only for a real BGE-aligned
    /// run, never for the `--allow-fake-anchors` plumbing-only escape hatch.
    /// One half of the honesty gate — the other half is checking the app's
    /// *live* embedder is also the real BGE, not the deterministic stub
    /// (see `SpectralStateEstimator.init`).
    var isRealAnchorSpace: Bool {
        targetSpace.hasPrefix("bge:")
    }
}
