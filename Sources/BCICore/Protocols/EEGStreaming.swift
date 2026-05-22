import Foundation

/// A source of EEG samples. Implementations: BrainFlow service, synthetic
/// generator, CSV playback.
///
/// Streaming is cooperatively cancellable: closing the returned `AsyncStream`
/// must release all resources (BLE handles, file descriptors, ring buffers).
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
