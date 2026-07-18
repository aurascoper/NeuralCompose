import Foundation

/// Tiny, self-contained — duplicated rather than shared with
/// `SemanticEval/GitInfo.swift`'s identical helper, same rationale that
/// file's own doc comment already gives for duplicating
/// `EmbeddingBench/SystemInfo.swift`'s equivalent: not worth a
/// shared-utility target for a ten-line function.
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
