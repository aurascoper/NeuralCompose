import Foundation

/// A machine-readable snapshot of the app's runtime health, written ~every
/// couple of seconds to `~/Documents/NeuralCompose/health.json` (latest) and, on
/// state changes, appended to `health-<day>.jsonl`.
///
/// Why this exists: the app emits health only to `os_log`, which is **not**
/// externally readable when the app runs as an ad-hoc-signed bundle. Every silent
/// degradation that made a live session hard to debug — synthetic-EEG fallback,
/// a stub spectral estimator, a stub sentence embedder, a gloss stuck at neutral,
/// zero EEG throughput — is invisible until you can read a file. This snapshot is
/// that file. It carries only backend/throughput/state *metadata* (no transcripts),
/// so it is always-on and independent of the interaction-log opt-in.
public struct HealthSnapshot: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let uptimeSeconds: Double

    // ── EEG acquisition ──
    public let acquisition: String          // localMuse / synthetic / playback / remotePhone
    public let transport: String
    public let signalQuality: String?        // healthy / poor / lost
    public let windowsPerSecond: Double

    // ── Model backends (the silent-stub surface) ──
    public let estimatorKind: String         // mlx / stub
    public let embedderKind: String          // coreml / stub
    public let predictorKind: String         // mlx / stub
    public let classifierKind: String        // coreML / mock
    public let fullyLive: Bool
    public let substitutionSummary: String

    // ── Dialectic gloss + loop ──
    public let spectralState: String?        // badge label, or nil = estimator produced nothing
    public let glossStuck: Bool              // estimator==mlx yet no state (nil every window)
    public let loopMode: String?             // the active HypnagogicMode, or nil if the loop is off
    public let loopRunning: Bool
    public let turnCount: Int?
    public let secondsSinceLastTurn: Double?

    // ── Derived ──
    public let degraded: [String]            // machine-readable reasons; empty == healthy

    public init(
        timestamp: Date, uptimeSeconds: Double,
        acquisition: String, transport: String, signalQuality: String?, windowsPerSecond: Double,
        estimatorKind: String, embedderKind: String, predictorKind: String, classifierKind: String,
        fullyLive: Bool, substitutionSummary: String,
        spectralState: String?, glossStuck: Bool,
        loopMode: String?, loopRunning: Bool, turnCount: Int?, secondsSinceLastTurn: Double?,
        degraded: [String]
    ) {
        self.timestamp = timestamp
        self.uptimeSeconds = uptimeSeconds
        self.acquisition = acquisition
        self.transport = transport
        self.signalQuality = signalQuality
        self.windowsPerSecond = windowsPerSecond
        self.estimatorKind = estimatorKind
        self.embedderKind = embedderKind
        self.predictorKind = predictorKind
        self.classifierKind = classifierKind
        self.fullyLive = fullyLive
        self.substitutionSummary = substitutionSummary
        self.spectralState = spectralState
        self.glossStuck = glossStuck
        self.loopMode = loopMode
        self.loopRunning = loopRunning
        self.turnCount = turnCount
        self.secondsSinceLastTurn = secondsSinceLastTurn
        self.degraded = degraded
    }

    /// Pure degraded-reason classifier — no app state, so it is fully unit-testable
    /// and the single source of truth for "what counts as degraded". Mirrors the
    /// warmup-grace + flat-count logic of `Scripts/overnight-telemetry.py::
    /// evaluate_capture_health` for the zero-throughput case.
    ///
    /// - `expectedLive`: the app was launched wanting a live Muse (a `muses*`
    ///   board profile), so a synthetic acquisition is a *fallback*, not a choice.
    public static func degradedReasons(
        acquisition: String,
        expectedLive: Bool,
        estimatorKind: String,
        embedderKind: String,
        predictorKind: String,
        classifierKind: String,
        windowsPerSecond: Double,
        uptimeSeconds: Double,
        glossStuck: Bool,
        loopRunning: Bool,
        secondsSinceLastTurn: Double?,
        warmupGraceSeconds: Double = 8,
        noTurnsTimeoutSeconds: Double = 90
    ) -> [String] {
        var reasons: [String] = []
        if expectedLive && acquisition == "synthetic" { reasons.append("eeg-synthetic-fallback") }
        if estimatorKind == "stub"    { reasons.append("estimator-stub") }
        if embedderKind == "stub"     { reasons.append("embedder-stub") }
        if predictorKind == "stub"    { reasons.append("predictor-stub") }
        if classifierKind == "mock"   { reasons.append("classifier-mock") }
        // Zero-throughput only after a warmup grace, so a just-launched app that
        // hasn't produced its first window yet is not flagged.
        if uptimeSeconds > warmupGraceSeconds && windowsPerSecond <= 0 {
            reasons.append("eeg-zero-throughput")
        }
        if glossStuck { reasons.append("gloss-nil-despite-live-estimator") }
        if loopRunning, let s = secondsSinceLastTurn, s > noTurnsTimeoutSeconds {
            reasons.append("loop-no-turns")
        }
        return reasons
    }
}
