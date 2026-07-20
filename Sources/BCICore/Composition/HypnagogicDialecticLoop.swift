import Foundation

/// Experimental, opt-in **dialectic** sibling of `HypnagogicDialogueLoop`.
/// Where that loop collapses each turn into one mirror reply, this one runs a
/// persistent dynamical competition: on each heard utterance, every
/// `DialecticalRole` generates a candidate from its own tension-aware prompt;
/// the candidates are embedded and scored on shared semantic axes; and the turn
/// resolves — by a tension-sharpened softmax sample — into *speaking* a basin,
/// falling *silent* on a metastable stalemate, or (once memory is wired in)
/// voicing an emergent *synthesis*. Standing tension is carried across turns, so
/// contradiction can persist rather than being resolved every cycle.
///
/// Milestone 2 scope: two roles, a bounded temporal trajectory driving the
/// history/reply centroids, fixed weights (no EEG bias yet), and an injected RNG
/// so the single point of non-determinism stays deterministic under test. The
/// semantic-graph memory + emergent synthesis (milestone 3), prosody blending
/// (4), `SpectralState` bias (5), and telemetry (6) layer on without changing
/// this control flow.
///
/// Honest scope (identical to `HypnagogicDialogueLoop`): MANUAL trigger only,
/// NOT wired to any sleep-stage detector; the generator MAY be a cloud model
/// (the sole runtime network exception) — and note this loop makes **two**
/// `generate()` calls per turn, one per role. Pure orchestration over injected
/// seams; it links no AVFoundation/MLX/CLI itself. Mic and speaker alternate
/// strictly, so the mic is never hot during playback.
public actor HypnagogicDialecticLoop {

    public struct Config: Sendable {
        public var listenTimeout: TimeInterval
        public var interTurnDelayNanos: UInt64
        public var maxTokens: Int
        /// Base prosody for spoken turns (milestone 4 replaces this with a
        /// competition-weighted blend).
        public var prosody: SpeechProsody
        /// A metastable silence can persist at most this many consecutive turns
        /// before a soft induction cue breaks it — so the loop never stalls into
        /// permanent silence.
        public var maxConsecutiveSilence: Int
        /// Rotating soft cues spoken to break a silence run or on an empty
        /// listen turn (no model call).
        public var silenceCues: [String]
        /// How many recent turns feed the history/reply centroids.
        public var historyWindow: Int

        public init(
            listenTimeout: TimeInterval = 15,
            interTurnDelayNanos: UInt64 = 3_000_000_000,
            maxTokens: Int = 60,
            prosody: SpeechProsody = .hypnagogic,
            maxConsecutiveSilence: Int = 3,
            silenceCues: [String] = HypnagogicDialogueLoop.defaultSilenceCues,
            historyWindow: Int = 16
        ) {
            self.listenTimeout = listenTimeout
            self.interTurnDelayNanos = interTurnDelayNanos
            self.maxTokens = maxTokens
            self.prosody = prosody
            self.maxConsecutiveSilence = maxConsecutiveSilence
            self.silenceCues = silenceCues
            self.historyWindow = historyWindow
        }
    }

    // Injected seams.
    private let listener: any HypnagogicListening
    private let generator: any TextGenerating
    private let speaker: any SpeechSynthesizing
    private let embedder: any SentenceEmbedder
    private let roles: [DialecticalRole]
    private let tuning: DialecticalDynamics.Tuning
    /// The single point of non-determinism: a uniform draw in `[0, 1)`.
    private let random: @Sendable () -> Double
    /// Fast biological clock source — the latest `SpectralState` gloss (or nil).
    /// Defaults to no bias, so the loop is fully text-driven until EEG is wired.
    private let glossProvider: @Sendable () async -> SpectralState?
    /// Opt-in persistence of each turn's competition. Null by default.
    private let turnLogger: any DialecticalTurnLogging
    private let config: Config

    // Evolving state.
    private var loopTask: Task<Void, Never>?
    public private(set) var isRunning = false
    private var silenceIndex = 0
    private var consecutiveSilence = 0
    private var turnIndex = 0
    /// Tension carried from the previous turn — shapes this turn's prompts.
    private var standingTension: Float = 0
    /// The semantic-graph memory the dialectic lives in (centroids, recurrence,
    /// synthesis gating). Initialized in `init` from the config + tuning.
    private var memory: DialecticalMemory
    /// Slow semantic clock — the competition weights, evolving with inertia.
    private var field: DialecticalField
    /// Fast biological clock — EMA-smoothed `SpectralState` gloss.
    private var gloss = SpectralGloss()

    public init(
        listener: any HypnagogicListening,
        generator: any TextGenerating,
        speaker: any SpeechSynthesizing,
        embedder: any SentenceEmbedder,
        roles: [DialecticalRole] = DialecticalRole.defaultRoles,
        tuning: DialecticalDynamics.Tuning = .default,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        glossProvider: @escaping @Sendable () async -> SpectralState? = { nil },
        turnLogger: any DialecticalTurnLogging = NullDialecticalTurnLogger(),
        config: Config = .init()
    ) {
        self.listener = listener
        self.generator = generator
        self.speaker = speaker
        self.embedder = embedder
        self.roles = roles
        self.tuning = tuning
        self.random = random
        self.glossProvider = glossProvider
        self.turnLogger = turnLogger
        self.config = config
        self.memory = DialecticalMemory(
            historyWindow: config.historyWindow,
            tensionCeiling: tuning.synthesisTensionCeiling
        )
        self.field = DialecticalField(base: tuning.weights,
                                      inertia: tuning.fieldInertia, wind: tuning.glossWind)
    }

    /// Starts the loop if not already running. Idempotent.
    public func start() {
        guard loopTask == nil else { return }
        isRunning = true
        loopTask = Task { [weak self] in await self?.run() }
    }

    /// Cancels the loop, aborts any in-flight listen, and interrupts speech.
    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        await listener.cancel()
        await speaker.stopSpeaking()
    }

    // MARK: - Loop

    private func run() async {
        while !Task.isCancelled {
            do {
                let heard = try await listener.listen(timeout: config.listenTimeout)
                try Task.checkCancellation()

                if let transcript = heard?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !transcript.isEmpty {
                    try await runTurn(heard: transcript)
                } else {
                    // Empty *input* (the user said nothing) — distinct from a
                    // dialectical silence. Breathe with an induction cue.
                    try await speakChunks(nextSilenceCue(), prosody: config.prosody)
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
            }

            do {
                try await Task.sleep(nanoseconds: config.interTurnDelayNanos)
            } catch {
                return
            }
        }
    }

    /// One dialectical turn: generate one candidate per role, embed, score,
    /// compete, and act on the outcome.
    private func runTurn(heard: String) async throws {
        // 1. Two generators, each shaped by the standing tension.
        var candidateTexts: [(roleID: String, text: String)] = []
        for role in roles {
            try Task.checkCancellation()
            let raw = try await generator.generate(
                prompt: role.promptShaper(heard, standingTension),
                maxTokens: config.maxTokens,
                temperature: role.temperature,
                cancellationID: UUID()
            )
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { candidateTexts.append((role.id, text)) }
        }
        guard !candidateTexts.isEmpty else { return }  // both generators empty — skip, no state change

        // 2. Embed heard + every candidate in one batch.
        try Task.checkCancellation()
        let embeddings = try await embedder.encode([heard] + candidateTexts.map(\.text))
        guard embeddings.count == candidateTexts.count + 1 else { return }
        let heardEmb = embeddings[0]
        let candidateEmbs = Array(embeddings.dropFirst())

        // 3. Advance the two clocks and score against the accumulated trajectory.
        //    Fast (gloss EMA) and slow (field inertia over entropy/drift) combine
        //    only in the field's target — biological noise can't swing the weights.
        let state = await glossProvider()
        gloss.update(state, alpha: tuning.glossEMAAlpha)
        let weights = field.advance(glossScalar: gloss.value,
                                    entropy: memory.entropy, drift: memory.drift)

        let historyCentroid = memory.historyCentroid
        let replyCentroid = memory.replyCentroid
        let scored: [ScoredCandidate] = zip(candidateTexts, candidateEmbs).map { pair, emb in
            let (roleID, text) = pair
            let energy = DialecticalDynamics.energy(
                candidate: emb, heard: heardEmb,
                historyCentroid: historyCentroid, replyCentroid: replyCentroid
            )
            let role = roles.first { $0.id == roleID }
            return ScoredCandidate(
                candidate: DialecticalCandidate(text: text, embedding: emb, roleID: roleID),
                energy: energy,
                potential: energy.potential(weights),
                roleFulfillment: role?.objective(energy) ?? 0
            )
        }
        let tension = DialecticalDynamics.tension(among: candidateEmbs)

        // An old idea may re-enter to bridge the two most-opposed poles. Uses
        // the *prior* convergence streak, so `observe` runs after this.
        var synthesis: DialecticalCandidate?
        if candidateEmbs.count >= 2 {
            let (i, j) = mostOpposedPair(candidateEmbs)
            synthesis = memory.synthesisCandidate(thesis: candidateEmbs[i],
                                                  antithesis: candidateEmbs[j], tuning: tuning)
        }

        let result = DialecticalDynamics.compete(
            scored: scored, tension: tension, draw: random(), tuning: tuning,
            synthesis: synthesis, forceSynthesis: synthesis != nil
        )

        // 4. Record the turn and act.
        memory.recordHeard(text: heard, embedding: heardEmb, turnIndex: turnIndex)
        memory.observe(tension: tension)
        standingTension = tension

        let record = DialecticalCompetition(
            index: turnIndex, heard: heard, scored: scored, tension: tension,
            margin: result.margin, selectionTemperature: result.selectionTemperature,
            outcome: result.outcome, glossScalar: gloss.value, spectralState: state
        )
        await turnLogger.log(DialecticalTurnEvent(record))

        switch result.outcome {
        case let .spoke(candidate), let .synthesized(candidate):
            consecutiveSilence = 0
            memory.recordReply(text: candidate.text, embedding: candidate.embedding, turnIndex: turnIndex)
            // Block a later synthesis from re-speaking this verbatim.
            memory.recordVoiced(candidate.text)
            // Voice the winner, blended by how the competition actually went, so
            // a close call carries the losing pole's colour (audible tension).
            let probs = DialecticalDynamics.probabilities(
                potentials: scored.map(\.potential), tau: result.selectionTemperature)
            let turnProsody = SpeechProsody.blend(
                zip(scored, probs).map { (roleProsody(for: $0.candidate.roleID), $1) })
            try await speakChunks(candidate.text, prosody: turnProsody)
        case .silent:
            consecutiveSilence += 1
            if consecutiveSilence >= config.maxConsecutiveSilence {
                consecutiveSilence = 0
                try await speakChunks(nextSilenceCue(), prosody: config.prosody)
            }
        }
        turnIndex += 1
    }

    /// The voice of the role that produced a candidate (the base prosody for an
    /// unknown role id, e.g. a resurfaced `"synthesis"`).
    private func roleProsody(for id: String) -> SpeechProsody {
        roles.first { $0.id == id }?.voiceProsody ?? config.prosody
    }

    /// Indices of the two most semantically opposed candidate embeddings — the
    /// poles a synthesis would have to bridge.
    private func mostOpposedPair(_ embeddings: [Embedding]) -> (Int, Int) {
        var best = (0, 1)
        var worst: Float = -1
        for i in 0..<embeddings.count {
            for j in (i + 1)..<embeddings.count {
                let d = 1 - DialecticalDynamics.normalized(embeddings[i].cosineSimilarity(to: embeddings[j]))
                if d > worst { worst = d; best = (i, j) }
            }
        }
        return best
    }

    // MARK: - Speech

    private func speakChunks(_ text: String, prosody: SpeechProsody) async throws {
        for chunk in HypnagogicDialogueLoop.chunk(text) {
            try Task.checkCancellation()
            try await speaker.speak(chunk, prosody: prosody)
        }
    }

    private func nextSilenceCue() -> String {
        guard !config.silenceCues.isEmpty else { return "" }
        let cue = config.silenceCues[silenceIndex % config.silenceCues.count]
        silenceIndex += 1
        return cue
    }
}
