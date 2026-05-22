import Foundation

/// A single LLM-suggested next token / word, ready to be shown in the carousel.
///
/// `text` is what gets appended to the composed sentence. `displayText` may
/// differ (e.g., strip the leading space for compact rendering).
public struct PredictedWord: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let text: String
    public let displayText: String
    public let probability: Float

    public init(
        id: UUID = UUID(),
        text: String,
        displayText: String? = nil,
        probability: Float
    ) {
        self.id = id
        self.text = text
        self.displayText = displayText ?? Self.makeDisplay(from: text)
        self.probability = probability
    }

    private static func makeDisplay(from text: String) -> String {
        // Strip a single leading space for compact carousel layout; keep
        // internal whitespace intact in case the model emitted a multi-word
        // chunk.
        if let first = text.first, first == " " {
            return String(text.dropFirst())
        }
        return text
    }
}
