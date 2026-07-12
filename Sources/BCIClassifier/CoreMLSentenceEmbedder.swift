import BCICore
import CoreML
import Foundation

/// Core ML-backed `SentenceEmbedder` for BGE-small-en-v1.5.
///
/// `modelDirectory` (e.g. `Models/BGE-small-en-v1.5/`) is expected to
/// contain three co-located artifacts, all produced by
/// `Scripts/convert-sentence-embedder.py`:
///   • `model.mlmodelc` (or `.mlpackage`) — the converted encoder
///   • `tokenizer.json` — the model's own canonical tokenizer, parsed by
///     `WordPieceTokenizer`
///   • `metadata.json` — records which pooling strategy the conversion
///     script's self-verification step determined is correct, so that
///     choice never has to be hardcoded or fixed by a source edit
///
/// Same compute-placement discipline as `CoreMLIntentClassifier`: defaults
/// off the GPU so MLX keeps unobstructed access.
public final class CoreMLSentenceEmbedder: SentenceEmbedder, @unchecked Sendable {
    public let modelID = "bge-small-en-v1.5"
    public let version = "1"
    public let dimension = 384

    /// `"cls"` or `"mean"`, as recorded in `metadata.json`. Not part of the
    /// `SentenceEmbedder` protocol — exposed on the concrete type so
    /// `EmbeddingBench` can record it without re-parsing metadata itself.
    public let poolingDescription: String

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let pooling: PoolingStrategy
    private let inputIDsName: String
    private let attentionMaskName: String
    private let outputFeatureName: String

    private enum PoolingStrategy: String {
        case cls
        case mean
    }

    public init(
        modelDirectory: URL,
        computeMode: ClassifierComputeMode = .cpuAndNeuralEngine,
        inputIDsName: String = "input_ids",
        attentionMaskName: String = "attention_mask",
        outputFeatureName: String = "last_hidden_state"
    ) throws {
        let metadataURL = modelDirectory.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw BCIError.embedderModelMissing(path: modelDirectory.path)
        }
        let metadata: ModelMetadata
        do {
            let data = try Data(contentsOf: metadataURL)
            metadata = try JSONDecoder().decode(ModelMetadata.self, from: data)
        } catch {
            throw BCIError.embedderMetadataInvalid(
                path: metadataURL.path,
                reason: error.localizedDescription
            )
        }
        guard metadata.dimension == 384 else {
            throw BCIError.embedderMetadataInvalid(
                path: metadataURL.path,
                reason: "expected dimension 384, metadata says \(metadata.dimension)"
            )
        }
        guard let resolvedPooling = PoolingStrategy(rawValue: metadata.pooling) else {
            throw BCIError.embedderMetadataInvalid(
                path: metadataURL.path,
                reason: "pooling must be 'cls' or 'mean', got '\(metadata.pooling)'"
            )
        }
        self.pooling = resolvedPooling
        self.poolingDescription = metadata.pooling

        let tokenizerURL = modelDirectory.appendingPathComponent(metadata.tokenizer)
        self.tokenizer = try WordPieceTokenizer(tokenizerJSONURL: tokenizerURL)

        let mlpackageURL = modelDirectory.appendingPathComponent("model.mlpackage")
        let mlmodelcURL = modelDirectory.appendingPathComponent("model.mlmodelc")
        let modelURL: URL
        if FileManager.default.fileExists(atPath: mlmodelcURL.path) {
            modelURL = mlmodelcURL
        } else if FileManager.default.fileExists(atPath: mlpackageURL.path) {
            modelURL = mlpackageURL
        } else {
            throw BCIError.embedderModelMissing(path: modelDirectory.path)
        }

        let config = MLModelConfiguration()
        config.computeUnits = CoreMLIntentClassifier.translate(computeMode)
        config.allowLowPrecisionAccumulationOnGPU = false

        let loadURL: URL
        if modelURL.pathExtension == "mlpackage" {
            do {
                loadURL = try MLModel.compileModel(at: modelURL)
            } catch {
                throw BCIError.embedderLoadFailed(
                    path: modelURL.path,
                    underlying: "compileModel: \(error.localizedDescription)"
                )
            }
        } else {
            loadURL = modelURL
        }

        do {
            self.model = try MLModel(contentsOf: loadURL, configuration: config)
        } catch {
            throw BCIError.embedderLoadFailed(path: modelURL.path, underlying: error.localizedDescription)
        }

        self.inputIDsName = inputIDsName
        self.attentionMaskName = attentionMaskName
        self.outputFeatureName = outputFeatureName
    }

    public func encode(_ texts: [String]) async throws -> [Embedding] {
        var results: [Embedding] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await embed(text))
        }
        return results
    }

    // MARK: - Per-text inference

    private func embed(_ text: String) async throws -> Embedding {
        let (inputIDs, attentionMask, _) = tokenizer.tokenize(text)
        let provider = try makeFeatureProvider(inputIDs: inputIDs, attentionMask: attentionMask)

        let prediction: any MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            throw BCIError.embedderInferenceFailed(reason: error.localizedDescription)
        }

        guard let hiddenStates = prediction.featureValue(for: outputFeatureName)?.multiArrayValue else {
            throw BCIError.embedderOutputShapeUnexpected(
                expected: outputFeatureName,
                actual: prediction.featureNames.joined(separator: ",")
            )
        }
        guard hiddenStates.shape.count == 3, hiddenStates.shape[2].intValue == dimension else {
            throw BCIError.embedderOutputShapeUnexpected(
                expected: "[1, seq, \(dimension)]",
                actual: hiddenStates.shape.map { "\($0)" }.joined(separator: ",")
            )
        }

        let pooled = pool(hiddenStates: hiddenStates, attentionMask: attentionMask)
        let values = Self.l2Normalized(pooled) ?? Self.axisUnitVector(dimension: dimension)

        return Embedding(values: values, modelID: modelID, dimension: dimension, version: version, seed: 0)
    }

    private func makeFeatureProvider(inputIDs: [Int32], attentionMask: [Int32]) throws -> MLDictionaryFeatureProvider {
        let sequenceLength = inputIDs.count
        let idsArray = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32)
        let maskArray = try MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32)
        let idsPointer = idsArray.dataPointer.assumingMemoryBound(to: Int32.self)
        let maskPointer = maskArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<sequenceLength {
            idsPointer[i] = inputIDs[i]
            maskPointer[i] = attentionMask[i]
        }
        return try MLDictionaryFeatureProvider(dictionary: [
            inputIDsName: MLFeatureValue(multiArray: idsArray),
            attentionMaskName: MLFeatureValue(multiArray: maskArray),
        ])
    }

    /// CLS = index-0 extraction; mean = attention-mask-weighted average over
    /// real (non-padding) tokens. Which one runs is decided entirely by
    /// `metadata.json`, never hardcoded.
    private func pool(hiddenStates: MLMultiArray, attentionMask: [Int32]) -> [Float] {
        let sequenceLength = hiddenStates.shape[1].intValue
        let hiddenSize = hiddenStates.shape[2].intValue
        let pointer = hiddenStates.dataPointer.assumingMemoryBound(to: Float32.self)

        switch pooling {
        case .cls:
            var vector = [Float](repeating: 0, count: hiddenSize)
            for h in 0..<hiddenSize { vector[h] = pointer[h] }
            return vector
        case .mean:
            var sum = [Float](repeating: 0, count: hiddenSize)
            var count: Float = 0
            for t in 0..<sequenceLength where attentionMask[t] == 1 {
                let base = t * hiddenSize
                for h in 0..<hiddenSize { sum[h] += pointer[base + h] }
                count += 1
            }
            guard count > 0 else { return sum }
            return sum.map { $0 / count }
        }
    }

    // MARK: - Numeric helpers

    private static func l2Normalized(_ v: [Float]) -> [Float]? {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 1e-6 else { return nil }
        return v.map { $0 / norm }
    }

    private static func axisUnitVector(dimension: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[0] = 1
        return v
    }
}

/// `metadata.json` schema written by `Scripts/convert-sentence-embedder.py`.
private struct ModelMetadata: Decodable {
    let model: String
    let revision: String
    let pooling: String
    let dimension: Int
    let tokenizer: String
    let convertedWith: String

    enum CodingKeys: String, CodingKey {
        case model, revision, pooling, dimension, tokenizer
        case convertedWith = "converted_with"
    }
}
