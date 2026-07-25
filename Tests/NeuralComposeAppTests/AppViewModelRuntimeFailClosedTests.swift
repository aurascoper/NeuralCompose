import XCTest
@testable import NeuralComposeApp
@testable import BCIEEG
@testable import BCICore
@testable import BCIClassifier
@testable import BCILLM
@testable import BCIVoice
@testable import BCICloudBridge

/// R7 + R18 fail-closed coverage, and R3's "a disabled role resolves nothing".
///
/// These drive `resolveHypnagogicRuntime` / `resolveWitnessRuntime` — the real
/// resolution steps including their `catch` — rather than the disable helper,
/// which would only prove the helper works when called, not that a failure
/// reaches it.
///
/// **A1 left one gap here, now closed.** The enabled→disabled *transition* was
/// unprovable: `hypnagogicLoopEnabled` defaults to `false`, so an assertion
/// that it ends `false` passed even with the production assignment deleted.
/// `testFailureTransitionsAnEnabledLoopToDisabled` sets the toggle first and
/// cancels the reconcile task so the authorization gate cannot flip it instead.
@MainActor
final class AppViewModelRuntimeFailClosedTests: XCTestCase {

    /// A sanitized failure of the kind `LiveRuntimeFactory` actually throws.
    private func makeFailure(
        code: RuntimeReadinessFailure = .modelMissing,
        requestedProvider: String = "ollama",
        requestedModel: String = "qwen2.5:0.5b",
        publicMessage: String = "Ollama does not have the model 'qwen2.5:0.5b'.",
        internalDetail: String? = "PATH=/very/private/path"
    ) -> RuntimeResolutionFailure {
        RuntimeResolutionFailure(
            identity: ResolvedRuntimeIdentity(
                role: .dialectic,
                requestedProvider: requestedProvider,
                requestedModel: requestedModel,
                resolvedProvider: "",
                resolvedModel: "",
                locality: .onDevice,
                readiness: .unavailable(code),
                promptProfile: "wakingDialectical",
                promptHash: "",
                systemPromptSource: "unresolved"
            ),
            code: code,
            publicMessage: publicMessage,
            internalDetail: internalDetail
        )
    }

    private func makeIdentity(
        role: RuntimeRole,
        provider: String = "ollama",
        model: String = "qwen2.5:0.5b",
        locality: RuntimeLocality = .onDevice
    ) -> ResolvedRuntimeIdentity {
        ResolvedRuntimeIdentity(
            role: role,
            requestedProvider: provider, requestedModel: model,
            resolvedProvider: provider, resolvedModel: model,
            locality: locality, readiness: .ready,
            promptProfile: LiveRuntimeFactory.promptProfile(for: role).rawValue,
            promptHash: "hash-\(role.rawValue)",
            systemPromptSource: "PromptProfile"
        )
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

    // MARK: - Fail closed

    func testResolutionFailureYieldsNoRuntimeAndRecordsTheReason() async {
        let viewModel = await makeViewModel()
        var resolverCalls = 0
        XCTAssertNil(viewModel.lastError, "precondition")
        let startupBefore = viewModel.startupWarning

        let result = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            resolverCalls += 1
            throw self.makeFailure()
        }

        XCTAssertNil(result, "a failed resolution must yield no runtime")
        XCTAssertEqual(resolverCalls, 1, "the resolver runs exactly once")

        // Fails if `setLastError` is removed from disableHypnagogicLoop.
        let recorded = viewModel.lastError ?? ""
        XCTAssertTrue(recorded.contains("unavailable"), "should say unavailable: \(recorded)")
        XCTAssertTrue(
            recorded.contains("qwen2.5:0.5b"),
            "the sanitized public reason must be preserved: \(recorded)")

        // Fails if a runtime failure were filed as a startup substitution notice.
        XCTAssertEqual(viewModel.startupWarning, startupBefore)
    }

    func testFailureDoesNotProduceASubstituteRuntime() async {
        let viewModel = await makeViewModel()
        let result = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            throw self.makeFailure()
        }
        XCTAssertNil(result, "the old code returned a ClaudeCLIGenerator here instead of nil")
    }

    /// Closes A1's M4 gap. The toggle is set true first, and the reconcile task
    /// is cancelled so the authorization gate cannot be the thing that turns it
    /// off. Deleting `hypnagogicLoopEnabled = false` from production fails this.
    func testFailureTransitionsAnEnabledLoopToDisabled() async {
        let viewModel = await makeViewModel()
        viewModel.hypnagogicLoopEnabled = true
        viewModel.cancelPendingHypnagogicReconcile()
        XCTAssertTrue(viewModel.hypnagogicLoopEnabled, "precondition: the loop is enabled")

        _ = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            throw self.makeFailure()
        }

        XCTAssertFalse(
            viewModel.hypnagogicLoopEnabled,
            "a readiness failure must turn an ENABLED loop off, not merely leave it off")
    }

    /// Generation must be impossible while readiness is unavailable: the caller
    /// receives no generator at all, so there is nothing to call.
    func testUnavailableReadinessLeavesNoGeneratorToCall() async {
        let viewModel = await makeViewModel()
        let result = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            throw self.makeFailure(code: .endpointUnreachable)
        }
        XCTAssertNil(result)
        let identity = viewModel.dialogueRuntimeIdentity
        XCTAssertEqual(identity?.readiness, .unavailable(.endpointUnreachable))
        XCTAssertEqual(identity?.isReady, false)
    }

    // MARK: - Sanitization

    /// `lastError` is rendered in the privacy banner. The internal detail —
    /// which on the Claude path carries the resolver's full `PATH` dump — must
    /// not reach it.
    func testInternalDetailNeverReachesTheUserFacingError() async {
        let viewModel = await makeViewModel()
        _ = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            throw self.makeFailure(internalDetail: "PATH=/Users/someone/secret/bin:/usr/bin")
        }
        let recorded = viewModel.lastError ?? ""
        XCTAssertFalse(recorded.contains("PATH="), "leaked internal detail: \(recorded)")
        XCTAssertFalse(recorded.contains("/Users/someone"), "leaked a private path: \(recorded)")
    }

    /// An error type that is not a `RuntimeResolutionFailure` still fails
    /// closed, and its raw description is still kept out of the UI.
    func testUntypedErrorFailsClosedWithoutLeakingItsDescription() async {
        struct Leaky: Error, CustomStringConvertible {
            let description = "PATH=/Users/someone/secret/bin"
        }
        let viewModel = await makeViewModel()
        let result = await viewModel.resolveHypnagogicRuntime(role: .dialectic) { throw Leaky() }
        XCTAssertNil(result)
        let recorded = viewModel.lastError ?? ""
        XCTAssertFalse(recorded.contains("/Users/someone"), "leaked: \(recorded)")
    }

    // MARK: - Identity storage

    func testSuccessStoresTheDialogueIdentity() async {
        let viewModel = await makeViewModel()
        let expected = makeIdentity(role: .dialectic)
        let resolved = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            (StubGenerator(), expected)
        }
        XCTAssertNotNil(resolved)
        XCTAssertEqual(viewModel.dialogueRuntimeIdentity, expected)
        XCTAssertNil(viewModel.lastError, "a successful resolution records no error")
    }

    /// A failure stores the *requested* identity, so the banner can say what was
    /// asked for and why it is unavailable rather than falling silent.
    func testFailureStillStoresADisplayableIdentity() async {
        let viewModel = await makeViewModel()
        _ = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            throw self.makeFailure()
        }
        let identity = viewModel.dialogueRuntimeIdentity
        XCTAssertEqual(identity?.requestedProvider, "ollama")
        XCTAssertEqual(identity?.requestedModel, "qwen2.5:0.5b")
        XCTAssertEqual(identity?.displayReadiness, "Model unavailable")
    }

    func testMirrorAndDialecticBothFileUnderTheDialogueIdentity() async {
        let viewModel = await makeViewModel()
        _ = await viewModel.resolveHypnagogicRuntime(role: .mirror) {
            (StubGenerator(), self.makeIdentity(role: .mirror))
        }
        XCTAssertEqual(viewModel.dialogueRuntimeIdentity?.role, .mirror)
        XCTAssertNil(viewModel.witnessRuntimeIdentity)
    }

    // MARK: - R3: a disabled Witness resolves nothing

    /// The exact regression: the Witness was resolved unconditionally and the
    /// `witnessEnabled` flag was consulted only afterwards, when deciding
    /// whether to *use* it. A disabled role must not load a prompt, construct a
    /// runtime, or probe an endpoint.
    func testDisabledWitnessIsNeverResolved() async {
        let viewModel = await makeViewModel()
        var resolverCalls = 0

        let outcome = await viewModel.resolveWitnessRuntime(witnessEnabled: false) {
            resolverCalls += 1
            return (StubGenerator(), self.makeIdentity(role: .witness))
        }

        guard case .disabled = outcome else {
            return XCTFail("a disabled Witness must report .disabled, got \(outcome)")
        }
        XCTAssertEqual(
            resolverCalls, 0,
            "a disabled Witness must not resolve a runtime, load a prompt, or probe an endpoint")
        XCTAssertNil(viewModel.witnessRuntimeIdentity)
        XCTAssertNil(viewModel.lastError, "a disabled role is not an error")
    }

    func testEnabledWitnessResolvesAndStoresItsOwnIdentity() async {
        let viewModel = await makeViewModel()
        let witnessIdentity = makeIdentity(role: .witness)
        let outcome = await viewModel.resolveWitnessRuntime(witnessEnabled: true) {
            (StubGenerator(), witnessIdentity)
        }
        guard case .resolved = outcome else {
            return XCTFail("expected .resolved, got \(outcome)")
        }
        XCTAssertEqual(viewModel.witnessRuntimeIdentity, witnessIdentity)
        XCTAssertEqual(viewModel.witnessRuntimeIdentity?.promptProfile, "witness")
        XCTAssertNil(
            viewModel.dialogueRuntimeIdentity,
            "the Witness must not overwrite the dialogue identity")
    }

    /// Handing the Witness a *pole* runtime must fail closed rather than be
    /// filed under the Witness identity. Both sides are the same tuple type, so
    /// nothing but this check catches it.
    func testWitnessResolvedToThePoleRuntimeIsRefused() async {
        let viewModel = await makeViewModel()
        let poleIdentity = makeIdentity(role: .dialectic)

        let outcome = await viewModel.resolveWitnessRuntime(witnessEnabled: true) {
            (StubGenerator(), poleIdentity)   // the pole's runtime, not the Witness's
        }

        guard case .failed = outcome else {
            return XCTFail("a pole runtime must not be accepted as the Witness, got \(outcome)")
        }
        XCTAssertNil(
            viewModel.witnessRuntimeIdentity,
            "a rejected runtime must not be stored as the Witness identity")
        XCTAssertFalse(viewModel.hypnagogicLoopEnabled)
    }

    func testDialogueResolvedToTheWitnessRuntimeIsRefused() async {
        let viewModel = await makeViewModel()
        let result = await viewModel.resolveHypnagogicRuntime(role: .dialectic) {
            (StubGenerator(), self.makeIdentity(role: .witness))
        }
        XCTAssertNil(result, "a Witness runtime must not stand in for the dialectic poles")
        XCTAssertNil(viewModel.dialogueRuntimeIdentity)
    }

    /// A requested Witness that cannot resolve fails the configuration closed
    /// rather than degrading to a two-voice exchange the user did not select.
    func testRequestedWitnessFailureIsNotSilentlyDowngraded() async {
        let viewModel = await makeViewModel()
        let outcome = await viewModel.resolveWitnessRuntime(witnessEnabled: true) {
            throw self.makeFailure(code: .promptResourceUnavailable)
        }
        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertFalse(viewModel.hypnagogicLoopEnabled)
        XCTAssertEqual(
            viewModel.witnessRuntimeIdentity?.readiness,
            .unavailable(.promptResourceUnavailable))
    }
}

/// Minimal `TextGenerating` that never generates. Present only so identity
/// plumbing has something to carry; calling it would be a test bug.
private struct StubGenerator: TextGenerating {
    let isLive = false
    let modelIdentifier = "stub"
    func generate(
        prompt: String, maxTokens: Int, temperature: Double, cancellationID: UUID
    ) async throws -> String {
        XCTFail("no test in this file may generate")
        return ""
    }
}
