import Foundation

/// The discrete intents the EEG classifier emits per window.
///
/// `modelOutputOrder` is the canonical class ordering used by both the Core ML
/// model and the mock classifier. If you train a custom model with a different
/// ordering, change this enum *and* the model — never one without the other.
public enum IntentClass: Int, CaseIterable, Sendable, Hashable, Codable {
    case rest          = 0
    case jawClench     = 1
    case singleBlink   = 2
    case doubleBlink   = 3
    case select        = 4

    public static let modelOutputOrder: [IntentClass] = [
        .rest, .jawClench, .singleBlink, .doubleBlink, .select
    ]

    public var displayName: String {
        switch self {
        case .rest:        return "Rest"
        case .jawClench:   return "Jaw Clench"
        case .singleBlink: return "Single Blink"
        case .doubleBlink: return "Double Blink"
        case .select:      return "Select"
        }
    }
}

/// One classifier output. Carries the predicted class, its probability, and
/// the full softmax (or pseudo-softmax) distribution for the smoother to
/// reason about confidence margins.
public struct IntentPrediction: Sendable, Hashable {
    public let intent: IntentClass
    public let confidence: Float
    public let distribution: [IntentClass: Float]
    public let windowSequence: UInt64
    public let endTimestamp: TimeInterval

    public init(
        intent: IntentClass,
        confidence: Float,
        distribution: [IntentClass: Float],
        windowSequence: UInt64,
        endTimestamp: TimeInterval
    ) {
        self.intent = intent
        self.confidence = confidence
        self.distribution = distribution
        self.windowSequence = windowSequence
        self.endTimestamp = endTimestamp
    }
}

/// Smoothed, debounced intents that bubble up to the application FSM.
public enum SmoothedIntent: Sendable, Hashable {
    case idle
    case advance        // user is holding a non-rest signal: bias toward next slot
    case selectActive   // user has produced a deliberate "select" pattern
}
