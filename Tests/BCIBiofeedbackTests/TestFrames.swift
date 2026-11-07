import Foundation
import BCICore
@testable import BCIBiofeedback

/// Frame builders shared by the mapper, mirror and feature tests. Band
/// powers are given in linear µV² per channel; health defaults to all
/// healthy.
enum TestFrames {

    static func powers(alpha: Float = 10, beta: Float = 10, theta: Float = 10, delta: Float = 10, gamma: Float = 10) -> BandPowers {
        BandPowers(power: [.alpha: alpha, .beta: beta, .theta: theta, .delta: delta, .gamma: gamma])
    }

    static func frame(
        at t: TimeInterval,
        tp9: BandPowers? = powers(),
        af7: BandPowers? = powers(),
        af8: BandPowers? = powers(),
        tp10: BandPowers? = powers(),
        health: [EEGChannel: ChannelHealthStatus] = allHealthy,
        blink: Bool = false,
        jawClench: Bool = false,
        accel: MovementSample? = nil,
        gyro: MovementSample? = nil
    ) -> BiofeedbackFrame {
        var bandPowers: [EEGChannel: BandPowers] = [:]
        if let tp9 { bandPowers[.tp9] = tp9 }
        if let af7 { bandPowers[.af7] = af7 }
        if let af8 { bandPowers[.af8] = af8 }
        if let tp10 { bandPowers[.tp10] = tp10 }
        return BiofeedbackFrame(
            timestamp: t,
            bandPowers: bandPowers,
            health: health,
            blink: blink,
            jawClench: jawClench,
            accel: accel,
            gyro: gyro
        )
    }

    static let allHealthy: [EEGChannel: ChannelHealthStatus] = [
        .tp9: .healthy, .af7: .healthy, .af8: .healthy, .tp10: .healthy,
    ]

    static func health(af7: ChannelHealthStatus) -> [EEGChannel: ChannelHealthStatus] {
        var h = allHealthy
        h[.af7] = af7
        return h
    }
}
