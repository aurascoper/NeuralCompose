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

    func testProsodyTraceWritesSeparateJSONLStream() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = TelemetryLogger(directory: dir)

        let event = ProsodyTraceEvent(
            index: 7,
            sourceKind: "spoken-generation-requested-prosody",
            utteranceText: "Maybe this could work.",
            dialogueState: ["cycle_index": 2, "phrase_index": 1],
            requested: ProsodyFeatureVector(
                speechRate: 0.42,
                pauseBefore: 0.25,
                emphasis: 0.1,
                hesitation: 0.4,
                cadenceClass: "hedged"
            ),
            voiceIdentifier: "test-voice",
            synthesizerIdentifier: "stub"
        )
        await logger.log(event)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current
        let expectedURL = dir.appendingPathComponent("prosody-trace-\(dayFormatter.string(from: Date())).jsonl")

        let contents = try String(contentsOf: expectedURL, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)

        let decoded = try JSONDecoder().decode(ProsodyTraceEvent.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.index, 7)
        XCTAssertEqual(decoded.schemaVersion, ProsodyTraceEvent.currentSchemaVersion)
        XCTAssertEqual(decoded.utteranceText, "Maybe this could work.")
        XCTAssertEqual(decoded.requested?.pauseBefore, 0.25)
        XCTAssertEqual(decoded.requested?.cadenceClass, "hedged")
        XCTAssertNil(decoded.measured, "requested-control trace is not acoustic measurement")
    }

    func testDefaultDirectoryMatchesRecordingsConvention() {
        let expected = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuralCompose")
            .appendingPathComponent("InteractionLogs")
        XCTAssertEqual(TelemetryLogger.defaultDirectory(), expected)
    }

    func testAutobankAndAutoforgetIfNeededFiltersNoiseAndCompactsWhenThresholdExceeded() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let expiredTraceURL = dir.appendingPathComponent("prosody-trace-2026-08-01.jsonl")
        try "{}".write(to: expiredTraceURL, atomically: true, encoding: .utf8)

        let logger = TelemetryLogger(directory: dir)
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current
        let todayStr = dayFormatter.string(from: Date())

        let emb = Embedding(values: [1, 0], modelID: "test", dimension: 2, version: "1", seed: 0)
        let validCand = DialecticalCandidate(text: "Muse S board 39 streams 256 Hz over native BLE.", embedding: emb, roleID: "coherence-seeking")
        let validScored = ScoredCandidate(
            candidate: validCand,
            energy: .init(coherence: 0.9, resonance: 0.8, novelty: 0.4),
            potential: 0.85,
            roleFulfillment: 0.85
        )

        let validTurn = DialecticalTurnEvent(
            DialecticalCompetition(
                index: 1,
                heard: "Should we test out the Bluetooth muse BCI connection to NeuralCompose",
                scored: [validScored],
                tension: 0.06,
                margin: 0.12,
                selectionTemperature: 0.0,
                outcome: .spoke(validCand),
                glossScalar: 0.5,
                selfSimilarity: 0.82
            ),
            runID: "run-valid",
            recordedAt: "2026-11-01T19:29:44.340Z"
        )

        let stutterTurn = DialecticalTurnEvent(
            DialecticalCompetition(
                index: 2,
                heard: "Sex sex sex",
                scored: [validScored],
                tension: 0.04,
                margin: 0.01,
                selectionTemperature: 0.25,
                outcome: .spoke(validCand),
                glossScalar: 0.5,
                selfSimilarity: 0.94
            ),
            runID: "run-valid",
            recordedAt: "2026-11-01T19:30:10.000Z"
        )

        let contemplativeCand = DialecticalCandidate(
            text: "Vizard streams ZeroMQ VizMessage frames from Basilisk while SPICE.jl evaluates planetary ephemeris kernels.",
            embedding: emb,
            roleID: "tension-holding"
        )
        let contemplativeScored = ScoredCandidate(
            candidate: contemplativeCand,
            energy: .init(coherence: 0.92, resonance: 0.88, novelty: 0.65),
            potential: 1.54,
            roleFulfillment: 0.91
        )
        let contemplativeTurn = DialecticalTurnEvent(
            DialecticalCompetition(
                index: 3,
                heard: "What is a wizard about and how it applied to the spice Julia Colonels",
                scored: [contemplativeScored],
                tension: 0.08,
                margin: 0.14,
                selectionTemperature: 0.0,
                outcome: .spoke(contemplativeCand),
                glossScalar: 0.5,
                selfSimilarity: 0.93,
                witnessAttempted: false
            ),
            runID: "run-contemplative",
            recordedAt: "2026-11-01T19:31:00.000Z"
        )

        await logger.log(validTurn)
        await logger.log(stutterTurn)
        await logger.log(contemplativeTurn)

        let report = await logger.autobankAndAutoforgetIfNeeded(
            day: todayStr,
            maxTransientAgeDays: 30,
            maxSelfSimilarity: 0.92,
            compactPrimaryIfNeeded: true,
            collapseRatioThreshold: 0.25
        )

        XCTAssertEqual(report.prunedTransientFiles, 1, "expired transient prosody-trace file must be pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredTraceURL.path))
        XCTAssertEqual(report.evaluatedTurns, 3)
        XCTAssertEqual(report.autobankedTurns, 2, "both validTurn and contemplativeTurn (pot=1.54, witnessAttempted=false) must be autobanked")
        XCTAssertEqual(report.forgottenTurns, 1)
        XCTAssertTrue(report.compactedPrimaryLog)

        let autobankURL = dir.appendingPathComponent("dialectic-autobank-\(todayStr).jsonl")
        let autobankLines = try String(contentsOf: autobankURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(autobankLines.count, 2)

        let backupURL = dir.appendingPathComponent("dialectic-turns-\(todayStr).jsonl.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "compacting primary log must preserve .bak snapshot")
    }

    func testLogSanitizesEmAndEnDashesAtWriteTime() async throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logger = TelemetryLogger(directory: dir)
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current
        let todayStr = dayFormatter.string(from: Date())

        let emb = Embedding(values: [1, 0], modelID: "test", dimension: 2, version: "1", seed: 0)
        let cand = DialecticalCandidate(
            text: "Translation isn't the failure\u{2014}M7.1 is a header\u{2013}float is a type.",
            embedding: emb,
            roleID: "displacement-seeking"
        )
        let scored = ScoredCandidate(
            candidate: cand,
            energy: .init(coherence: 0.93, resonance: 0.85, novelty: 0.10),
            potential: 1.73,
            roleFulfillment: 0.90
        )
        let turn = DialecticalTurnEvent(
            DialecticalCompetition(
                index: 34,
                heard: "Saying things like M71M8\u{2014}header versus float\u{2013}classification",
                scored: [scored],
                tension: 0.04,
                margin: 0.01,
                selectionTemperature: 0.48,
                outcome: .spoke(cand),
                glossScalar: 0.1,
                witnessFinding: "Both treat M71M8\u{2014}or float\u{2013}decimal as sorted.",
                selfSimilarity: 0.90,
                witnessAttempted: true
            ),
            runID: "run-dash-test",
            recordedAt: "2026-11-02T06:58:31.206Z"
        )

        await logger.log(turn)

        let logURL = dir.appendingPathComponent("dialectic-turns-\(todayStr).jsonl")
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("\u{2014}"), "JSONL must not contain em-dash")
        XCTAssertFalse(contents.contains("\u{2013}"), "JSONL must not contain en-dash")
        XCTAssertTrue(contents.contains(" - "), "Em-dashes and en-dashes must be sanitized to ' - '")
    }
}
