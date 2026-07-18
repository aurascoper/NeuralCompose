import Foundation
import CoreML
import BCICore

/// Wraps `LatentPredictor.mlpackage` (exported by
/// `WorldModel/export_coreml.py` with a FIXED batch dimension of 512,
/// matching `WorldModelMPCConfig.numCandidates`'s default). `predictBatch`
/// builds one real `[512, 32]`/`[512, 2]` `MLMultiArray` per call — NOT
/// 512 separate single-example calls, and NOT `MLArrayBatchProvider`
/// (which also dispatches N separate single-example predictions
/// internally, so it wouldn't actually solve the batching problem). This
/// mirrors what `mpc.py::score_candidates` itself does: one batched
/// forward pass per horizon step, scoring every candidate at once.
public final class WorldModelLatentPredictorModel: @unchecked Sendable {

    private let model: MLModel
    public let batchSize: Int

    public init(
        modelURL: URL,
        batchSize: Int = 512,
        latentInputFeatureName: String = "current_latent",
        actionInputFeatureName: String = "action_vector",
        outputFeatureName: String = "predicted_latent"
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw BCIError.worldModelDemoModelMissing(path: modelURL.path)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let loadURL: URL
        if modelURL.pathExtension == "mlpackage" {
            do {
                loadURL = try MLModel.compileModel(at: modelURL)
            } catch {
                throw BCIError.worldModelDemoLoadFailed(
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
            throw BCIError.worldModelDemoLoadFailed(path: modelURL.path, underlying: error.localizedDescription)
        }
        self.batchSize = batchSize
        self.latentInputFeatureName = latentInputFeatureName
        self.actionInputFeatureName = actionInputFeatureName
        self.outputFeatureName = outputFeatureName
    }

    private let latentInputFeatureName: String
    private let actionInputFeatureName: String
    private let outputFeatureName: String

    /// `latents`/`actions` must each have exactly `batchSize` rows —
    /// the export's fixed batch dimension, see this type's doc comment.
    public func predictBatch(latents: [[Float]], actions: [[Float]]) async throws -> [[Float]] {
        precondition(latents.count == batchSize && actions.count == batchSize)
        let latentDim = latents.first?.count ?? 0
        let latentArray = try latents.toBatchedMultiArray()
        let actionArray = try actions.toBatchedMultiArray()
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            latentInputFeatureName: MLFeatureValue(multiArray: latentArray),
            actionInputFeatureName: MLFeatureValue(multiArray: actionArray),
        ])
        let prediction: any MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            throw BCIError.worldModelDemoInferenceFailed(reason: error.localizedDescription)
        }
        guard let output = prediction.featureValue(for: outputFeatureName)?.multiArrayValue else {
            throw BCIError.worldModelDemoOutputShapeUnexpected(
                expected: outputFeatureName,
                actual: prediction.featureNames.joined(separator: ",")
            )
        }
        return output.toBatchedFloatArrays(count: batchSize, dim: latentDim)
    }
}
