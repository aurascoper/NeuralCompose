import XCTest
@testable import BCICore

final class JEPATransitionTests: XCTestCase {

    private func state(_ timestamp: TimeInterval) -> JEPASpectralState {
        JEPASpectralState(
            timestamp: timestamp,
            alphaPower: Float(timestamp + 1),
            betaPower: Float(timestamp + 2),
            thetaPower: Float(timestamp + 3),
            channelPowers: [Float(timestamp + 4), Float(timestamp + 5)]
        )
    }

    func testRingRejectsPartialWindowsAndUnrollsChronologicallyAfterWrap() {
        let buffer = JEPASpectralStateRingBuffer(capacity: 3)
        buffer.append(state(0))
        buffer.append(state(1))
        XCTAssertNil(buffer.snapshot(), "partial feature windows must not enter a transition")

        buffer.append(state(2))
        XCTAssertEqual(buffer.snapshot()?.map(\.timestamp), [0, 1, 2])

        buffer.append(state(3))
        XCTAssertEqual(buffer.snapshot()?.map(\.timestamp), [1, 2, 3])
    }

    func testTransitionCodableRoundTripPreservesWindowsAndAction() throws {
        let original = JEPATransition(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            timestamp: 1_752_000_000.25,
            preActionWindow: [state(1), state(2)],
            actionVector: [1, 0.7, 0],
            postActionWindow: [state(6), state(7)]
        )

        let decoded = try JSONDecoder().decode(
            JEPATransition.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded, original)
    }

    func testActionEncoderUsesOnlyNormalizedAppliedGenerationSettings() {
        XCTAssertEqual(JEPAActionEncoder.featureNames.count, 3)
        XCTAssertEqual(JEPAActionEncoder.vector(for: .raw), [1, 0.7, 0])

        let adapted = GenerationAdaptation(
            maxCandidates: 2,
            temperature: 0.3,
            styleInstruction: "Prefer short words."
        )
        XCTAssertEqual(JEPAActionEncoder.vector(for: adapted), [2.0 / 3.0, 0.3, 1])
    }

    func testFeatureStateBuildsFromExistingWindowShape() throws {
        let window = EEGWindow(
            samples: [[3, 4], [0, 5]],
            sampleRate: 16,
            endTimestamp: 2,
            sequence: 7
        )
        let state = try XCTUnwrap(JEPASpectralState(window: window, timestamp: 100))

        XCTAssertEqual(state.timestamp, 100)
        XCTAssertEqual(state.channelPowers.count, 2)
        XCTAssertEqual(state.channelPowers[0], 12.5, accuracy: 0.0001)
        XCTAssertEqual(state.channelPowers[1], 12.5, accuracy: 0.0001)
        XCTAssertTrue(state.alphaPower.isFinite)
        XCTAssertTrue(state.betaPower.isFinite)
        XCTAssertTrue(state.thetaPower.isFinite)
    }
}
