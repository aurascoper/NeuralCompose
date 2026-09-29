import XCTest
@testable import BCICloudBridge

/// Verifies a *packaged* `.app` against the same locator the app runs.
///
/// The crash this guards was invisible to `swift test` and `swift run`,
/// because SwiftPM leaves the resource bundle beside the binary in
/// `.build/<config>/` where `Bundle.module` resolves fine. Only the packaged
/// layout was broken, and nothing exercised it. These tests close that gap
/// without launching the GUI app (which would need window-server access and
/// TCC grants for mic/speech).
///
/// Skips unless `Scripts/package-app-bundle.sh` has produced an app;
/// `Scripts/smoke-packaged-resources.sh` builds one and then runs this suite.
final class PackagedAppResourceTests: XCTestCase {

    /// `.build/NeuralCompose.app`, or nil when it has not been packaged.
    private var packagedResourcesURL: URL? {
        // .../.build/<config>/<TestBundle>.xctest → walk up to `.build`.
        var dir = Bundle(for: PackagedAppResourceTests.self).bundleURL
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            let app = dir.appendingPathComponent("NeuralCompose.app")
            let resources = app.appendingPathComponent("Contents/Resources")
            if FileManager.default.fileExists(atPath: resources.path) { return resources }
        }
        return nil
    }

    func testPackagedAppContainsPromptBundle() throws {
        guard let resources = packagedResourcesURL else {
            throw XCTSkip("no packaged .app; run Scripts/package-app-bundle.sh first")
        }
        let bundle = resources.appendingPathComponent("\(PromptResourceLocator.bundleName).bundle")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bundle.path),
            "packaged app is missing \(PromptResourceLocator.bundleName).bundle — "
                + "this is the exact defect that crashed the app with SIGTRAP")
    }

    /// The load-bearing assertion: the real locator, pointed at the real
    /// packaged layout, resolves every prompt. If this passes, the packaged
    /// app cannot reach the missing-resource path at all.
    func testLocatorResolvesEveryPromptInPackagedLayout() throws {
        guard let resources = packagedResourcesURL else {
            throw XCTSkip("no packaged .app; run Scripts/package-app-bundle.sh first")
        }
        let locator = PromptResourceLocator(roots: [resources])
        for profile in PromptProfile.allCases {
            let text = try profile.load(using: locator)
            XCTAssertFalse(
                text.isEmpty,
                "\(profile.rawValue) resolved empty in the packaged layout")
        }
    }
}
