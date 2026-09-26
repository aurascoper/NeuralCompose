import XCTest
@testable import NeuralComposeApp

final class HypnagogicRuntimeConfigurationTests: XCTestCase {

    func testEnvironmentOverridesPersistedRuntimeAndModel() {
        let configuration = HypnagogicRuntimeConfiguration.resolve(
            environment: [
                "NEURALCOMPOSE_RUNTIME": "ollama",
                "NEURALCOMPOSE_MODEL": "qwen2.5:3b",
            ],
            preference: .claude
        )

        XCTAssertEqual(configuration.runtimeName, "ollama")
        XCTAssertEqual(configuration.model, "qwen2.5:3b")
        XCTAssertEqual(configuration.source, .environment)
        XCTAssertTrue(configuration.isEnvironmentControlled)
    }

    func testSavedOllamaPreferenceUsesLocalDefaultModel() {
        let configuration = HypnagogicRuntimeConfiguration.resolve(
            environment: [:],
            preference: .ollama
        )

        XCTAssertEqual(configuration.runtimeName, "ollama")
        XCTAssertEqual(configuration.model, "qwen2.5:0.5b")
        XCTAssertEqual(configuration.source, .savedPreference)
        XCTAssertEqual(configuration.transportLabel, "local HTTP")
    }

    func testModelEnvironmentOverrideIsNotSilentlyDiscarded() {
        let configuration = HypnagogicRuntimeConfiguration.resolve(
            environment: ["NEURALCOMPOSE_MODEL": "claude-opus-test"],
            preference: .claude
        )

        XCTAssertEqual(configuration.runtimeName, "claude")
        XCTAssertEqual(configuration.model, "claude-opus-test")
        XCTAssertEqual(configuration.source, .environment)
    }
}
