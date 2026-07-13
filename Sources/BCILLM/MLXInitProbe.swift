import Foundation

/// Outcome of an MLX init+generate probe. `.success`/`.failed` are the only
/// two cases a probe can observe about *itself* — a process can't detect
/// its own timeout-by-parent or its own uncaught-signal crash. `.timeout`
/// and `.crashed` only ever get constructed by whichever process is
/// *supervising* a probe subprocess (`PredictorFactory`), by interpreting
/// how that child process actually terminated.
public enum ProbeResult: Sendable, Codable, Equatable {
    case success(ProbeMetrics)
    case failed(reason: String)
    case timeout
    case crashed(signal: Int32)
}

public struct ProbeMetrics: Sendable, Codable, Equatable {
    public let modelIdentifier: String
    /// Wall-clock time for `MLXNextWordPredictor.init` — model weights,
    /// tokenizer, and everything else `LLMModelFactory.loadContainer`
    /// does, combined. Not split into model-load vs. tokenizer-load: that
    /// would require timing checkpoints inside the vendored
    /// `mlx-swift-examples` package, out of scope here.
    public let modelLoadTime: TimeInterval
    /// `GenerateResult.promptTime` — time to process the prompt / produce
    /// the first token.
    public let firstTokenLatency: TimeInterval
    /// `GenerateResult.generateTime` — time to generate the rest.
    public let totalGenerateTime: TimeInterval
    public let tokensPerSecond: Double
    /// The actual generated text — not just a metric, but what makes a
    /// probe run useful as a reviewer-facing smoke test: seeing real
    /// output, not only timing numbers.
    public let generatedText: String

    public init(
        modelIdentifier: String, modelLoadTime: TimeInterval,
        firstTokenLatency: TimeInterval, totalGenerateTime: TimeInterval,
        tokensPerSecond: Double, generatedText: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.modelLoadTime = modelLoadTime
        self.firstTokenLatency = firstTokenLatency
        self.totalGenerateTime = totalGenerateTime
        self.tokensPerSecond = tokensPerSecond
        self.generatedText = generatedText
    }
}

/// The single implementation both `MLXProbe` (CLI) and
/// `PredictorFactory`'s subprocess probe call into — the property that
/// matters is that they run the *exact same sequence*, not that they're
/// merely similar. Constructs `MLXNextWordPredictor` for real (no mocking,
/// no stubbing) and runs one real `generate()` call, timing both.
public enum MLXInitProbe {
    /// `prompt`/`maxTokens` default to something small and fast —
    /// `PredictorFactory` runs this on every app launch as a capability
    /// check, not just when a developer invokes `MLXProbe` by hand for
    /// deeper testing.
    public static func run(
        modelDirectory: URL,
        prompt: String = "Hello",
        maxTokens: Int = 16,
        temperature: Double = 0.7
    ) async -> ProbeResult {
        let initStart = Date()
        let predictor: MLXNextWordPredictor
        do {
            predictor = try await MLXNextWordPredictor(modelDirectory: modelDirectory)
        } catch {
            return .failed(reason: String(describing: error))
        }
        let modelLoadTime = Date().timeIntervalSince(initStart)

        let generation: GenerationMetrics
        do {
            generation = try await predictor.generateDetailed(
                prompt: prompt, maxTokens: maxTokens, temperature: temperature,
                cancellationID: UUID()
            )
        } catch {
            return .failed(reason: String(describing: error))
        }

        return .success(
            ProbeMetrics(
                modelIdentifier: predictor.modelIdentifier,
                modelLoadTime: modelLoadTime,
                firstTokenLatency: generation.promptTime,
                totalGenerateTime: generation.generateTime,
                tokensPerSecond: generation.tokensPerSecond,
                generatedText: generation.text
            )
        )
    }
}
