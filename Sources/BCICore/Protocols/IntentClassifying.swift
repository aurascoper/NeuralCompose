import Foundation

/// Classifies one preprocessed `EEGWindow` into an `IntentPrediction`.
///
/// Implementations must be safe to call concurrently — the windowing stage
/// produces windows faster than the classifier can drain them under load,
/// and the controller debounces by dropping older outputs. Returning
/// quickly is more important than perfect ordering. The `windowSequence`
/// on the input/output lets consumers reorder if they care.
/// ## API stability (frozen as of v0.3.0-foundation)
///
/// `MockIntentClassifier` (the CI/synthetic-mode implementation) and
/// `CoreMLIntentClassifier` both conform to exactly this. The golden-
/// recording regression suite, the 3D workspace's tint/pulse mapping, and
/// the intent smoother all consume `IntentPrediction` as produced here.
/// A future BCILLM embedding stage reads `IntentPrediction`, not this
/// protocol directly — so extending classification (e.g. richer features)
/// should stay behind this same three-member surface where possible.
public protocol IntentClassifying: Sendable {
    /// The compute placement this classifier is currently using.
    var computeMode: ClassifierComputeMode { get }

    /// True if this classifier is the real Core ML model; false if it's the
    /// deterministic mock. Drives the privacy-mode banner.
    var isLive: Bool { get }

    /// Classify a single window. Throws on inference failure — the caller
    /// will surface this as a degraded-mode warning and *not* take the app
    /// down.
    func classify(window: EEGWindow) async throws -> IntentPrediction
}
