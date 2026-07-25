import XCTest
@testable import NeuralComposeApp
@testable import BCIEEG
@testable import BCICore
@testable import BCIClassifier
@testable import BCILLM
@testable import BCIVoice
@testable import BCICloudBridge

/// R7 regression coverage. The behaviour itself landed in PR #29; these tests
/// pin it so it cannot silently regress.
///
/// They drive `resolveHypnagogicRuntime` — the real resolution step, including
/// its `catch` — rather than calling the disable helper directly. Calling the
/// helper would only prove that the helper works when called; it would not
/// prove that a resolution failure ever reaches it.
///
/// The production call sites sit behind a mic/speech authorization gate, so a
/// toggle-driven test would return early at that gate and pass without
/// executing any of this. Injecting the resolver bypasses the permission gate
/// without bypassing the control flow under test.
@MainActor
final class AppViewModelRuntimeFailClosedTests: XCTestCase {

    private struct StubResolutionError: Error, CustomStringConvertible {
        let description = "unknown runtime 'olama' — supported: claude, ollama"
    }

    /// Counts anything a fallback would have had to construct.
    private final class ConstructionSpy {
        private(set) var resolverCalls = 0
        private(set) var generatorsBuilt = 0
        private(set) var processesLaunched = 0

        func recordResolverCall() { resolverCalls += 1 }
        func recordGenerator() { generatorsBuilt += 1 }
        func recordProcess() { processesLaunched += 1 }
    }

    /// Fully stubbed container — no model, no mic, no network.
    private func makeViewModel() async -> AppViewModel {
        let container = AppContainer(
            streamResolved: EEGStreamFactory.makeSynthetic(),
            classifierResolved: ClassifierFactory.live(),
            predictorResolved: await PredictorFactory.live(modelDirectory: nil),
            voiceOutputResolved: VoiceOutputFactory.live(),
            voiceInputResolved: VoiceInputFactory.live(overrideAvailability: false),
            voiceCommandResolved: VoiceCommandFactory.live(overrideAvailability: false),
            metrics: MetricsCollector(),
            windowingConfig: EEGWindowingConfig(
                windowSeconds: 2.0, strideSeconds: 1.0, sampleRate: 256, channelCount: 4
            )
        )
        return AppViewModel(container: container)
    }

    // MARK: - The catch path

    func testResolutionFailureFailsClosedAndConstructsNothing() async {
        let viewModel = await makeViewModel()
        let spy = ConstructionSpy()
        XCTAssertNil(viewModel.lastError, "precondition")
        let startupBefore = viewModel.startupWarning

        let result = viewModel.resolveHypnagogicRuntime {
            spy.recordResolverCall()
            throw StubResolutionError()
        }

        XCTAssertNil(result, "a failed resolution must yield no runtime")
        XCTAssertEqual(spy.resolverCalls, 1, "the resolver runs exactly once")
        XCTAssertEqual(spy.generatorsBuilt, 0, "no generator may be constructed after a failure")
        XCTAssertEqual(spy.processesLaunched, 0, "no subprocess may be launched after a failure")
        XCTAssertFalse(viewModel.hypnagogicLoopEnabled, "the loop must be disabled")
        XCTAssertEqual(
            viewModel.startupWarning, startupBefore,
            "a runtime failure is not a startup substitution notice")

        let recorded = viewModel.lastError ?? ""
        XCTAssertTrue(recorded.contains("unavailable"), "message should say unavailable: \(recorded)")
        XCTAssertTrue(
            recorded.contains("olama"),
            "the typed reason must be preserved, not flattened: \(recorded)")
    }

    /// No alternate provider is requested after a failure. If the old
    /// `?? (ClaudeCLIGenerator(...), …)` were reintroduced, the second
    /// resolution would run and this would fail.
    func testFailureDoesNotTriggerAnAlternateProviderRequest() async {
        let viewModel = await makeViewModel()
        let spy = ConstructionSpy()

        _ = viewModel.resolveHypnagogicRuntime {
            spy.recordResolverCall()
            throw StubResolutionError()
        }

        XCTAssertEqual(
            spy.resolverCalls, 1,
            "exactly one resolution attempt — no retry against a different provider")
    }

    // MARK: - The success path is unchanged

    func testSuccessfulResolutionStillReturnsTheRequestedRuntime() async throws {
        let viewModel = await makeViewModel()
        let spy = ConstructionSpy()

        let expected = try LiveRuntimeFactory.make(
            runtimeName: "claude", model: "claude-sonnet-5", systemPrompt: "SYS")

        let result = viewModel.resolveHypnagogicRuntime {
            spy.recordResolverCall()
            spy.recordGenerator()
            return expected
        }

        let resolved = try XCTUnwrap(result)
        XCTAssertEqual(resolved.resolved.name, "claude-cli")
        XCTAssertEqual(resolved.resolved.model, "claude-sonnet-5")
        XCTAssertEqual(spy.resolverCalls, 1)
        XCTAssertNil(viewModel.lastError, "a successful resolution records no error")
        XCTAssertFalse(
            viewModel.hypnagogicLoopEnabled,
            "resolution alone must not enable the loop; the toggle is the user's")
    }

    /// The loop is opt-in and a failed opt-in stays failed.
    func testDefaultOffBehaviourIsPreserved() async {
        let viewModel = await makeViewModel()
        XCTAssertFalse(viewModel.hypnagogicLoopEnabled, "opt-in, defaults off")
        _ = viewModel.resolveHypnagogicRuntime { throw StubResolutionError() }
        XCTAssertFalse(viewModel.hypnagogicLoopEnabled)
    }
}
