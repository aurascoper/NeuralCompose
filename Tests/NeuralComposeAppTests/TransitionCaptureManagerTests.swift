import XCTest
@testable import BCICore
@testable import NeuralComposeApp

final class TransitionCaptureManagerTests: XCTestCase {

    private func state(_ timestamp: TimeInterval) -> JEPASpectralState {
        JEPASpectralState(
            timestamp: timestamp,
            alphaPower: Float(timestamp + 1),
            betaPower: Float(timestamp + 2),
            thetaPower: Float(timestamp + 3),
            channelPowers: [Float(timestamp + 4)]
        )
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jepa-transition-capture-test-\(UUID().uuidString)")
    }

    func testDoesNotRecordUntilPreActionWindowIsFull() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TransitionCaptureManager(
            eegBuffer: JEPASpectralStateRingBuffer(capacity: 2),
            predictionHorizon: 0,
            fileURL: directory.appendingPathComponent("transitions.jsonl")
        )

        manager.ingest(state(0))
        XCTAssertNil(manager.recordTransition(actionVector: [1, 0.7, 0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testWritesOneDecodableJSONLTransitionAfterHorizon() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("transitions.jsonl")
        let manager = TransitionCaptureManager(
            eegBuffer: JEPASpectralStateRingBuffer(capacity: 2),
            predictionHorizon: 0,
            fileURL: fileURL
        )
        manager.ingest(state(10))
        manager.ingest(state(11))

        let task = try XCTUnwrap(manager.recordTransition(actionVector: [1, 0.7, 0]))
        await task.value

        let line = try XCTUnwrap(String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first)
        let transition = try JSONDecoder().decode(JEPATransition.self, from: Data(line.utf8))
        XCTAssertEqual(transition.preActionWindow.map(\.timestamp), [10, 11])
        XCTAssertEqual(transition.postActionWindow.map(\.timestamp), [10, 11])
        XCTAssertEqual(transition.actionVector, [1, 0.7, 0])
    }

    /// Regression test for a real bug: `JEPASpectralStateRingBuffer.isFull`
    /// was a one-way latch that never reset, so a manager reused across a
    /// disable/re-enable of the capture toggle would return stale
    /// pre-toggle-off contents as a "complete" window instead of correctly
    /// warming up again from scratch.
    func testClearResetsToPreWarmupState() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let buffer = JEPASpectralStateRingBuffer(capacity: 2)
        let manager = TransitionCaptureManager(
            eegBuffer: buffer,
            predictionHorizon: 0,
            fileURL: directory.appendingPathComponent("transitions.jsonl")
        )
        manager.ingest(state(0))
        manager.ingest(state(1))
        XCTAssertNotNil(manager.recordTransition(actionVector: [1, 0.7, 0]), "buffer must be full before clear")

        manager.clear()

        // Immediately after clear, the buffer must behave exactly like a
        // fresh one warming up — not return the stale pre-clear window.
        XCTAssertNil(manager.recordTransition(actionVector: [1, 0.7, 0]), "must not serve stale data after clear()")
        manager.ingest(state(2))
        XCTAssertNil(manager.recordTransition(actionVector: [1, 0.7, 0]), "must still be warming up with only 1 of 2 slots filled")
        manager.ingest(state(3))
        XCTAssertNotNil(manager.recordTransition(actionVector: [1, 0.7, 0]), "must be full again once genuinely refilled")
    }

    func testOverlappingCapturesAppendSeparateJSONLines() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("transitions.jsonl")
        let manager = TransitionCaptureManager(
            eegBuffer: JEPASpectralStateRingBuffer(capacity: 2),
            predictionHorizon: 0,
            fileURL: fileURL
        )
        manager.ingest(state(20))
        manager.ingest(state(21))

        let first = try XCTUnwrap(manager.recordTransition(actionVector: [1, 0.7, 0]))
        let second = try XCTUnwrap(manager.recordTransition(actionVector: [2.0 / 3.0, 0.3, 1]))
        await first.value
        await second.value

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            XCTAssertNoThrow(try JSONDecoder().decode(JEPATransition.self, from: Data(line.utf8)))
        }
    }
}
