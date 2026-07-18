import Foundation

/// Estimates a coarse `SpectralState` for one preprocessed `EEGWindow`.
///
/// Implementations: `StubSpectralStateEstimator` (always present,
/// in-process, always returns `nil`), `SpectralStateEstimator` (optional,
/// MLX-backed, in `BCILLM`). The factory swaps them transparently when
/// weights are missing, the anchor space isn't trusted (see the
/// bridge-not-decoder honesty constraint on `SpectralState`), or
/// initialization fails — matching the same stub-by-default convention as
/// `IntentClassifying`/`NextWordPredicting`.
///
/// `nil` covers every "no opinion" case uniformly — stub, missing/mismatched
/// weights, wrong window shape, an artifact-contaminated window, or an
/// untrusted anchor space — never a thrown error. A missing opinion here is
/// not an app error, exactly like `SignalQuality` being optional today;
/// callers fall back to `SignalQualityGenerationRules`.
public protocol SpectralStateEstimating: Sendable {
    /// True if this is the MLX-backed implementation; false if it's the stub.
    var isLive: Bool { get }

    /// Estimate the spectral state of `window`, or `nil` if this estimator
    /// has no opinion (see the type's doc comment for what that covers).
    func estimate(window: EEGWindow) async -> SpectralState?
}
