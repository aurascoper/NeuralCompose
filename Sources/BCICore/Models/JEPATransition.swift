import Foundation

/// One compact, time-stamped view of an EEG window for the JEPA data set.
///
/// `SpectralState` is already the public five-way heuristic classification
/// enum, so this deliberately uses a distinct name. It carries measured
/// values only; it does not make a claim about a person's cognitive state.
/// The first three values are aggregate band-energy proxies from the live
/// window and `channelPowers` preserves per-electrode spatial information.
public struct JEPASpectralState: Sendable, Codable, Equatable {
    /// Unix time at which this feature state was produced.
    public let timestamp: TimeInterval
    public let alphaPower: Float
    public let betaPower: Float
    public let thetaPower: Float
    /// Per-electrode RMS-squared values in the stream's native channel order.
    public let channelPowers: [Float]

    public init(
        timestamp: TimeInterval,
        alphaPower: Float,
        betaPower: Float,
        thetaPower: Float,
        channelPowers: [Float]
    ) {
        self.timestamp = timestamp
        self.alphaPower = alphaPower
        self.betaPower = betaPower
        self.thetaPower = thetaPower
        self.channelPowers = channelPowers
    }

    /// Converts the app's existing raw-window representation into the compact
    /// state persisted for offline JEPA training. Returns `nil` rather than
    /// emitting malformed JSON when an upstream window has no channels or a
    /// non-finite value.
    public init?(window: EEGWindow, timestamp: TimeInterval) {
        guard timestamp.isFinite, window.channelCount > 0, window.sampleCount > 0 else {
            return nil
        }
        let features = FeatureExtractor.features(for: window)
        let channelPowers = features.rmsByChannel.map { $0 * $0 }
        let values = [features.alphaEnergy, features.betaEnergy, features.thetaEnergy] + channelPowers
        guard values.allSatisfy(\.isFinite) else { return nil }

        self.init(
            timestamp: timestamp,
            alphaPower: features.alphaEnergy,
            betaPower: features.betaEnergy,
            thetaPower: features.thetaEnergy,
            channelPowers: channelPowers
        )
    }
}

/// A paired transition used to train an offline EEG JEPA.
///
/// The two windows are chronological and have the same fixed length. The
/// action vector deliberately contains the generation settings that really
/// reached the predictor, never invented UI controls or the user's text.
public struct JEPATransition: Sendable, Codable, Equatable {
    public let id: UUID
    /// Unix time at which the action was committed.
    public let timestamp: TimeInterval
    public let preActionWindow: [JEPASpectralState]
    public let actionVector: [Float]
    public let postActionWindow: [JEPASpectralState]

    public init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        preActionWindow: [JEPASpectralState],
        actionVector: [Float],
        postActionWindow: [JEPASpectralState]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.preActionWindow = preActionWindow
        self.actionVector = actionVector
        self.postActionWindow = postActionWindow
    }
}

/// Stable normalization of the app's actual generation-control surface.
///
/// The three entries are `[maxCandidates / 3, temperature, hasStylePrompt]`.
/// `maxCandidates` is clamped to the current supported 1...3 range so a
/// malformed configuration cannot create an out-of-schema data row. The
/// style text itself is intentionally never persisted in this data set.
public enum JEPAActionEncoder {
    public static let featureNames = [
        "max_candidates_fraction",
        "temperature",
        "has_style_prompt",
    ]

    public static func vector(for adaptation: GenerationAdaptation) -> [Float] {
        let candidates = min(max(adaptation.maxCandidates, 1), 3)
        let temperature = min(max(adaptation.temperature, 0), 1)
        return [
            Float(candidates) / 3,
            Float(temperature),
            adaptation.styleInstruction.isEmpty ? 0 : 1,
        ]
    }
}
