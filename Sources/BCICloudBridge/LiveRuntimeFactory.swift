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
/// **The factory returns a runtime *and* an identity.** The identity is not a
/// log line — it is the value telemetry, readiness logic, and the privacy UI
/// consume, and it exists on the failure path too (carried by
/// `RuntimeResolutionFailure`), because a UI that can only describe runtimes
/// that resolved cannot tell the user what went wrong with the one that didn't.
///
/// **Readiness is checked before the loop starts, never by generating** — and
/// the two paths prove different things, so they report different readiness.
///   - Claude → `.configured`: the executable is resolved through
///     `ClaudeExecutableResolver` — the same resolver the harness uses — and
///     the prompt is loaded and hashed. No request is made to Anthropic, so
///     authentication, account state, and model entitlement remain unverified.
///   - Ollama → `.ready`: a bounded `GET /api/tags` confirms the daemon is up
///     and has the exact requested model. No prompt is sent.
///
/// Both are usable (`canAttemptGeneration`); only one is verified (`isReady`).
/// A generation that later succeeds is *session* evidence and does not mutate
/// the identity — the identity describes what resolution proved, and rewriting
/// it after the fact would erase the distinction this split exists to record.
///
/// A readiness failure disables the loop. **No alternate provider is ever
/// attempted**: substituting Claude when Ollama is unavailable would turn a
/// local-inference choice into unrequested network egress.
///
/// ADR-009 invariant #2 (runtime is transport, not semantics): the factory does
/// NOT modify prompt text. The prompt profile is selected by *role*, and the
/// hash recorded is of the bytes actually transmitted.
public enum LiveRuntimeFactory {

    /// The default Ollama endpoint. Loopback, hence `onDevice`.
    public static let defaultOllamaBaseURL = URL(string: "http://localhost:11434")!

    public static let defaultClaudeModel = "claude-sonnet-5"
    public static let defaultOllamaModel = "qwen2.5:0.5b"

    /// Build a runtime for `role`, plus the identity describing it.
    ///
    /// - Throws: `RuntimeResolutionFailure`, which carries a sanitized identity
    ///   and a `publicMessage` safe to render. Never throws a raw
    ///   `ResolutionError`, whose description embeds the environment `PATH`.
    public static func make(
        role: RuntimeRole,
        runtimeName: String? = ProcessInfo.processInfo.environment["NEURALCOMPOSE_RUNTIME"],
        model: String? = ProcessInfo.processInfo.environment["NEURALCOMPOSE_MODEL"],
        ollamaBaseURL: URL = defaultOllamaBaseURL,
        session: URLSession? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probeTimeout: TimeInterval = 3.0
    ) async throws -> (generator: any TextGenerating, identity: ResolvedRuntimeIdentity) {
        let requestedProvider = (runtimeName ?? "claude").lowercased()
        let requestedModel: String = {
            if let model, !model.isEmpty { return model }
            return requestedProvider == "ollama" ? defaultOllamaModel : defaultClaudeModel
        }()
        let profile = promptProfile(for: role)

        switch requestedProvider {
        case "claude":
            return try await makeClaude(
                role: role,
                profile: profile,
                requestedProvider: requestedProvider,
                requestedModel: requestedModel,
                environment: environment
            )

        case "ollama":
            return try await makeOllama(
                role: role,
                profile: profile,
                requestedProvider: requestedProvider,
                requestedModel: requestedModel,
                baseURL: ollamaBaseURL,
                session: session,
                probeTimeout: probeTimeout
            )

        default:
            throw RuntimeResolutionFailure(
                identity: unresolvedIdentity(
                    role: role,
                    profile: profile,
                    requestedProvider: requestedProvider,
                    requestedModel: requestedModel,
                    // An unknown provider has no endpoint, so there is nothing
                    // to classify — and `.localBrokerToRemoteService`, which
                    // this used to report, *was* a guess: it asserted a known
                    // egress topology for a provider nothing knows anything
                    // about. `.unresolved` keeps the conservative egress
                    // presentation without the false claim.
                    locality: .unresolved,
                    failure: .unknownProvider
                ),
                code: .unknownProvider,
                publicMessage: "Unknown runtime '\(requestedProvider)'. Supported: claude, ollama."
            )
        }
    }

    /// The prompt profile a role transmits. This binding is why two runtimes
    /// with identical provider and model are still distinct identities.
    public static func promptProfile(for role: RuntimeRole) -> PromptProfile {
        switch role {
        case .dialectic: return .wakingDialectical
        case .witness:   return .witness
        case .mirror:    return .hypnagogic
        }
    }

    // MARK: - Claude

    private static func makeClaude(
        role: RuntimeRole,
        profile: PromptProfile,
        requestedProvider: String,
        requestedModel: String,
        environment: [String: String]
    ) async throws -> (generator: any TextGenerating, identity: ResolvedRuntimeIdentity) {
        // The Claude CLI is a *local broker*. Inference is remote. Classifying
        // it by where the process runs rather than where the tokens go would
        // make the privacy banner assert on-device inference for the one path
        // that leaves the machine.
        let locality: RuntimeLocality = .localBrokerToRemoteService

        func failure(
            _ code: RuntimeReadinessFailure,
            _ message: String,
            detail: String?
        ) -> RuntimeResolutionFailure {
            RuntimeResolutionFailure(
                identity: unresolvedIdentity(
                    role: role, profile: profile,
                    requestedProvider: requestedProvider, requestedModel: requestedModel,
                    locality: locality, failure: code
                ),
                code: code,
                publicMessage: message,
                internalDetail: detail
            )
        }

        // R2 continuation: the app now uses the same exact resolver the harness
        // does, so `/usr/bin/env` can no longer stand in for the CLI on this
        // path either. The resolver's own error embeds the full PATH, so it is
        // deliberately NOT interpolated into the public message.
        let executablePath: String
        do {
            executablePath = try ClaudeExecutableResolver.resolve(environment: environment)
        } catch let error as ClaudeExecutableResolver.ResolutionError {
            let code: RuntimeReadinessFailure =
                if case .notFoundOnPath = error { .executableNotFound } else { .executableInvalid }
            throw failure(
                code,
                "The claude CLI was not found. Install Claude Code and run `claude login`.",
                detail: String(describing: error)
            )
        }

        let promptText: String
        do {
            promptText = try profile.load()
        } catch {
            throw failure(
                .promptResourceUnavailable,
                "The \(profile.rawValue) prompt resource is unavailable, so this runtime cannot run.",
                detail: String(describing: error)
            )
        }

        let generator: ClaudeCLIGenerator
        do {
            generator = try ClaudeCLIGenerator(
                model: requestedModel,
                systemPrompt: promptText,
                executablePath: executablePath
            )
        } catch {
            throw failure(
                .promptResourceUnavailable,
                "The Claude runtime could not be constructed with a constraining prompt.",
                detail: String(describing: error)
            )
        }

        return (generator, ResolvedRuntimeIdentity(
            role: role,
            requestedProvider: requestedProvider,
            requestedModel: requestedModel,
            resolvedProvider: "claude",
            resolvedModel: requestedModel,
            // The Claude CLI reports no content digest. `nil` rather than a
            // placeholder, so telemetry never records a fabricated value.
            modelDigest: nil,
            locality: locality,
            // `configured`, not `ready`. Everything above proved the runtime is
            // *constructible*: an executable resolved and a prompt loaded. No
            // request reached the provider, so authentication, account state,
            // network reachability, and whether this account may use this model
            // are all still unknown. Reporting `ready` here claimed the
            // verification only the Ollama path actually performs.
            readiness: .configured,
            promptProfile: profile.rawValue,
            promptHash: PromptProfile.sha256Hex(promptText),
            systemPromptSource: "PromptProfile(\(profile.rawValue))"
        ))
    }

    // MARK: - Ollama

    private static func makeOllama(
        role: RuntimeRole,
        profile: PromptProfile,
        requestedProvider: String,
        requestedModel: String,
        baseURL: URL,
        session: URLSession?,
        probeTimeout: TimeInterval
    ) async throws -> (generator: any TextGenerating, identity: ResolvedRuntimeIdentity) {
        // Loopback means the tokens stay here. Any other host is another
        // machine, and inference there is not on-device however local the
        // configuration file looks.
        let locality: RuntimeLocality =
            RuntimeIdentityRedaction.isLoopback(baseURL) ? .onDevice : .remoteEndpoint
        let endpoint = RuntimeIdentityRedaction.endpoint(baseURL)

        func failure(
            _ code: RuntimeReadinessFailure,
            _ message: String,
            detail: String?
        ) -> RuntimeResolutionFailure {
            RuntimeResolutionFailure(
                identity: unresolvedIdentity(
                    role: role, profile: profile,
                    requestedProvider: requestedProvider, requestedModel: requestedModel,
                    locality: locality, failure: code
                ),
                code: code,
                publicMessage: message,
                internalDetail: detail
            )
        }

        let promptText: String
        do {
            promptText = try profile.load()
        } catch {
            throw failure(
                .promptResourceUnavailable,
                "The \(profile.rawValue) prompt resource is unavailable, so this runtime cannot run.",
                detail: String(describing: error)
            )
        }

        // Readiness before enablement. An unpulled model used to resolve
        // cleanly and fail at the first generation — after the loop was live.
        let probe = OllamaReadinessProbe(
            baseURL: baseURL, session: session, timeout: probeTimeout)
        let resolvedModel: String
        let digest: String?
        switch await probe.probe(model: requestedModel) {
        case .present(let available):
            resolvedModel = available.name
            digest = available.digest
        case .modelMissing:
            // The available-model list is deliberately not surfaced: it is a
            // record of what the user has pulled locally, which the privacy
            // banner has no business enumerating.
            throw failure(
                .modelMissing,
                "Ollama does not have the model '\(requestedModel)'. Pull it with "
                    + "`ollama pull \(requestedModel)`.",
                detail: "model not present in /api/tags"
            )
        case .unreachable(let detail):
            throw failure(
                .endpointUnreachable,
                "Ollama is not reachable at \(endpoint). Start it with `ollama serve`.",
                detail: detail
            )
        }

        let runtime: OllamaGenerationRuntime
        do {
            runtime = try OllamaGenerationRuntime(
                model: resolvedModel,
                systemPrompt: promptText,
                interactionStyle: "dialectical",
                baseURL: baseURL,
                session: session ?? URLSession(configuration: .ephemeral)
            )
        } catch {
            throw failure(
                .promptResourceUnavailable,
                "The Ollama runtime could not be constructed with a constraining prompt.",
                detail: String(describing: error)
            )
        }
        let adapter = GenerationRuntimeTextGeneratingAdapter(runtime: runtime)

        return (adapter, ResolvedRuntimeIdentity(
            role: role,
            requestedProvider: requestedProvider,
            requestedModel: requestedModel,
            resolvedProvider: "ollama",
            // The daemon's canonical name, which may carry an implicit tag the
            // request omitted. Recording the request here would misreport what
            // is loaded.
            resolvedModel: resolvedModel,
            modelDigest: digest,
            locality: locality,
            // `ready` is earned here: `OllamaReadinessProbe` reached the daemon
            // and matched the exact requested model before enablement.
            readiness: .ready,
            promptProfile: profile.rawValue,
            promptHash: PromptProfile.sha256Hex(promptText),
            systemPromptSource: "PromptProfile(\(profile.rawValue))"
        ))
    }

    // MARK: - Failure identity

    /// The identity to report when nothing resolved.
    ///
    /// `resolvedProvider` / `resolvedModel` are empty rather than echoing the
    /// request: nothing resolved, and echoing would let a UI that reads only
    /// the resolved fields display a runtime that does not exist.
    private static func unresolvedIdentity(
        role: RuntimeRole,
        profile: PromptProfile,
        requestedProvider: String,
        requestedModel: String,
        locality: RuntimeLocality,
        failure: RuntimeReadinessFailure
    ) -> ResolvedRuntimeIdentity {
        ResolvedRuntimeIdentity(
            role: role,
            requestedProvider: requestedProvider,
            requestedModel: requestedModel,
            resolvedProvider: "",
            resolvedModel: "",
            modelDigest: nil,
            locality: locality,
            readiness: .unavailable(failure),
            promptProfile: profile.rawValue,
            // No bytes were transmitted, so there is no transmitted-byte hash.
            promptHash: "",
            systemPromptSource: "unresolved"
        )
    }
}
