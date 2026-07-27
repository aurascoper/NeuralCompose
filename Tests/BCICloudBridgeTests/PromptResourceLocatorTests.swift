import XCTest
@testable import BCICloudBridge

/// Regression tests for the packaged-app SIGTRAP.
///
/// A packaged `/Applications/NeuralCompose.app` crashed on the main thread
/// inside SwiftPM's generated `NSBundle.module` accessor, reached from
/// `PromptProfile.load()` → `LiveRuntimeFactory.make(...)` →
/// `AppViewModel.ensureHypnagogicLoopRunning()`. The bundle was absent from
/// the app because the packaging script copied only the MLX resource bundle.
///
/// The distinction these tests pin: a missing resource must be a *typed
/// error*, not an assertion. `Bundle.module` cannot give us that — its
/// generated initializer calls `fatalError()`, which trips during the lazy
/// global's `dispatch_once`, before any Swift error exists. Every test below
/// that completes at all is also evidence the process did not trap.
final class PromptResourceLocatorTests: XCTestCase {

    // MARK: - The bundle is found in the layout the tests actually run in

    func testStandardLocatorFindsBundle() throws {
        let locator = PromptResourceLocator.standard
        let url = locator.url(forResource: "witness", withExtension: "md")
        XCTAssertNotNil(
            url,
            "standard locator found no prompt resource. Searched: "
                + locator.searchedPaths.joined(separator: ", ")
        )
    }

    /// Pins the SwiftPM bundle name. A package or target rename silently
    /// invalidates the hardcoded string, and the only symptom would be a
    /// packaged-app failure — so fail here instead.
    func testBundleNameMatchesSwiftPMConvention() {
        XCTAssertEqual(PromptResourceLocator.bundleName, "NeuralCompose_BCICloudBridge")
    }

    func testEveryProfileLoadsAndIsNonEmpty() throws {
        for profile in PromptProfile.allCases {
            let text = try profile.load()
            XCTAssertFalse(text.isEmpty, "\(profile.rawValue) loaded empty")
        }
    }

    // MARK: - Absence is a value, not a trap

    func testMissingBundleThrowsTypedErrorInsteadOfTrapping() throws {
        let empty = try makeTemporaryDirectory()
        let locator = PromptResourceLocator(roots: [empty])

        XCTAssertNil(locator.url(forResource: "witness", withExtension: "md"))

        do {
            _ = try PromptProfile.witness.load(using: locator)
            XCTFail("expected missingResource; a missing bundle must never succeed")
        } catch let error as PromptProfileError {
            guard case .missingResource(let file, let searched) = error else {
                return XCTFail("expected .missingResource, got \(error)")
            }
            XCTAssertEqual(file, "witness.md")
            XCTAssertFalse(searched.isEmpty, "diagnostics must report searched paths")
        }
    }

    /// The bundle exists but the individual resource does not — the case the
    /// original `guard` was written for, which was unreachable whenever the
    /// whole bundle was missing.
    func testMissingFileInsidePresentBundleThrows() throws {
        let root = try makeTemporaryDirectory()
        let bundle = root.appendingPathComponent("\(PromptResourceLocator.bundleName).bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "not the witness".write(
            to: bundle.appendingPathComponent("hypnagogic.md"), atomically: true, encoding: .utf8)

        let locator = PromptResourceLocator(roots: [root])
        XCTAssertNotNil(locator.url(forResource: "hypnagogic", withExtension: "md"))

        do {
            _ = try PromptProfile.witness.load(using: locator)
            XCTFail("expected missingResource for the absent file")
        } catch let error as PromptProfileError {
            guard case .missingResource = error else {
                return XCTFail("expected .missingResource, got \(error)")
            }
        }
    }

    /// An empty prompt file must be refused rather than returned. `claude -p
    /// --system-prompt ""` is an unconstrained model on the one deliberate
    /// network-egress path, so "" is never a usable value.
    func testEmptyResourceIsRefused() throws {
        let root = try makeTemporaryDirectory()
        let bundle = root.appendingPathComponent("\(PromptResourceLocator.bundleName).bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "\n".write(
            to: bundle.appendingPathComponent("witness.md"), atomically: true, encoding: .utf8)

        do {
            _ = try PromptProfile.witness.load(using: PromptResourceLocator(roots: [root]))
            XCTFail("expected emptyResource; an empty constraining prompt must be refused")
        } catch let error as PromptProfileError {
            guard case .emptyResource = error else {
                return XCTFail("expected .emptyResource, got \(error)")
            }
        }
    }

    // MARK: - Layout coverage

    /// The packaged `.app` puts the bundle in `Contents/Resources`, whereas a
    /// SwiftPM build leaves it beside the executable. Both must resolve.
    func testFlatAndNestedBundleLayoutsBothResolve() throws {
        for nested in [false, true] {
            let root = try makeTemporaryDirectory()
            var dir = root.appendingPathComponent("\(PromptResourceLocator.bundleName).bundle")
            if nested { dir.appendPathComponent("Contents/Resources") }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "body".write(
                to: dir.appendingPathComponent("witness.md"), atomically: true, encoding: .utf8)

            XCTAssertNotNil(
                PromptResourceLocator(roots: [root]).url(forResource: "witness", withExtension: "md"),
                "nested=\(nested) layout did not resolve")
        }
    }

    /// Loading against a non-standard locator must not poison the process-wide
    /// cache that the real app reads.
    func testNonStandardLocatorDoesNotPoisonCache() throws {
        let root = try makeTemporaryDirectory()
        let bundle = root.appendingPathComponent("\(PromptResourceLocator.bundleName).bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "sentinel-value".write(
            to: bundle.appendingPathComponent("witness.md"), atomically: true, encoding: .utf8)

        let injected = try PromptProfile.witness.load(using: PromptResourceLocator(roots: [root]))
        XCTAssertEqual(injected, "sentinel-value")

        let real = try PromptProfile.witness.load()
        XCTAssertNotEqual(real, "sentinel-value", "injected load leaked into the standard cache")
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nc-prompt-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
