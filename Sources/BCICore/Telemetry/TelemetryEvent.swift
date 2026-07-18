import Foundation

/// One word-commit interaction, captured for possible future local training
/// data (see `docs/architecture/decision-log/ADR-005-local-interaction-logging.md`).
///
/// Deliberately narrower than a "prompt/response" log: this app's actual
/// interaction unit is a single carousel candidate committed via a
/// brain-signal selection (`TextCompositionController.handleAction(.commitActive)`),
/// not a chat turn. Deliberately omits the raw continuous spectral
/// embedding — `detectedSpectralState` is the classified anchor label, and
/// logging more than that would imply a precision `SpectralState.honestyCaveat`
/// explicitly disclaims.
public struct TelemetryEvent: Sendable, Codable, Equatable {
    public let eventId: UUID
    public let timestamp: Date
    /// `composed` text immediately before this commit (never the
    /// style-instruction-prefixed prompt the predictor actually saw).
    public let composedContextBeforeCommit: String
    public let committedWord: String
    /// `SignalQuality`'s description, if known at commit time. Kept as a
    /// plain `String` so this pure-Swift `BCICore` type never has to import
    /// `SignalQuality` (defined in `NeuralComposeApp`).
    public let signalQuality: String?
    /// `SpectralState.badgeLabel`, if the estimator had an opinion.
    public let detectedSpectralState: String?
    public let appliedMaxCandidates: Int
    public let appliedTemperature: Double
    public let appliedStyleInstruction: String
    public let adaptiveComplexityEnabled: Bool

    public init(
        eventId: UUID = UUID(),
        timestamp: Date = Date(),
        composedContextBeforeCommit: String,
        committedWord: String,
        signalQuality: String?,
        detectedSpectralState: String?,
        appliedMaxCandidates: Int,
        appliedTemperature: Double,
        appliedStyleInstruction: String,
        adaptiveComplexityEnabled: Bool
    ) {
        self.eventId = eventId
        self.timestamp = timestamp
        self.composedContextBeforeCommit = composedContextBeforeCommit
        self.committedWord = committedWord
        self.signalQuality = signalQuality
        self.detectedSpectralState = detectedSpectralState
        self.appliedMaxCandidates = appliedMaxCandidates
        self.appliedTemperature = appliedTemperature
        self.appliedStyleInstruction = appliedStyleInstruction
        self.adaptiveComplexityEnabled = adaptiveComplexityEnabled
    }
}
