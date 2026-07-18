import Foundation
import CoreML
import BCICore

/// Wraps one of the two encoder `.mlpackage`s exported by
/// `WorldModel/export_coreml.py` — instantiate twice: once at
/// `Encoder.mlpackage` (the live/current state, matching `mpc.py`'s
/// online `encoder`) and once at `GoalEncoder.mlpackage` (the goal state,
/// matching `mpc.py`'s `target_encoder`). These are architecturally
/// identical but have different learned weights — `mpc.py`'s own module
/// docstring warns that mixing them up is an easy mistake, so callers
/// must keep the two instances distinct (see `WorldModelDemoFactory`).
///
/// Shape mirrors `CoreMLIntentClassifier`: `MLModelConfiguration`,
/// compile-`.mlpackage`-on-first-load via `MLModel.compileModel(at:)`,
/// throwing init, never crashes.
public final class WorldModelStateEncoderModel: @unchecked Sendable {

    private let model: MLModel
    private let inputFeatureName: String
    private let outputFeatureName: String

    public init(
        modelURL: URL,
        inputFeatureName: String = "state_in",
        outputFeatureName: String = "latent_out"
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
        self.inputFeatureName = inputFeatureName
        self.outputFeatureName = outputFeatureName
    }

    /// `state` is `[x, y, vx, vy]` (batch size 1 — a single live/goal state).
    public func encode(state: [Float]) async throws -> [Float] {
        let input = try state.toMultiArray(shape: [1, state.count])
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [inputFeatureName: MLFeatureValue(multiArray: input)]
        )
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
        return output.toFloatArray()
    }
}
