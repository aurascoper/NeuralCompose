import Foundation
import BCICore

/// Phases of one trial in the imagined-speech protocol.
public enum ImaginedSpeechPhase: String, Sendable, Hashable {
    case idle           // Before start / after stop
    case cue            // Show the upcoming target word
    case active         // User silently rehearses the word; recorder commits samples
    case rest           // Baseline; recorder discards
    case finished       // All trials done; session complete
}

/// One immutable snapshot of protocol state. The actor emits a new value on
/// every phase transition AND on every 100 ms tick during a phase, so the UI
/// can render a countdown without polling the actor itself.
public struct ImaginedSpeechProtocolState: Sendable, Hashable {
    public let phase: ImaginedSpeechPhase
    public let target: ImaginedWordClass?    // nil during rest / idle / finished
    public let trialIndex: Int               // 1-based across the whole session
    public let totalTrials: Int
    public let phaseStartTimestamp: TimeInterval   // Unix epoch — matches EEG sample stamps
    public let phaseDuration: TimeInterval
    public let timeRemaining: TimeInterval

    public init(
        phase: ImaginedSpeechPhase,
        target: ImaginedWordClass?,
        trialIndex: Int,
        totalTrials: Int,
        phaseStartTimestamp: TimeInterval,
        phaseDuration: TimeInterval,
        timeRemaining: TimeInterval
    ) {
        self.phase = phase
        self.target = target
        self.trialIndex = trialIndex
        self.totalTrials = totalTrials
        self.phaseStartTimestamp = phaseStartTimestamp
        self.phaseDuration = phaseDuration
        self.timeRemaining = timeRemaining
    }
}

/// Drives the cue → active → rest → cue → … cadence that grounds the
/// imagined-speech experiment. Single source of truth for both the wizard UI
/// and `TrackBRecorder`: subscribers consume the same AsyncStream and never
/// peek at the actor's internal state out-of-band.
///
/// Default cadence (from Master Plan): cue=2s, active=3s, rest=2s, 50 trials
/// per active class. With `.wordYes` + `.wordNo` that's 100 trials × 7 s ≈
/// 11.7 minutes of protocol time, plus settling overhead. Surfaced via
/// `expectedDurationSeconds` so the UI can warn the user before they start.
public actor ImaginedSpeechProtocol {
    public struct Config: Sendable {
        public var cueSeconds: TimeInterval
        public var activeSeconds: TimeInterval
        public var restSeconds: TimeInterval
        public var trialsPerClass: Int
        public var activeClasses: [ImaginedWordClass]

        public init(
            cueSeconds: TimeInterval = 2.0,
            activeSeconds: TimeInterval = 3.0,
            restSeconds: TimeInterval = 2.0,
            trialsPerClass: Int = 50,
            activeClasses: [ImaginedWordClass] = ImaginedWordClass.activeTargets
        ) {
            self.cueSeconds = cueSeconds
            self.activeSeconds = activeSeconds
            self.restSeconds = restSeconds
            self.trialsPerClass = trialsPerClass
            self.activeClasses = activeClasses
        }

        public var totalTrials: Int { trialsPerClass * activeClasses.count }
        public var expectedDurationSeconds: TimeInterval {
            TimeInterval(totalTrials) * (cueSeconds + activeSeconds + restSeconds)
        }
    }

    private let config: Config
    private let continuation: AsyncStream<ImaginedSpeechProtocolState>.Continuation
    public nonisolated let states: AsyncStream<ImaginedSpeechProtocolState>

    private var runTask: Task<Void, Never>?
    /// Seed so trial-order randomization is reproducible per session — useful
    /// when a debugger steps through the same recording twice. The seed is
    /// written into metadata.json by the recorder.
    private let trialOrderSeed: UInt64

    public init(config: Config = .init(), trialOrderSeed: UInt64 = UInt64.random(in: 0..<UInt64.max)) {
        self.config = config
        self.trialOrderSeed = trialOrderSeed
        var continuation: AsyncStream<ImaginedSpeechProtocolState>.Continuation!
        self.states = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { c in
            continuation = c
        }
        self.continuation = continuation
    }

    public nonisolated var configuration: Config { config }
    public nonisolated var orderSeed: UInt64 { trialOrderSeed }

    public func start() {
        guard runTask == nil else { return }
        let trials = buildTrialOrder()
        runTask = Task { [weak self] in
            await self?.runLoop(trials: trials)
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        emit(.idle, target: nil, trialIndex: 0, phaseStart: Date().timeIntervalSince1970,
             phaseDuration: 0, timeRemaining: 0)
    }

    // MARK: - Run loop

    private func runLoop(trials: [ImaginedWordClass]) async {
        for (idx, target) in trials.enumerated() {
            let trialNumber = idx + 1
            do {
                try await runPhase(.cue, target: target, trialNumber: trialNumber, duration: config.cueSeconds)
                try await runPhase(.active, target: target, trialNumber: trialNumber, duration: config.activeSeconds)
                try await runPhase(.rest, target: nil, trialNumber: trialNumber, duration: config.restSeconds)
            } catch is CancellationError {
                emit(.idle, target: nil, trialIndex: trialNumber, phaseStart: Date().timeIntervalSince1970,
                     phaseDuration: 0, timeRemaining: 0)
                runTask = nil
                return
            } catch {
                emit(.idle, target: nil, trialIndex: trialNumber, phaseStart: Date().timeIntervalSince1970,
                     phaseDuration: 0, timeRemaining: 0)
                runTask = nil
                return
            }
        }
        emit(.finished, target: nil, trialIndex: trials.count, phaseStart: Date().timeIntervalSince1970,
             phaseDuration: 0, timeRemaining: 0)
        continuation.finish()
        runTask = nil
    }

    /// Emit the entry state, then tick at ~10 Hz until the phase elapses.
    /// Cancellation propagates through `Task.sleep` so `stop()` halts the
    /// loop mid-phase without flag polling.
    private func runPhase(
        _ phase: ImaginedSpeechPhase,
        target: ImaginedWordClass?,
        trialNumber: Int,
        duration: TimeInterval
    ) async throws {
        let start = Date().timeIntervalSince1970
        emit(phase, target: target, trialIndex: trialNumber, phaseStart: start,
             phaseDuration: duration, timeRemaining: duration)
        let tickSeconds: TimeInterval = 0.1
        var elapsed: TimeInterval = 0
        while elapsed + tickSeconds < duration {
            try await Task.sleep(nanoseconds: UInt64(tickSeconds * 1_000_000_000))
            elapsed += tickSeconds
            emit(phase, target: target, trialIndex: trialNumber, phaseStart: start,
                 phaseDuration: duration, timeRemaining: max(0, duration - elapsed))
        }
        let remaining = duration - elapsed
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    private func emit(
        _ phase: ImaginedSpeechPhase,
        target: ImaginedWordClass?,
        trialIndex: Int,
        phaseStart: TimeInterval,
        phaseDuration: TimeInterval,
        timeRemaining: TimeInterval
    ) {
        let state = ImaginedSpeechProtocolState(
            phase: phase,
            target: target,
            trialIndex: trialIndex,
            totalTrials: config.totalTrials,
            phaseStartTimestamp: phaseStart,
            phaseDuration: phaseDuration,
            timeRemaining: timeRemaining
        )
        continuation.yield(state)
    }

    // MARK: - Trial order

    /// Interleaved random order across active classes. Each class appears
    /// exactly `trialsPerClass` times; the sequence is a balanced shuffle of
    /// the class set repeated `trialsPerClass` times. Adjacent identical
    /// targets are allowed (a pure block-randomized order would let the
    /// classifier overfit to slow drift).
    private func buildTrialOrder() -> [ImaginedWordClass] {
        var pool: [ImaginedWordClass] = []
        pool.reserveCapacity(config.totalTrials)
        for cls in config.activeClasses {
            for _ in 0..<config.trialsPerClass { pool.append(cls) }
        }
        var rng = SeededRandomNumberGenerator(seed: trialOrderSeed)
        pool.shuffle(using: &rng)
        return pool
    }
}

/// Lightweight reproducible RNG so trial order is recoverable from the seed
/// recorded in metadata.json. Splitmix64 — adequate for shuffles, not crypto.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xDEADBEEFCAFEBABE : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
