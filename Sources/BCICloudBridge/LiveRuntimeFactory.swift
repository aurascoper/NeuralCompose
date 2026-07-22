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
/// The keep-bar: the Claude path returns the *legacy*
/// `ClaudeCLIGenerator` unchanged (the same path the live app
/// has been using pre-branch), so the production behavior is
/// preserved when the env vars are absent. The Ollama path
/// composes `OllamaGenerationRuntime` over `OllamaHTTPTransport`
/// and wraps it in the `GenerationRuntimeTextGeneratingAdapter`
/// the harness uses (step 6, commit `4002d3e`).
///
/// ADR-009 invariant #2 (runtime is transport, not semantics):
/// the factory does NOT modify the prompt text. The system
/// prompt bytes are loaded from the `PromptProfile` resource
/// for the Ollama path (matching the harness); the Claude path
/// uses the legacy `ClaudeCLIGenerator.hypnagogicSystemPrompt`
/// default (also pre-extraction, also unchanged). Switching
/// runtimes is a configuration change, not a semantics change.
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
    ///   - systemPrompt: the system prompt to use. For the
    ///     Claude path, this is passed through to
    ///     `ClaudeCLIGenerator(systemPrompt:)`. For the Ollama
    ///     path, this is the text the `OllamaHTTPTransport`
    ///     concatenates onto the user prompt with the
    ///     `systemPromptDelimiter` (ADR-009 invariant #2). If
    ///     `nil`, the Ollama path loads the prompt from the
    ///     `PromptProfile` resource (same as the harness).
    public static func make(
        runtimeName: String? = ProcessInfo.processInfo.environment["NEURALCOMPOSE_RUNTIME"],
        model: String? = ProcessInfo.processInfo.environment["NEURALCOMPOSE_MODEL"],
        systemPrompt: String? = nil,
        ollamaBaseURL: URL = URL(string: "http://localhost:11434")!
    ) throws -> (generator: any TextGenerating, resolved: Resolved) {
        let resolvedName = (runtimeName ?? "claude").lowercased()
        let resolvedModel: String = {
            if let m = model, !m.isEmpty { return m }
            return resolvedName == "ollama" ? "qwen2.5:0.5b" : "claude-sonnet-5"
        }()

        switch resolvedName {
        case "claude":
            // Legacy path: same `ClaudeCLIGenerator` the live app
            // used pre-branch. Preserved byte-for-byte so the
            // production state is unchanged when the env vars
            // are absent.
            let gen = ClaudeCLIGenerator(
                model: resolvedModel,
                systemPrompt: systemPrompt ?? ClaudeCLIGenerator.hypnagogicSystemPrompt
            )
            return (gen, Resolved(
                name: "claude-cli", model: resolvedModel,
                systemPromptSource: "legacy-static"
            ))

        case "ollama":
            // New path: compose the `OllamaGenerationRuntime`
            // (step 4, commit `ce68a53`) over the
            // `OllamaHTTPTransport`, wrap in the
            // `GenerationRuntimeTextGeneratingAdapter` (step 6,
            // commit `4002d3e`). The system prompt bytes are
            // loaded from the `PromptProfile` resource — the same
            // bytes the harness sends to Ollama. ADR-009 invariant
            // #2 is preserved: the transport concatenates the
            // system prompt onto the user prompt with the
            // documented delimiter, never modifies semantic
            // intent.
            let promptText: String
            if let s = systemPrompt { promptText = s }
            else { promptText = (try? PromptProfile.wakingDialectical.load()) ?? "" }
            let runtime = OllamaGenerationRuntime(
                model: resolvedModel,
                systemPrompt: promptText,
                interactionStyle: "dialectical",
                baseURL: ollamaBaseURL
            )
            let adapter = GenerationRuntimeTextGeneratingAdapter(
                runtime: runtime,
                systemPrompt: promptText
            )
            return (adapter, Resolved(
                name: "ollama", model: resolvedModel,
                systemPromptSource: "PromptProfile"
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
