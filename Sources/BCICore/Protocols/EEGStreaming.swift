import Foundation

/// A source of EEG samples. Implementations: BrainFlow service, synthetic
/// generator, CSV playback.
///
/// Streaming is cooperatively cancellable: closing the returned `AsyncStream`
/// must release all resources (BLE handles, file descriptors, ring buffers).
///
/// ## API stability (frozen as of v0.3.0-foundation)
///
/// Every downstream consumer — the 2D plotter, `ChannelHealthProviding`
/// implementations, `EEGWindowing`, the golden-recording regression suite —
/// is written against exactly this protocol, not against any concrete
/// stream type. That's deliberate: it's what lets `AppContainer` swap
/// BrainFlow for synthetic or playback data without touching anything
/// downstream, and it's the seam a future remote/OSC source would plug into
/// the same way. Treat this surface (the 4 members below) as a contract —
/// changing it means auditing every conformer (`BrainFlowService`,
/// `SyntheticEEGStream`, `PlaybackEEGStream`) and every consumer, not just
/// the type that prompted the change.
public protocol EEGStreaming: Sendable {

    /// Static metadata describing this source. Must not change between
    /// `start()` calls on the same instance.
    var profile: MuseBoardProfile { get }

    /// Effective sample rate in Hz, after BrainFlow downsampling if any.
    var effectiveSampleRate: Double { get }

    /// Effective number of EEG channels emitted per sample.
    var channelCount: Int { get }

    /// Open the stream and return an `AsyncThrowingStream` of samples.
    ///
    /// Cancelling the consuming task (or letting it deinit) must teardown the
    /// stream. Calling `start()` twice on the same source is an error.
    func start() async throws -> AsyncThrowingStream<EEGSample, any Error>

    /// Stop the stream synchronously. Idempotent — calling more than once is a
    /// no-op. After `stop()` returns, no further samples will be delivered.
    func stop() async
}
