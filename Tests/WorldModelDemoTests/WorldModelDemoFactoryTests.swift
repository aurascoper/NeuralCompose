import XCTest
@testable import WorldModelDemo

final class WorldModelDemoFactoryTests: XCTestCase {
    func testFallsBackToBaselineWhenModelsDirectoryMissing() {
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorldModelDemoFactoryTests-\(UUID().uuidString)")
            .path

        let resolved = WorldModelDemoFactory.live(modelsDirectory: missingDir)

        XCTAssertEqual(resolved.kind, .baseline)
        XCTAssertFalse(resolved.engine.isLive)
    }
}
