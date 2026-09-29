import BCICore
import Foundation

/// CLI options for `dialectic-session`. Parsed from `CommandLine.arguments`
/// with a precedence of: explicit CLI flags > environment variables >
/// built-in defaults.
///
/// Built-in defaults preserve the existing harness behavior:
///   - `runtime` defaults to "claude"
///   - `model` defaults to "claude-sonnet-5" for Claude and
///     "qwen2.5:0.5b" for Ollama (the smallest available local
///     model, so a default run is cheap)
///
/// `--dry-run` is the CI / smoke-test mode: it initializes the
/// runtime, loads the prompt profile, prints the `GeneratorFingerprint`,
/// verifies the transport is reachable, and exits 0 — *no* LLM
/// call. Use `--runtime-report` to print the same diagnostic
/// block without running the loop at all (so callers can inspect
/// the runtime identity without consuming cloud/budget spend).
public struct CLIOptions {
    public var runtime: String
    public var model: String
    public var dryRun: Bool
    public var runtimeReport: Bool
    public var profile: String
    public var outPath: String
    public var heardLines: [String]

    public static let defaultClaudeModel = "claude-sonnet-5"
    public static let defaultOllamaModel = "qwen2.5:0.5b"

    public init(
        runtime: String,
        model: String,
        dryRun: Bool,
        runtimeReport: Bool,
        profile: String,
        outPath: String,
        heardLines: [String]
    ) {
        self.runtime = runtime
        self.model = model
        self.dryRun = dryRun
        self.runtimeReport = runtimeReport
        self.profile = profile
        self.outPath = outPath
        self.heardLines = heardLines
    }

    /// Parse `CommandLine.arguments` (excluding the program name) into
    /// `CLIOptions`. Returns `nil` and prints a usage line on
    /// `stderr` if the input is malformed; the harness exits with
    /// code 2 on a usage error.
    public static func parse(_ args: [String]) -> CLIOptions? {
        var runtime: String? = nil
        var model: String? = nil
        var dryRun = false
        var runtimeReport = false
        var positional: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--runtime":
                guard i + 1 < args.count else { usage(); return nil }
                runtime = args[i + 1]; i += 2
            case "--model":
                guard i + 1 < args.count else { usage(); return nil }
                model = args[i + 1]; i += 2
            case "--dry-run":
                dryRun = true; i += 1
            case "--runtime-report":
                runtimeReport = true; i += 1
            case "-h", "--help":
                usage(); exit(0)
            default:
                positional.append(a); i += 1
            }
        }

        // Resolve runtime: CLI > env > default ("claude")
        let envRuntime = ProcessInfo.processInfo.environment["NEURALCOMPOSE_RUNTIME"]
        let resolvedRuntime = runtime ?? envRuntime ?? "claude"

        // Resolve model: CLI > env > default-for-runtime
        let envModel = ProcessInfo.processInfo.environment["NEURALCOMPOSE_MODEL"]
        let defaultModel = (resolvedRuntime == "ollama") ? defaultOllamaModel : defaultClaudeModel
        let resolvedModel = model ?? envModel ?? defaultModel

        // Profile / out path / heard lines: existing positional contract.
        // For `--runtime-report` and `--dry-run`, the profile and out path
        // are optional (the harness short-circuits before using them).
        if runtimeReport || dryRun {
            let profile = positional.first ?? "focused"
            let outPath = positional.count >= 2 ? positional[1] : "/dev/null"
            let heard = Array(positional.dropFirst(2))
            return CLIOptions(
                runtime: resolvedRuntime,
                model: resolvedModel,
                dryRun: dryRun,
                runtimeReport: runtimeReport,
                profile: profile,
                outPath: outPath,
                heardLines: heard
            )
        }

        guard positional.count >= 3, let _ = ContextProfile(rawValue: positional[0]) else {
            usage(); return nil
        }
        return CLIOptions(
            runtime: resolvedRuntime,
            model: resolvedModel,
            dryRun: false,
            runtimeReport: false,
            profile: positional[0],
            outPath: positional[1],
            heardLines: Array(positional.dropFirst(2))
        )
    }

    public static func usage() {
        let msg = """
        usage:
          dialectic-session [--runtime R] [--model M] [--dry-run] <profile> <out.jsonl> <heard...>
          dialectic-session --runtime-report [--runtime R] [--model M]
          dialectic-session --dry-run [--runtime R] [--model M] [profile]

        flags:
          --runtime R            select runtime: claude (default) | ollama
          --model M              model name (default: claude-sonnet-5 / qwen2.5:0.5b)
          --dry-run              initialize + verify + report; do not generate
          --runtime-report       print runtime diagnostics and exit
          -h, --help             show this help

        environment:
          NEURALCOMPOSE_RUNTIME  default runtime when --runtime is absent
          NEURALCOMPOSE_MODEL    default model when --model is absent

        profiles: focused | reflective | contemplative
        """
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}
