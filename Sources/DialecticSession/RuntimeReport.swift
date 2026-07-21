import BCICore
import BCICloudBridge
import Foundation
import os

/// A diagnostic report for a resolved runtime. Prints the
/// runtime / transport / model / prompt / interaction / endpoint
/// / availability / generation-enabled state in a stable,
/// human-readable format. Used by both `--runtime-report` and
/// `--dry-run` (the dry-run mode also performs the live
/// verification; the report mode just prints what *would* be
/// used).
///
/// Failure prints an actionable diagnostic to `stderr` and exits
/// non-zero; it never panics, never throws, never crashes the
/// harness.
public enum RuntimeReport {
    public static func render(resolved: ResolvedRuntime, runtimeName: String, model: String) {
        let runtime = resolved.runtime
        print("Runtime:")
        print("  \(runtime.runtimeName)")
        print("Transport:")
        print("  \(transportName(of: runtime))")
        print("Model:")
        print("  \(runtime.modelIdentifier)")
        print("Prompt:")
        print("  \(resolved.promptProfile.rawValue)")
        print("Interaction:")
        print("  \(resolved.interactionStyle)")
        print("Endpoint:")
        print("  \(endpoint(of: runtime))")
        print("Available:")
        print("  \(runtime.isLive ? "yes" : "no")")
        print("Generation:")
        print("  \(runtime.isLive ? "enabled" : "disabled (stub)")")
        print("Capabilities:")
        print("  tokenCounting=\(runtime.capabilities.tokenCounting) streaming=\(runtime.capabilities.streaming) logProbs=\(runtime.capabilities.logProbs)")
        if let hash = try? resolved.promptProfile.hash() {
            print("Prompt hash:")
            print("  \(hash)")
        }
        // The fingerprint is what the telemetry records. The
        // keep-bar: a future cross-provider run is attributable
        // to a specific (runtime, transport, provider, model,
        // promptProfile, interactionStyle, promptHash) tuple.
        let meta = GenerationMetadata(
            runtime: runtime.runtimeName,
            transport: transportName(of: runtime),
            provider: providerName(of: runtime),
            model: model,
            promptHash: (try? resolved.promptProfile.hash()) ?? "",
            promptProfile: resolved.promptProfile.rawValue,
            interactionStyle: resolved.interactionStyle
        )
        let fp = GeneratorFingerprint(meta)
        print("Fingerprint:")
        print("  runtime=\(fp.runtime)")
        print("  transport=\(fp.transport)")
        print("  provider=\(fp.provider)")
        print("  model=\(fp.model)")
        print("  promptProfile=\(fp.promptProfile)")
        print("  interactionStyle=\(fp.interactionStyle)")
        print("  promptHash=\(fp.promptHash)")
    }

    /// Perform the live verification: load the prompt profile,
    /// probe the transport, and (for Ollama) verify the model is
    /// available. Returns a tuple of (promptLoaded, transportOK,
    /// modelAvailable). All checks are best-effort; failures
    /// return `false` for the failed check and never throw.
    public static func verify(resolved: ResolvedRuntime) -> (promptLoaded: Bool, transportOK: Bool, modelAvailable: Bool) {
        let promptLoaded: Bool
        do {
            _ = try resolved.promptProfile.load()
            promptLoaded = true
        } catch {
            promptLoaded = false
        }

        // For Ollama, the factory already validated the model is
        // available. The runtime's `isLive` is true. We re-probe
        // `/api/tags` only as a freshness check; failure here
        // does not block the report.
        if resolved.runtime is OllamaGenerationRuntime {
            let url = URL(string: "http://localhost:11434/api/tags")!
            let ok = OSAllocatedUnfairLock<Bool>(initialState: false)
            let sem = DispatchSemaphore(value: 0)
            let task = Task {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200,
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = obj["models"] as? [[String: Any]] {
                        let names = models.compactMap { $0["name"] as? String }
                        ok.withLock { $0 = names.contains(resolved.runtime.modelIdentifier.replacingOccurrences(of: " (ollama)", with: "")) }
                    }
                } catch {
                    ok.withLock { $0 = false }
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5)
            task.cancel()
            let transportOK = ok.withLock { $0 }
            return (promptLoaded, transportOK, transportOK)
        } else if resolved.runtime is ClaudeCLIGenerationRuntime {
            // Claude: the subprocess path validates the CLI on
            // first call. For the dry-run, we don't call. We
            // report `transportOK = true` (the factory has the
            // runtime) and `modelAvailable = true` (the
            // subprocess will tell us on the first live call).
            return (promptLoaded, true, true)
        }

        return (promptLoaded, false, false)
    }

    private static func transportName(of runtime: any GenerationRuntime) -> String {
        // The runtime carries `runtimeName` ("claude-cli" /
        // "ollama"); the transport name is part of metadata,
        // published on the *result* of `generate()`. For the
        // report we publish the same string the transport
        // publishes, by convention.
        switch runtime.runtimeName {
        case "claude-cli": return "claude-cli"
        case "ollama":     return "ollama-http"
        default:           return runtime.runtimeName
        }
    }

    private static func providerName(of runtime: any GenerationRuntime) -> String {
        switch runtime.runtimeName {
        case "claude-cli": return "anthropic"
        case "ollama":     return "ollama"
        default:           return runtime.runtimeName
        }
    }

    private static func endpoint(of runtime: any GenerationRuntime) -> String {
        switch runtime.runtimeName {
        case "claude-cli": return "/usr/bin/env claude -p"
        case "ollama":     return "http://localhost:11434"
        default:           return "(unknown)"
        }
    }
}
