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
    /// available. All checks are best-effort and never throw.
    ///
    /// **A check that was not performed is not a check that passed.**
    /// This returned `(promptLoaded, true, true)` for Claude while
    /// its own comment said no call had been made, so the harness
    /// printed `transport reachable: yes` / `model available: yes`
    /// on evidence it had not collected. `notChecked` is the third
    /// state that was missing; it is not a failure, and a
    /// configuration-only dry run still exits 0.
    public static func verify(resolved: ResolvedRuntime) -> RuntimeVerification {
        let promptLoaded: VerificationStatus
        do {
            _ = try resolved.promptProfile.load()
            promptLoaded = .passed
        } catch {
            promptLoaded = .failed
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
            let reached: VerificationStatus = ok.withLock { $0 } ? .passed : .failed
            return RuntimeVerification(
                prompt: promptLoaded, transport: reached, model: reached)
        } else if resolved.runtime is ClaudeCLIGenerationRuntime {
            // Claude validates the CLI on the first call, and a
            // dry run makes no call — so the provider was never
            // contacted and this account's entitlement to this
            // model is unknown. Both are reported as `notChecked`
            // rather than assumed good; the prompt check above is
            // real and still stands on its own.
            return RuntimeVerification(
                prompt: promptLoaded,
                transport: .notChecked,
                model: .notChecked,
                notCheckedReason: "no generation request made"
            )
        }

        return RuntimeVerification(prompt: promptLoaded, transport: .failed, model: .failed)
    }

    /// The `Verification:` block, as lines rather than `print`
    /// calls, so the wording is reachable by a test. The previous
    /// version formatted inline at two call sites in `main.swift`,
    /// which is why nothing could assert on what it claimed.
    public static func verificationLines(_ v: RuntimeVerification) -> [String] {
        [
            "Verification:",
            "  prompt loaded:        \(describe(v.prompt, reason: v.notCheckedReason))",
            "  provider reachable:   \(describe(v.transport, reason: v.notCheckedReason))",
            "  exact model present:  \(describe(v.model, reason: v.notCheckedReason))",
        ]
    }

    /// The dry-run summary. Only checks that actually ran get a
    /// `✓`; unchecked ones get a `–` that names the gap, so the
    /// summary cannot read as stronger evidence than the block
    /// above it.
    public static func dryRunSummaryLines(_ v: RuntimeVerification) -> [String] {
        var lines = ["✓ runtime configured"]
        if v.prompt == .passed { lines.append("✓ prompt loaded") }
        switch (v.transport, v.model) {
        case (.passed, .passed):
            lines.append("✓ endpoint reachable")
            lines.append("✓ exact model present")
        case (.notChecked, .notChecked):
            lines.append("– provider and model were not operationally verified")
        default:
            if v.transport == .passed { lines.append("✓ endpoint reachable") }
            if v.model == .passed { lines.append("✓ exact model present") }
        }
        lines.append("✓ fingerprint generated")
        return lines
    }

    private static func describe(_ status: VerificationStatus, reason: String?) -> String {
        switch status {
        case .passed:     return "yes"
        case .failed:     return "no"
        case .notChecked: return "not checked — \(reason ?? "not performed on this path")"
        }
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

/// The outcome of one verification check.
///
/// Three states, not two. A boolean forces every check that was
/// skipped to be reported as either a pass or a failure, and the
/// Claude dry-run path chose "pass" — printing `transport
/// reachable: yes` for a provider it had never contacted.
public enum VerificationStatus: Equatable, Sendable {
    /// The check ran and the condition held.
    case passed
    /// The check ran and the condition did not hold.
    case failed
    /// The check did not run, so there is no evidence either way.
    /// Explicitly **not** a failure.
    case notChecked
}

/// What a dry run actually established about a runtime.
///
/// This mirrors `RuntimeReadiness`'s configured/ready split on the
/// headless side: a Claude runtime can be fully constructed with a
/// loaded prompt while its provider and model entitlement remain
/// entirely unverified.
public struct RuntimeVerification: Equatable, Sendable {
    public let prompt: VerificationStatus
    public let transport: VerificationStatus
    public let model: VerificationStatus
    /// Why the unchecked checks were not run, rendered beside each
    /// `notChecked` line so an absence of evidence names its cause
    /// instead of looking like an omission.
    public let notCheckedReason: String?

    public init(
        prompt: VerificationStatus,
        transport: VerificationStatus,
        model: VerificationStatus,
        notCheckedReason: String? = nil
    ) {
        self.prompt = prompt
        self.transport = transport
        self.model = model
        self.notCheckedReason = notCheckedReason
    }

    /// Only an actual `failed` check fails the run. A
    /// configuration-only dry run — everything that could be
    /// checked passed, the rest was never attempted — still exits 0.
    public var hasFailure: Bool {
        [prompt, transport, model].contains(.failed)
    }
}
