import Foundation
import BCICore

/// Pure-Swift synthetic EEG generator.
///
/// Emits Muse-shaped samples (4 channels, 256 Hz default) on a `Task.sleep`
/// schedule, mixing 1/f-ish noise with a low-amplitude alpha oscillation. An
/// optional "demo mode" injects periodic high-amplitude bursts so the mock
/// classifier can see something interesting without a real user.
///
/// No BrainFlow, no Bluetooth, no hardware. This is what the app falls back
/// to when nothing else is available.
public struct SyntheticEEGStreamConfig: Sendable {
    public var channelCount: Int
    public var sampleRate: Double
    public var amplitude: Float
    public var alphaFrequencyHz: Double
    public var enableDemoBursts: Bool

    public init(
        channelCount: Int = 4,
        sampleRate: Double = 256.0,
        amplitude: Float = 8.0,
        alphaFrequencyHz: Double = 10.0,
        enableDemoBursts: Bool = true
    ) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.amplitude = amplitude
        self.alphaFrequencyHz = alphaFrequencyHz
        self.enableDemoBursts = enableDemoBursts
    }
}

public final class SyntheticEEGStream: EEGStreaming, @unchecked Sendable {

    public let profile: MuseBoardProfile = .synthetic
    public var effectiveSampleRate: Double { config.sampleRate }
    public var channelCount: Int { config.channelCount }

    private let config: SyntheticEEGStreamConfig
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(config: SyntheticEEGStreamConfig = .init()) {
        self.config = config
    }

    public func start() async throws -> AsyncThrowingStream<EEGSample, any Error> {
        let cfg = config
        return AsyncThrowingStream<EEGSample, any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startNanos = DispatchTime.now().uptimeNanoseconds
                let periodNanos = UInt64(1_000_000_000.0 / cfg.sampleRate)
                var n: UInt64 = 0
                var burstCounter: Int = 0
                let burstEvery = Int(cfg.sampleRate * 5)   // every 5 s
                let burstWidth = Int(cfg.sampleRate / 4)   // 250 ms

                while !Task.isCancelled {
                    let t = Double(n) / cfg.sampleRate

                    var channels: [Float] = []
                    channels.reserveCapacity(cfg.channelCount)
                    for ch in 0..<cfg.channelCount {
                        // Per-channel noise + alpha + tiny offset.
                        let alpha = Float(sin(2 * .pi * cfg.alphaFrequencyHz * t + Double(ch) * 0.4))
                                     * (cfg.amplitude * 0.4)
                        let noise = Float.random(in: -cfg.amplitude...cfg.amplitude)
                        var v = alpha + noise

                        // Demo bursts: spikes that energetically resemble jaw
                        // clench → the mock classifier picks them up as
                        // .jawClench → smoother eventually fires `.advance`.
                        if cfg.enableDemoBursts {
                            let phase = burstCounter % burstEvery
                            if phase < burstWidth {
                                v += Float.random(in: -1...1) * cfg.amplitude * 6
                            }
                            if phase == burstEvery - 1 {
                                // Add a select-shaped pattern at the trailing
                                // edge: a sustained high-frequency segment.
                                v += Float.random(in: -1...1) * cfg.amplitude * 12
                            }
                        }
                        channels.append(v)
                    }
                    burstCounter += 1

                    let sample = EEGSample(timestamp: t, channels: channels)
                    continuation.yield(sample)
                    n &+= 1

                    // Sleep until the next sample boundary.
                    let target = startNanos &+ n &* periodNanos
                    let now = DispatchTime.now().uptimeNanoseconds
                    if target > now {
                        try? await Task.sleep(nanoseconds: target &- now)
                    }
                }
                continuation.finish()
            }
            self.lock.withLock { self.task = task }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func stop() async {
        lock.withLock { task?.cancel(); task = nil }
    }
}
