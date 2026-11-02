import XCTest
@testable import BCIVoice

/// The end-of-utterance rule, without a microphone. Times are offsets from `t0`.
final class UtteranceEndpointerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNothingHeardNeverFinishes() {
        let e = UtteranceEndpointer(trailingSilence: 1.8)
        XCTAssertNil(e.transcript)
        XCTAssertFalse(e.shouldFinish(at: at(100)))
    }

    func testPauseShorterThanTheThresholdDoesNotFinish() {
        var e = UtteranceEndpointer(trailingSilence: 1.8)
        e.observe("above the critical pressure", isFinal: false, at: at(0))
        XCTAssertFalse(e.shouldFinish(at: at(1.7)))
    }

    func testTrailingSilenceFinishes() {
        var e = UtteranceEndpointer(trailingSilence: 1.8)
        e.observe("above the critical pressure", isFinal: false, at: at(0))
        XCTAssertTrue(e.shouldFinish(at: at(1.8)))
        XCTAssertEqual(e.transcript, "above the critical pressure")
    }

    /// The Oct 13 failure: the recognizer finalizes on a mid-sentence pause.
    /// That closes a segment; the speaker goes on, and the turn keeps both.
    func testIsFinalThenMoreSpeechJoinsTheSegments() {
        var e = UtteranceEndpointer(trailingSilence: 1.8)
        e.observe("it only loses density gradually so the", isFinal: false, at: at(0))
        e.observe("it only loses density gradually so the", isFinal: true, at: at(0.9))
        XCTAssertFalse(e.shouldFinish(at: at(1.2)), "a recognizer isFinal alone does not end the turn")
        e.observe("phase boundary disappears", isFinal: false, at: at(1.5))
        XCTAssertFalse(e.shouldFinish(at: at(3.0)))
        XCTAssertTrue(e.shouldFinish(at: at(3.4)))
        XCTAssertEqual(e.transcript, "it only loses density gradually so the phase boundary disappears")
    }

    /// The pause that made the recognizer finalize counts toward the silence:
    /// an unchanged final result does not restart the clock.
    func testUnchangedFinalResultDoesNotRestartTheClock() {
        var e = UtteranceEndpointer(trailingSilence: 1.8)
        e.observe("samarium", isFinal: false, at: at(0))
        e.observe("samarium", isFinal: true, at: at(1.0))
        XCTAssertTrue(e.shouldFinish(at: at(1.8)))
        XCTAssertEqual(e.transcript, "samarium")
    }

    /// What a timeout or error hands back: everything heard so far, including
    /// the open segment.
    func testTranscriptIncludesTheOpenSegment() {
        var e = UtteranceEndpointer(trailingSilence: 1.8)
        e.observe("Oklo", isFinal: true, at: at(0))
        e.observe("reactor zone", isFinal: false, at: at(1))
        XCTAssertEqual(e.transcript, "Oklo reactor zone")
    }

    func testRequestCarriesTheVocabularyAndStaysOnDevice() {
        let req = HypnagogicListener.makeRequest(contextualStrings: ["Oklo", "samarium"], onDevice: true)
        XCTAssertEqual(req.contextualStrings, ["Oklo", "samarium"])
        XCTAssertTrue(req.requiresOnDeviceRecognition)
        XCTAssertTrue(req.shouldReportPartialResults)
    }
}
