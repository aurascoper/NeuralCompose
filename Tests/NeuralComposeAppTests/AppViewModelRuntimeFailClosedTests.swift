import XCTest
@testable import NeuralComposeApp
@testable import BCIEEG
@testable import BCICore
@testable import BCIClassifier
@testable import BCILLM
@testable import BCIVoice
@testable import BCICloudBridge

/// R7 regression coverage. The behaviour landed in PR #29; these tests pin it.
///
/// They drive `resolveHypnagogicRuntime` — the real resolution step including
/// its `catch` — rather than the disable helper, which would only prove the
/// helper works when called, not that a failure reaches it.
///
/// **What these tests deliberately do NOT claim.** An earlier version asserted
/// `generatorsBuilt == 0` and `processesLaunched == 0` against counters that
/// nothing in production ever increments; they were structurally incapable of
/// failing. It also asserted `hypnagogicLoopEnabled == false` on a property
/// that defaults to `false` and was never set `true` — deleting the assignment
/// from production left the test green. Both were removed rather than left as
/// false comfort.
///
/// Proving the toggle *transition*, and proving the call-site `guard`
/// short-circuits, both require stubbing the mic/speech authorization gate that
/// sits in front of `ensureHypnagogicLoopRunning`. That is A2 work; until then
/// those two properties are unverified and are not claimed here.
@MainActor
final class AppViewModelRuntimeFailClosedTests: XCTestCase {

    private struct StubResolutionError: Error, CustomStringConvertible {
        let description = "unknown runtime 'olama' — supported: claude, ollama"
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

    /// A failed resolution yields no runtime. Every assertion here fails if the
    /// corresponding production line is removed.
    func testResolutionFailureYieldsNoRuntimeAndRecordsTheReason() async {
        let viewModel = await makeViewModel()
        var resolverCalls = 0
        XCTAssertNil(viewModel.lastError, "precondition")
        let startupBefore = viewModel.startupWarning

        let result = viewModel.resolveHypnagogicRuntime {
            resolverCalls += 1
            throw StubResolutionError()
        }

        // Fails if `catch` returned anything but nil.
        XCTAssertNil(result, "a failed resolution must yield no runtime")
        XCTAssertEqual(resolverCalls, 1, "the resolver runs exactly once")

        // Fails if `setLastError` is removed from disableHypnagogicLoop.
        let recorded = viewModel.lastError ?? ""
        XCTAssertTrue(recorded.contains("unavailable"), "should say unavailable: \(recorded)")
        XCTAssertTrue(
            recorded.contains("olama"),
            "the typed reason must be preserved, not flattened: \(recorded)")

        // Fails if a runtime failure were filed as a startup substitution notice.
        XCTAssertEqual(viewModel.startupWarning, startupBefore)
    }

    /// The success path is untouched: a resolved runtime is returned verbatim
    /// and records no error.
    func testSuccessfulResolutionReturnsTheRequestedRuntime() async throws {
        let viewModel = await makeViewModel()
        let expected = try LiveRuntimeFactory.make(
            runtimeName: "claude", model: "claude-sonnet-5", systemPrompt: "SYS")

        let resolved = try XCTUnwrap(viewModel.resolveHypnagogicRuntime { expected })

        XCTAssertEqual(resolved.resolved.name, "claude-cli")
        XCTAssertEqual(resolved.resolved.model, "claude-sonnet-5")
        XCTAssertNil(viewModel.lastError, "a successful resolution records no error")
    }

    /// A thrown error is not swallowed into a substituted provider: the caller
    /// receives nil and must decide, which is what the production `guard` does.
    func testFailureDoesNotProduceASubstituteRuntime() async {
        let viewModel = await makeViewModel()
        let result = viewModel.resolveHypnagogicRuntime { throw StubResolutionError() }
        XCTAssertNil(
            result,
            "the old code returned a ClaudeCLIGenerator here instead of nil")
    }
}
