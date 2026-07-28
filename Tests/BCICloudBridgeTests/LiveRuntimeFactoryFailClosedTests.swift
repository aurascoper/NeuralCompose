import BCICore
import XCTest
@testable import BCICloudBridge

/// `LiveRuntimeFactory` is the app's runtime-resolution seam. It must either
/// return the runtime that was requested *and* an identity that truthfully
/// describes it, or throw a failure that still carries a displayable identity —
/// never substitute.
///
/// The defect this guards: `AppViewModel` used to write
/// `(try? LiveRuntimeFactory.make(...)) ?? (ClaudeCLIGenerator(...), …)`, so a
/// mistyped `NEURALCOMPOSE_RUNTIME` — set by a user who wanted local-only
/// inference — silently produced cloud egress to Anthropic instead.
///
/// **No test here makes a real provider request.** Most Claude tests stop at
/// executable validation; the commit-J provenance tests additionally invoke a
/// stub `claude` that prints a canned JSON envelope, which never leaves the
/// machine. Ollama readiness is served by `MockURLProtocol`.
final class LiveRuntimeFactoryFailClosedTests: XCTestCase {

    private let ollamaURL = URL(string: "http://localhost:11434")!

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-factory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A PATH containing a stub executable named `claude`. Resolution validates
    /// the file and never runs it, so this is enough to reach a `configured`
    /// identity without contacting Anthropic — and never enough to reach
    /// `ready`, which requires a verified provider round trip this path has no
    /// way to perform.
    private func makeClaudeEnvironment() throws -> [String: String] {
        let dir = try makeDirectory()
        let claude = dir.appendingPathComponent("claude")
        try "#!/bin/bash\nexit 0\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return ["PATH": dir.path]
    }

    /// An environment whose PATH holds `/usr/bin` — hence `env`, but no
    /// `claude`. Distinctive enough that a leaked PATH is detectable.
    private func makeClaudelessEnvironment() throws -> [String: String] {
        let marker = try makeDirectory()
        return ["PATH": "/usr/bin:\(marker.path)"]
    }

    private func stubTags(_ models: [(name: String, digest: String?)]) {
        MockURLProtocol.handler = { request in
            MockURLProtocol.tagsResponse(models, for: request)
        }
    }

    private func makeOllama(
        role: RuntimeRole = .dialectic,
        model: String,
        baseURL: URL? = nil
    ) async throws -> (generator: any TextGenerating, identity: ResolvedRuntimeIdentity) {
        try await LiveRuntimeFactory.make(
            role: role,
            runtimeName: "ollama",
            model: model,
            ollamaBaseURL: baseURL ?? ollamaURL,
            session: MockURLProtocol.makeSession(),
            environment: [:]
        )
    }

    // MARK: - No substitution

    func testUnknownRuntimeThrowsAndConstructsNothing() async {
        // `olama` is the realistic typo: the user meant local Ollama.
        do {
            _ = try await LiveRuntimeFactory.make(
                role: .dialectic, runtimeName: "olama", model: "qwen2.5:0.5b",
                environment: [:])
            XCTFail("a typo'd runtime must not resolve")
        } catch let failure as RuntimeResolutionFailure {
            XCTAssertEqual(failure.code, .unknownProvider)
            XCTAssertTrue(
                failure.publicMessage.contains("olama"),
                "the message must name the runtime actually requested: \(failure.publicMessage)")
            XCTAssertEqual(failure.identity.requestedProvider, "olama")
            XCTAssertEqual(
                failure.identity.resolvedProvider, "",
                "nothing resolved, so the resolved provider must be empty rather than a guess")
            // An unknown provider has no endpoint to classify, so its locality
            // is a fourth honest state — not a claim of any known topology.
            XCTAssertEqual(
                failure.identity.locality, .unresolved,
                "an unknown provider is not known to be a local broker")
            XCTAssertTrue(
                failure.identity.locality.involvesNetworkEgress,
                "unverified egress must still be presented conservatively as egress")
            XCTAssertEqual(failure.identity.locality.displayLabel, "Egress unverified")
        } catch {
            XCTFail("expected RuntimeResolutionFailure, got \(error)")
        }
    }

    func testOllamaFailureNeverYieldsAClaudeGenerator() async {
        stubTags([("some-other-model", "sha256:aaa")])
        do {
            _ = try await makeOllama(model: "qwen2.5:0.5b")
            XCTFail("a missing model must not resolve")
        } catch let failure as RuntimeResolutionFailure {
            // The whole point: a local-inference request that cannot be
            // satisfied fails. It does not quietly become cloud egress.
            XCTAssertEqual(failure.code, .modelMissing)
            XCTAssertNotEqual(failure.identity.resolvedProvider, "claude")
            XCTAssertEqual(failure.identity.requestedProvider, "ollama")
        } catch {
            XCTFail("expected RuntimeResolutionFailure, got \(error)")
        }
    }

    // MARK: - R18 readiness

    /// Was `testAppPathCharacterizationDoesNotProbeOllamaModelAvailability_R18`,
    /// which recorded the *absence* of probing and was written to fail once
    /// probing landed. It has now been inverted, as its own doc comment
    /// instructed.
    func testMissingOllamaModelFailsBeforeAnyGeneration() async {
        stubTags([("qwen2.5:0.5b", "sha256:aaa")])
        do {
            _ = try await makeOllama(model: "definitely-not-a-pulled-model")
            XCTFail("an unpulled model must not resolve")
        } catch let failure as RuntimeResolutionFailure {
            XCTAssertEqual(failure.code, .modelMissing)
            XCTAssertEqual(failure.identity.readiness, .unavailable(.modelMissing))
            XCTAssertFalse(
                failure.identity.isReady,
                "an unavailable runtime must never report ready")
        } catch {
            XCTFail("expected RuntimeResolutionFailure, got \(error)")
        }
    }

    /// Deleting the probe must fail a test. Asserting only on the *outcome*
    /// would not catch a probe replaced by a hardcoded success, so this asserts
    /// the request was actually issued.
    func testReadinessActuallyQueriesTagsEndpoint() async throws {
        stubTags([("qwen2.5:0.5b", "sha256:abc")])
        _ = try await makeOllama(model: "qwen2.5:0.5b")

        let probed = MockURLProtocol.requestedURLs.map(\.path)
        XCTAssertTrue(
            probed.contains { $0.hasSuffix("/api/tags") },
            "readiness must query /api/tags; saw \(probed)")
    }

    func testUnreachableEndpointIsUnavailableNotModelMissing() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await makeOllama(model: "qwen2.5:0.5b")
            XCTFail("an unreachable daemon must not resolve")
        } catch let failure as RuntimeResolutionFailure {
            // Infrastructure failures are distinguishable from configuration
            // failures; collapsing them would hide "the daemon is down" behind
            // "pull the model".
            XCTAssertEqual(failure.code, .endpointUnreachable)
        } catch {
            XCTFail("expected RuntimeResolutionFailure, got \(error)")
        }
    }

    func testResolvedOllamaIdentityRecordsCanonicalNameAndDigest() async throws {
        stubTags([("qwen2.5:0.5b", "sha256:deadbeef")])
        let (_, identity) = try await makeOllama(model: "qwen2.5:0.5b")
        XCTAssertEqual(identity.resolvedProvider, "ollama")
        XCTAssertEqual(identity.resolvedModel, "qwen2.5:0.5b")
        XCTAssertEqual(identity.modelDigest, "sha256:deadbeef")
        XCTAssertEqual(identity.readiness, .ready)
    }

    /// An untagged request resolves to the daemon's `:latest` entry, and the
    /// identity records the *stored* name — what is loaded, not what was typed.
    ///
    /// The identity must agree with the probe about what "the same model"
    /// means: the probe deliberately accepts `qwen2.5:latest` for `qwen2.5`,
    /// so `isSubstitution` comparing the raw strings made one resolution both
    /// "the same model" (readiness) and "a substitution" (identity). A
    /// canonical `:latest` resolution is not a substitution alarm.
    func testUntaggedRequestRecordsTheCanonicalStoredName() async throws {
        stubTags([("qwen2.5:latest", "sha256:beef")])
        let (_, identity) = try await makeOllama(model: "qwen2.5")
        XCTAssertEqual(identity.requestedModel, "qwen2.5")
        XCTAssertEqual(identity.resolvedModel, "qwen2.5:latest")
        XCTAssertFalse(
            identity.isSubstitution,
            "the probe's canonicalization and the identity's comparison must agree")
    }

    /// The canonicalization must not widen into fuzzy matching: any resolved
    /// model that differs by more than the implicit `:latest` tag is still a
    /// substitution the UI discloses.
    func testNonLatestModelDifferenceIsStillASubstitution() {
        let base = ResolvedRuntimeIdentity(
            role: .dialectic,
            requestedProvider: "ollama", requestedModel: "qwen2.5",
            resolvedProvider: "ollama", resolvedModel: "qwen2.5:0.5b",
            locality: .onDevice, readiness: .ready,
            promptProfile: "wakingDialectical", promptHash: "abc",
            systemPromptSource: "test")
        XCTAssertTrue(
            base.isSubstitution,
            "an explicit non-latest tag is a different model, not a canonical spelling")

        let provider = ResolvedRuntimeIdentity(
            role: .dialectic,
            requestedProvider: "ollama", requestedModel: "qwen2.5",
            resolvedProvider: "claude", resolvedModel: "qwen2.5",
            locality: .localBrokerToRemoteService, readiness: .ready,
            promptProfile: "wakingDialectical", promptHash: "abc",
            systemPromptSource: "test")
        XCTAssertTrue(
            provider.isSubstitution,
            "a provider swap is always a substitution, whatever the model strings say")
    }

    // MARK: - Locality

    /// The single most consequential classification in this file. The Claude
    /// CLI is a *local executable* whose inference is remote; labelling it
    /// on-device because the process is local would make the privacy banner
    /// assert local inference for the one path that leaves the machine.
    func testClaudeCLIIsNotClassifiedAsOnDevice() async throws {
        let environment = try makeClaudeEnvironment()
        let (_, identity) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: "claude-sonnet-5",
            environment: environment)
        XCTAssertEqual(identity.locality, .localBrokerToRemoteService)
        XCTAssertNotEqual(identity.locality, .onDevice)
        XCTAssertTrue(
            identity.locality.involvesNetworkEgress,
            "the Claude CLI path must always be disclosed as egress")
    }

    func testLoopbackOllamaIsOnDeviceAndNonLoopbackIsNot() async throws {
        stubTags([("qwen2.5:0.5b", "sha256:abc")])
        let (_, local) = try await makeOllama(model: "qwen2.5:0.5b")
        XCTAssertEqual(local.locality, .onDevice)
        XCTAssertFalse(local.locality.involvesNetworkEgress)

        stubTags([("qwen2.5:0.5b", "sha256:abc")])
        let (_, remote) = try await makeOllama(
            model: "qwen2.5:0.5b", baseURL: URL(string: "http://192.168.1.40:11434")!)
        XCTAssertEqual(
            remote.locality, .remoteEndpoint,
            "another host on the LAN is not this device")
        XCTAssertTrue(remote.locality.involvesNetworkEgress)
    }

    // MARK: - Role-distinct prompts (R3)

    /// Two runtimes with identical provider and model are still distinct
    /// identities, because they transmit different bytes. If the Witness were
    /// ever handed the pole's prompt these hashes would collide.
    func testWitnessAndDialecticIdentitiesDifferByPromptEvenOnTheSameModel() async throws {
        let environment = try makeClaudeEnvironment()
        let (_, dialectic) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: "claude-sonnet-5",
            environment: environment)
        let (_, witness) = try await LiveRuntimeFactory.make(
            role: .witness, runtimeName: "claude", model: "claude-sonnet-5",
            environment: environment)

        XCTAssertEqual(dialectic.resolvedProvider, witness.resolvedProvider)
        XCTAssertEqual(dialectic.resolvedModel, witness.resolvedModel)

        XCTAssertEqual(dialectic.promptProfile, "wakingDialectical")
        XCTAssertEqual(witness.promptProfile, "witness")
        XCTAssertNotEqual(
            dialectic.promptHash, witness.promptHash,
            "the Witness must not transmit the pole prompt")
        XCTAssertNotEqual(dialectic.role, witness.role)
    }

    func testEachRoleLoadsItsOwnProfile() {
        XCTAssertEqual(LiveRuntimeFactory.promptProfile(for: .dialectic), .wakingDialectical)
        XCTAssertEqual(LiveRuntimeFactory.promptProfile(for: .witness), .witness)
        XCTAssertEqual(LiveRuntimeFactory.promptProfile(for: .mirror), .hypnagogic)
    }

    /// The hash must be of the bytes actually sent, not of the profile name or
    /// a constant — otherwise `promptHash` attests to nothing.
    func testPromptHashMatchesTheTransmittedBytes() async throws {
        let environment = try makeClaudeEnvironment()
        let (_, identity) = try await LiveRuntimeFactory.make(
            role: .witness, runtimeName: "claude", model: "claude-sonnet-5",
            environment: environment)
        let expected = PromptProfile.sha256Hex(try PromptProfile.witness.load())
        XCTAssertEqual(identity.promptHash, expected)
    }

    // MARK: - Sanitization

    /// `ResolutionError.notFoundOnPath` embeds the user's entire `PATH`. The
    /// factory catches it and must not forward that text into a message the UI
    /// renders and `lastError` stores.
    func testExecutableFailureMessageDoesNotLeakPath() async throws {
        let environment = try makeClaudelessEnvironment()
        let path = try XCTUnwrap(environment["PATH"])
        let marker = try XCTUnwrap(path.split(separator: ":").last).description

        do {
            _ = try await LiveRuntimeFactory.make(
                role: .dialectic, runtimeName: "claude", model: "claude-sonnet-5",
                environment: environment)
            XCTFail("resolution must fail when no claude is on PATH")
        } catch let failure as RuntimeResolutionFailure {
            XCTAssertEqual(failure.code, .executableNotFound)
            XCTAssertFalse(
                failure.publicMessage.contains(path),
                "the public message must not contain the environment PATH")
            XCTAssertFalse(
                failure.publicMessage.contains(marker),
                "the public message must not contain any searched directory: "
                    + failure.publicMessage)
            XCTAssertFalse(
                String(describing: failure).contains(marker),
                "`description` is what call sites interpolate by reflex; it must be the safe one")
            // The detail is still captured — for the log, not the UI.
            XCTAssertNotNil(failure.internalDetail)
        } catch {
            XCTFail("expected RuntimeResolutionFailure, got \(error)")
        }
    }

    func testEndpointMessageDropsCredentialsAndQuery() {
        let url = URL(string: "http://user:secret@ollama.example:11434/api?token=abc123#frag")!
        let redacted = RuntimeIdentityRedaction.endpoint(url)
        for forbidden in ["secret", "token", "abc123", "frag", "/api"] {
            XCTAssertFalse(
                redacted.contains(forbidden),
                "'\(forbidden)' must not survive redaction: \(redacted)")
        }
        XCTAssertTrue(redacted.contains("ollama.example"))
        XCTAssertTrue(redacted.contains("11434"))
    }

    func testLoopbackDetectionDoesNotTreatLANHostsAsLocal() {
        for local in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            XCTAssertTrue(
                RuntimeIdentityRedaction.isLoopback(URL(string: local)!), local)
        }
        for remote in [
            "http://192.168.1.5:11434", "http://ollama.local:11434", "https://ollama.example.com",
        ] {
            XCTAssertFalse(
                RuntimeIdentityRedaction.isLoopback(URL(string: remote)!),
                "\(remote) is another machine")
        }
    }

    // MARK: - Defaults

    func testDefaultResolutionIsStillClaude() async throws {
        let environment = try makeClaudeEnvironment()
        let (generator, identity) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: nil, model: nil, environment: environment)
        XCTAssertEqual(identity.resolvedProvider, "claude")
        XCTAssertEqual(identity.resolvedModel, "claude-sonnet-5")
        XCTAssertFalse(identity.isSubstitution)
        // The Claude path now returns a metadata-publishing adapter, not a raw
        // `ClaudeCLIGenerator`. Asserting the concrete adapter type would pin an
        // implementation detail; asserting the *capability* pins the thing that
        // was actually broken — see `testClaudeGeneratorPublishesMetadata`.
        XCTAssertTrue(generator is any MetadataPublishingTextGenerating)
    }

    // MARK: - App-side Claude provenance (commit J)

    /// The regression guard. Returning a raw `ClaudeCLIGenerator` here — as the
    /// factory did through `71c5c02` — makes this fail, because that type
    /// conforms only to `TextGenerating`.
    ///
    /// `HypnagogicDialecticLoop` populates `generatorFingerprint` *solely* from a
    /// `MetadataPublishingTextGenerating` (`HypnagogicDialecticLoop.swift:86`), so
    /// without this conformance the packaged app persisted Claude turns with no
    /// provider, model, or prompt hash — and the same gap hid the Claude
    /// Witness's identity. The Ollama path had it; the harness had it; the app's
    /// Claude path did not.
    func testClaudeGeneratorPublishesMetadata() async throws {
        let environment = try makeClaudeEnvironment()
        let (generator, _) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: nil, environment: environment)

        XCTAssertTrue(
            generator is any MetadataPublishingTextGenerating,
            "a Claude generator that cannot publish metadata leaves every app-side "
                + "turn with no durable provider/model/prompt identity")
        XCTAssertFalse(
            generator is ClaudeCLIGenerator,
            "the raw generator is the defect this commit fixes")
    }

    /// Readiness is unchanged by the provenance fix: resolution still contacts
    /// nothing, so it is still `configured` rather than `ready`.
    func testClaudeReadinessStaysConfiguredAfterMetadataChange() async throws {
        let environment = try makeClaudeEnvironment()
        let (_, identity) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: nil, environment: environment)
        XCTAssertEqual(identity.readiness, .configured)
        XCTAssertFalse(identity.isReady)
        XCTAssertTrue(identity.canAttemptGeneration)
        XCTAssertEqual(identity.locality, .localBrokerToRemoteService)
    }

    /// The identity is a description of what *resolution* proved and must not be
    /// rewritten by a later successful call. Constructing the runtime does not
    /// mutate it, and nothing in the adapter path writes back to it.
    func testResolvedIdentityIsUnchangedByConstruction() async throws {
        let environment = try makeClaudeEnvironment()
        let (_, first) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: nil, environment: environment)
        let (_, second) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: nil, environment: environment)
        XCTAssertEqual(first, second, "resolution must be deterministic and side-effect free")
    }

    /// Role selects the prompt profile, and the profile the runtime hashes must
    /// be the one the identity reports — the Witness must not be able to resolve
    /// to the poles' prompt.
    func testWitnessRoleResolvesADifferentPromptThanTheDialecticPole() async throws {
        let environment = try makeClaudeEnvironment()
        let (_, pole) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: nil, environment: environment)
        let (_, witness) = try await LiveRuntimeFactory.make(
            role: .witness, runtimeName: "claude", model: nil, environment: environment)

        XCTAssertNotEqual(pole.promptProfile, witness.promptProfile)
        XCTAssertNotEqual(
            pole.promptHash, witness.promptHash,
            "a shared pole/Witness prompt hash is the exact collision the Witness "
                + "fingerprint exists to make impossible")
    }

    /// Both roles publish metadata, so a Reflective turn can record the pole and
    /// the Witness fingerprints independently.
    func testBothClaudeRolesPublishMetadata() async throws {
        let environment = try makeClaudeEnvironment()
        for role in [RuntimeRole.dialectic, .witness, .mirror] {
            let (generator, _) = try await LiveRuntimeFactory.make(
                role: role, runtimeName: "claude", model: nil, environment: environment)
            XCTAssertTrue(
                generator is any MetadataPublishingTextGenerating,
                "role \(role) must be able to attest its own generator")
        }
    }

    /// A PATH with a stub `claude` that emits `body` on stdout. Nothing here
    /// contacts Anthropic; the transport only parses the envelope.
    private func makeStubClaudeEnvironment(emitting body: String) throws -> [String: String] {
        let dir = try makeDirectory()
        let claude = dir.appendingPathComponent("claude")
        // `cat <<'EOF'` so the JSON is emitted verbatim regardless of quoting.
        try "#!/bin/bash\ncat <<'ENVELOPE'\n\(body)\nENVELOPE\n"
            .write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return ["PATH": dir.path]
    }

    /// A successful call publishes the identity the log needs: which runtime,
    /// which provider, which model, which profile, and the hash of the bytes
    /// that were actually transmitted.
    func testSuccessfulClaudeGenerationPublishesMetadata() async throws {
        let environment = try makeStubClaudeEnvironment(emitting: #"{"result":"ok"}"#)
        let (generator, identity) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: "claude-sonnet-5",
            environment: environment)

        let captured = MetadataCapture()
        var publisher = try XCTUnwrap(generator as? any MetadataPublishingTextGenerating)
        publisher.onMetadata = { captured.record($0) }

        _ = try await publisher.generate(
            prompt: "p", maxTokens: 32, temperature: 0.7, cancellationID: UUID())

        let m = try XCTUnwrap(captured.value, "a successful call must publish metadata")
        XCTAssertEqual(m.runtime, "claude-cli")
        XCTAssertEqual(m.transport, "claude-cli")
        XCTAssertEqual(m.provider, "anthropic")
        XCTAssertEqual(m.model, "claude-sonnet-5")
        // The real profile, not `custom` — `custom` would tell a later reader
        // nothing about which prompt governed the turn.
        XCTAssertEqual(m.promptProfile, LiveRuntimeFactory.promptProfile(for: .dialectic).rawValue)
        // The hash attests the bytes transmitted, and agrees with the identity
        // resolution reported before any call was made.
        XCTAssertEqual(
            m.promptHash,
            try LiveRuntimeFactory.promptProfile(for: .dialectic).hash())
        XCTAssertEqual(m.promptHash, identity.promptHash)
    }

    /// A failed call must publish nothing. Metadata is built inside
    /// `ClaudeCLIGenerationRuntime.generate` only after `transport.send`
    /// returns, and the adapter fires `onMetadata` only after `generate`
    /// returns — so a throw short-circuits both. A success fingerprint on a
    /// failed turn would be exactly the fabricated evidence commit I removed
    /// from the harness.
    func testFailedClaudeGenerationPublishesNoMetadata() async throws {
        let environment = try makeStubClaudeEnvironment(emitting: #"{"is_error":true}"#)
        let (generator, _) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: "claude-sonnet-5",
            environment: environment)

        let captured = MetadataCapture()
        var publisher = try XCTUnwrap(generator as? any MetadataPublishingTextGenerating)
        publisher.onMetadata = { captured.record($0) }

        do {
            _ = try await publisher.generate(
                prompt: "p", maxTokens: 32, temperature: 0.7, cancellationID: UUID())
            XCTFail("a CLI-reported error must propagate, not resolve")
        } catch {
            // expected
        }
        XCTAssertNil(captured.value, "a failed generation must publish no metadata")
    }

    /// Ollama already published metadata; this fix must not disturb it.
    func testOllamaMetadataPublicationIsUnchanged() async throws {
        stubTags([("qwen2.5:0.5b", "sha256:deadbeef")])
        let (generator, identity) = try await makeOllama(model: "qwen2.5:0.5b")
        XCTAssertTrue(generator is any MetadataPublishingTextGenerating)
        XCTAssertEqual(identity.readiness, .ready)
    }

    // MARK: - Readiness evidence: configured vs verified

    /// Claude resolution proves the runtime is *constructible*, never that it
    /// works. Nothing here contacts Anthropic, so `ready` — which the Ollama
    /// path earns with an exact-model match against a live daemon — would be an
    /// unearned claim. This assertion is the one the original suite lacked:
    /// `testDefaultResolutionIsStillClaude` checked provider, model,
    /// substitution and generator type, and never looked at readiness at all,
    /// which is precisely how the over-claim survived.
    func testClaudeResolutionIsConfiguredNotVerified() async throws {
        let environment = try makeClaudeEnvironment()
        let (_, identity) = try await LiveRuntimeFactory.make(
            role: .dialectic, runtimeName: "claude", model: nil, environment: environment)

        XCTAssertEqual(identity.readiness, .configured)
        XCTAssertFalse(identity.isReady, "an unverified runtime must not report verified")
        XCTAssertTrue(identity.canAttemptGeneration, "configured is unverified, not broken")
        XCTAssertEqual(identity.displayReadiness, "Configured")
    }

    /// The Ollama path reached the daemon and matched the exact requested
    /// model, so `ready` is a statement about an observed fact.
    func testOllamaExactModelResolutionIsVerified() async throws {
        stubTags([("qwen2.5:0.5b", "sha256:deadbeef")])
        let (_, identity) = try await makeOllama(model: "qwen2.5:0.5b")

        XCTAssertEqual(identity.readiness, .ready)
        XCTAssertTrue(identity.isReady)
        XCTAssertTrue(identity.canAttemptGeneration)
        XCTAssertEqual(identity.displayReadiness, "Endpoint + model verified")
    }

    /// The usability predicate admits both success cases. Without this the
    /// strict predicate would have to serve both questions, and every Claude
    /// session would render as a fault.
    func testConfiguredRuntimeCanAttemptGeneration() {
        XCTAssertTrue(RuntimeReadiness.configured.canAttemptGeneration)
        XCTAssertTrue(RuntimeReadiness.ready.canAttemptGeneration)
    }

    /// Every failure reason stays fail-closed. Iterating `allCases` rather than
    /// spot-checking one means a newly added failure cannot default to usable.
    func testUnavailableRuntimeCannotAttemptGeneration() {
        for failure in RuntimeReadinessFailure.allCases {
            XCTAssertFalse(
                RuntimeReadiness.unavailable(failure).canAttemptGeneration,
                "\(failure) must not be attemptable")
        }
    }

    // MARK: - Readiness wire compatibility

    /// Adding a case must not rewrite the encoding of the existing ones.
    /// Synthesized enum `Codable` keys on the *case name*, not a declaration
    /// ordinal, so `configured` landing first in the declaration cannot shift
    /// `ready` — but that is a property of the compiler, not of this type, so
    /// it is asserted rather than assumed.
    func testOldReadyIdentityStillDecodes() throws {
        let legacy = Data(#"{"ready":{}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeReadiness.self, from: legacy), .ready)

        // And the current encoder still emits exactly that form.
        let encoded = try JSONEncoder().encode(RuntimeReadiness.ready)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"ready":{}}"#)
    }

    func testOldUnavailableIdentityStillDecodes() throws {
        let legacy = Data(#"{"unavailable":{"_0":"modelMissing"}}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(RuntimeReadiness.self, from: legacy),
            .unavailable(.modelMissing))
    }
}

/// Thread-safe one-shot capture for the adapter's metadata callback, which
/// fires synchronously on whichever task called `generate`.
private final class MetadataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GenerationMetadata?
    var value: GenerationMetadata? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func record(_ m: GenerationMetadata) {
        lock.lock(); defer { lock.unlock() }
        stored = m
    }
}
