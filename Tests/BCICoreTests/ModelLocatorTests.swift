import XCTest
@testable import BCICore

final class ModelLocatorTests: XCTestCase {
    private var root: URL!
    private let model = "BGE-small-en-v1.5"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A models directory under the temp root, optionally holding `model`.
    private func modelsDir(_ name: String, holdsModel: Bool) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: holdsModel ? dir.appendingPathComponent(model) : dir, withIntermediateDirectories: true)
        return dir
    }

    func testEnvironmentDirectoryWinsWhenItHasTheModel() throws {
        let env = try modelsDir("env", holdsModel: true)
        let url = ModelLocator.url(for: model,
                                   environment: [ModelLocator.environmentKey: env.path],
                                   workingDirectoryModels: try modelsDir("cwd", holdsModel: true),
                                   applicationSupport: try modelsDir("support", holdsModel: true))
        XCTAssertEqual(url.path, env.appendingPathComponent(model).path)
    }

    /// `swift run` from the repo keeps using the repo's copy, even when an
    /// installed copy exists in Application Support.
    func testWorkingDirectoryCopyBeatsApplicationSupport() throws {
        let cwd = try modelsDir("cwd", holdsModel: true)
        let url = ModelLocator.url(for: model, environment: [:],
                                   workingDirectoryModels: cwd,
                                   applicationSupport: try modelsDir("support", holdsModel: true))
        XCTAssertEqual(url.path, cwd.appendingPathComponent(model).path)
    }

    /// The installed app's case: no env var, a working directory of `/` with no
    /// `Models/`, and the model in Application Support.
    func testApplicationSupportIsUsedWhenNothingEarlierHasTheModel() throws {
        let support = try modelsDir("support", holdsModel: true)
        let url = ModelLocator.url(for: model,
                                   environment: [ModelLocator.environmentKey: try modelsDir("env", holdsModel: false).path],
                                   workingDirectoryModels: try modelsDir("cwd", holdsModel: false),
                                   applicationSupport: support)
        XCTAssertEqual(url.path, support.appendingPathComponent(model).path)
    }

    /// Nothing anywhere: the working-directory path comes back, so the caller's
    /// "not found" log is unchanged.
    func testMissingEverywhereFallsBackToTheWorkingDirectoryPath() throws {
        let cwd = try modelsDir("cwd", holdsModel: false)
        let url = ModelLocator.url(for: model, environment: [:],
                                   workingDirectoryModels: cwd,
                                   applicationSupport: try modelsDir("support", holdsModel: false))
        XCTAssertEqual(url.path, cwd.appendingPathComponent(model).path)
    }

    func testDefaultWorkingDirectoryPathIsRelative() {
        let url = ModelLocator.url(for: "no-such-model-\(UUID().uuidString)",
                                   environment: [:], applicationSupport: nil)
        XCTAssertTrue(url.relativePath.hasPrefix("Models/"), url.relativePath)
    }

    func testDefaultApplicationSupportLocation() throws {
        let url = try XCTUnwrap(ModelLocator.applicationSupportModels())
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/NeuralCompose/Models"), url.path)
    }
}
