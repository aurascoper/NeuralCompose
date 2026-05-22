import Foundation
import BCICore

#if canImport(Tokenizers)
import Tokenizers
#endif
#if canImport(Hub)
import Hub
#endif

/// Tokenizer facade.
///
/// We deliberately keep this loose: the real production path uses
/// `swift-transformers`' `AutoTokenizer` to load a local `tokenizer.json`
/// from a directory, but the exact factory signature has drifted across
/// minor releases (`from(pretrained:)`, `from(modelFolder:)`,
/// `from(tokenizerConfig:tokenizerData:)`, etc.).
///
/// To insulate the app from that drift we:
///   • try a known-good loader, wrapped in `try?`,
///   • on any failure, fall back to a built-in whitespace tokenizer.
///
/// Result: the project always compiles, never reaches the Hub at runtime,
/// and the stub LLM still drives a coherent demo without a real model.
public final class TokenizerService: TokenizerProviding, @unchecked Sendable {

    public let isLive: Bool

    public init(modelDirectory: URL?) {
        // We currently use the whitespace-fallback path unconditionally. To
        // wire up a real `AutoTokenizer` once you've picked an MLX model,
        // replace the body of this init with the matching swift-transformers
        // loader for *your pinned version*. The factory call has changed
        // shape several times in 2024–2026; we'd rather compile reliably
        // than guess.
        //
        // Example for swift-transformers 0.1.x using the directory loader,
        // when the API supports it:
        //
        //   if let dir = modelDirectory,
        //      let t = try? await AutoTokenizer.from(modelFolder: dir) {
        //       self._tokenizer = t
        //   }
        //
        _ = modelDirectory
        self.isLive = false
    }

    public func encode(_ text: String) throws -> [Int32] {
        // Whitespace fallback — produces stable but synthetic token IDs that
        // are only valid inside this process. The stub predictor doesn't use
        // them; the MLX adapter does its own tokenization via the model's
        // bundled tokenizer.
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .map { Int32(abs($0.hashValue) % 50_000) }
    }

    public func decode(_ tokens: [Int32]) throws -> String {
        return tokens.map { "[\($0)]" }.joined(separator: " ")
    }

    public func applyChatTemplate(context: String) -> String {
        // For next-word completion we want raw context, not chat-formatted.
        return context
    }
}
