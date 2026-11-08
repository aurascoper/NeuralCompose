import Foundation
import BCICore
import BCIEEG

/// Turns a stream of `BiofeedbackFrame`s into OSC and MIDI outputs
/// according to a set of `BiofeedbackMapping`s. Deterministic: the same
/// frames in the same order produce the same outputs, which is what lets
/// `BCIBiofeedbackTests` pin behaviour as fixtures and what the golden
/// recording replay (follow-up issue) will regress against.
///
/// Pure value type with explicit state, no I/O, no clock of its own: time
/// comes from `frame.timestamp`. Transports (`OSCUDPSender`,
/// `CoreMIDIVirtualSource`) receive the outputs through `BiofeedbackSink`
/// and never see a frame. Mappings are processed in array order and
/// outputs are appended in that order, so a fixture is stable across
/// runs.
///
/// Health gating lives here and nowhere else. Each mapping's
/// `HealthPolicy` decides what is emitted on ticks where
/// `feature.isHealthy(in:)` is false; `MindMonitorMirror`, by contrast,
/// deliberately emits ungated compatibility values plus the horseshoe,
/// because that is what a Mind Monitor consumer expects.
public struct FeatureMapper: Sendable {

    private struct State: Sendable {
        var smoothed: Float?
        var lastGood: Float?
        var unhealthySince: TimeInterval?
        var lastTimestamp: TimeInterval?
        var lastEmit: TimeInterval?
        var lastQuantised: Int?
        var noteOpen = false
        var noteOpenUntil: TimeInterval = 0
    }

    public private(set) var mappings: [BiofeedbackMapping]
    private var states: [UUID: State]

    public init(mappings: [BiofeedbackMapping] = []) {
        self.mappings = mappings
        self.states = [:]
    }

    /// Replace the mapping set. State is kept for mappings whose `id`
    /// survives and dropped for the rest, so editing one row in a UI does
    /// not reset every smoother.
    public mutating func replaceMappings(_ newMappings: [BiofeedbackMapping]) {
        let keep = Set(newMappings.map(\.id))
        states = states.filter { keep.contains($0.key) }
        mappings = newMappings
    }

    /// Forget all state (smoothers, gates, rate limiters).
    public mutating func reset() {
        states = [:]
    }

    /// Process one frame and return everything to emit for it.
    public mutating func step(_ frame: BiofeedbackFrame) -> [BiofeedbackOutput] {
        var outputs: [BiofeedbackOutput] = []
        let now = frame.timestamp

        for mapping in mappings {
            var state = states[mapping.id] ?? State()
            let dt = state.lastTimestamp.map { max(0, now - $0) } ?? 0
            let healthy = mapping.feature.isHealthy(in: frame)
            let raw = mapping.feature.evaluate(in: frame, healthyOnly: true)

            var value: Float?
            if healthy, let raw {
                let target = mapping.normalise(raw)
                state.smoothed = FeatureMapper.smooth(previous: state.smoothed, target: target, dt: dt, tau: mapping.smoothingTau)
                state.lastGood = state.smoothed
                state.unhealthySince = nil
                value = state.smoothed
            } else {
                switch mapping.healthPolicy {
                case .passthrough:
                    if let raw {
                        let target = mapping.normalise(raw)
                        state.smoothed = FeatureMapper.smooth(previous: state.smoothed, target: target, dt: dt, tau: mapping.smoothingTau)
                        value = state.smoothed
                    }
                case .holdLast:
                    value = state.lastGood
                case .decayToRest(let rest, let tau):
                    if let last = state.lastGood {
                        let since = state.unhealthySince ?? now
                        state.unhealthySince = since
                        let elapsed = max(0, now - since)
                        let decayed: Float
                        if tau > 0 {
                            decayed = rest + (last - rest) * Float(exp(-elapsed / tau))
                        } else {
                            decayed = rest
                        }
                        state.smoothed = decayed
                        value = decayed
                    }
                case .mute:
                    value = nil
                }
            }
            state.lastTimestamp = now

            switch mapping.target {
            case .midiNote(let note, let channel, let velocity, let gate):
                // Gates run every tick regardless of rate limiting so an
                // expired or muted gate always closes.
                let on = (value ?? 0) >= 0.5
                if on, !state.noteOpen {
                    outputs.append(.midi(.noteOn(channel: channel, note: note, velocity: velocity)))
                    state.noteOpen = true
                    state.noteOpenUntil = now + gate
                    state.lastEmit = now
                } else if state.noteOpen, !on || now >= state.noteOpenUntil {
                    outputs.append(.midi(.noteOff(channel: channel, note: note)))
                    state.noteOpen = false
                    state.lastEmit = now
                }

            case .osc(let address):
                if let value, FeatureMapper.rateAllows(state: state, now: now, minInterval: mapping.minInterval) {
                    outputs.append(.osc(OSCMessage(address: address, arguments: [.float(value)])))
                    state.lastEmit = now
                }

            case .midiControl(let controller, let channel, let fourteenBit):
                if let value, FeatureMapper.rateAllows(state: state, now: now, minInterval: mapping.minInterval) {
                    let span: Float = fourteenBit ? 16383 : 127
                    let quantised = Int((value * span).rounded())
                    if quantised != state.lastQuantised {
                        if fourteenBit {
                            for event in MIDIEvent.controlChange14(channel: channel, controller: controller, value: UInt16(quantised)) {
                                outputs.append(.midi(event))
                            }
                        } else {
                            outputs.append(.midi(.controlChange(channel: channel, controller: controller, value: UInt8(quantised))))
                        }
                        state.lastQuantised = quantised
                        state.lastEmit = now
                    }
                }
            }

            states[mapping.id] = state
        }
        return outputs
    }

    /// Exponential moving average toward `target`. With no previous value
    /// or no time constant the target is adopted outright.
    static func smooth(previous: Float?, target: Float, dt: TimeInterval, tau: TimeInterval) -> Float {
        guard let previous, tau > 0, dt > 0 else { return target }
        let alpha = Float(1 - exp(-dt / tau))
        return previous + alpha * (target - previous)
    }

    private static func rateAllows(state: State, now: TimeInterval, minInterval: TimeInterval) -> Bool {
        guard minInterval > 0, let last = state.lastEmit else { return true }
        return now - last >= minInterval
    }
}
