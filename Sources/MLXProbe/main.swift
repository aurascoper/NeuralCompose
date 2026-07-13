import BCILLM
import Foundation

// Standalone, isolated MLX load probe — deliberately has none of
// `PredictorFactory`'s machinery: no subprocess spawn, no semaphore bridge,
// no SwiftUI/App lifecycle. Exists to answer one question during the
// "why does the MLX probe subprocess stall" investigation: does
// `MLXNextWordPredictor.init()` itself hang/succeed/fail when run directly,
// independent of everything `PredictorFactory`/`NeuralComposeAppEntry` wrap
// around it? If this hangs, the problem is in model loading. If it
// succeeds quickly, the problem is in the probe/subprocess/semaphore
// architecture around it, not MLX itself.
//
// Usage: swift run MLXProbe <model-directory>
//    or: .build/xcode/Build/Products/Debug/MLXProbe <model-directory>
//
// Temporary diagnostic tool — not part of the app, not wired into
// `PredictorFactory`. Delete once the stall is diagnosed.

print("MLXProbe: CommandLine.arguments = \(CommandLine.arguments)")
print("MLXProbe: Bundle.main.bundlePath = \(Bundle.main.bundlePath)")
print("MLXProbe: Bundle.main.resourcePath = \(Bundle.main.resourcePath ?? "nil")")
print("MLXProbe: FileManager.default.currentDirectoryPath = \(FileManager.default.currentDirectoryPath)")

guard CommandLine.arguments.count > 1 else {
    print("MLXProbe: usage: MLXProbe <model-directory>")
    exit(1)
}

let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
print("MLXProbe: model directory = \(modelDirectory.path)")
print("MLXProbe: directory exists = \(FileManager.default.fileExists(atPath: modelDirectory.path))")

let start = Date()
print("MLXProbe: about to construct MLXNextWordPredictor — \(Date())")

do {
    let predictor = try await MLXNextWordPredictor(modelDirectory: modelDirectory)
    let elapsed = Date().timeIntervalSince(start)
    print("MLXProbe: SUCCESS after \(elapsed)s — modelIdentifier=\(predictor.modelIdentifier)")

    // Also exercise a real generate() call — the actual thing the app needs,
    // not just a successful load — while we're isolated and can see output.
    // Optional second CLI argument overrides the default prompt.
    let prompt = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Say the word no"
    let genStart = Date()
    let output = try await predictor.generate(
        prompt: prompt, maxTokens: 120, temperature: 0.7, cancellationID: UUID()
    )
    let genElapsed = Date().timeIntervalSince(genStart)
    print("MLXProbe: prompt: \"\(prompt)\"")
    print("MLXProbe: generate() returned after \(genElapsed)s: \"\(output)\"")
    exit(0)
} catch {
    let elapsed = Date().timeIntervalSince(start)
    print("MLXProbe: FAILED after \(elapsed)s — error: \(error)")
    exit(1)
}
