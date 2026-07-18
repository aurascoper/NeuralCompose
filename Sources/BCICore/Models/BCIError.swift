import Foundation

/// Errors surfaced across module boundaries.
///
/// Each case carries enough detail to drive both a log line and a
/// user-facing privacy/diagnostic banner. Avoid stringly-typed wrapping —
/// the FSM matches on these cases.
public enum BCIError: Error, Sendable, CustomStringConvertible {

    // EEG streaming
    case bridgeUnavailable(reason: String)
    case streamConnectFailed(profile: MuseBoardProfile, underlying: String)
    case streamFailed(reason: String)
    case playbackFileNotFound(path: String)
    case playbackFileMalformed(path: String, reason: String)
    case channelShapeMismatch(expected: Int, actual: Int)

    // Classification
    case classifierModelMissing(path: String)
    case classifierLoadFailed(path: String, underlying: String)
    case classifierInferenceFailed(reason: String)
    case classifierOutputShapeUnexpected(expected: String, actual: String)

    // LLM
    case predictorWeightsMissing(path: String)
    case predictorInitFailed(reason: String)
    case predictorInferenceFailed(reason: String)

    // Tokenizer
    case tokenizerLoadFailed(reason: String)

    // Sentence embedding
    case embedderModelMissing(path: String)
    case embedderLoadFailed(path: String, underlying: String)
    case embedderInferenceFailed(reason: String)
    case embedderOutputShapeUnexpected(expected: String, actual: String)
    case embedderMetadataInvalid(path: String, reason: String)

    // Voice
    case speechSynthesisFailed(reason: String)
    case speechRecognitionUnavailable(reason: String)
    case microphonePermissionDenied
    case speechRecognitionPermissionDenied

    // World Model demo (synthetic-task JEPA+MPC research demo, not real EEG)
    case worldModelDemoModelMissing(path: String)
    case worldModelDemoLoadFailed(path: String, underlying: String)
    case worldModelDemoInferenceFailed(reason: String)
    case worldModelDemoOutputShapeUnexpected(expected: String, actual: String)

    // App-level
    case cancelled

    public var description: String {
        switch self {
        case .bridgeUnavailable(let reason):
            return "BCIBridge unavailable: \(reason)"
        case .streamConnectFailed(let profile, let underlying):
            return "Could not connect to \(profile.displayName): \(underlying)"
        case .streamFailed(let reason):
            return "EEG stream failed: \(reason)"
        case .playbackFileNotFound(let path):
            return "Playback file not found: \(path)"
        case .playbackFileMalformed(let path, let reason):
            return "Playback file malformed at \(path): \(reason)"
        case .channelShapeMismatch(let expected, let actual):
            return "Expected \(expected) channels, got \(actual)"
        case .classifierModelMissing(let path):
            return "Core ML model not found at \(path)"
        case .classifierLoadFailed(let path, let underlying):
            return "Core ML load failed at \(path): \(underlying)"
        case .classifierInferenceFailed(let reason):
            return "Core ML inference failed: \(reason)"
        case .classifierOutputShapeUnexpected(let expected, let actual):
            return "Core ML output shape mismatch — expected \(expected), got \(actual)"
        case .predictorWeightsMissing(let path):
            return "MLX weights not found at \(path)"
        case .predictorInitFailed(let reason):
            return "MLX predictor init failed: \(reason)"
        case .predictorInferenceFailed(let reason):
            return "MLX predictor inference failed: \(reason)"
        case .tokenizerLoadFailed(let reason):
            return "Tokenizer load failed: \(reason)"
        case .embedderModelMissing(let path):
            return "Sentence embedder model not found at \(path)"
        case .embedderLoadFailed(let path, let underlying):
            return "Sentence embedder load failed at \(path): \(underlying)"
        case .embedderInferenceFailed(let reason):
            return "Sentence embedder inference failed: \(reason)"
        case .embedderOutputShapeUnexpected(let expected, let actual):
            return "Sentence embedder output shape mismatch — expected \(expected), got \(actual)"
        case .embedderMetadataInvalid(let path, let reason):
            return "Sentence embedder metadata invalid at \(path): \(reason)"
        case .speechSynthesisFailed(let reason):
            return "Speech synthesis failed: \(reason)"
        case .speechRecognitionUnavailable(let reason):
            return "Speech recognition unavailable: \(reason)"
        case .microphonePermissionDenied:
            return "Microphone permission denied"
        case .speechRecognitionPermissionDenied:
            return "Speech recognition permission denied"
        case .worldModelDemoModelMissing(let path):
            return "World Model demo Core ML model not found at \(path)"
        case .worldModelDemoLoadFailed(let path, let underlying):
            return "World Model demo Core ML load failed at \(path): \(underlying)"
        case .worldModelDemoInferenceFailed(let reason):
            return "World Model demo Core ML inference failed: \(reason)"
        case .worldModelDemoOutputShapeUnexpected(let expected, let actual):
            return "World Model demo Core ML output shape mismatch — expected \(expected), got \(actual)"
        case .cancelled:
            return "Cancelled"
        }
    }
}
