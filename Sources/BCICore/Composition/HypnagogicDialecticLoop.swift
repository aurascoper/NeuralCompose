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
        /// Enable the introspective Witness (a non-voiced observer). Set true ONLY
        /// for the Reflective profile — this is what makes Reflective a real rung
        /// vs Focused (see `Sources/BCICore/Dialectic/WITNESS.md`). Off ⇒ no
        /// witness generation, no extra cloud call; the reflexive `selfSimilarity`
        /// metric is still logged regardless.
        public var witnessEnabled: Bool

        public init(
            listenTimeout: TimeInterval = 15,
            interTurnDelayNanos: UInt64 = 3_000_000_000,
            maxTokens: Int = 60,
            prosody: SpeechProsody = .hypnagogic,
            maxConsecutiveSilence: Int = 3,
            silenceCues: [String] = HypnagogicDialogueLoop.defaultSilenceCues,
            historyWindow: Int = 16,
            witnessEnabled: Bool = false
        ) {
            self.listenTimeout = listenTimeout
            self.interTurnDelayNanos = interTurnDelayNanos
            self.maxTokens = maxTokens
            self.prosody = prosody
            self.maxConsecutiveSilence = maxConsecutiveSilence
            self.silenceCues = silenceCues
            self.historyWindow = historyWindow
            self.witnessEnabled = witnessEnabled
        }
    }

    // Injected seams.
    private let listener: any HypnagogicListening
    private let generator: any TextGenerating
    /// The introspective Witness generator (Reflective only) — a SEPARATE
    /// `TextGenerating` with a relaxed system prompt (`witnessSystemPrompt`). nil ⇒
    /// no witness pass. Its output is never voiced and never fed to the poles.
    private let witness: (any TextGenerating)?
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
    /// Broadcast of spoken-node events for grounding the voice in the 3D
    /// workspace (Stage 1b): a `place` event per voiced candidate + a
    /// `re-brighten` event per spoken word. Opt-in — nothing is produced unless
    /// a consumer calls `spokenNodeStream()`, and it stays entirely on-device.
    private let spokenNodeChannel = AsyncMulticastChannel<SpokenNodeEvent>(capacity: 32)

    // Evolving state.
    private var loopTask: Task<Void, Never>?
    public private(set) var isRunning = false
    private var silenceIndex = 0
    private var consecutiveSilence = 0
    /// Number of completed turns this loop instance — exposed for the health
    /// watchdog to detect a stalled or dead loop (no turns while listening).
    public private(set) var turnIndex = 0
    /// Wall-clock of the last completed turn (health watchdog).
    public private(set) var lastTurnAt: Date?
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
        witness: (any TextGenerating)? = nil,
        config: Config = .init()
    ) {
        self.listener = listener
        self.generator = generator
        self.witness = witness
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
        // RVS-001 fix: when both voices return empty text (e.g. a
        // cloud-routed model that uses all `num_predict` tokens on
        // its `thinking` and produces no `response`), the previous
        // behavior was to return early without advancing
        // `turnIndex`, which deadlocked the loop's progress check
        // (`while await loop.turnIndex < heardLines.count`) until
        // the 90s watchdog killed the harness. The harness then
        // reported "0/N turns run" with no telemetry explaining
        // why. The new behavior: log a `.silent` turn with no
        // candidates, let `turnIndex` advance, and let the silence
        // counter drive the cue cadence. A persistently-silent run
        // is now visible in the rollup as N `silent` outcomes, not
        // as a hang.
        guard !candidateTexts.isEmpty else {
            await logSilentTurn(heard: heard)
            return
        }

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

        // Introspection (the Reflective rung — see WITNESS.md). Two ORTHOGONAL
        // signals, deliberately not one dial: (1) the reflexive metric —
        // `selfSimilarity`, how much this turn's utterance collapses onto the
        // dialogue's own reply centroid (logged for EVERY profile, on-device);
        // (2) the Witness — a non-voiced observer naming what BOTH poles avoided
        // (Reflective only, one extra cloud call). Neither is ever spoken, and the
        // witness finding never re-enters the poles' prompts (so they can't game it).
        let spokenEmb: Embedding? = {
            switch result.outcome {
            case let .spoke(c), let .synthesized(c): return c.embedding
            case .silent: return scored.max { $0.potential < $1.potential }?.candidate.embedding
            }
        }()
        let selfSimilarity: Float? = spokenEmb.flatMap { emb in
            replyCentroid.map { DialecticalDynamics.normalized(emb.cosineSimilarity(to: $0)) }
        }
        var witnessFinding: String?
        var witnessDistance: Float?
        // `witnessAttempted` records that the Witness RAN this turn, independent of
        // whether it produced a finding — so a persistently-failing witness (an
        // all-nil Reflective run) is not silently mistaken for a Focused run in the
        // rollup (reflective_active is derived from attempts, not findings).
        let witnessAttempted = config.witnessEnabled && witness != nil
        if config.witnessEnabled, let witness {
            do {
                let finding = try await witness.generate(
                    prompt: Self.witnessPrompt(heard: heard, candidates: candidateTexts.map(\.text)),
                    maxTokens: config.maxTokens, temperature: 1.0, cancellationID: UUID()
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if !finding.isEmpty {
                    witnessFinding = finding
                    if let spokenEmb, let findingEmb = try? await embedder.encode([finding]).first {
                        witnessDistance = 1 - DialecticalDynamics.normalized(findingEmb.cosineSimilarity(to: spokenEmb))
                    }
                }
            } catch is CancellationError {
                // Stopping mid-call — not a failure; the checkCancellation below aborts cleanly.
            } catch {
                // A witness failure must NOT break the turn — but it must NOT be
                // silent either: a persistently-failing witness would make Reflective
                // look byte-identical to Focused. Leave a trace.
                let idx = turnIndex
                BCILog.pipeline.notice("witness generate failed (turn \(idx, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
            try Task.checkCancellation()
        }

        let record = DialecticalCompetition(
            index: turnIndex, heard: heard, scored: scored, tension: tension,
            margin: result.margin, selectionTemperature: result.selectionTemperature,
            outcome: result.outcome, glossScalar: gloss.value, spectralState: state,
            witnessFinding: witnessFinding, witnessDistance: witnessDistance,
            selfSimilarity: selfSimilarity, witnessAttempted: witnessAttempted
        )
        await turnLogger.log(DialecticalTurnEvent(record))

        switch result.outcome {
        case let .spoke(candidate), let .synthesized(candidate):
            consecutiveSilence = 0
            memory.recordReply(text: candidate.text, embedding: candidate.embedding, turnIndex: turnIndex)
            // Block a later synthesis from re-speaking this verbatim.
            memory.recordVoiced(candidate.text)
            // Ground the voice: place (and full-brighten) this utterance's
            // workspace node *before* speaking, then re-brighten it per word as
            // the synthesizer voices it (`speakChunks` forwards the word events).
            // One spoken turn ⇒ one node; `turnIndex` is its stable id.
            let nodeID = String(turnIndex)
            spokenNodeChannel.send(SpokenNodeEvent(
                nodeID: nodeID, text: candidate.text, embedding: candidate.embedding,
                word: nil, turnIndex: turnIndex))
            // Voice the winner, blended by how the competition actually went, so
            // a close call carries the losing pole's colour (audible tension).
            let probs = DialecticalDynamics.probabilities(
                potentials: scored.map(\.potential), tau: result.selectionTemperature)
            let turnProsody = SpeechProsody.blend(
                zip(scored, probs).map { (roleProsody(for: $0.candidate.roleID), $1) })
            try await speakChunks(candidate.text, prosody: turnProsody,
                                  grounding: (nodeID: nodeID, embedding: candidate.embedding))
        case .silent:
            consecutiveSilence += 1
            if consecutiveSilence >= config.maxConsecutiveSilence {
                consecutiveSilence = 0
                try await speakChunks(nextSilenceCue(), prosody: config.prosody)
            }
        }
        lastTurnAt = Date()
        turnIndex += 1
    }

    /// RVS-001: log a `.silent` turn when both voice generators
    /// returned empty text. This is the only state change for a
    /// silent turn: the rollup records `outcome: "silent"` and
    /// `turnIndex` advances so the loop's progress check sees the
    /// turn as completed. The 90s watchdog no longer fires for
    /// these runs.
    private func logSilentTurn(heard: String) async {
        let competition = DialecticalCompetition(
            index: turnIndex,
            heard: heard,
            scored: [],
            tension: 0,
            margin: 0,
            selectionTemperature: 0,
            outcome: .silent,
            glossScalar: 0.5,
            spectralState: nil,
            witnessFinding: nil,
            witnessDistance: nil,
            selfSimilarity: nil,
            witnessAttempted: config.witnessEnabled && witness != nil,
            generatorFingerprint: nil
        )
        let event = DialecticalTurnEvent(competition)
        await turnLogger.log(event)
        consecutiveSilence += 1
        if consecutiveSilence >= config.maxConsecutiveSilence {
            consecutiveSilence = 0
            try? await speakChunks(nextSilenceCue(), prosody: config.prosody)
        }
        lastTurnAt = Date()
        turnIndex += 1
    }

    /// The Witness's user prompt: the heard input + both poles' candidate texts,
    /// so it can name what the pair avoided. Pure; the *observing* stance lives in
    /// `ClaudeCLIGenerator.witnessSystemPrompt`.
    static func witnessPrompt(heard: String, candidates: [String]) -> String {
        let voices = candidates.enumerated()
            .map { "Voice \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n")
        return "They heard: \(heard)\n\n\(voices)\n\nWhat did both voices avoid noticing?"
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

    /// A private stream of spoken-node events — the grounding signal the 3D
    /// workspace subscribes to (Stage 1b). Each call returns its own
    /// `AsyncStream`; `nonisolated` because the channel is a `Sendable` `let`,
    /// mirroring the raw-sample fan-out (`AppViewModel.liveSampleStream()`).
    /// Purely local: these events never leave the device.
    public nonisolated func spokenNodeStream() -> AsyncStream<SpokenNodeEvent> {
        spokenNodeChannel.subscribe()
    }

    /// Speaks `text` chunk-by-chunk. When `grounding` is supplied, each word the
    /// synthesizer reaches re-brightens the utterance's workspace node via a
    /// `SpokenNodeEvent` (best-effort — synthesizers without word timing simply
    /// never fire it, and the initial `place` event already lit the node).
    private func speakChunks(_ text: String, prosody: SpeechProsody,
                             grounding: (nodeID: String, embedding: Embedding)? = nil) async throws {
        // Capture Sendable locals so the per-word closure stays `@Sendable`
        // (the channel is a Sendable `let`; the AV callback fires off-actor).
        let channel = spokenNodeChannel
        let turn = turnIndex
        var onWord: (@Sendable (SpokenWord) -> Void)?
        if let g = grounding {
            let nodeID = g.nodeID, emb = g.embedding
            onWord = { (word: SpokenWord) in
                // `send` is @discardableResult (subscriber count); discard so
                // the closure stays `(SpokenWord) -> Void`.
                _ = channel.send(SpokenNodeEvent(
                    nodeID: nodeID, text: text, embedding: emb,
                    word: word, turnIndex: turn))
            }
        }
        for chunk in HypnagogicDialogueLoop.chunk(text) {
            try Task.checkCancellation()
            try await speaker.speak(chunk, prosody: prosody, onWord: onWord)
        }
    }

    private func nextSilenceCue() -> String {
        guard !config.silenceCues.isEmpty else { return "" }
        let cue = config.silenceCues[silenceIndex % config.silenceCues.count]
        silenceIndex += 1
        return cue
    }
}

/// A spoken-node event emitted by `HypnagogicDialecticLoop` as it voices a
/// winning candidate — the grounding signal the 3D workspace consumes to place
/// and light a concept node per utterance, so speech carries a spatial-semantic
/// referent rather than prosody alone. Carries the candidate's already-computed
/// sentence embedding (for placement) so nothing is re-embedded. Purely local;
/// never leaves the device.
public struct SpokenNodeEvent: Sendable, Equatable {
    /// Stable per-utterance id — the workspace's node key. One spoken turn ⇒ one
    /// node; also the `node:<id>` vocabulary the session-time memory gate
    /// (Stage 2) namespaces on.
    public let nodeID: String
    /// The full spoken candidate text (the node's label).
    public let text: String
    /// The candidate's sentence embedding — the workspace projects this to 3D.
    public let embedding: Embedding
    /// `nil` when the node is first voiced (place + full-brighten); the word
    /// being spoken now when the synthesizer reaches it (re-brighten). Best-
    /// effort: synthesizers without word timing only ever emit the `nil` event.
    public let word: SpokenWord?
    /// The originating turn index (monotonic; also the temporal ordering key).
    public let turnIndex: Int

    public init(nodeID: String, text: String, embedding: Embedding,
                word: SpokenWord?, turnIndex: Int) {
        self.nodeID = nodeID
        self.text = text
        self.embedding = embedding
        self.word = word
        self.turnIndex = turnIndex
    }
}
