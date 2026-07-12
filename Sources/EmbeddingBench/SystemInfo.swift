import CryptoKit
import Darwin
import Foundation

/// Host machine and build identity for benchmark provenance. Isolated here
/// so `BenchmarkRunner` stays free of Darwin/`Process` specifics.
enum SystemInfo {
    /// Human-readable device name, e.g. `"Apple M4"`.
    static func device() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// `"26.5.2"`-style OS version string.
    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The current commit, via `git rev-parse HEAD`. `"unknown"` if the
    /// binary is run outside a git checkout.
    static func buildSHA() -> String {
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

    /// Resident set size of the current process, in megabytes.
    static func residentSetSizeMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    /// SHA-256 hex digest of a single file's contents.
    static func sha256(ofFileAt url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 hex digest of a directory (e.g. a `.mlmodelc` bundle):
    /// concatenates every regular file's contents in sorted relative-path
    /// order, then hashes the result. Sorted order makes this deterministic
    /// regardless of the filesystem's directory-enumeration order.
    static func sha256(ofDirectoryAt url: URL) -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        let files = enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.path < $1.path }

        var hasher = SHA256()
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
