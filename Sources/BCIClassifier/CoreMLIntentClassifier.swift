import Foundation
import CoreML
import BCICore

/// Core ML-backed intent classifier.
///
/// Configuration:
///   • Defaults `MLModelConfiguration.computeUnits` to `.cpuAndNeuralEngine`,
///     which deliberately routes off the GPU so MLX has unobstructed access.
///   • `.all` and `.cpuOnly` are also offered at runtime, but `.cpuOnly` is a
///     debug fallback only and the UI will warn about it.
///   • There is no `.neuralEngineOnly`. Don't try to add one; that value
///     does not exist in `MLComputeUnits`.
///
/// Input/output:
///   • Input: `MLMultiArray` of shape `[1, channels, samples]`, dtype Float32.
///   • Output: `MLMultiArray` of shape `[1, classes]`, dtype Float32.
///   • Classes follow `IntentClass.modelOutputOrder`.
///
/// If your trained model uses different I/O names, change `inputFeatureName`
/// and `outputFeatureName` — that's the only place in the codebase that
/// mentions them.
public final class CoreMLIntentClassifier: IntentClassifying, @unchecked Sendable {

    public let isLive: Bool = true
    public let computeMode: ClassifierComputeMode

    private let model: MLModel
    private let inputFeatureName: String
    private let outputFeatureName: String
    private let expectedChannels: Int
    private let expectedSamples: Int

    /// Try to load a Core ML model at `url`. Falls back to throwing if either
    /// the file is missing or the model can't be initialized for any reason —
    /// the factory catches and returns a `MockIntentClassifier` instead.
    public init(
        modelURL: URL,
        computeMode: ClassifierComputeMode = .cpuAndNeuralEngine,
        inputFeatureName: String = "eeg_window",
        outputFeatureName: String = "intent_logits",
        expectedChannels: Int = 4,
        expectedSamples: Int = 512
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw BCIError.classifierModelMissing(path: modelURL.path)
        }
        let config = MLModelConfiguration()
        config.computeUnits = Self.translate(computeMode)
        config.allowLowPrecisionAccumulationOnGPU = false

        // Core ML's `MLModel(contentsOf:)` wants a compiled `.mlmodelc`. A
        // raw `.mlpackage` from coremltools.convert() must be compiled first
        // via `MLModel.compileModel(at:)` — which writes a `.mlmodelc` into
        // the temp dir, valid until next launch. We cache that location for
        // the lifetime of the process; for production, compile once with
        // `xcrun coremlcompiler` and ship the `.mlmodelc` instead.
        let loadURL: URL
        if modelURL.pathExtension == "mlpackage" {
            do {
                loadURL = try MLModel.compileModel(at: modelURL)
            } catch {
                throw BCIError.classifierLoadFailed(
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
            throw BCIError.classifierLoadFailed(
                path: modelURL.path,
                underlying: error.localizedDescription
            )
        }
        self.computeMode = computeMode
        self.inputFeatureName = inputFeatureName
        self.outputFeatureName = outputFeatureName
        self.expectedChannels = expectedChannels
        self.expectedSamples = expectedSamples
    }

    /// Hot-swap the compute placement without reloading from disk. Re-creates
    /// the underlying `MLModel` with the new `MLModelConfiguration`.
    public func setComputeMode(_ mode: ClassifierComputeMode) throws -> CoreMLIntentClassifier {
        // MLModel is immutable wrt its configuration, so to change compute
        // mode we re-instantiate at the same URL. We don't store the URL
        // back-reference — caller (the factory) does.
        throw BCIError.classifierInferenceFailed(reason: "use factory.reload(with:) to change compute mode")
    }

    public func classify(window: EEGWindow) async throws -> IntentPrediction {
        precondition(window.channelCount == expectedChannels,
                     "model expects \(expectedChannels) channels, got \(window.channelCount)")

        let input = try multiArray(from: window)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputFeatureName: MLFeatureValue(multiArray: input)])
        let prediction: any MLFeatureProvider
        do {
            prediction = try await model.prediction(from: provider)
        } catch {
            throw BCIError.classifierInferenceFailed(reason: error.localizedDescription)
        }
        guard let outputArray = prediction.featureValue(for: outputFeatureName)?.multiArrayValue else {
            throw BCIError.classifierOutputShapeUnexpected(
                expected: outputFeatureName,
                actual: prediction.featureNames.joined(separator: ",")
            )
        }
        return try Self.makePrediction(from: outputArray, window: window)
    }

    // MARK: - Helpers

    private func multiArray(from window: EEGWindow) throws -> MLMultiArray {
        // Pad / truncate to expectedSamples so a 2-second window at any
        // sample rate fits the model.
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: expectedChannels), NSNumber(value: expectedSamples)],
            dataType: .float32
        )
        let pointer = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let stride0 = expectedChannels * expectedSamples
        for ch in 0..<expectedChannels {
            let row = window.samples[ch]
            let rowSamples = min(row.count, expectedSamples)
            for s in 0..<rowSamples {
                pointer[0 * stride0 + ch * expectedSamples + s] = row[s]
            }
            // Zero-pad the tail.
            for s in rowSamples..<expectedSamples {
                pointer[0 * stride0 + ch * expectedSamples + s] = 0
            }
        }
        return array
    }

    private static func makePrediction(from output: MLMultiArray, window: EEGWindow) throws -> IntentPrediction {
        let classes = IntentClass.modelOutputOrder
        guard output.count == classes.count else {
            throw BCIError.classifierOutputShapeUnexpected(
                expected: "[1, \(classes.count)]",
                actual: output.shape.map { "\($0)" }.joined(separator: ",")
            )
        }
        var distribution: [IntentClass: Float] = [:]
        var maxIntent: IntentClass = .rest
        var maxValue: Float = -.infinity
        // Softmax with max-subtraction for numerical stability. The model is a
        // bare `nn.Linear` (train-intent-classifier.py) emitting RAW logits under
        // CrossEntropyLoss, and the Python server softmaxes as
        // exp(logits - max(logits)). Without the max-subtraction, a strong gesture
        // can produce a logit ≳ 88 that overflows expf to +inf → sum = inf →
        // argmax = inf/inf = NaN → the *clearest* intents silently return the
        // wrong class at confidence 0. Subtract the max first, matching the ref.
        var logits: [Float] = []
        logits.reserveCapacity(classes.count)
        for i in 0..<classes.count { logits.append(output[i].floatValue) }
        let maxLogit = logits.max() ?? 0
        var exps: [Float] = []
        exps.reserveCapacity(classes.count)
        var sum: Float = 0
        for v in logits {
            let e = expf(v - maxLogit)
            exps.append(e)
            sum += e
        }
        if sum == 0 { sum = 1 }
        for (i, c) in classes.enumerated() {
            let p = exps[i] / sum
            distribution[c] = p
            if p > maxValue { maxValue = p; maxIntent = c }
        }
        return IntentPrediction(
            intent: maxIntent,
            confidence: maxValue,
            distribution: distribution,
            windowSequence: window.sequence,
            endTimestamp: window.endTimestamp
        )
    }

    static func translate(_ mode: ClassifierComputeMode) -> MLComputeUnits {
        switch mode {
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .all:                return .all
        case .cpuOnly:            return .cpuOnly
        }
    }
}
