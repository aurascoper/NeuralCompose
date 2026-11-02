import XCTest
import Foundation
@testable import BCICore

/// Milestone 3 - the semantic-graph memory and the emergent-synthesis gate.
final class DialecticalMemoryTests: XCTestCase {

    private func emb(_ v: [Float]) -> Embedding {
        let norm = sqrtf(v.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 0 ? v.map { $0 / norm } : v
        return Embedding(values: unit, modelID: "t", dimension: v.count, version: "1", seed: 0)
    }

    // MARK: - SemanticGraph

    func testGraphLinksSimilarNodesAndRanksByProximity() {
        var g = SemanticGraph(capacity: 8, edgeThreshold: 0.9)
        g.insert(text: "sea", embedding: emb([1, 0]), turnIndex: 0, kind: .heard)
        g.insert(text: "ocean", embedding: emb([0.98, 0.2]), turnIndex: 1, kind: .reply)   // near "sea"
        g.insert(text: "clock", embedding: emb([0, 1]), turnIndex: 2, kind: .reply)        // orthogonal

        XCTAssertEqual(g.edges.count, 1, "only the two near vectors are linked above threshold")
        let near = g.nearestPriorNodes(to: emb([1, 0]), limit: 2)
        XCTAssertEqual(near.first?.text, "sea", "the closest prior idea ranks first")
        XCTAssertEqual(near.map(\.text), ["sea", "ocean"], "ranked by descending similarity")
    }

    func testGraphEvictsOldestBeyondCapacity() {
        var g = SemanticGraph(capacity: 2, edgeThreshold: 0.5)
        g.insert(text: "a", embedding: emb([1, 0]), turnIndex: 0, kind: .heard)
        g.insert(text: "b", embedding: emb([0, 1]), turnIndex: 1, kind: .heard)
        g.insert(text: "c", embedding: emb([1, 1]), turnIndex: 2, kind: .heard)
        XCTAssertEqual(g.nodes.map(\.text), ["b", "c"], "the oldest node is evicted at capacity")
        XCTAssertFalse(g.edges.contains { $0.a == 0 || $0.b == 0 }, "its edges go with it")
    }

    // MARK: - Derived slow-clock quantities

    func testEntropyAndDriftReflectReplyMovement() {
        var focused = DialecticalMemory(historyWindow: 8)
        focused.recordReply(text: "x", embedding: emb([1, 0]), turnIndex: 0)
        focused.recordReply(text: "x2", embedding: emb([1, 0.02]), turnIndex: 1)  // barely moved

        var wandering = DialecticalMemory(historyWindow: 8)
        wandering.recordReply(text: "a", embedding: emb([1, 0]), turnIndex: 0)
        wandering.recordReply(text: "b", embedding: emb([0, 1]), turnIndex: 1)     // jumped

        XCTAssertLessThan(focused.entropy, wandering.entropy, "a focused dialogue has lower entropy")
        XCTAssertLessThan(focused.drift, wandering.drift, "…and lower drift")
    }

    // MARK: - Synthesis gate

    func testResurfacedBridgingIdeaBecomesSynthesisCandidate() {
        var m = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        // A prior *reply* sitting close to both of the poles we'll present later
        // (synthesis reconciles from replies, not from heard input).
        m.recordReply(text: "the tide remembers", embedding: emb([1, 1, 0]), turnIndex: 0)

        let thesis = emb([1, 0, 0])
        let antithesis = emb([0, 1, 0])
        let synth = m.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default)
        XCTAssertEqual(synth?.text, "the tide remembers",
                       "an old idea that reconciles both poles resurfaces as the synthesis")
        XCTAssertEqual(synth?.roleID, "synthesis")
    }

    func testNoBridgingIdeaMeansNoSynthesis() {
        var m = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        // A prior reply aligned with only ONE pole - reconciles nothing.
        m.recordReply(text: "only thesis", embedding: emb([1, 0, 0]), turnIndex: 0)
        let synth = m.synthesisCandidate(thesis: emb([1, 0, 0]), antithesis: emb([0, 1, 0]),
                                         tuning: .default)
        XCTAssertNil(synth, "an idea close to one pole only does not clear the strict bar")
    }

    func testSustainedConvergenceLowersTheSynthesisBar() {
        // An idea whose reconciliation score sits between the low and high bars
        // (min-sim ≈ 0.57): barred while opposed, admitted once converged.
        let bridge = emb([1, 0.15, 0])
        let thesis = emb([1, 0, 0])
        let antithesis = emb([0, 1, 0])

        var opposed = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        opposed.recordReply(text: "bridge", embedding: bridge, turnIndex: 0)
        XCTAssertNil(opposed.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default),
                     "below the strict bar while the poles are opposed")

        var converged = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        converged.recordReply(text: "bridge", embedding: bridge, turnIndex: 0)
        for _ in 0..<DialecticalDynamics.Tuning.default.synthesisSustainK {
            converged.observe(tension: 0.1)   // a run of low-tension turns
        }
        XCTAssertNotNil(converged.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default),
                        "sustained convergence lowers the bar and admits the synthesis")

        converged.resetLowTensionStreak()
        XCTAssertEqual(converged.lowTensionStreak, 0)
        XCTAssertNil(converged.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default),
                     "resetting the convergence streak restores the strict synthesis bar")
    }

    func testVoicedRepliesDoNotResurfaceAfterHistoryWindowExpires() {
        var m = DialecticalMemory(historyWindow: 4, graphCapacity: 32, tensionCeiling: 0.35)
        let thesis = emb([1, 0, 0])
        let antithesis = emb([0, 1, 0])
        let bridge = emb([1, 1, 0])

        for i in 0..<10 {
            let text = "voiced-turn-\(i)"
            m.recordReply(text: text, embedding: bridge, turnIndex: i)
            m.recordVoiced(text)
            m.observe(tension: 0.1)
        }

        let synth = m.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default)
        XCTAssertNil(synth, "voiced replies still inside graphCapacity must never be replayed verbatim after historyWindow turns")
    }

    // MARK: - Conditional Autoforgetting & Autobank Gate (when/iff needed)

    func testAutoforgetIfNeededPrunesOnlyAfterSustainedReflexiveCollapseOrForceReset() {
        var m = DialecticalMemory(historyWindow: 8, graphCapacity: 32, tensionCeiling: 0.35)
        for i in 0..<6 {
            m.recordHeard(text: "heard-\(i)", embedding: emb([1, Float(i) * 0.01]), turnIndex: i)
            m.recordReply(text: "reply-\(i)", embedding: emb([1, Float(i) * 0.01]), turnIndex: i)
        }
        XCTAssertEqual(m.replyEmbeddings.count, 6)

        // Single high self-similarity turn does not prune when sustainK == 2
        let prunedFirst = m.autoforgetIfNeeded(selfSimilarity: 0.89, collapseThreshold: 0.85, sustainK: 2, minRetained: 2)
        XCTAssertFalse(prunedFirst)
        XCTAssertEqual(m.reflexiveCollapseStreak, 1)
        XCTAssertEqual(m.replyEmbeddings.count, 6)

        // Healthy turn resets the streak
        let prunedHealthy = m.autoforgetIfNeeded(selfSimilarity: 0.72, collapseThreshold: 0.85, sustainK: 2, minRetained: 2)
        XCTAssertFalse(prunedHealthy)
        XCTAssertEqual(m.reflexiveCollapseStreak, 0)

        // Two consecutive reflexive-collapse turns trigger conditional autoforgetting
        _ = m.autoforgetIfNeeded(selfSimilarity: 0.88, collapseThreshold: 0.85, sustainK: 2, minRetained: 2)
        let prunedSecond = m.autoforgetIfNeeded(selfSimilarity: 0.91, collapseThreshold: 0.85, sustainK: 2, minRetained: 2)
        XCTAssertTrue(prunedSecond, "sustained reflexive collapse must prune the oldest half of rolling embeddings")
        XCTAssertEqual(m.replyEmbeddings.count, 3)
        XCTAssertEqual(m.heardEmbeddings.count, 3)
        XCTAssertEqual(m.reflexiveCollapseStreak, 0)
        XCTAssertEqual(m.autoforgetCount, 1)
        XCTAssertEqual(m.graph.nodes.count, 12, "SemanticGraph long-horizon nodes remain intact for synthesis")

        // Force reset prunes down to minRetained immediately
        let forced = m.autoforgetIfNeeded(selfSimilarity: nil, minRetained: 2, forceReset: true)
        XCTAssertTrue(forced)
        XCTAssertEqual(m.replyEmbeddings.count, 2)
        XCTAssertEqual(m.heardEmbeddings.count, 2)
        XCTAssertEqual(m.autoforgetCount, 2)
    }

    func testShouldAutobankTurnGatesStuttersBackchannelsControlAndCollapse() {
        XCTAssertTrue(
            DialecticalMemory.shouldAutobankTurn(
                heard: "Should we test out the Bluetooth muse BCI brain computer interface EEG connection to NeuralCompose",
                spoken: "Yes, test Muse S native BLE board 39 or MindMonitor UDP 5000 over Tailscale.",
                outcome: "spoke:coherence-seeking",
                selfSimilarity: 0.8681
            )
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "Sex sex sex",
                spoken: "Any response",
                outcome: "spoke:coherence-seeking",
                selfSimilarity: 0.50
            ),
            "single-token repetition stutters must not be autobanked"
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "Kind of",
                spoken: "Any response",
                outcome: "spoke:coherence-seeking",
                selfSimilarity: 0.50
            ),
            "short backchannels/hedges (< 3 words) must not be autobanked"
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "Turn off",
                spoken: "Any response",
                outcome: "spoke:coherence-seeking",
                selfSimilarity: 0.50
            ),
            "control/reset commands must not be autobanked"
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "OK I should be good I'll be down in a second",
                spoken: "Any response",
                outcome: "spoke:displacement-seeking",
                selfSimilarity: 0.9114
            ),
            "transient room transit announcements must not be autobanked"
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "Sex, sex, sex.",
                spoken: "Any response",
                outcome: "spoke:coherence-seeking",
                selfSimilarity: 0.50
            ),
            "comma-separated single-token stutters must not be autobanked"
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "Please reset memory now",
                spoken: "Any response",
                outcome: "spoke:coherence-seeking",
                selfSimilarity: 0.50
            ),
            "reset memory phrases must not be autobanked"
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "How does the slow core interact with the fast wireframe in phase space",
                spoken: "Any response",
                outcome: "error",
                selfSimilarity: 0.50
            ),
            "non-spoke/non-synthesized outcomes must not be autobanked"
        )
        XCTAssertFalse(
            DialecticalMemory.shouldAutobankTurn(
                heard: "How does the slow core interact with the fast wireframe in phase space",
                spoken: "Repeated collapsed reply",
                outcome: "spoke:displacement-seeking",
                selfSimilarity: 0.95,
                maxSelfSimilarity: 0.92
            ),
            "turns exceeding maxSelfSimilarity collapse threshold must not be autobanked"
        )

        let w1 = DialecticalMemory.evaluateAutobankWarrant(
            heard: "Three words here",
            spoken: "One",
            outcome: "spoke:coherence-seeking",
            selfSimilarity: 0.40
        )
        XCTAssertFalse(w1.eligible)
        XCTAssertEqual(w1.reason, "short_backchannel_or_hedge")

        let w2 = DialecticalMemory.evaluateAutobankWarrant(
            heard: "Three words here",
            spoken: "Two words",
            outcome: "spoke:coherence-seeking",
            selfSimilarity: 0.40
        )
        XCTAssertTrue(w2.eligible)
        XCTAssertEqual(w2.reason, "warranted")

        // Secondary contemplative-mode warrant rule (!witnessAttempted && maxCandidatePotential >= 1.40 && selfSimilarity in 0.85...0.96)
        let wContemplative = DialecticalMemory.evaluateAutobankWarrant(
            heard: "What is a wizard about and how it applied to the spice Julia Colonels",
            spoken: "A wizard is about mastery earned through study, mapping to Vizard and SPICE.jl ephemeris kernels.",
            outcome: "spoke:coherence-seeking",
            selfSimilarity: 0.9247,
            maxSelfSimilarity: 0.92,
            witnessAttempted: false,
            maxCandidatePotential: 1.445
        )
        XCTAssertTrue(wContemplative.eligible)
        XCTAssertEqual(wContemplative.reason, "warranted_contemplative")

        // ASR Phonetic Recovery Dictionary verification (Turn L79 & Turn L115)
        let recL79 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "Are the viral arc jeans worth modeling and something like open foam or pie mall or Kmart"
        )
        XCTAssertTrue(recL79.canonicalHeard.contains("viral Arc capsid gene"))
        XCTAssertTrue(recL79.canonicalHeard.contains("OpenFOAM"))
        XCTAssertTrue(recL79.canonicalHeard.contains("PyMOL"))
        XCTAssertTrue(recL79.canonicalHeard.contains("ChimeraX"))
        XCTAssertEqual(recL79.matchedRules.count, 4)

        let recL115 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "What is a wizard about and how it applied to the spice Julia Colonels"
        )
        XCTAssertTrue(recL115.canonicalHeard.contains("Vizard"))
        XCTAssertTrue(recL115.canonicalHeard.contains("SPICE.jl"))
        XCTAssertEqual(recL115.matchedRules.count, 2, "spice julia colonels replacement must not redundantly re-trigger julia colonels")
        XCTAssertTrue(HypnagogicDialecticLoop.isAstrodynamicsOrM7MultiscaleQuery("What is a wizard about and how it applied to the spice Julia Colonels"))
        XCTAssertTrue(HypnagogicDialecticLoop.isDirectRecallOrClarificationQuery("What is a wizard about and how it applied to the spice Julia Colonels"))

        // Context guard: literal retail sentence without modeling/biology context must not rewrite "Kmart" or "pie mall"
        let recRetail = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "I walked past a Kmart and a pie mall on my way home"
        )
        XCTAssertEqual(recRetail.matchedRules.count, 0)
        XCTAssertFalse(recRetail.canonicalHeard.contains("ChimeraX"))
        XCTAssertFalse(recRetail.canonicalHeard.contains("PyMOL"))

        let recL127 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "somebody Baczynski the disintegration loops and a thermodynamic and tropic signal or web MCP calls on Huawei's logic folding to subvert more law"
        )
        XCTAssertTrue(recL127.canonicalHeard.contains("Basinski"))
        XCTAssertTrue(recL127.canonicalHeard.contains("entropic signal"))
        XCTAssertTrue(recL127.canonicalHeard.contains("LogicFolding"))
        XCTAssertTrue(recL127.canonicalHeard.contains("Moore's Law"))
        XCTAssertTrue(HypnagogicDialecticLoop.isAstrodynamicsOrM7MultiscaleQuery("So can you do you know calls like web MCP calls on Huawei's logic folding to subvert more law"))

        let recL132And134 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "compartmentalization of the deal modules and what's considered the golden recording that be face be sleep"
        )
        XCTAssertTrue(recL132And134.canonicalHeard.contains("feel modulus"))
        XCTAssertTrue(recL132And134.canonicalHeard.contains("Phase B sleep"))

        // High-potential rescue rule (witnessAttempted && maxCandidatePotential >= 1.60 && selfSimilarity in 0.85...0.96, rescuing L145, L151, L152, L153)
        let wHighPot = DialecticalMemory.evaluateAutobankWarrant(
            heard: "Basilisk is an open source Astro dynamic simulation framework developed by the university of Colorado's ABS lab in LA ASP la",
            spoken: "Basilisk pairs a fast C/C++ modular dynamics core with SWIG-wrapped Python scripting for closed-loop spacecraft GNC.",
            outcome: "spoke:coherence-seeking",
            selfSimilarity: 0.9355,
            maxSelfSimilarity: 0.92,
            witnessAttempted: true,
            maxCandidatePotential: 1.6701
        )
        XCTAssertTrue(wHighPot.eligible)
        XCTAssertEqual(wHighPot.reason, "warranted_high_potential")

        // L147..L156 ASR phonetic recovery (Basilisk, SmallModularBioReactors.jl, Vizard Unity 3D, CSPICE, SPICE.jl)
        let recL154 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "A standalone visualization tool called wizard based on the unity engine can display the spacecraft local planets sensors and actuators and 3-D"
        )
        XCTAssertTrue(recL154.canonicalHeard.contains("Vizard"))
        XCTAssertTrue(HypnagogicDialecticLoop.isAstrodynamicsOrM7MultiscaleQuery("A standalone visualization tool called wizard based on the unity engine can display the spacecraft local planets sensors and actuators and 3-D"))

        let recL156 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "Sea spice itself returns to KM and KM over S and nothing and read me claims a conversion so treat spy.jail output as KM until you check SPKPOS on a known body yourself"
        )
        XCTAssertTrue(recL156.canonicalHeard.contains("CSPICE"))
        XCTAssertTrue(recL156.canonicalHeard.contains("SPICE.jl"))

        // 2026-11-02 L1..L11 UTC rollover ASR phonetic recovery (1e3 to m/s, Basilisk-generated state, SPICE.jl, Vizard, OpenMC, OpenFOAM, Simulink, Simscape)
        let recRolloverL1L3 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "In velocities by one E3 2M over S against a basis generated state for spice stock jail Colonels and visitor visualization visitor with open MC"
        )
        XCTAssertTrue(recRolloverL1L3.canonicalHeard.contains("1e3 to m/s"))
        XCTAssertTrue(recRolloverL1L3.canonicalHeard.contains("Basilisk-generated state"))
        XCTAssertTrue(recRolloverL1L3.canonicalHeard.contains("SPICE.jl ephemeris kernels"))
        XCTAssertTrue(recRolloverL1L3.canonicalHeard.contains("Vizard 3D visualization"))
        XCTAssertTrue(recRolloverL1L3.canonicalHeard.contains("OpenMC (Monte Carlo particle transport)"))

        let recRolloverL4L11 = HypnagogicDialecticLoop.canonicalizeASRTranscript(
            "for argon to orchestrate open phone calls and sign out for for all my workflows with cogeneration simulant product family tested measurement mat lab and slink student suite simulator link and Simca electrical"
        )
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("for our run to orchestrate"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("OpenFOAM CFD solver runs"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("sign up for for all my workflows"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("Code Generation (MATLAB Coder / Simulink Coder)"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("Simulink Product Family"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("Test and Measurement"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("MATLAB and Simulink Student Suite"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("Simulink"))
        XCTAssertTrue(recRolloverL4L11.canonicalHeard.contains("Simscape Electrical"))
    }
}


