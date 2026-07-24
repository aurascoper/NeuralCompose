import BCICore
import BCICloudBridge
import Foundation

// Phase-1 runtime smoke test for the co-development loop.
//
// Proves Sonnet 5 is reachable and healthy as the app's runtime agent — driven
// through the EXACT `ClaudeCLIGenerator` (`claude -p --model claude-sonnet-5`)
// and the waking role prompts the dialectical loop uses — with no headband, no
// EEG, and no GUI. The user's "Phase 1: establish that the runtime behaves
// consistently" before any live/EEG run.
//
// Usage:  swift run dialectic-smoke ["what was heard"]
// Exit 0 = both role voices returned non-empty text; exit 1 = any failure.

let heard = CommandLine.arguments.dropFirst().first
    ?? "I keep starting projects and never finishing them."

let generator: ClaudeCLIGenerator
do {
    generator = try ClaudeCLIGenerator(
        systemPrompt: ClaudeCLIGenerator.wakingDialecticalSystemPrompt()
    )
} catch {
    FileHandle.standardError.write(Data("● dialectic-smoke: \(error)\n".utf8))
    exit(1)
}

print("● dialectic-smoke — model: \(generator.modelIdentifier)")
print("● heard: \"\(heard)\"\n")

var anyFailure = false
for role in DialecticalRole.wakingRoles {
    let prompt = role.promptShaper(heard, 0.5)
    do {
        let reply = try await generator.generate(
            prompt: prompt,
            maxTokens: 128,
            temperature: role.temperature,
            cancellationID: UUID()
        )
        if reply.isEmpty {
            print("✗ \(role.id): EMPTY reply")
            anyFailure = true
        } else {
            print("✓ \(role.id) (temp \(role.temperature)):")
            print("    \(reply)\n")
        }
    } catch {
        print("✗ \(role.id): \(error)")
        anyFailure = true
    }
}

if anyFailure {
    print("dialectic-smoke: FAILED — Sonnet 5 runtime not healthy")
    exit(1)
}
print("dialectic-smoke: OK — Sonnet 5 waking dialectic reachable")
