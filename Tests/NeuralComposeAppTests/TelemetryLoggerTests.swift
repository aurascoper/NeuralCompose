import XCTest
@testable import NeuralComposeApp
@testable import BCICore

final class TelemetryLoggerTests: XCTestCase {

    private func makeEvent(word: String, timestamp: Date = Date()) -> TelemetryEvent {
        TelemetryEvent(
            timestamp: timestamp,
            composedContextBeforeCommit: "the quick",
            committedWord: word,
            signalQuality: "healthy",
            detectedSpectralState: "Engaged/focused",
            appliedMaxCandidates: 3,
            appliedTemperature: 0.7,
            appliedStyleInstruction: "",
            adaptiveComplexityEnabled: true
        )
    }

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-logger-test-\(UUID().uuidString)")
    }

    func testLogAppendsOneValidJSONLLinePerEvent() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = TelemetryLogger(directory: dir)

        let today = Date()
        await logger.log(makeEvent(word: "fox", timestamp: today))
        await logger.log(makeEvent(word: "jumps", timestamp: today))

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current
        let expectedURL = dir.appendingPathComponent("interactions-\(dayFormatter.string(from: today)).jsonl")

        let contents = try String(contentsOf: expectedURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "one line per logged event")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let firstEvent = try decoder.decode(TelemetryEvent.self, from: Data(lines[0].utf8))
        let secondEvent = try decoder.decode(TelemetryEvent.self, from: Data(lines[1].utf8))
        XCTAssertEqual(firstEvent.committedWord, "fox")
        XCTAssertEqual(secondEvent.committedWord, "jumps")
    }

    func testLogCreatesDirectoryIfMissing() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let logger = TelemetryLogger(directory: dir)
        await logger.log(makeEvent(word: "hello"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testEventsOnDifferentDaysGoToDifferentFiles() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = TelemetryLogger(directory: dir)

        let day1 = Date(timeIntervalSince1970: 1_752_000_000) // 2025-07-08
        let day2 = Date(timeIntervalSince1970: 1_752_100_000) // ~1.16 days later
        await logger.log(makeEvent(word: "first", timestamp: day1))
        await logger.log(makeEvent(word: "second", timestamp: day2))

        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(entries.count, 2, "events on different calendar days must land in separate files, found: \(entries)")
    }

    func testDefaultDirectoryMatchesRecordingsConvention() {
        let expected = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuralCompose")
            .appendingPathComponent("InteractionLogs")
        XCTAssertEqual(TelemetryLogger.defaultDirectory(), expected)
    }
}
