import XCTest
import BCICore
import BCICloudBridge
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

    func testMissingPromptResourceIsTerminalAndNamesWhatWasSearched() {
        let searched = "/Applications/NeuralCompose.app/Contents/Resources"
        let (phase, message) = HypnagogicRuntimeDiagnostics.failure(
            for: PromptProfileError.missingResource("hypnagogic.md", searched: [searched]))

        XCTAssertEqual(phase, .stopped)
        XCTAssertTrue(message.contains(searched), message)
        XCTAssertTrue(message.contains("hypnagogic.md"), message)
    }

    func testOtherRuntimeFailuresStayRetryable() {
        struct Transient: Error {}
        let (phase, message) = HypnagogicRuntimeDiagnostics.failure(for: Transient())

        XCTAssertEqual(phase, .retrying)
        XCTAssertTrue(message.hasPrefix("Runtime configuration failed:"), message)
    }
}
