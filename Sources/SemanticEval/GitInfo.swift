import Foundation

/// Tiny, self-contained — duplicated rather than shared with
/// `EmbeddingBench/SystemInfo.swift`'s equivalent helper, same rationale as
/// `SplitMix64` being duplicated across the codebase rather than factored
/// out for a ten-line utility.
enum GitInfo {
    static func commitSHA() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "HEAD"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let sha = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (sha?.isEmpty == false) ? sha! : "unknown"
        } catch {
            return "unknown"
        }
    }
}
