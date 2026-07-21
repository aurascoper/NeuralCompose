import XCTest
import Foundation
import CryptoKit
@testable import BCICloudBridge

/// Tests for `PromptProfile` and the byte-identity keep-bar from
/// seed-004 (`prompt-portability` hypothesis): the prompt text loaded
/// from `Sources/BCICloudBridge/Prompts/*.md` must be the exact same
/// bytes the runtime sends to the model, regardless of which provider
/// is consuming it. The Markdown files are the source of truth; the
/// `static var` accessors on `ClaudeCLIGenerator` are load-by-name
/// conveniences for legacy call sites.
final class PromptProfileTests: XCTestCase {

    func testHypnagogicPromptLoadsFromBundle() throws {
        let p = try PromptProfile.hypnagogic.load()
        XCTAssertFalse(p.isEmpty, "hypnagogic prompt must load")
        XCTAssertTrue(p.contains("NEVER ask questions"))
        XCTAssertTrue(p.contains("TWO short"))
        XCTAssertTrue(p.contains("hypnagogic"))
    }

    func testWakingDialecticalPromptLoadsFromBundle() throws {
        let p = try PromptProfile.wakingDialectical.load()
        XCTAssertFalse(p.isEmpty, "waking-dialectical prompt must load")
        XCTAssertTrue(p.contains("waking dialectical exchange"))
        XCTAssertTrue(p.contains("THREE sentences"))
        XCTAssertTrue(p.contains("never ask"))
    }

    func testWitnessPromptLoadsFromBundle() throws {
        let p = try PromptProfile.witness.load()
        XCTAssertFalse(p.isEmpty, "witness prompt must load")
        XCTAssertTrue(p.contains("two-voice dialectical exchange"))
        XCTAssertTrue(p.contains("ONE sentence"))
    }

    func testPromptsAreDistinct() throws {
        // The three prompts must be different from each other; the
        // witness must NOT reuse the poles' prompt.
        let hypo = try PromptProfile.hypnagogic.load()
        let waking = try PromptProfile.wakingDialectical.load()
        let witness = try PromptProfile.witness.load()
        XCTAssertNotEqual(hypo, waking)
        XCTAssertNotEqual(hypo, witness)
        XCTAssertNotEqual(waking, witness)
    }

    func testWitnessPromptIsWakingRegister() throws {
        // The witness ships pre-GATE; it must not contain sleep imagery
        // that would mislead the model into a hypnagogic register.
        let p = try PromptProfile.witness.load().lowercased()
        for word in ["drift", "dissolv", "sleep", "dream"] {
            XCTAssertFalse(p.contains(word), "witness prompt must stay waking (found '\(word)')")
        }
    }

    func testHypnagogicPromptContainsSleepImagery() throws {
        // The hypnagogic prompt is allowed (required) to use sleep imagery.
        let p = try PromptProfile.hypnagogic.load().lowercased()
        XCTAssertTrue(p.contains("sleep") || p.contains("hypnagogic"))
    }

    func testPromptHashIsStable() throws {
        // The hash must be deterministic and stable across loads.
        let h1 = try PromptProfile.wakingDialectical.hash()
        let h2 = try PromptProfile.wakingDialectical.hash()
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64, "sha256 hex digest must be 64 chars")
        XCTAssertTrue(h1.allSatisfy { $0.isHexDigit })
    }

    func testPromptHashesAreDistinct() throws {
        let h1 = try PromptProfile.hypnagogic.hash()
        let h2 = try PromptProfile.wakingDialectical.hash()
        let h3 = try PromptProfile.witness.hash()
        XCTAssertNotEqual(h1, h2)
        XCTAssertNotEqual(h1, h3)
        XCTAssertNotEqual(h2, h3)
    }

    func testClaudeCLIGeneratorLoadsPromptsFromBundle() {
        // The legacy `static var` accessors on `ClaudeCLIGenerator`
        // must produce the same content as `PromptProfile.load()`.
        // This is the keep-bar test: the public API of the generator
        // continues to expose these names, but the bytes are now
        // sourced from the Markdown files.
        XCTAssertEqual(ClaudeCLIGenerator.hypnagogicSystemPrompt,
                       (try? PromptProfile.hypnagogic.load()) ?? "")
        XCTAssertEqual(ClaudeCLIGenerator.wakingDialecticalSystemPrompt,
                       (try? PromptProfile.wakingDialectical.load()) ?? "")
        XCTAssertEqual(ClaudeCLIGenerator.witnessSystemPrompt,
                       (try? PromptProfile.witness.load()) ?? "")
    }

    func testClaudeCLIGeneratorPromptsAreNotEmpty() {
        // The bundled files exist; the legacy accessors must return
        // non-empty strings. (A regression where the resources are
        // missing would silently produce empty strings today; the
        // keep-bar requires the loaded text to match the historical
        // values, so emptiness is the first thing to fail.)
        XCTAssertFalse(ClaudeCLIGenerator.hypnagogicSystemPrompt.isEmpty)
        XCTAssertFalse(ClaudeCLIGenerator.wakingDialecticalSystemPrompt.isEmpty)
        XCTAssertFalse(ClaudeCLIGenerator.witnessSystemPrompt.isEmpty)
    }
}
