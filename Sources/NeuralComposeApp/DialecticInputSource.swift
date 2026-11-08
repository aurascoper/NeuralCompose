import Foundation

/// Where the hypnagogic loop's turns come from while it is enabled.
///
/// `microphone` is the default and the only path that captures audio: the
/// loop opens the mic for each listen turn and closes it before speaking.
/// `typedPrompt` swaps the mic listener for `TypedPromptListener`: the user
/// types a prompt in the `TypedPromptPanel`, the loop treats it as the heard
/// utterance, and speech output stays on. No microphone or speech
/// authorization is requested on this path. Transcript egress to the
/// configured runtime is the same on both paths; only the capture differs,
/// and the privacy banner's badge says which is active.
public enum DialecticInputSource: String, CaseIterable, Sendable, Identifiable {
    case microphone = "Microphone"
    case typedPrompt = "Typed prompts"

    public var id: String { rawValue }

    /// Short label for the segmented picker.
    public var label: String { rawValue }
}
