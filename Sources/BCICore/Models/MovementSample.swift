import Foundation

/// One accelerometer or gyroscope reading from the headset's IMU — a triaxial
/// vector at a point in time. Deliberately a **separate type from `EEGSample`,
/// never folded into it**: movement is a parallel data stream with its own
/// meaning (and, per `SLEEP_CYCLE_DESIGN.md`'s no-actigraphy stance, no claimed
/// role in the EEG pipeline). Keeping it parallel is the same architecture-
/// isolation discipline the intent/imagined-speech labels follow.
///
/// `timestamp` shares the **same stream-relative clock** as `EEGSample.timestamp`
/// (seconds since the transport started), so movement and EEG captured in one
/// session can be aligned post-hoc without a shared wall-clock. Only transports
/// that actually carry an IMU (today: the Mind Monitor OSC path) produce these;
/// see `MovementStreaming`.
public struct MovementSample: Sendable, Hashable {

    public enum Kind: String, Sendable, Hashable, Codable {
        case accel   // /muse/acc  — linear acceleration (g)
        case gyro    // /muse/gyro — angular velocity (deg/s)
    }

    public let timestamp: TimeInterval
    public let kind: Kind
    public let x: Float
    public let y: Float
    public let z: Float

    public init(timestamp: TimeInterval, kind: Kind, x: Float, y: Float, z: Float) {
        self.timestamp = timestamp
        self.kind = kind
        self.x = x
        self.y = y
        self.z = z
    }
}
