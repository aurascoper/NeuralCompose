import BCICore
import Foundation

/// `LiveRuntimeFactory` resolves a `TextGenerating` for the live
/// `NeuralCompose` app from the same env-var contract the headless
/// `dialectic-session` harness uses (`NEURALCOMPOSE_RUNTIME`,
/// `NEURALCOMPOSE_MODEL`).
///
/// Precedence:
///   1. Explicit constructor arguments (used by tests).
///   2. `NEURALCOMPOSE_RUNTIME` / `NEURALCOMPOSE_MODEL` env vars.
///   3. Built-in defaults: `claude` / `claude-sonnet-5`.
///
/// Both paths compose a `GenerationRuntime` (`ClaudeCLIGenerationRuntime`
/// over `ClaudeCLITransport`, `OllamaGenerationRuntime` over
/// `OllamaHTTPTransport`) and wrap it in the
/// `GenerationRuntimeTextGeneratingAdapter` the harness uses (step 6,
/// commit `4002d3e`), so every turn can record which provider, model
/// and prompt produced it. The Claude path used to return a bare
/// `ClaudeCLIGenerator`, which publishes no metadata, so the app's
/// Claude turns were logged with no `generatorFingerprint` (ported
/// from the intent of `abb0eea`). The `claude -p` argv and the
/// executable lookup are unchanged.
///
/// ADR-009 invariant #2 (runtime is transport, not semantics):
/// the factory does NOT modify the prompt text. The system
/// prompt bytes come from the caller or from the `PromptProfile`
/// resource; neither runtime edits them. Switching runtimes is a
/// configuration change, not a semantics change.
public enum LiveRuntimeFactory {

    /// Resolved runtime identity (for logging / diagnostics).
    public struct Resolved: Sendable, CustomStringConvertible {
        public let name: String           // "claude-cli" or "ollama"
        public let model: String          // "claude-sonnet-5" / "qwen2.5:0.5b"
        public let systemPromptSource: String  // "legacy-static" or "PromptProfile"
        public init(name: String, model: String, systemPromptSource: String) {
            self.name = name
            self.model = model
            self.systemPromptSource = systemPromptSource
        }
        public var description: String {
            "name=\(name) model=\(model) systemPrompt=\(systemPromptSource)"
        }
    }

    /// Build a `TextGenerating` for the live app, reading env vars
    /// for runtime selection. The returned generator is what the
    /// `HypnagogicDialecticLoop` and the `HypnagogicDialogueLoop`
    /// call into.
    ///
    /// - Parameters:
    ///   - systemPrompt: caller-owned system prompt text. Recorded
    ///     in metadata as profile `custom`, hashed over these bytes.
    ///     For the Ollama path this is the text the
    ///     `OllamaHTTPTransport` concatenates onto the user prompt
    ///     with the `systemPromptDelimiter` (ADR-009 invariant #2).
    ///   - promptProfile: the profile to load when `systemPrompt`
    ///     is nil, recorded in metadata by name. Defaults to
    ///     `.hypnagogic` for Claude and `.wakingDialectical` for
    ///     Ollama, as before.
    ///   - claudeExecutablePath: absolute path to a `claude`
    ///     executable; nil resolves `claude` from PATH. Tests point
    ///     it at a stub.
    public static func make(
        runtimeName: String? = ProcessInfo.processInfo.environment["NEURALCOMPOSE_RUNTIME"],
        model: String? = ProcessInfo.processInfo.environment["NEURALCOMPOSE_MODEL"],
        systemPrompt: String? = nil,
        promptProfile: PromptProfile? = nil,
        ollamaBaseURL: URL = URL(string: "http://localhost:11434")!,
        claudeExecutablePath: String? = nil
    ) throws -> (generator: any TextGenerating, resolved: Resolved) {
        let resolvedName = (runtimeName ?? "claude").lowercased()
        let resolvedModel: String = {
            if let m = model, !m.isEmpty { return m }
            return resolvedName == "ollama" ? "qwen2.5:0.5b" : "claude-sonnet-5"
        }()

        switch resolvedName {
        case "claude":
            // Same `claude -p` argv and PATH lookup as the legacy
            // `ClaudeCLIGenerator`, but through the runtime + adapter,
            // so each call publishes `GenerationMetadata`.
            let profile = promptProfile ?? .hypnagogic
            let promptText = try systemPrompt ?? profile.load()
            let runtime = try systemPrompt.map {
                try ClaudeCLIGenerationRuntime(
                    model: resolvedModel, systemPrompt: $0, executablePath: claudeExecutablePath)
            } ?? ClaudeCLIGenerationRuntime(
                model: resolvedModel, promptProfile: profile, executablePath: claudeExecutablePath)
            let adapter = GenerationRuntimeTextGeneratingAdapter(
                runtime: runtime,
                systemPrompt: promptText
            )
            return (adapter, Resolved(
                name: "claude-cli", model: resolvedModel,
                systemPromptSource: systemPrompt == nil ? "PromptProfile:\(profile.rawValue)" : "custom"
            ))

        case "ollama":
            // Compose the `OllamaGenerationRuntime` (step 4, commit
            // `ce68a53`) over the `OllamaHTTPTransport`, wrapped in the
            // `GenerationRuntimeTextGeneratingAdapter` (step 6, commit
            // `4002d3e`). ADR-009 invariant #2 is preserved: the
            // transport concatenates the system prompt onto the user
            // prompt with the documented delimiter, never modifies
            // semantic intent.
            let profile = promptProfile ?? .wakingDialectical
            let promptText = try systemPrompt ?? profile.load()
            let runtime = try systemPrompt.map {
                try OllamaGenerationRuntime(
                    model: resolvedModel, systemPrompt: $0,
                    interactionStyle: "dialectical", baseURL: ollamaBaseURL)
            } ?? OllamaGenerationRuntime(
                model: resolvedModel, promptProfile: profile,
                interactionStyle: "dialectical", baseURL: ollamaBaseURL)
            let adapter = GenerationRuntimeTextGeneratingAdapter(
                runtime: runtime,
                systemPrompt: promptText
            )
            return (adapter, Resolved(
                name: "ollama", model: resolvedModel,
                systemPromptSource: systemPrompt == nil ? "PromptProfile:\(profile.rawValue)" : "custom"
            ))

        default:
            throw NSError(
                domain: "LiveRuntimeFactory", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "unknown runtime '\(resolvedName)' — supported: claude, ollama"]
            )
        }
    }
}
