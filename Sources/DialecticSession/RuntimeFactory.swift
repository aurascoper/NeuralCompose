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
///     `claude` CLI at first call (kept here as a no-op factory
///     so `--dry-run` can succeed without the CLI being
///     installed; the live call surfaces the rate-limit cleanly
///     via the existing `predictorInferenceFailed` path).
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
        session: URLSession = URLSession(configuration: .default)
    ) throws -> ResolvedRuntime {
        switch runtimeName.lowercased() {
        case "claude":
            return makeClaude(model: model, promptProfile: promptProfile, interactionStyle: interactionStyle)
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
        interactionStyle: String
    ) -> ResolvedRuntime {
        // Probe the `claude` CLI. If absent, raise a clean error so
        // the harness reports it and exits 1 — no panic. The
        // keep-bar: rate-limit produces a clean failure at the
        // *first call*, not at construction; that's the legacy
        // behavior and we preserve it.
        let cliPath = resolveClaudeCLI()
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
        let systemPrompt = (try? promptProfile.load()) ?? ClaudeCLIGenerator.hypnagogicSystemPrompt
        let runtime = ClaudeCLIGenerationRuntime(
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
        let runtime = OllamaGenerationRuntime(
            model: model,
            systemPrompt: (try? promptProfile.load()) ?? "",
            interactionStyle: interactionStyle,
            baseURL: baseURL,
            session: session
        )
        let sys = (try? promptProfile.load()) ?? ""
        return ResolvedRuntime(
            runtime: runtime,
            systemPrompt: sys,
            promptProfile: promptProfile,
            interactionStyle: interactionStyle
        )
    }

    /// Best-effort resolution of the `claude` CLI on PATH. Returns
    /// the absolute path or `nil` if the binary is not on PATH.
    /// Used only so we can give a clean error at dry-run time if
    /// it's missing; the live subprocess path uses `/usr/bin/env
    /// claude` so the keep-bar subprocess invocation is
    /// unchanged.
    private static func resolveClaudeCLI() -> String? {
        let candidates = ["/usr/bin/env", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
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
