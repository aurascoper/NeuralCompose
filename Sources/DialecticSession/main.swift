import BCICore
import BCICloudBridge
import Foundation

// Headless, scripted run of the FULL HypnagogicDialecticLoop with REAL Sonnet
// cloud calls (and the introspective Witness for the reflective profile) — the
// seed-002 Focused-vs-Reflective experiment tool. No mic, no Muse, no GUI: a
// scripted listener feeds fixed "heard" lines so a Focused and a Reflective run
// can be compared on identical input. Logs dialectic-turns JSONL to <outfile>,
// which `Scripts/session-seed.py` rolls up.
//
// Usage: dialectic-session <focused|reflective|contemplative> <out.jsonl> <heard...>
// ⚠️ CLOUD EGRESS: 2 Sonnet calls/turn (3 for reflective — the Witness). Text only.

let a = Array(CommandLine.arguments.dropFirst())
guard a.count >= 3, let profile = ContextProfile(rawValue: a[0]) else {
    FileHandle.standardError.write(Data(
        "usage: dialectic-session <focused|reflective|contemplative> <out.jsonl> <heard...>\n".utf8))
    exit(2)
}
let outPath = a[1]
let heardLines = Array(a[2...])

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

/// Appends one JSON line per turn to a fresh <path>, holding ONE open handle for
/// the run. Fails LOUDLY: a bad path (failable init) or any write/encode error
/// (stderr + `failed`) is surfaced, and `written` counts lines actually on disk.
/// The harness gates exit 0 on `written`, never on loop progress — so a short,
/// empty, or biased experiment file can never masquerade as a clean run.
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

print("● dialectic-session — profile=\(profile.rawValue) witness=\(profile.witnessEnabled) "
      + "turns=\(heardLines.count) → \(outPath)")

// Fail fast if the output file can't be opened (else a whole run's cloud egress
// is spent logging nothing while the loop happily advances).
guard let logger = FileLogger(outPath) else { exit(1) }

let loop = HypnagogicDialecticLoop(
    listener: ScriptedListener(heardLines),
    generator: ClaudeCLIGenerator(systemPrompt: ClaudeCLIGenerator.wakingDialecticalSystemPrompt),
    speaker: SilentSpeaker(),
    embedder: DeterministicSentenceEmbedder(),
    roles: DialecticalRole.wakingRoles,
    tuning: profile.tuning,
    turnLogger: logger,
    witness: profile.witnessEnabled
        ? ClaudeCLIGenerator(systemPrompt: ClaudeCLIGenerator.witnessSystemPrompt)
        : nil,
    config: profile.loopConfig(base: HypnagogicDialecticLoop.Config(
        listenTimeout: 2, interTurnDelayNanos: 100_000_000)))

await loop.start()
// Backstop scales with the input; break EARLY if a turn stalls (a failed cloud
// call doesn't advance turnIndex) rather than burning the whole budget in silence.
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
// Exit 0 ONLY if every scripted turn actually landed on disk and no write failed —
// gated on lines-written, NOT on loop progress, so a short/empty file can't pass.
exit(written >= heardLines.count && !failed ? 0 : 1)
