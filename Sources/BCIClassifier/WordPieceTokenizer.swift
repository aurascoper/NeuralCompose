import BCICore
import Foundation

/// WordPiece tokenizer driven entirely by a HuggingFace `tokenizers`-library
/// `tokenizer.json` — vocab, special-token ids, and normalizer flags are all
/// **read from that file**, never assumed. Only the WordPiece
/// greedy-longest-match algorithm itself (a fixed, well-specified part of
/// BERT-family tokenization) is implemented here; every parameter it runs
/// with comes from the artifact the source model actually shipped, not from
/// documentation-derived guesses. See `Scripts/convert-sentence-embedder.py`,
/// which saves the model's own `tokenizer.json` rather than hand-deriving one.
struct WordPieceTokenizer: Sendable {
    private let vocab: [String: Int32]
    private let unkTokenID: Int32
    private let continuingSubwordPrefix: String
    private let maxInputCharsPerWord: Int
    private let lowercase: Bool
    private let stripAccents: Bool
    private let clsTokenID: Int32
    private let sepTokenID: Int32
    private let padTokenID: Int32
    private let maxSequenceLength: Int

    init(tokenizerJSONURL: URL, maxSequenceLength: Int = 512) throws {
        guard let data = try? Data(contentsOf: tokenizerJSONURL) else {
            throw BCIError.tokenizerLoadFailed(reason: "file not found at \(tokenizerJSONURL.path)")
        }

        let decoded: TokenizerJSON
        do {
            decoded = try JSONDecoder().decode(TokenizerJSON.self, from: data)
        } catch {
            throw BCIError.tokenizerLoadFailed(reason: "malformed tokenizer.json: \(error.localizedDescription)")
        }

        self.vocab = decoded.model.vocab
        self.continuingSubwordPrefix = decoded.model.continuingSubwordPrefix
        self.maxInputCharsPerWord = decoded.model.maxInputCharsPerWord
        self.lowercase = decoded.normalizer?.lowercase ?? true
        // HF ties strip_accents to lowercase when the field is null.
        self.stripAccents = decoded.normalizer?.stripAccents ?? self.lowercase
        self.maxSequenceLength = maxSequenceLength

        guard let unkID = vocab[decoded.model.unkToken] else {
            throw BCIError.tokenizerLoadFailed(
                reason: "unk_token '\(decoded.model.unkToken)' not present in vocab"
            )
        }
        self.unkTokenID = unkID

        func specialTokenID(_ content: String) throws -> Int32 {
            if let found = decoded.addedTokens.first(where: { $0.content == content && $0.special })?.id {
                return found
            }
            if let found = decoded.model.vocab[content] {
                return found
            }
            throw BCIError.tokenizerLoadFailed(reason: "special token '\(content)' not present in tokenizer.json")
        }

        self.clsTokenID = try specialTokenID("[CLS]")
        self.sepTokenID = try specialTokenID("[SEP]")
        self.padTokenID = try specialTokenID("[PAD]")
    }

    /// `[CLS] <subwords> [SEP]`, truncated to `maxSequenceLength - 2`
    /// subwords and padded with `[PAD]` up to `maxSequenceLength`.
    func tokenize(_ text: String) -> (inputIDs: [Int32], attentionMask: [Int32], tokenTypeIDs: [Int32]) {
        let basicTokens = Self.basicTokenize(text, lowercase: lowercase, stripAccents: stripAccents)

        var subwordIDs: [Int32] = []
        for token in basicTokens {
            subwordIDs.append(contentsOf: wordPieceSplit(token))
        }

        let maxContentLength = max(0, maxSequenceLength - 2)
        let truncated = Array(subwordIDs.prefix(maxContentLength))

        var inputIDs: [Int32] = [clsTokenID] + truncated + [sepTokenID]
        var attentionMask = [Int32](repeating: 1, count: inputIDs.count)

        while inputIDs.count < maxSequenceLength {
            inputIDs.append(padTokenID)
            attentionMask.append(0)
        }

        let tokenTypeIDs = [Int32](repeating: 0, count: maxSequenceLength)
        return (inputIDs, attentionMask, tokenTypeIDs)
    }

    // MARK: - Basic tokenization (whitespace + punctuation splitting)

    private static func basicTokenize(_ text: String, lowercase: Bool, stripAccents: Bool) -> [String] {
        var normalized = text.precomposedStringWithCanonicalMapping
        if lowercase {
            normalized = normalized.lowercased()
        }
        if stripAccents {
            normalized = normalized.decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { $0.properties.generalCategory != .nonspacingMark }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
        }

        var tokens: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else if isPunctuation(scalar) {
                if !current.isEmpty { tokens.append(current); current = "" }
                tokens.append(String(scalar))
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Mirrors BERT's `BasicTokenizer._is_punctuation`: ASCII punctuation
    /// ranges plus Unicode punctuation/symbol categories for everything else.
    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (33...47).contains(value) || (58...64).contains(value)
            || (91...96).contains(value) || (123...126).contains(value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    // MARK: - WordPiece subword splitting

    /// Greedy longest-match-first, continuation pieces prefixed with
    /// `continuingSubwordPrefix`. Falls back to a single `[UNK]` for the
    /// whole token if any piece can't be resolved against the vocab.
    private func wordPieceSplit(_ token: String) -> [Int32] {
        let chars = Array(token)
        guard chars.count <= maxInputCharsPerWord else { return [unkTokenID] }

        var result: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var matchedID: Int32?
            while start < end {
                let piece = String(chars[start..<end])
                let candidate = start > 0 ? continuingSubwordPrefix + piece : piece
                if let id = vocab[candidate] {
                    matchedID = id
                    break
                }
                end -= 1
            }
            guard let id = matchedID else { return [unkTokenID] }
            result.append(id)
            start = end
        }
        return result
    }
}

/// Minimal subset of the HF `tokenizers`-library `tokenizer.json` schema —
/// only the fields `WordPieceTokenizer` actually needs.
private struct TokenizerJSON: Decodable {
    struct Model: Decodable {
        let unkToken: String
        let continuingSubwordPrefix: String
        let maxInputCharsPerWord: Int
        let vocab: [String: Int32]

        enum CodingKeys: String, CodingKey {
            case unkToken = "unk_token"
            case continuingSubwordPrefix = "continuing_subword_prefix"
            case maxInputCharsPerWord = "max_input_chars_per_word"
            case vocab
        }
    }

    struct Normalizer: Decodable {
        let lowercase: Bool?
        let stripAccents: Bool?

        enum CodingKeys: String, CodingKey {
            case lowercase
            case stripAccents = "strip_accents"
        }
    }

    struct AddedToken: Decodable {
        let id: Int32
        let content: String
        let special: Bool
    }

    let model: Model
    let normalizer: Normalizer?
    let addedTokens: [AddedToken]

    enum CodingKeys: String, CodingKey {
        case model
        case normalizer
        case addedTokens = "added_tokens"
    }
}
