import XCTest
@testable import BCICore

/// The `neuralcompose://` URL scheme is the Siri-Shortcut entry point. These pin
/// the parse grammar so a Shortcut's "Open URL" reliably maps to an app action —
/// and, critically, that a malformed or foreign URL is ignored (nil), never
/// mis-dispatched.
final class URLCommandTests: XCTestCase {

    private func parse(_ s: String) -> URLCommand? {
        guard let url = URL(string: s) else { XCTFail("bad test URL: \(s)"); return nil }
        return URLCommand.parse(url)
    }

    func testSpeakWithoutTextIsComposed() {
        XCTAssertEqual(parse("neuralcompose://speak"), .speakComposed)
        XCTAssertEqual(parse("neuralcompose://speak/"), .speakComposed)
    }

    func testSpeakWithTextDecodesPercentEncoding() {
        XCTAssertEqual(parse("neuralcompose://speak?text=Hello%20world"), .speak(text: "Hello world"))
    }

    func testBlankTextFallsBackToComposed() {
        // A Shortcut that passes an empty "Ask for Input" must not speak nothing —
        // it reads the composed sentence instead.
        XCTAssertEqual(parse("neuralcompose://speak?text=%20%20"), .speakComposed)
        XCTAssertEqual(parse("neuralcompose://speak?text="), .speakComposed)
    }

    func testDispatchActionsMapToAppCommands() {
        XCTAssertEqual(parse("neuralcompose://refine"), .dispatch(.refine))
        XCTAssertEqual(parse("neuralcompose://dictate"), .dispatch(.startDictation))
        XCTAssertEqual(parse("neuralcompose://start-dictation"), .dispatch(.startDictation))
        XCTAssertEqual(parse("neuralcompose://stop-dictation"), .dispatch(.stopDictation))
        XCTAssertEqual(parse("neuralcompose://reset"), .dispatch(.resetComposition))
    }

    func testActionIsCaseInsensitive() {
        XCTAssertEqual(parse("neuralcompose://SPEAK"), .speakComposed)
        XCTAssertEqual(parse("NEURALCOMPOSE://Refine"), .dispatch(.refine))
    }

    func testForeignSchemeOrUnknownActionIsIgnored() {
        XCTAssertNil(parse("https://speak"), "wrong scheme must not dispatch")
        XCTAssertNil(parse("neuralcompose://unknownaction"))
        XCTAssertNil(parse("neuralcompose://"))
    }
}
