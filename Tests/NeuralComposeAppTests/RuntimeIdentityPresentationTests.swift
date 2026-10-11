import XCTest
@testable import NeuralComposeApp
@testable import BCICloudBridge

/// R8 — the privacy banner must describe what actually resolved.
///
/// The strings under test were literals inside `PrivacyIndicatorView.body`:
/// `"the claude CLI"` and `"Listening + Cloud"`, emitted whenever the loop was
/// enabled. They had been wrong since runtime selection landed — with
/// `NEURALCOMPOSE_RUNTIME=ollama` the loop ran entirely on-device while the
/// banner reported cloud egress to Anthropic — and being inside a SwiftUI
/// `body` meant no test could reach them.
final class RuntimeIdentityPresentationTests: XCTestCase {

    private func identity(
        role: RuntimeRole = .dialectic,
        provider: String = "ollama",
        model: String = "qwen2.5:0.5b",
        locality: RuntimeLocality = .onDevice,
        readiness: RuntimeReadiness = .ready
    ) -> ResolvedRuntimeIdentity {
        ResolvedRuntimeIdentity(
            role: role,
            requestedProvider: provider, requestedModel: model,
            // Resolved fields are populated whenever something resolved, and
            // empty only on the failure identity. Keyed on
            // `canAttemptGeneration`, not `== .ready`: a `configured` runtime
            // did resolve a provider and model, and the older two-valued test
            // would have handed it the empty *failure* shape instead.
            resolvedProvider: readiness.canAttemptGeneration ? provider : "",
            resolvedModel: readiness.canAttemptGeneration ? model : "",
            locality: locality, readiness: readiness,
            promptProfile: "p", promptHash: "h", systemPromptSource: "s"
        )
    }

    private func allText(_ p: RuntimeIdentityPresentation) -> String {
        [p.headline, p.dialogueLine, p.witnessLine, p.caption, p.badgeLabel]
            .joined(separator: " ")
    }

    // MARK: - No hardcoded provider

    /// The headline mutation: hardcoding Claude in the banner must fail here.
    func testOnDeviceOllamaIsNeverDescribedAsClaudeOrCloud() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(), witness: nil, isDialectical: false)
        let text = allText(p).lowercased()

        XCTAssertFalse(text.contains("claude"), "an Ollama runtime must not be called Claude: \(text)")
        XCTAssertFalse(text.contains("cloud"), "on-device inference must not be called cloud: \(text)")
        XCTAssertTrue(text.contains("ollama"))
        XCTAssertFalse(p.involvesEgress)
        XCTAssertEqual(p.badgeLabel, "Listening · On-device")
    }

    func testClaudeIsDescribedAsEgressAndNamedAsClaude() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(
                provider: "claude", model: "claude-sonnet-5",
                locality: .localBrokerToRemoteService),
            witness: nil, isDialectical: false)
        XCTAssertTrue(p.involvesEgress)
        XCTAssertEqual(p.badgeLabel, "Listening + Cloud")
        XCTAssertTrue(p.dialogueLine.contains("Claude CLI"))
        XCTAssertTrue(p.caption.contains("may leave this device"))
    }

    /// Locality drives the claim, not the provider name. Ollama on another host
    /// is egress even though "Ollama" reads as local everywhere else.
    func testNonLoopbackOllamaIsDisclosedAsEgress() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(locality: .remoteEndpoint), witness: nil, isDialectical: false)
        XCTAssertTrue(p.involvesEgress, "another host is not this device")
        XCTAssertEqual(p.badgeLabel, "Listening + Cloud")
    }

    /// A mixed configuration discloses egress: one remote runtime is enough.
    func testAnyEgressRuntimeMakesTheWholeBannerDiscloseEgress() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(locality: .onDevice),
            witness: identity(
                role: .witness, provider: "claude", model: "claude-sonnet-5",
                locality: .localBrokerToRemoteService),
            isDialectical: true)
        XCTAssertTrue(p.involvesEgress)
    }

    // MARK: - Unknown is not reassuring

    /// Before the first resolution there is nothing to read. The banner must
    /// not claim on-device operation it cannot substantiate.
    func testUnresolvedRuntimeDefaultsToTheAlarmingClaim() {
        let p = RuntimeIdentityPresentation(dialogue: nil, witness: nil, isDialectical: false)
        XCTAssertTrue(p.involvesEgress, "unknown must not read as safe")
        XCTAssertEqual(p.headline, "Resolving runtime")
        XCTAssertTrue(p.caption.contains("potential egress"))
    }

    /// An identity whose locality could not be established (unknown provider)
    /// discloses egress and says the classification is unverified — never
    /// "On-device", never a named remote topology it cannot substantiate.
    func testUnresolvedLocalityDisclosesEgressAsUnverified() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(
                provider: "olama", locality: .unresolved,
                readiness: .unavailable(.unknownProvider)),
            witness: nil, isDialectical: false)
        XCTAssertTrue(p.involvesEgress, "unverified egress must read as egress")
        XCTAssertTrue(p.dialogueLine.contains("Egress unverified"), p.dialogueLine)
        XCTAssertFalse(p.dialogueLine.contains("On-device"), p.dialogueLine)
    }

    // MARK: - Readiness

    func testUnavailableRuntimeShowsItsFailureNotReady() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(readiness: .unavailable(.modelMissing)),
            witness: nil, isDialectical: false)
        XCTAssertTrue(p.dialogueLine.contains("Model unavailable"), p.dialogueLine)
        XCTAssertFalse(p.dialogueLine.contains("Ready"), p.dialogueLine)
        // Still names what was requested, so the user can act on it.
        XCTAssertTrue(p.dialogueLine.contains("qwen2.5:0.5b"), p.dialogueLine)
    }

    // MARK: - Witness

    func testAbsentWitnessReadsAsDisabledNotAsAFailure() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(), witness: nil, isDialectical: true)
        XCTAssertEqual(p.witnessLine, "Witness: Disabled")
        XCTAssertTrue(p.caption.contains("two calls per turn"), p.caption)
    }

    func testPresentWitnessIsCountedAsAThirdCall() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(), witness: identity(role: .witness), isDialectical: true)
        XCTAssertTrue(p.caption.contains("three calls per turn"), p.caption)
        XCTAssertTrue(p.witnessLine.contains("Ollama"), p.witnessLine)
    }

    func testMirrorModeReportsOneCallPerTurn() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(), witness: nil, isDialectical: false)
        XCTAssertTrue(p.caption.contains("one call per turn"), p.caption)
    }

    // MARK: - Last runtime attempt (visible after fail-closed disablement)

    /// A fresh app has attempted nothing: the disabled row must stay plainly
    /// "Disabled at runtime" with no phantom attempt to explain.
    func testNoAttemptYieldsNoLastAttemptLines() {
        XCTAssertTrue(
            RuntimeIdentityPresentation.lastAttemptLines(dialogue: nil, witness: nil).isEmpty)
    }

    /// The fail-closed sequence stores the unavailable identity and disables
    /// the toggle. The expanded diagnostics must keep showing what was
    /// requested and why it failed — the identity was designed to preserve
    /// exactly this, and rendering only "Disabled at runtime" discarded it.
    func testFailedIdentityStaysVisibleAfterDisablement() {
        let lines = RuntimeIdentityPresentation.lastAttemptLines(
            dialogue: identity(readiness: .unavailable(.modelMissing)),
            witness: nil)
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertTrue(line.contains("Last attempt"), line)
        // The failure identity resolves nothing, so display falls back to the
        // *requested* pair — the user must see what they asked for.
        XCTAssertTrue(line.contains("Ollama"), line)
        XCTAssertTrue(line.contains("qwen2.5:0.5b"), line)
        XCTAssertTrue(line.contains("On-device"), line)
        XCTAssertTrue(line.contains("Model unavailable"), line)
        XCTAssertFalse(line.contains("Ready"), line)
    }

    /// A failed Witness attempt is part of the requested configuration and is
    /// reported alongside the dialogue attempt, in that order.
    func testWitnessAttemptIsReportedAlongsideTheDialogueAttempt() {
        let lines = RuntimeIdentityPresentation.lastAttemptLines(
            dialogue: identity(),
            witness: identity(
                role: .witness, provider: "claude", model: "claude-sonnet-5",
                locality: .localBrokerToRemoteService,
                readiness: .unavailable(.executableNotFound)))
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Dialogue"), lines[0])
        XCTAssertTrue(lines[1].contains("Witness"), lines[1])
        XCTAssertTrue(lines[1].contains("CLI not found"), lines[1])
    }

    // MARK: - Readiness evidence is read, never inferred

    /// The banner must say "Configured" because the *identity* says so — not
    /// because the provider happens to be spelled "claude".
    ///
    /// The mutation this catches is the tempting contained fix: branching the
    /// view on `resolvedProvider == "claude"`. That would reproduce the exact
    /// class of provider-name inference R8 removed, and would silently
    /// mis-describe any future runtime whose resolution is also unverified. So
    /// the identity here is a **Claude-free** one — an Ollama provider carrying
    /// `configured` — which a provider-branching implementation renders as
    /// verified and this assertion rejects.
    func testPresentationShowsConfiguredWithoutProviderBranching() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(provider: "ollama", readiness: .configured),
            witness: nil,
            isDialectical: false)

        XCTAssertTrue(p.dialogueLine.contains("Configured"), p.dialogueLine)
        XCTAssertFalse(p.dialogueLine.contains("verified"), p.dialogueLine)
        XCTAssertFalse(allText(p).lowercased().contains("claude"), allText(p))
    }

    /// The converse, for the same reason: a Claude-spelled provider carrying a
    /// verified readiness must render as verified. Together these two pin the
    /// line text to `readiness` in both directions, so no implementation can
    /// satisfy both by reading the provider.
    func testPresentationShowsEndpointAndModelVerified() {
        let p = RuntimeIdentityPresentation(
            dialogue: identity(
                provider: "claude", model: "claude-sonnet-5",
                locality: .localBrokerToRemoteService, readiness: .ready),
            witness: nil,
            isDialectical: false)

        XCTAssertTrue(p.dialogueLine.contains("Endpoint + model verified"), p.dialogueLine)
        XCTAssertFalse(p.dialogueLine.contains("Configured"), p.dialogueLine)
    }
}
