import Foundation

/// Local tokenizer utilities. We use `swift-transformers` for the real impl,
/// but only for *tokenizer + chat template* functionality — never for Hub
/// network access at runtime.
public protocol TokenizerProviding: Sendable {
    /// True if the tokenizer was loaded from a real `tokenizer.json`; false
    /// if it's the simple whitespace fallback.
    var isLive: Bool { get }

    /// Encode text to token IDs. Used for context windowing before LLM input.
    func encode(_ text: String) throws -> [Int32]

    /// Decode token IDs back to text. Used to turn predicted token IDs into
    /// `PredictedWord`s for the carousel.
    func decode(_ tokens: [Int32]) throws -> String

    /// Apply the model's chat template, if one exists, to format `context`
    /// for next-word generation. For raw-completion models, this is the
    /// identity function.
    func applyChatTemplate(context: String) -> String
}
