import BCICore

/// Always-present, in-process stand-in for `SpectralStateEstimating`. Used
/// whenever `Models/EEGEncoder/` is missing, its anchor space isn't
/// trusted, or real construction fails — same stub-by-default role
/// `StubNextWordPredictor` plays for the LLM predictor.
public struct StubSpectralStateEstimator: SpectralStateEstimating, Sendable {
    public let isLive: Bool = false

    public init() {}

    public func estimate(window: EEGWindow) async -> SpectralState? {
        nil
    }
}
