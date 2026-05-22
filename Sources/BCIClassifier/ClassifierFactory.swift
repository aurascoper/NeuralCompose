import Foundation
import CoreML
import BCICore

/// Picks the right `IntentClassifying` implementation: Core ML if the
/// compiled model exists at the standard location, mock otherwise.
public enum ClassifierFactory {

    /// Search paths, in priority order. `.mlmodelc` is pre-compiled (needs
    /// Xcode's `coremlcompiler` to produce) and loads instantly. `.mlpackage`
    /// is the raw export from `Scripts/train-intent-classifier.py` and is
    /// auto-compiled by Core ML on first load — slower start, no Xcode needed.
    public static let defaultModelPath = "Models/IntentClassifier.mlmodelc"
    public static let defaultPackagePath = "Models/IntentClassifier.mlpackage"

    public struct Resolved: Sendable {
        public let classifier: any IntentClassifying
        public let kind: PipelineMode.Classifier
        public let computeMode: ClassifierComputeMode
        public let warning: String?
    }

    public static func live(
        computeMode: ClassifierComputeMode = .cpuAndNeuralEngine,
        modelPath: String? = nil
    ) -> Resolved {
        let path = modelPath ?? Self.resolvePath()
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let cls = try CoreMLIntentClassifier(modelURL: url, computeMode: computeMode)
                return Resolved(
                    classifier: cls,
                    kind: .coreML,
                    computeMode: computeMode,
                    warning: nil
                )
            } catch {
                let reason = (error as? BCIError)?.description ?? error.localizedDescription
                BCILog.classifier.error("Core ML load failed (\(reason, privacy: .public)); using mock")
                return Resolved(
                    classifier: MockIntentClassifier(),
                    kind: .mock,
                    computeMode: .cpuOnly,
                    warning: "Core ML model present but failed to load: \(reason)"
                )
            }
        }
        BCILog.classifier.notice("No Core ML model at \(url.path, privacy: .public); using mock")
        return Resolved(
            classifier: MockIntentClassifier(),
            kind: .mock,
            computeMode: .cpuOnly,
            warning: nil
        )
    }

    private static func resolvePath() -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: defaultModelPath) { return defaultModelPath }
        if fm.fileExists(atPath: defaultPackagePath) { return defaultPackagePath }
        return defaultModelPath
    }
}
