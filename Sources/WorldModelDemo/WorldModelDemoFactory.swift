import Foundation
import BCICore

/// Picks the right `WorldModelDemoPlanning` implementation: CoreML if all
/// three exported models are present and load, the baseline proportional
/// controller otherwise. Synchronous, no subprocess probe — unlike
/// `PredictorFactory` (MLX's C++/Metal layer can abort the whole process
/// in a way no Swift `try/catch` can intercept, so it probes in a
/// disposable child process first), CoreML load failures are ordinary
/// Swift errors, same as `ClassifierFactory`.
public enum WorldModelDemoFactory {
    public static let defaultModelsDirectory = "Models/WorldModelDemo"

    public enum Kind: String, Sendable {
        case coreML
        case baseline
    }

    public struct Resolved: Sendable {
        public let engine: any WorldModelDemoPlanning
        public let kind: Kind
        public let warning: String?

        public init(engine: any WorldModelDemoPlanning, kind: Kind, warning: String?) {
            self.engine = engine
            self.kind = kind
            self.warning = warning
        }
    }

    public static func live(modelsDirectory: String? = nil) -> Resolved {
        // Mirrors ClassifierFactory/PredictorFactory's env-var override —
        // a GUI-launched `.app` gets CWD `/`, silently resolving the
        // relative default to nothing.
        let directory = modelsDirectory
            ?? ProcessInfo.processInfo.environment["NEURALCOMPOSE_WORLDMODEL_DEMO_MODELS"]
            ?? defaultModelsDirectory
        let base = URL(fileURLWithPath: directory)

        do {
            let onlineEncoder = try WorldModelStateEncoderModel(
                modelURL: base.appendingPathComponent("Encoder.mlpackage")
            )
            let goalEncoder = try WorldModelStateEncoderModel(
                modelURL: base.appendingPathComponent("GoalEncoder.mlpackage"),
                inputFeatureName: "goal_state_in",
                outputFeatureName: "goal_latent_out"
            )
            let predictor = try WorldModelLatentPredictorModel(
                modelURL: base.appendingPathComponent("LatentPredictor.mlpackage")
            )

            // WorldModelMPCConfig.numCandidates and the exported predictor's
            // fixed batch size are independently-hardcoded literals (Swift
            // default, this batchSize, export_coreml.py's PREDICTOR_BATCH)
            // kept in sync only by convention. WorldModelMPCEngine.planStep
            // enforces this with a `precondition` (a fatal, uncatchable
            // trap) — check it here instead, at resolve time, so a drift
            // falls back to the baseline controller gracefully rather than
            // crashing the demo the first time someone opens it.
            let expectedNumCandidates = WorldModelMPCConfig().numCandidates
            guard predictor.batchSize == expectedNumCandidates else {
                BCILog.worldModelDemo.notice(
                    "World Model demo LatentPredictor batch size (\(predictor.batchSize, privacy: .public)) does not match WorldModelMPCConfig.numCandidates (\(expectedNumCandidates, privacy: .public)); using baseline controller"
                )
                return Resolved(engine: BaselineWorldModelDemoPlanner(), kind: .baseline, warning: nil)
            }

            let engine = WorldModelMPCEngine(onlineEncoder: onlineEncoder, goalEncoder: goalEncoder, predictor: predictor)
            return Resolved(engine: engine, kind: .coreML, warning: nil)
        } catch {
            let reason = (error as? BCIError)?.description ?? error.localizedDescription
            BCILog.worldModelDemo.notice("World Model demo CoreML models unavailable (\(reason, privacy: .public)); using baseline controller")
            return Resolved(engine: BaselineWorldModelDemoPlanner(), kind: .baseline, warning: nil)
        }
    }
}
