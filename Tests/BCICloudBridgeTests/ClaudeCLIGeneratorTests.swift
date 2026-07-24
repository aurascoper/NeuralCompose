import XCTest
import Foundation
import BCICore
@testable import BCICloudBridge

/// The subprocess path (`claude -p`) is exercised by manual smoke, not unit
/// tests. Here we cover the pure JSON-envelope parsing and the non-isolated
/// metadata, which is where the parsing bugs would live.
final class ClaudeCLIGeneratorTests: XCTestCase {

    func testParsesResultFieldAndTrims() throws {
        let json = #"{"type":"result","is_error":false,"result":"  Drifting deeper.  "}"#
            .data(using: .utf8)!
        XCTAssertEqual(try ClaudeCLIGenerator.parseResult(json), "Drifting deeper.")
    }

    func testThrowsWhenIsErrorTrue() throws {
        let json = #"{"is_error":true,"result":"boom"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeCLIGenerator.parseResult(json))
    }

    func testThrowsWhenResultMissing() throws {
        let json = #"{"is_error":false}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeCLIGenerator.parseResult(json))
    }

    func testThrowsOnNonJSON() throws {
        let data = "not json at all".data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeCLIGenerator.parseResult(data))
    }

    func testMetadata() throws {
        let gen = try ClaudeCLIGenerator(model: "claude-sonnet-5")
        XCTAssertTrue(gen.isLive)
        XCTAssertEqual(gen.modelIdentifier, "claude-sonnet-5 (claude-cli)")
    }

    func testDefaultSystemPromptIsConstrained() throws {
        // Guardrail: the network path must never default to an unconstrained
        // prompt — it must forbid questions and cap length.
        let p = try ClaudeCLIGenerator.hypnagogicSystemPrompt()
        XCTAssertTrue(p.contains("NEVER ask questions"))
        XCTAssertTrue(p.contains("TWO short"))
    }

    func testWitnessSystemPromptIsSeparateAndWaking() throws {
        // The witness prompt must be a DISTINCT constant (never the poles' prompt),
        // must stay in the waking register (no sleep imagery — it ships pre-GATE),
        // and must forbid the witness from addressing the user.
        XCTAssertNotEqual(try ClaudeCLIGenerator.witnessSystemPrompt(),
                          try ClaudeCLIGenerator.wakingDialecticalSystemPrompt())
        let p = try ClaudeCLIGenerator.witnessSystemPrompt().lowercased()
        for word in ["drift", "dissolv", "sleep", "dream"] {
            XCTAssertFalse(p.contains(word), "witness prompt must stay waking (found '\(word)')")
        }
        XCTAssertTrue(p.contains("never address the user"))
        XCTAssertTrue(p.contains("avoid"), "its job is to name what was avoided")
    }
}
