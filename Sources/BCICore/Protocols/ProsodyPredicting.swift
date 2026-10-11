import Foundation

/// Input to a future cadence/prosody model.
///
/// This is deliberately upstream of speech synthesis: it carries semantic
/// content, an optional sentence embedding, measured dialogue state, and prior
/// prosody targets. It carries no voice identity, no TTS provider state, and no
/// audio samples.
public struct ProsodyPredictionRequest: Sendable, Equatable {
    public let text: String
    public let embedding: Embedding?
    public let dialogueState: [String: Double]
    public let history: [ProsodyFeatureVector]

    public init(
        text: String,
        embedding: Embedding? = nil,
        dialogueState: [String: Double] = [:],
        history: [ProsodyFeatureVector] = []
    ) {
        self.text = text
        self.embedding = embedding
        self.dialogueState = dialogueState
        self.history = history
    }
}

/// Predicts how semantic content should be spoken.
///
/// A conformer is a cadence model, not a speech synthesizer. It may use a
/// sentence embedding, dialogue state, and prior prosody traces, but it returns
/// plain `SpeechProsody` parameters for the existing `SpeechSynthesizing` seam.
public protocol ProsodyPredicting: Sendable {
    var modelID: String { get }
    var version: String { get }

    func predictProsody(for request: ProsodyPredictionRequest) async throws -> SpeechProsody
}
