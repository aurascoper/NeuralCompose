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

/// Appends one JSON line per turn to <outPath> (a fresh file per run).
actor FileLogger: DialecticalTurnLogging {
    private let url: URL
    private let enc = JSONEncoder()
    init(_ path: String) {
        url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    func log(_ event: DialecticalTurnEvent) async {
        guard let data = try? enc.encode(event) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); fh.write(data); fh.write(Data("\n".utf8)); try? fh.close()
        }
    }
}

print("● dialectic-session — profile=\(profile.rawValue) witness=\(profile.witnessEnabled) "
      + "turns=\(heardLines.count) → \(outPath)")

let loop = HypnagogicDialecticLoop(
    listener: ScriptedListener(heardLines),
    generator: ClaudeCLIGenerator(systemPrompt: ClaudeCLIGenerator.wakingDialecticalSystemPrompt),
    speaker: SilentSpeaker(),
    embedder: DeterministicSentenceEmbedder(),
    roles: DialecticalRole.wakingRoles,
    tuning: profile.tuning,
    turnLogger: FileLogger(outPath),
    witness: profile.witnessEnabled
        ? ClaudeCLIGenerator(systemPrompt: ClaudeCLIGenerator.witnessSystemPrompt)
        : nil,
    config: profile.loopConfig(base: HypnagogicDialecticLoop.Config(
        listenTimeout: 2, interTurnDelayNanos: 100_000_000)))

await loop.start()
// Run until every scripted turn is logged (or a wall-clock backstop for a hung call).
let deadline = Date().addingTimeInterval(300)
while await loop.turnIndex < heardLines.count, Date() < deadline {
    try? await Task.sleep(nanoseconds: 500_000_000)
}
await loop.stop()
let done = await loop.turnIndex
print("● done — \(done)/\(heardLines.count) turns logged")
exit(done >= heardLines.count ? 0 : 1)
