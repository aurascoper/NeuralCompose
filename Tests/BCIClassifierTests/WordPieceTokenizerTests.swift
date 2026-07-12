import XCTest
@testable import BCICore
@testable import BCIClassifier

/// Exercises `WordPieceTokenizer` against a small, hand-crafted
/// `tokenizer.json` fixture (`Tests/Fixtures/tokenizer_test.json`) — not the
/// real BGE tokenizer. The point of this suite is to pin the *algorithm*
/// (basic tokenization, greedy WordPiece splitting, truncation/padding)
/// against a schema-correct file, independent of any real model existing on
/// disk.
final class WordPieceTokenizerTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureURL: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/tokenizer_test.json")
    }

    private func makeTokenizer(maxSequenceLength: Int = 8) throws -> WordPieceTokenizer {
        try WordPieceTokenizer(tokenizerJSONURL: fixtureURL, maxSequenceLength: maxSequenceLength)
    }

    // [PAD]=0 [UNK]=1 [CLS]=2 [SEP]=3 hello=4 world=5 play=6 ##ing=7 sleep=8 .=9

    func testBasicWordsMapToKnownIDs() throws {
        let tokenizer = try makeTokenizer()
        let (inputIDs, attentionMask, tokenTypeIDs) = tokenizer.tokenize("Hello world")

        XCTAssertEqual(inputIDs, [2, 4, 5, 3, 0, 0, 0, 0])
        XCTAssertEqual(attentionMask, [1, 1, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(tokenTypeIDs, [Int32](repeating: 0, count: 8))
    }

    func testWordPieceSplitsUnknownWordIntoSubwords() throws {
        let tokenizer = try makeTokenizer()
        let (inputIDs, _, _) = tokenizer.tokenize("playing")

        // "playing" isn't in the vocab whole; greedy longest-match splits it
        // into "play" + "##ing".
        XCTAssertEqual(inputIDs, [2, 6, 7, 3, 0, 0, 0, 0])
    }

    func testPunctuationIsSplitAsSeparateToken() throws {
        let tokenizer = try makeTokenizer()
        let (inputIDs, _, _) = tokenizer.tokenize("hello.")

        XCTAssertEqual(inputIDs, [2, 4, 9, 3, 0, 0, 0, 0])
    }

    func testUnresolvableTokenFallsBackToUNK() throws {
        let tokenizer = try makeTokenizer()
        let (inputIDs, _, _) = tokenizer.tokenize("xyz")

        XCTAssertEqual(inputIDs, [2, 1, 3, 0, 0, 0, 0, 0])
    }

    func testTruncationAtMaxSequenceLength() throws {
        // Content capacity is maxSequenceLength - 2 = 4 subwords; "hello
        // world playing sleep" produces 5 (hello, world, play, ##ing, sleep)
        // and must be truncated to the first 4.
        let tokenizer = try makeTokenizer(maxSequenceLength: 6)
        let (inputIDs, attentionMask, _) = tokenizer.tokenize("hello world playing sleep")

        XCTAssertEqual(inputIDs, [2, 4, 5, 6, 7, 3])
        XCTAssertEqual(attentionMask, [1, 1, 1, 1, 1, 1])
    }

    func testMissingFileThrows() {
        let missingURL = repoRoot.appendingPathComponent("Tests/Fixtures/does_not_exist.json")
        XCTAssertThrowsError(try WordPieceTokenizer(tokenizerJSONURL: missingURL)) { error in
            guard case BCIError.tokenizerLoadFailed = error else {
                return XCTFail("expected BCIError.tokenizerLoadFailed, got \(error)")
            }
        }
    }
}
