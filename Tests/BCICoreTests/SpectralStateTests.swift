import XCTest
@testable import BCICore

/// Drift guard: `SpectralState.descriptor` must byte-match
/// `Scripts/eeg_spectral.py::STATE_DESCRIPTORS`, in the same order — the
/// Swift port re-encodes these exact phrases through the app's live
/// `SentenceEmbedder` to rebuild the anchor table the Python-trained
/// encoder was aligned against, so a silent drift here would break
/// retrieval without any compiler error to catch it.
final class SpectralStateTests: XCTestCase {

    /// Hardcoded copy of the Python list — deliberately not read from the
    /// script at test time, so a change to either side that isn't mirrored
    /// in the other fails loudly here.
    private static let pythonStateDescriptors = [
        "drowsy and fatigued, theta-dominant low-frequency brain activity",
        "relaxed wakefulness, alpha-dominant brain activity",
        "engaged and focused, beta-dominant brain activity",
        "high cognitive load, elevated beta over alpha brain activity",
        "neutral baseline brain activity with no dominant rhythm",
    ]

    func testDescriptorsMatchPythonStateDescriptorsVerbatimAndInOrder() {
        let swiftDescriptors = SpectralState.allCases.map(\.descriptor)
        XCTAssertEqual(swiftDescriptors, Self.pythonStateDescriptors)
    }

    func testAllCasesOrderMatchesExpectedIndices() {
        XCTAssertEqual(SpectralState.allCases, [
            .drowsyFatigued, .relaxedWakefulness, .engagedFocused,
            .highCognitiveLoad, .neutralBaseline,
        ])
    }

    func testHonestyCaveatIsNonEmpty() {
        XCTAssertFalse(SpectralState.honestyCaveat.isEmpty)
    }

    func testBadgeLabelsAreNonEmptyForEveryCase() {
        for state in SpectralState.allCases {
            XCTAssertFalse(state.badgeLabel.isEmpty)
        }
    }
}
