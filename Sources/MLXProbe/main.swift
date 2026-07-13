import BCILLM
import Foundation

// Thin CLI wrapper over `MLXInitProbe.run(...)` — the actual init/generate
// logic lives in BCILLM so `PredictorFactory`'s subprocess probe and this
// executable run the exact same sequence, not two implementations that can
// drift apart.
//
// Usage:
//   MLXProbe [--backend qwen|gemma] <model-directory> [prompt]
//       human-readable output
//   MLXProbe --json [--backend qwen|gemma] <model-directory> [prompt]
//       exactly one JSON line on stdout (ProbeResult) — this is what
//       PredictorFactory parses
//
// `--backend` selects which GenerationConfiguration (EOS tokens,
// repetition penalty) to load the model with; defaults to `qwen`. It does
// not change which model directory gets loaded — that's still whatever
// directory is passed positionally.
//
// Needs the Xcode-built binary to reach the real MLX path — a bare
// `swift build` binary crashes on metallib load (pre-existing, documented
// limitation, unrelated to this tool). Build via
// `./Scripts/build-xcode-mlx.sh`, then run the product it produces.

var jsonMode = false
var backend = MLXBackend.qwen
var positional: [String] = []
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--json":
        jsonMode = true
    case "--backend":
        guard let value = args.next(), let parsed = MLXBackend(rawValue: value) else {
            FileHandle.standardError.write(
                "MLXProbe: --backend requires one of: \(MLXBackend.allCases.map(\.rawValue).joined(separator: ", "))\n"
                    .data(using: .utf8)!
            )
            exit(1)
        }
        backend = parsed
    default:
        positional.append(arg)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard let modelDirectoryArg = positional.first else {
    fail("Usage: MLXProbe [--json] [--backend qwen|gemma] <model-directory> [prompt]")
}

let modelDirectory = URL(fileURLWithPath: modelDirectoryArg)
let prompt = positional.count > 1 ? positional[1] : "Say the word no"

if !jsonMode {
    print("MLXProbe: model directory = \(modelDirectory.path)")
    print("MLXProbe: directory exists = \(FileManager.default.fileExists(atPath: modelDirectory.path))")
    print("MLXProbe: prompt = \"\(prompt)\"")
}

let result = await MLXInitProbe.run(
    modelDirectory: modelDirectory, configuration: backend.configuration,
    prompt: prompt, maxTokens: 120, temperature: 0.7
)

if jsonMode {
    // Exactly one line on stdout — nothing else. `PredictorFactory` reads
    // this whole stream and decodes it as `ProbeResult`.
    guard let data = try? JSONEncoder().encode(result),
          let line = String(data: data, encoding: .utf8) else {
        fail("MLXProbe: failed to encode ProbeResult as JSON")
    }
    print(line)
} else {
    switch result {
    case .success(let metrics):
        print("MLXProbe: SUCCESS")
        print("  modelIdentifier    = \(metrics.modelIdentifier)")
        print("  modelLoadTime      = \(metrics.modelLoadTime)s")
        print("  firstTokenLatency  = \(metrics.firstTokenLatency)s")
        print("  totalGenerateTime  = \(metrics.totalGenerateTime)s")
        print("  tokensPerSecond    = \(metrics.tokensPerSecond)")
        print("  output             = \"\(metrics.generatedText)\"")
    case .failed(let reason):
        print("MLXProbe: FAILED — \(reason)")
    case .timeout, .crashed:
        // Not producible in-process — `MLXInitProbe.run` only ever returns
        // `.success`/`.failed` (see its doc comment). Exhaustive switch,
        // not a real code path here.
        print("MLXProbe: unexpected result: \(result)")
    }
}

switch result {
case .success:
    exit(0)
default:
    exit(1)
}
