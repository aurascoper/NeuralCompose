import Foundation

/// Whether a voice capability (input or output) is backed by a real system
/// framework implementation or a zero-dependency stub. Deliberately not a
/// `PipelineMode` case — voice isn't part of the continuous EEG pipeline
/// substitution story (see `PipelineMode`'s own doc comment), it only meets
/// that pipeline at the composition buffer.
public enum VoiceCapabilityKind: String, Sendable, Codable {
    case live
    case stub
}
