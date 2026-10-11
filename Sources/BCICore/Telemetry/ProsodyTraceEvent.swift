import Foundation

/// A cadence/prosody target vector for science artifacts.
///
/// The same shape can represent requested controls, predicted controls, or
/// measured acoustic features. Requested vectors may only populate the fields
/// exposed by `SpeechProsody`; measured vectors can later add real duration,
/// pitch variance, pause density, RMS, spectral centroid, energy entropy, and
/// syllable cadence from recordings or deterministic measurement kernels.
public struct ProsodyFeatureVector: Codable, Sendable, Equatable {
    public let speechRate: Double?
    public let pauseBefore: TimeInterval?
    public let pauseAfter: TimeInterval?
    public let meanPitch: Double?
    public let pitchVariance: Double?
    public let energy: Double?
    public let duration: TimeInterval?
    public let voicedDuration: TimeInterval?
    public let syllablesPerSecond: Double?
    public let articulationRate: Double?
    public let pauseDensity: Double?
    public let rms: Double?
    public let zeroCrossingRate: Double?
    public let spectralCentroid: Double?
    public let pitchConfidence: Double?
    public let voicingProbability: Double?
    public let energyEntropy: Double?
    public let emphasis: Double?
    public let hesitation: Double?
    public let cadenceClass: String?

    public init(
        speechRate: Double? = nil,
        pauseBefore: TimeInterval? = nil,
        pauseAfter: TimeInterval? = nil,
        meanPitch: Double? = nil,
        pitchVariance: Double? = nil,
        energy: Double? = nil,
        duration: TimeInterval? = nil,
        voicedDuration: TimeInterval? = nil,
        syllablesPerSecond: Double? = nil,
        articulationRate: Double? = nil,
        pauseDensity: Double? = nil,
        rms: Double? = nil,
        zeroCrossingRate: Double? = nil,
        spectralCentroid: Double? = nil,
        pitchConfidence: Double? = nil,
        voicingProbability: Double? = nil,
        energyEntropy: Double? = nil,
        emphasis: Double? = nil,
        hesitation: Double? = nil,
        cadenceClass: String? = nil
    ) {
        self.speechRate = speechRate
        self.pauseBefore = pauseBefore
        self.pauseAfter = pauseAfter
        self.meanPitch = meanPitch
        self.pitchVariance = pitchVariance
        self.energy = energy
        self.duration = duration
        self.voicedDuration = voicedDuration
        self.syllablesPerSecond = syllablesPerSecond
        self.articulationRate = articulationRate
        self.pauseDensity = pauseDensity
        self.rms = rms
        self.zeroCrossingRate = zeroCrossingRate
        self.spectralCentroid = spectralCentroid
        self.pitchConfidence = pitchConfidence
        self.voicingProbability = voicingProbability
        self.energyEntropy = energyEntropy
        self.emphasis = emphasis
        self.hesitation = hesitation
        self.cadenceClass = cadenceClass
    }

    /// Builds the requested-control portion of the science vector from the
    /// runtime's existing AVFoundation-free prosody type.
    public init(
        requested prosody: SpeechProsody,
        pauseAfter: TimeInterval? = nil,
        duration: TimeInterval? = nil,
        syllableCount: Int? = nil,
        emphasis: Double? = nil,
        hesitation: Double? = nil,
        cadenceClass: String? = nil
    ) {
        let syllablesPerSecond: Double?
        if let duration, duration > 0, let syllableCount {
            syllablesPerSecond = Double(syllableCount) / duration
        } else {
            syllablesPerSecond = nil
        }

        self.init(
            speechRate: prosody.rate.map(Double.init),
            pauseBefore: prosody.preUtteranceDelay,
            pauseAfter: pauseAfter,
            meanPitch: prosody.pitchMultiplier.map(Double.init),
            pitchVariance: nil,
            energy: prosody.volume.map(Double.init),
            duration: duration,
            voicedDuration: nil,
            syllablesPerSecond: syllablesPerSecond,
            articulationRate: nil,
            pauseDensity: nil,
            rms: nil,
            zeroCrossingRate: nil,
            spectralCentroid: nil,
            pitchConfidence: nil,
            voicingProbability: nil,
            energyEntropy: nil,
            emphasis: emphasis,
            hesitation: hesitation,
            cadenceClass: cadenceClass
        )
    }

    enum CodingKeys: String, CodingKey {
        case speechRate = "speech_rate"
        case pauseBefore = "pause_before"
        case pauseAfter = "pause_after"
        case meanPitch = "mean_pitch"
        case pitchVariance = "pitch_variance"
        case energy
        case duration
        case voicedDuration = "voiced_duration"
        case syllablesPerSecond = "syllables_per_second"
        case articulationRate = "articulation_rate"
        case pauseDensity = "pause_density"
        case rms
        case zeroCrossingRate = "zero_crossing_rate"
        case spectralCentroid = "spectral_centroid"
        case pitchConfidence = "pitch_confidence"
        case voicingProbability = "voicing_probability"
        case energyEntropy = "energy_entropy"
        case emphasis
        case hesitation
        case cadenceClass = "cadence_class"
    }
}

/// Opt-in trace of the prosody boundary.
///
/// This event keeps semantic generation separate from vocal realization. It
/// records text, embedding provenance, dialogue-state scalars, and prosody
/// target vectors. It does not record raw audio, embedding values, prompts, or
/// provider-specific speech state.
public struct ProsodyTraceEvent: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = "prosody-trace-v0"

    public let schemaVersion: String
    public let index: Int
    public let sourceKind: String
    public let utteranceText: String
    public let embeddingModelID: String?
    public let embeddingVersion: String?
    public let dialogueState: [String: Double]
    public let requested: ProsodyFeatureVector?
    public let predicted: ProsodyFeatureVector?
    public let measured: ProsodyFeatureVector?
    public let voiceIdentifier: String?
    public let synthesizerIdentifier: String?

    public init(
        index: Int,
        sourceKind: String,
        utteranceText: String,
        embeddingModelID: String? = nil,
        embeddingVersion: String? = nil,
        dialogueState: [String: Double] = [:],
        requested: ProsodyFeatureVector? = nil,
        predicted: ProsodyFeatureVector? = nil,
        measured: ProsodyFeatureVector? = nil,
        voiceIdentifier: String? = nil,
        synthesizerIdentifier: String? = nil,
        schemaVersion: String = Self.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.index = index
        self.sourceKind = sourceKind
        self.utteranceText = utteranceText
        self.embeddingModelID = embeddingModelID
        self.embeddingVersion = embeddingVersion
        self.dialogueState = dialogueState
        self.requested = requested
        self.predicted = predicted
        self.measured = measured
        self.voiceIdentifier = voiceIdentifier
        self.synthesizerIdentifier = synthesizerIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case index
        case sourceKind = "source_kind"
        case utteranceText = "utterance_text"
        case embeddingModelID = "embedding_model_id"
        case embeddingVersion = "embedding_version"
        case dialogueState = "dialogue_state"
        case requested
        case predicted
        case measured
        case voiceIdentifier = "voice_identifier"
        case synthesizerIdentifier = "synthesizer_identifier"
    }
}

/// Sink for `ProsodyTraceEvent`s. The default drops everything so prosody
/// tracing stays opt-in, like the other science/diagnostic traces.
public protocol ProsodyTraceLogging: Sendable {
    func log(_ event: ProsodyTraceEvent) async
}

public struct NullProsodyTraceLogger: ProsodyTraceLogging {
    public init() {}
    public func log(_ event: ProsodyTraceEvent) async {}
}
