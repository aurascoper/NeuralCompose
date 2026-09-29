import Foundation
import XCTest

/// `SemanticEval` is an executable, so these tests run the built binary.
///
/// Each run starts in an empty temporary folder. A regression that evaluates
/// instead of refusing then cannot write into the repository's `Evaluation/`
/// folder, and the test can see whether anything was written at all.
final class SemanticEvalArgumentsTests: XCTestCase {

    private struct Run {
        let status: Int32
        let stderr: String
        let wroteEvaluation: Bool
    }

    /// BSD `EX_USAGE`. `SemanticEval` uses 1 for "the evaluation failed", so
    /// the two outcomes stay distinguishable.
    private let usageExitCode: Int32 = 64

    private func runSemanticEval(_ arguments: [String]) throws -> Run {
        let testBundle = try XCTUnwrap(
            Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") },
            "no .xctest bundle is loaded, so the build products folder can't be located")
        let binary = testBundle.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SemanticEval")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("SemanticEval is not built at \(binary.path)")
            throw CocoaError(.fileNoSuchFile)
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticEvalArgumentsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workingDirectory) }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Run(
            status: process.terminationStatus,
            stderr: String(decoding: stderrData, as: UTF8.self),
            wroteEvaluation: FileManager.default.fileExists(
                atPath: workingDirectory.appendingPathComponent("Evaluation").path))
    }

    private func assertUsageError(
        _ arguments: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let run = try runSemanticEval(arguments)
        XCTAssertEqual(run.status, usageExitCode, "stderr: \(run.stderr)", file: file, line: line)
        XCTAssertTrue(
            run.stderr.contains("Usage: SemanticEval"),
            "expected usage on stderr, got: \(run.stderr)", file: file, line: line)
        XCTAssertFalse(run.wroteEvaluation, "a usage error must not evaluate", file: file, line: line)
    }

    func testHelpPrintsUsageAndExitsWithoutEvaluating() throws {
        try assertUsageError(["--help"])
    }

    func testUnknownFlagIsAUsageError() throws {
        try assertUsageError(["--verbose"])
    }

    func testModelFlagWithoutAValueIsAUsageError() throws {
        try assertUsageError(["--model"])
    }

    /// Control: a well-formed argument list gets past the parser. In an empty
    /// folder the evaluator then stops for lack of a model, which is its own
    /// failure (status 1) and not a usage error.
    func testValidModelArgumentReachesTheEvaluator() throws {
        let run = try runSemanticEval(["--model", "bge"])
        XCTAssertEqual(run.status, 1, "stderr: \(run.stderr)")
        XCTAssertTrue(run.stderr.contains("No BGE model"), "got: \(run.stderr)")
        XCTAssertFalse(run.stderr.contains("Usage: SemanticEval"))
    }
}
