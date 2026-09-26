import XCTest
@testable import BCICloudBridge

final class LiveRuntimeFactoryTests: XCTestCase {

    func testExplicitOllamaSelectionProducesOllamaResolution() throws {
        let result = try LiveRuntimeFactory.make(
            runtimeName: "ollama",
            model: "qwen2.5:3b",
            systemPrompt: "test prompt"
        )

        XCTAssertEqual(result.resolved.name, "ollama")
        XCTAssertEqual(result.resolved.model, "qwen2.5:3b")
    }

    func testUnknownRuntimeFailsInsteadOfFallingBack() {
        XCTAssertThrowsError(
            try LiveRuntimeFactory.make(runtimeName: "not-a-runtime", model: nil)
        )
    }
}
