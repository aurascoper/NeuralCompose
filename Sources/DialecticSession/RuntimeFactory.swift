import BCICore
import BCICloudBridge
import Foundation
import os

/// A resolved runtime: the `GenerationRuntime` itself plus the
/// fixed system prompt the harness will use. The system prompt
/// is selected to match the runtime (Claude default
/// `wakingDialectical`, Ollama default `wakingDialectical` —
/// same profile, byte-equivalent to the prompt a real Claude
/// run would see).
public struct ResolvedRuntime: Sendable {
    public let runtime: any GenerationRuntime
    public let systemPrompt: String
    public let promptProfile: PromptProfile
    public let interactionStyle: String
}

/// Errors raised by `RuntimeFactory.make(...)`. Each case carries
/// the actionable diagnostic the harness prints before exiting
/// cleanly; nothing panics.
public enum RuntimeFactoryError: Error, CustomStringConvertible {
    case unknownRuntime(String)
    case ollamaUnreachable(String)
    case ollamaModelMissing(String, available: [String])
    case claudeCLINotFound
    case claudeCLIRateLimited
    case other(String)

    public var description: String {
        switch self {
        case .unknownRuntime(let n):
            return "unknown runtime '\(n)' — supported: claude, ollama"
        case .ollamaUnreachable(let url):
            return "Ollama not reachable at \(url) — start it with `ollama serve` or check the URL"
        case .ollamaModelMissing(let m, let available):
            return "Ollama model '\(m)' is not installed. Available models: \(available.isEmpty ? "<none>" : available.joined(separator: ", "))"
        case .claudeCLINotFound:
            return "the `claude` CLI was not found on PATH — install Claude Code (https://claude.com/download) and run `claude login`"
        case .claudeCLIRateLimited:
            return "the `claude` CLI is rate-limited — try again after the rate-limit window resets, or switch runtimes with --runtime ollama"
        case .other(let m):
            return m
        }
    }
}

/// The runtime factory: takes the resolved (runtime, model) pair
/// from `CLIOptions` and produces a `ResolvedRuntime` ready to
/// be wrapped in a `GenerationRuntimeTextGeneratingAdapter` and
/// handed to `HypnagogicDialecticLoop`.
///
/// Validation:
///   - `claude` → constructs `ClaudeCLIGenerationRuntime` with
///     the supplied model name; the subprocess path validates the
///     `claude` CLI at construction. NOTE: `--dry-run` now fails on a
///     machine with no `claude` on PATH. It previously "succeeded"
///     only because the old resolver always returned `/usr/bin/env`,
///     which is the defect this replaced — a dry run that passes
///     without Claude installed is not a useful dry run. A rate-limit
///     still surfaces cleanly at the first call, not at construction.
///   - `ollama` → constructs `OllamaGenerationRuntime`; probes
///     `GET /api/tags` to verify the daemon is reachable and
///     the requested model is pulled. On failure, raises
///     `RuntimeFactoryError` with the actionable diagnostic.
public enum RuntimeFactory {
    public static func make(
        runtimeName: String,
        model: String,
        promptProfile: PromptProfile = .wakingDialectical,
        interactionStyle: String = "dialectical",
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = URLSession(configuration: .default),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedRuntime {
        switch runtimeName.lowercased() {
        case "claude":
            return try makeClaude(
                model: model,
                promptProfile: promptProfile,
                interactionStyle: interactionStyle,
                environment: environment
            )
        case "ollama":
            return try makeOllama(
                model: model,
                promptProfile: promptProfile,
                interactionStyle: interactionStyle,
                baseURL: baseURL,
                session: session
            )
        default:
            throw RuntimeFactoryError.unknownRuntime(runtimeName)
        }
    }

    private static func makeClaude(
        model: String,
        promptProfile: PromptProfile,
        interactionStyle: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedRuntime {
        // Resolve the `claude` CLI to an actual executable, or fail with a
        // typed error before any Process is launched — the harness reports it
        // and exits 1, no panic. The keep-bar is unchanged: a rate-limit still
        // produces a clean failure at the *first call*, not at construction.
        //
        // Previously this took the first executable from a candidate list that
        // began with `/usr/bin/env`, which always matched, so the transport ran
        // `/usr/bin/env -p --model …` and env rejected `-p` as its own flag.
        let cliPath: String
        do {
            cliPath = try ClaudeExecutableResolver.resolve(environment: environment)
        } catch ClaudeExecutableResolver.ResolutionError.notFoundOnPath {
            // Preserve the actionable remediation the old error carried; a bare
            // PATH dump tells the operator what was searched but not what to do.
            throw RuntimeFactoryError.claudeCLINotFound
        }
        // `ClaudeCLIGenerationRuntime` is the `GenerationRuntime`
        // conformer for the `claude -p` path (added in step 3 of
        // the seed-004 plan). It composes `ClaudeCLITransport`
        // (which preserves the exact subprocess invocation the
        // legacy `ClaudeCLIGenerator` used) + a `PromptProfile`.
        // The factory wraps it via `GenerationRuntimeTextGeneratingAdapter`
        // at the call site, so the loop sees the same `TextGenerating`
        // seam the legacy harness used. The system prompt bytes
        // are loaded from the `PromptProfile` so the transport sees
        // the same bytes the Markdown file declares.
        // A failed load previously substituted the hypnagogic (sleep-mirror)
        // prompt while `promptProfile` still reported the requested profile,
        // so the fingerprint recorded a profile that was never sent. Fail
        // instead: the caller reports the runtime as unavailable.
        let systemPrompt = try promptProfile.load()
        let runtime = try ClaudeCLIGenerationRuntime(
            model: model,
            systemPrompt: systemPrompt,
            interactionStyle: interactionStyle,
            executablePath: cliPath
        )
        return ResolvedRuntime(
            runtime: runtime,
            systemPrompt: systemPrompt,
            promptProfile: promptProfile,
            interactionStyle: interactionStyle
        )
    }

    private static func makeOllama(
        model: String,
        promptProfile: PromptProfile,
        interactionStyle: String,
        baseURL: URL,
        session: URLSession
    ) throws -> ResolvedRuntime {
        // Probe the Ollama daemon synchronously (the harness is
        // CLI-shaped, so a small async-blocking bridge is fine).
        // Errors are translated into actionable diagnostics.
        let probe = OllamaProbe(baseURL: baseURL, session: session)
        let result = probe.runSync()
        switch result {
        case .failure(let msg):
            throw RuntimeFactoryError.ollamaUnreachable("\(baseURL.absoluteString) — \(msg)")
        case .success(let tags):
            if !tags.contains(model) {
                throw RuntimeFactoryError.ollamaModelMissing(model, available: tags)
            }
        }
        // `OllamaGenerationRuntime` is a `GenerationRuntime`. The
        // factory wraps it via `GenerationRuntimeTextGeneratingAdapter`
        // at the call site. The system prompt is loaded from the
        // `PromptProfile` so the transport sees the same bytes
        // the Markdown file declares.
        let systemPrompt = try promptProfile.load()
        let runtime = try OllamaGenerationRuntime(
            model: model,
            systemPrompt: systemPrompt,
            interactionStyle: interactionStyle,
            baseURL: baseURL,
            session: session
        )
        return ResolvedRuntime(
            runtime: runtime,
            systemPrompt: systemPrompt,
            promptProfile: promptProfile,
            interactionStyle: interactionStyle
        )
    }

}

/// `OllamaProbe` is a tiny sync wrapper around an async Ollama
/// `/api/tags` GET. The factory needs a synchronous result;
/// `RunLoop`-style blocking on `URLSession.data(for:)` is the
/// simplest way to keep the harness's control flow synchronous
/// without dragging a full async-rewrite through the rest of
/// `dialectic-session`. The probe is `internal` to this file.
struct OllamaProbe {
    let baseURL: URL
    let session: URLSession

    enum ProbeResult {
        case success(available: [String])
        case failure(String)
    }

    func runSync() -> ProbeResult {
        let url = baseURL.appendingPathComponent("api/tags")
        let out = OSAllocatedUnfairLock<ProbeResult>(initialState: .failure("never ran"))
        let sem = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else {
                    out.withLock { $0 = .failure("non-HTTP response") }; sem.signal(); return
                }
                guard http.statusCode == 200 else {
                    out.withLock { $0 = .failure("HTTP \(http.statusCode))") }
                    sem.signal(); return
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = obj["models"] as? [[String: Any]] else {
                    out.withLock { $0 = .failure("invalid JSON envelope") }
                    sem.signal(); return
                }
                let names: [String] = models.compactMap { $0["name"] as? String }
                out.withLock { $0 = .success(available: names) }
            } catch {
                out.withLock { $0 = .failure(error.localizedDescription) }
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        task.cancel()
        return out.withLock { $0 }
    }
}
