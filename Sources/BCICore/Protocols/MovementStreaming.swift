import Foundation

/// Optional capability for an `EEGStreaming` transport that ALSO carries IMU
/// (accelerometer / gyroscope) data — kept as a **separate protocol** so only
/// transports that genuinely provide movement conform. Synthetic, playback, and
/// BrainFlow do not; the Mind Monitor OSC transport does (Mind Monitor sends
/// `/muse/acc` + `/muse/gyro` alongside `/muse/eeg`).
///
/// The supervisor discovers movement via `stream as? any MovementStreaming` and
/// drains this channel in parallel with the EEG sample loop; a transport that
/// doesn't conform simply has no movement, with no branching required elsewhere.
///
/// The stream is created once for the transport's lifetime (not per `start()`),
/// so it survives the supervisor's stop()/start() reconnect cycles — movement is
/// a continuous side channel, not tied to a single EEG session attempt.
public protocol MovementStreaming: Sendable {
    var movementStream: AsyncStream<MovementSample> { get }
}
