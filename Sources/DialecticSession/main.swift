import BCICore
import BCICloudBridge
import Foundation

// Headless, scripted run of the FULL HypnagogicDialecticLoop with REAL generation
// calls (and the introspective Witness for the reflective profile) — the
// seed-002 Focused-vs-Reflective experiment tool, generalized to runtime
// selection.
//
// Usage:
//   dialectic-session [--runtime R] [--model M] [--dry-run] <profile> <out.jsonl> <heard...>
//   dialectic-session --runtime-report [--runtime R] [--model M]
//   dialectic-session --dry-run [--runtime R] [--model M] [profile]
//
// Runtime selection precedence: --runtime > NEURALCOMPOSE_RUNTIME > "claude".
// Model selection precedence: --model > NEURALCOMPOSE_MODEL > default-for-runtime.
// Defaults preserve the existing harness behavior: --runtime claude --model
// claude-sonnet-5 (the same `claude -p` invocation the legacy harness used).
//
// ⚠️ CLOUD EGRESS: 2 generation calls/turn (3 for reflective — the Witness).
// Text only.

guard let opts = CLIOptions.parse(Array(CommandLine.arguments.dropFirst())) else {
    exit(2)
}

// Runtime-report and dry-run short-circuit before opening any output file or
// starting the loop. They are the CI / smoke-test entry points.
if opts.runtimeReport {
    do {
        let resolved = try RuntimeFactory.make(
            runtimeName: opts.runtime,
            model: opts.model
        )
        print("● dialectic-session — runtime-report")
        print("● runtime=\(opts.runtime)  model=\(opts.model)  profile=\(opts.profile)")
        print("")
        RuntimeReport.render(resolved: resolved, runtimeName: opts.runtime, model: opts.model)
        let v = RuntimeReport.verify(resolved: resolved)
        print("")
        print("Verification:")
        print("  prompt loaded:       \(v.promptLoaded ? "yes" : "no")")
        print("  transport reachable: \(v.transportOK ? "yes" : "no")")
        print("  model available:     \(v.modelAvailable ? "yes" : "no")")
        exit(v.promptLoaded && v.transportOK && v.modelAvailable ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

if opts.dryRun {
    do {
        let resolved = try RuntimeFactory.make(
            runtimeName: opts.runtime,
            model: opts.model
        )
        print("● dialectic-session — dry-run")
        print("● runtime=\(opts.runtime)  model=\(opts.model)  profile=\(opts.profile)")
        print("")
        RuntimeReport.render(resolved: resolved, runtimeName: opts.runtime, model: opts.model)
        let v = RuntimeReport.verify(resolved: resolved)
        print("")
        print("Verification:")
        print("  prompt loaded:       \(v.promptLoaded ? "yes" : "no")")
        print("  transport reachable: \(v.transportOK ? "yes" : "no")")
        print("  model available:     \(v.modelAvailable ? "yes" : "no")")
        if !(v.promptLoaded && v.transportOK && v.modelAvailable) {
            FileHandle.standardError.write(Data("dry-run failed verification\n".utf8))
            exit(1)
        }
        print("")
        print("✓ runtime created")
        print("✓ transport reachable")
        print("✓ model exists")
        print("✓ prompt loaded")
        print("✓ fingerprint generated")
        print("")
        print("No LLM call was made.")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}

// Live path: positional contract (profile, out.jsonl, heard...).
// `opts` already carries the parsed values; no need to re-parse
// `CommandLine.arguments` (which would treat `--runtime` and
// `--model` as positional).
guard let profile = ContextProfile(rawValue: opts.profile) else {
    FileHandle.standardError.write(Data("error: invalid profile '\(opts.profile)'\n".utf8))
    exit(2)
}
let outPath = opts.outPath
let heardLines = opts.heardLines

// Resolve the runtime through the factory. The factory is the only
// place that knows about the (runtime, model) → GenerationRuntime mapping.
// For `claude`, the legacy `ClaudeCLIGenerator` (which the existing harness
// uses) is wrapped via the `GenerationRuntimeTextGeneratingAdapter`; for
// `ollama`, the new `OllamaGenerationRuntime` is wrapped the same way.
let resolved: ResolvedRuntime
do {
    resolved = try RuntimeFactory.make(
        runtimeName: opts.runtime,
        model: opts.model
    )
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

let poleGenerator = GenerationRuntimeTextGeneratingAdapter(
    runtime: resolved.runtime,
    systemPrompt: resolved.systemPrompt
)
let witnessGenerator: GenerationRuntimeTextGeneratingAdapter? = profile.witnessEnabled
    ? GenerationRuntimeTextGeneratingAdapter(
        runtime: resolved.runtime,
        systemPrompt: (try? PromptProfile.witness.load()) ?? ""
    )
    : nil

print("● dialectic-session — profile=\(profile.rawValue) witness=\(profile.witnessEnabled) "
      + "runtime=\(opts.runtime) model=\(opts.model) turns=\(heardLines.count) → \(outPath)")

// Fail fast if the output file can't be opened.
guard let logger = FileLogger(outPath) else { exit(1) }

let loop = HypnagogicDialecticLoop(
    listener: ScriptedListener(heardLines),
    generator: poleGenerator,
    speaker: SilentSpeaker(),
    embedder: DeterministicSentenceEmbedder(),
    roles: DialecticalRole.wakingRoles,
    tuning: profile.tuning,
    turnLogger: logger,
    witness: witnessGenerator,
    config: profile.loopConfig(base: HypnagogicDialecticLoop.Config(
        listenTimeout: 2, interTurnDelayNanos: 100_000_000)))

await loop.start()
let deadline = Date().addingTimeInterval(Double(heardLines.count) * 40 + 30)
var lastIdx = 0
var lastProgress = Date()
while await loop.turnIndex < heardLines.count, Date() < deadline {
    try? await Task.sleep(nanoseconds: 500_000_000)
    let idx = await loop.turnIndex
    if idx > lastIdx {
        lastIdx = idx; lastProgress = Date()
    } else if Date().timeIntervalSince(lastProgress) > 90 {
        FileHandle.standardError.write(Data(
            "warning: no turn progress for 90s (turn \(idx) likely failing); stopping early\n".utf8))
        break
    }
}
await loop.stop()
let done = await loop.turnIndex
let written = await logger.written
let failed = await logger.failed
await logger.finish()
print("● done — \(done)/\(heardLines.count) turns run; \(written) lines written"
      + (failed ? " (WRITE FAILURES)" : ""))
exit(written >= heardLines.count && !failed ? 0 : 1)

// MARK: - Local harness types

/// Feeds fixed lines one per turn, then reports silence (nil) so the loop idles.
actor ScriptedListener: HypnagogicListening {
    nonisolated let isLive = false
    private var lines: [String]
    init(_ lines: [String]) { self.lines = lines }
    func requestAuthorization() async -> Bool { true }
    func listen(timeout: TimeInterval) async throws -> String? {
        if lines.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000); return nil }
        return lines.removeFirst()
    }
    func cancel() async {}
}

/// No-op speaker — the harness cares about telemetry, not audio.
struct SilentSpeaker: SpeechSynthesizing {
    nonisolated let isLive = false
    nonisolated let voiceIdentifier = "harness-silent"
    func speak(_ text: String) async throws {}
    func speak(_ text: String, prosody: SpeechProsody) async throws {}
    func speak(_ text: String, prosody: SpeechProsody, onWord: (@Sendable (SpokenWord) -> Void)?) async throws {}
    func stopSpeaking() async {}
}

/// Appends one JSON line per turn to a fresh <path>. Fails LOUDLY: a bad
/// path (failable init) or any write/encode error (stderr + `failed`) is
/// surfaced, and `written` counts lines actually on disk. The harness gates
/// exit 0 on `written`, never on loop progress.
actor FileLogger: DialecticalTurnLogging {
    private let handle: FileHandle
    private let enc = JSONEncoder()
    private(set) var written = 0
    private(set) var failed = false

    init?(_ path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else {
            FileHandle.standardError.write(Data("error: cannot open output file '\(path)'\n".utf8))
            return nil
        }
        handle = fh
    }
    func log(_ event: DialecticalTurnEvent) async {
        do {
            try handle.write(contentsOf: enc.encode(event))
            try handle.write(contentsOf: Data("\n".utf8))
            written += 1
        } catch {
            failed = true
            FileHandle.standardError.write(Data("error: failed to write a turn: \(error)\n".utf8))
        }
    }
    func finish() { try? handle.close() }
}
