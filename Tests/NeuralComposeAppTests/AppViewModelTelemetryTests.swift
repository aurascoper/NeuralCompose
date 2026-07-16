import XCTest
@testable import NeuralComposeApp
@testable import BCICore

/// Exercises `AppViewModel.telemetryEvent(...)` directly — the pure
/// commit-detection function extracted out of `apply(snapshot:)` precisely
/// so this doesn't need a live pipeline (EEG stream, classifier, predictor)
/// to test, per this project's seam-based testing preference.
final class AppViewModelTelemetryTests: XCTestCase {

    private func snapshot(composedText: String, lastCommittedWord: String?) -> TextCompositionController.Snapshot {
        TextCompositionController.Snapshot(
            composedText: composedText,
            candidates: [],
            highlightIndex: 0,
            isPredicting: false,
            lastCommittedWord: lastCommittedWord
        )
    }

    func testNoEventWhenLastCommittedWordUnchanged() {
        let event = AppViewModel.telemetryEvent(
            previousComposedText: "the quick",
            previousCommittedWord: "quick",
            snapshot: snapshot(composedText: "the quick", lastCommittedWord: "quick"),
            signalQuality: .healthy,
            detectedSpectralState: nil,
            appliedAdaptation: .raw,
            adaptiveComplexityEnabled: false
        )
        XCTAssertNil(event, "a carousel tick or prediction refresh that doesn't change lastCommittedWord must not log")
    }

    func testNoEventWhenLastCommittedWordIsStillNil() {
        let event = AppViewModel.telemetryEvent(
            previousComposedText: "",
            previousCommittedWord: nil,
            snapshot: snapshot(composedText: "", lastCommittedWord: nil),
            signalQuality: nil,
            detectedSpectralState: nil,
            appliedAdaptation: .raw,
            adaptiveComplexityEnabled: false
        )
        XCTAssertNil(event)
    }

    func testEventFiresOnGenuineNewCommitWithPreCommitContext() throws {
        let event = AppViewModel.telemetryEvent(
            previousComposedText: "the quick",
            previousCommittedWord: "quick",
            snapshot: snapshot(composedText: "the quick brown", lastCommittedWord: "brown"),
            signalQuality: .healthy,
            detectedSpectralState: .engagedFocused,
            appliedAdaptation: GenerationAdaptation(maxCandidates: 3, temperature: 0.7, styleInstruction: ""),
            adaptiveComplexityEnabled: true
        )
        let unwrapped = try XCTUnwrap(event)
        XCTAssertEqual(unwrapped.committedWord, "brown")
        XCTAssertEqual(unwrapped.composedContextBeforeCommit, "the quick", "must be the context BEFORE this commit, not after")
        XCTAssertEqual(unwrapped.signalQuality, "healthy")
        XCTAssertEqual(unwrapped.detectedSpectralState, "Engaged/focused")
        XCTAssertEqual(unwrapped.appliedMaxCandidates, 3)
        XCTAssertEqual(unwrapped.appliedTemperature, 0.7)
        XCTAssertTrue(unwrapped.adaptiveComplexityEnabled)
    }

    func testEventFiresOnFirstCommitFromNilToWord() throws {
        let event = AppViewModel.telemetryEvent(
            previousComposedText: "",
            previousCommittedWord: nil,
            snapshot: snapshot(composedText: "hello", lastCommittedWord: "hello"),
            signalQuality: .poor,
            detectedSpectralState: nil,
            appliedAdaptation: .raw,
            adaptiveComplexityEnabled: false
        )
        let unwrapped = try XCTUnwrap(event)
        XCTAssertEqual(unwrapped.committedWord, "hello")
        XCTAssertEqual(unwrapped.composedContextBeforeCommit, "")
        XCTAssertNil(unwrapped.detectedSpectralState, "no spectral opinion available must round-trip as nil, not a placeholder string")
    }

    func testAppliedAdaptationIsLoggedNotDetected() throws {
        // .raw is what appliedAdaptation collapses to whenever adaptive mode
        // is off, regardless of what the rule table currently detects — the
        // event must reflect what actually reached the predictor.
        let event = AppViewModel.telemetryEvent(
            previousComposedText: "a",
            previousCommittedWord: "a",
            snapshot: snapshot(composedText: "a b", lastCommittedWord: "b"),
            signalQuality: .lost,
            detectedSpectralState: .highCognitiveLoad,
            appliedAdaptation: .raw,
            adaptiveComplexityEnabled: false
        )
        let unwrapped = try XCTUnwrap(event)
        XCTAssertEqual(unwrapped.appliedMaxCandidates, GenerationAdaptation.raw.maxCandidates)
        XCTAssertEqual(unwrapped.appliedTemperature, GenerationAdaptation.raw.temperature)
        XCTAssertFalse(unwrapped.adaptiveComplexityEnabled)
    }
}
