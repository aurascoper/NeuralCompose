import Foundation

/// Source of per-channel EEG signal-quality snapshots.
///
/// Implementations are read-only consumers of an EEG sample stream.
/// They are *not* expected to call `EEGStreaming.start()` themselves;
/// the live path is owned by `AppViewModel` (see
/// `AppViewModel.liveSampleStream()` for the single-owner invariant).
///
/// The protocol is `Sendable` and the method is `async` so that
/// implementations can be actors or live behind an actor boundary
/// without forcing the caller's view layer onto the actor's
/// executor. Implementations may return `.unknown` for some or all
/// channels when they have not yet accumulated enough samples to
/// form a stable estimate.
public protocol ChannelHealthProviding: Sendable {
    /// Return one `ChannelHealthState` per channel known to this
    /// provider, computed over the most recent `windowSeconds` of
    /// samples. The returned array's order is stable: it follows
    /// `EEGChannel.allCases`.
    ///
    /// - Parameter windowSeconds: Width of the rolling window used
    ///   to compute per-channel RMS. Implementations clamp this to
    ///   their internal ring capacity. Values <= 0 are treated as
    ///   "use the implementation's default window."
    func currentChannelHealth(windowSeconds: Double) async -> [ChannelHealthState]
}
