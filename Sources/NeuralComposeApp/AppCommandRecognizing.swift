import Foundation
import BCICore

/// Maps a free-text utterance (or a typed query) to an `AppCommand`,
/// given a vocabulary. The single method is a pure function — no
/// streaming, no partial results, no actor isolation.
///
/// Implementations:
///   - `StubCommandRecognizer` (deterministic dictionary match, no
///     external dependencies — exists in this iteration so the
///     dispatcher and palette can be exercised without any speech
///     framework)
///   - `SpeechCommandRecognizer` (future — uses `SFSpeechRecognizer`
///     from the Speech framework, lives in `BCIVoice`)
///   - `EmbeddingCommandRecognizer` (future — handles non-exact-match
///     utterances by projecting into embedding space; depends on
///     `BCIEmbedding` which is not yet built)
///   - `LLMCommandRecognizer` (future — handles ambiguous intents via
///     a local LLM; depends on the same MLX infrastructure the
///     dialectic engine uses)
///   - `ShortcutCommandRecognizer` (future — bridges Apple Shortcuts
///     to the command surface)
///
/// Every implementation takes the descriptor list as a parameter, so
/// the *vocabulary* is decoupled from the *matcher*. Adding a new
/// command does not require changes to any recognizer; adding a new
/// recognizer does not require changes to the vocabulary.
public protocol AppCommandRecognizing: Sendable {
    func recognize(
        _ text: String,
        in descriptors: [CommandDescriptor]
    ) -> AppCommand?
}
