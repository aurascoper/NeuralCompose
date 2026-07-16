import BCILLM
import Foundation

// Thin CLI wrapper over `SpectralInitProbe.run(...)` — the actual
// load/forward-pass logic lives in BCILLM so `SpectralStateEstimatorFactory`'s
// subprocess probe and this executable run the exact same sequence, not two
// implementations that can drift apart. Mirrors `MLXProbe`'s structure.
//
// Usage:
//   SpectralProbe <model-directory>
//       human-readable output
//   SpectralProbe --json <model-directory>
//       exactly one JSON line on stdout (SpectralProbeResult) — this is
//       what SpectralStateEstimatorFactory parses
//
// Needs the Xcode-built binary to reach the real MLX path — a bare
// `swift build` binary crashes on metallib load (pre-existing, documented
// limitation, unrelated to this tool). Build via
// `./Scripts/build-xcode-mlx.sh`, then run the product it produces.

var jsonMode = false
var positional: [String] = []
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--json":
        jsonMode = true
    default:
        positional.append(arg)
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

guard let modelDirectoryArg = positional.first else {
    fail("Usage: SpectralProbe [--json] <model-directory>")
}

let modelDirectory = URL(fileURLWithPath: modelDirectoryArg)

if !jsonMode {
    print("SpectralProbe: model directory = \(modelDirectory.path)")
    print("SpectralProbe: directory exists = \(FileManager.default.fileExists(atPath: modelDirectory.path))")
}

let result = await SpectralInitProbe.run(modelDirectory: modelDirectory)

if jsonMode {
    // Exactly one line on stdout — nothing else. `SpectralStateEstimatorFactory`
    // reads this whole stream and decodes it as `SpectralProbeResult`.
    guard let data = try? JSONEncoder().encode(result),
          let line = String(data: data, encoding: .utf8) else {
        fail("SpectralProbe: failed to encode SpectralProbeResult as JSON")
    }
    print(line)
} else {
    switch result {
    case .success(let metrics):
        print("SpectralProbe: SUCCESS")
        print("  modelLoadTime      = \(metrics.modelLoadTime)s")
        print("  forwardPassLatency = \(metrics.forwardPassLatency)s")
        print("  outputDimension    = \(metrics.outputDimension)")
        print("  outputL2Norm       = \(metrics.outputL2Norm)")
    case .failed(let reason):
        print("SpectralProbe: FAILED — \(reason)")
    case .timeout, .crashed:
        // Not producible in-process — `SpectralInitProbe.run` only ever
        // returns `.success`/`.failed`. Exhaustive switch, not a real code
        // path here.
        print("SpectralProbe: unexpected result: \(result)")
    }
}

switch result {
case .success:
    exit(0)
default:
    exit(1)
}
