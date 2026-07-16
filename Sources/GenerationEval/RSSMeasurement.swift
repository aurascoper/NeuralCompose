import Darwin
import Foundation

/// Tiny, self-contained — duplicated rather than shared with
/// `EmbeddingBench/SystemInfo.swift`'s equivalent helper, same rationale
/// `GitInfo.swift` already documents for its own duplication: not worth a
/// shared-utility target for a ten-line function.
enum RSSMeasurement {
    /// Human-readable device name, e.g. `"Apple M4"` — used instead of
    /// `ProcessInfo.hostName` for provenance, since a hostname can embed a
    /// personal machine/user name and this artifact may end up committed or
    /// shared.
    static func device() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
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
}
