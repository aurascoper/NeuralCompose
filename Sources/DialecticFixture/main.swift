import BCICore
import Foundation

// Emits the cross-language conformance fixture for `DialecticalDynamics`.
//
// WHY THIS EXISTS, AND WHY IT IS COMMITTED
//
// `crates/neuralcompose-hypnagogic/src/dynamics.rs` in the client-native repo
// is a hand port of `DialecticalDynamics.swift` + `DialecticalCompetition.swift`.
// A hand port of ~460 lines of scoring, tension carry-over and a
// tension-sharpened softmax can be internally consistent, fully unit-tested and
// still wrong — a transcription slip in the temperature path produces plausible
// output forever, and plausible output is what stops people looking.
//
// So the Rust asserts against THIS program's output, the way
// `band_power.rs` asserts against the Python reference to 12 significant
// figures. That is what makes "port" a checkable claim rather than a
// description of intent.
//
// This harness is COMMITTED, permanently, and is not a throwaway. A fixture
// whose generator has been deleted cannot be regenerated, and when the Swift
// dialectic moves there would be no way to tell whether the Rust drifted or the
// Swift did. Regenerating and diffing is the whole mechanism.
//
// DRAWS, NOT A SEED
//
// The fixture records the actual uniform draws consumed, never a seed. Swift's
// and Rust's PRNGs produce different sequences from the same seed, so a seeded
// fixture would fail against a *correct* port and the "selection differs while
// scores match" diagnostic would fire on every run and mean nothing. The Rust
// side replays these draws through its `ScriptedDraws` seam.
//
// EMBEDDINGS ARE FIXED, NOT GENERATED
//
// Vectors here are constructed arithmetically and L2-normalized in-process. No
// model is loaded and no embedder is called: the fixture must test the
// DYNAMICS, not whichever embedder happened to be installed. That also means
// this builds and runs under plain Command Line Tools, with no weights, no
// network and no headband.
//
// Usage:
//     swift run dialectic-fixture > \
//       ../neuralcompose-client-native/crates/neuralcompose-hypnagogic/tests/fixtures/dialectic_v1.json

// ── Deterministic, model-free embeddings ────────────────────────────────────

enum F {
    static let modelID = "fixture-v1"
    static let dimension = 8

    /// A reproducible unit vector. Values come from a fixed integer recurrence so
    /// the same index always yields the same vector on every platform and Swift
    /// version — no `Hasher`, no `Double.random`, nothing whose output is allowed
    /// to change between releases.
    static func embedding(_ index: Int) -> Embedding {
        var state = UInt64(index &* 2_654_435_761 &+ 1)
        var values: [Float] = []
        values.reserveCapacity(F.dimension)
        for _ in 0..<F.dimension {
            // xorshift64 — fully specified integer ops, identical everywhere.
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            // Take 16 bits and centre on zero so vectors point in varied directions.
            let raw = Float(Int64(state & 0xFFFF) - 0x8000)
            values.append(raw / Float(0x8000))
        }
        let norm = sqrtf(values.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 1e-6 ? values.map { $0 / norm } : values
        return Embedding(
            values: unit, modelID: F.modelID, dimension: F.dimension,
            version: "1", seed: 0
        )
    }

    /// Blends two fixture vectors and renormalizes — lets a case place a candidate
    /// deliberately near or far from `heard` without hand-writing coordinates.
    static func blend(_ a: Embedding, _ b: Embedding, _ w: Float) -> Embedding {
        var values = [Float](repeating: 0, count: F.dimension)
        for i in 0..<F.dimension { values[i] = a.values[i] * w + b.values[i] * (1 - w) }
        let norm = sqrtf(values.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 1e-6 ? values.map { $0 / norm } : values
        return Embedding(
            values: unit, modelID: F.modelID, dimension: F.dimension,
            version: "1", seed: 0
        )
    }

}

// ── JSON emission ───────────────────────────────────────────────────────────

/// Full `Float` precision. The Rust compares to 1e-6, but the fixture should
/// not be the thing that loses information.
func j(_ f: Float) -> String { String(format: "%.9g", f) }
func j(_ d: Double) -> String { String(format: "%.17g", d) }
func j(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}
func jArray(_ values: [Float]) -> String { "[" + values.map(j).joined(separator: ",") + "]" }

// ── Cases ───────────────────────────────────────────────────────────────────

/// One scored competition, with every intermediate the Rust must reproduce.
struct Case {
    let name: String
    /// What the profile tuning is — the Rust looks this up by id rather than
    /// re-encoding the numbers, so a drifted constant fails here too.
    let profile: String
    let tuning: DialecticalDynamics.Tuning
    let heardIndex: Int
    let historyIndices: [Int]
    let replyIndices: [Int]
    /// `(candidateIndex, blendWeightTowardHeard, roleID)`.
    let candidates: [(Int, Float, String)]
    let draw: Double
}

let profiles: [(String, DialecticalDynamics.Tuning)] = [
    ("focused", ContextProfile.focused.tuning),
    ("reflective", ContextProfile.reflective.tuning),
    ("contemplative", ContextProfile.contemplative.tuning),
]

var cases: [Case] = []

// Every profile against the same inputs — isolates the tuning as the variable.
for (name, tuning) in profiles {
    // A. Early turn: no history, no replies. Pins the neutral-0.5 path.
    cases.append(Case(
        name: "\(name)/early-turn-no-centroids", profile: name, tuning: tuning,
        heardIndex: 1, historyIndices: [], replyIndices: [],
        candidates: [(10, 0.85, "coherenceSeeking"), (11, 0.05, "displacementSeeking")],
        draw: 0.5
    ))
    // B. Established dialogue: both centroids present.
    cases.append(Case(
        name: "\(name)/with-both-centroids", profile: name, tuning: tuning,
        heardIndex: 2, historyIndices: [3, 4, 5], replyIndices: [6, 7],
        candidates: [(12, 0.80, "coherenceSeeking"), (13, 0.10, "displacementSeeking")],
        draw: 0.42
    ))
    // C. Near-tie under HIGH tension — the stalemate/silence gate, which is
    //    where the profiles differ most (focused resists, contemplative invites).
    cases.append(Case(
        name: "\(name)/near-tie-high-tension", profile: name, tuning: tuning,
        heardIndex: 8, historyIndices: [20, 21], replyIndices: [22],
        candidates: [(30, 0.50, "coherenceSeeking"), (31, 0.50, "displacementSeeking")],
        draw: 0.5
    ))
    // D. Draw sweep across a near-tie — the bifurcation. Different draws must
    //    select different basins, which is the one thing a seed could not pin.
    for (k, draw) in [0.01, 0.25, 0.49, 0.51, 0.75, 0.99].enumerated() {
        cases.append(Case(
            name: "\(name)/bifurcation-draw-\(k)", profile: name, tuning: tuning,
            heardIndex: 9, historyIndices: [23], replyIndices: [24],
            candidates: [(40, 0.52, "coherenceSeeking"), (41, 0.48, "displacementSeeking")],
            draw: draw
        ))
    }
    // E. Decisive margin — the dynamics, not the draw, must win regardless.
    cases.append(Case(
        name: "\(name)/decisive-margin", profile: name, tuning: tuning,
        heardIndex: 14, historyIndices: [25, 26], replyIndices: [27],
        candidates: [(50, 0.98, "coherenceSeeking"), (51, 0.02, "displacementSeeking")],
        draw: 0.99
    ))
    // F. Three roles — the competition iterates over `[DialecticalRole]`, so a
    //    port that hard-coded two poles passes everything above and fails here.
    cases.append(Case(
        name: "\(name)/three-candidates", profile: name, tuning: tuning,
        heardIndex: 15, historyIndices: [28], replyIndices: [29],
        candidates: [
            (60, 0.90, "coherenceSeeking"),
            (61, 0.45, "symbolic"),
            (62, 0.05, "displacementSeeking"),
        ],
        draw: 0.7
    ))
    // G. Single candidate — margin falls through to `sorted.first`, an edge the
    //    Swift handles unusually and a port is likely to "clean up".
    cases.append(Case(
        name: "\(name)/single-candidate", profile: name, tuning: tuning,
        heardIndex: 16, historyIndices: [], replyIndices: [],
        candidates: [(70, 0.75, "coherenceSeeking")],
        draw: 0.33
    ))
    // H. No candidates — resolves silent rather than trapping.
    cases.append(Case(
        name: "\(name)/no-candidates", profile: name, tuning: tuning,
        heardIndex: 17, historyIndices: [], replyIndices: [],
        candidates: [],
        draw: 0.5
    ))
}

// ── Run ─────────────────────────────────────────────────────────────────────

var out: [String] = []
var drawsConsumed: [Double] = []

for c in cases {
    let heard = F.embedding(c.heardIndex)
    let history = c.historyIndices.map { F.embedding($0) }
    let replies = c.replyIndices.map { F.embedding($0) }
    let historyCentroid = DialecticalDynamics.centroid(of: history)
    let replyCentroid = DialecticalDynamics.centroid(of: replies)

    let candidates: [DialecticalCandidate] = c.candidates.map { idx, w, role in
        DialecticalCandidate(
            text: "candidate-\(idx)",
            embedding: F.blend(F.embedding(idx), heard, w),
            roleID: role
        )
    }

    let scored: [ScoredCandidate] = candidates.map { cand in
        let e = DialecticalDynamics.energy(
            candidate: cand.embedding, heard: heard,
            historyCentroid: historyCentroid, replyCentroid: replyCentroid
        )
        return ScoredCandidate(
            candidate: cand, energy: e,
            potential: e.potential(c.tuning.weights),
            roleFulfillment: 0
        )
    }

    let tension = DialecticalDynamics.tension(among: candidates.map(\.embedding))
    let tau = DialecticalDynamics.selectionTemperature(tension: tension, tuning: c.tuning)
    let probs = DialecticalDynamics.probabilities(
        potentials: scored.map(\.potential), tau: tau
    )
    let result = DialecticalDynamics.compete(
        scored: scored, tension: tension, draw: c.draw, tuning: c.tuning
    )
    drawsConsumed.append(c.draw)

    let outcome: String
    let spoken: String
    switch result.outcome {
    case let .spoke(cand):
        outcome = "spoke:\(cand.roleID)"; spoken = cand.text
    case let .synthesized(cand):
        outcome = "synthesized:\(cand.roleID)"; spoken = cand.text
    case .silent:
        outcome = "silent"; spoken = ""
    }

    let candidateJSON = scored.map { s in
        """
        {"roleId":\(j(s.candidate.roleID)),\
        "embedding":\(jArray(s.candidate.embedding.values)),\
        "coherence":\(j(s.energy.coherence)),\
        "resonance":\(j(s.energy.resonance)),\
        "novelty":\(j(s.energy.novelty)),\
        "potential":\(j(s.potential))}
        """
    }.joined(separator: ",")

    out.append("""
    {"name":\(j(c.name)),\
    "profile":\(j(c.profile)),\
    "heard":\(jArray(heard.values)),\
    "historyCentroid":\(historyCentroid.map { jArray($0.values) } ?? "null"),\
    "replyCentroid":\(replyCentroid.map { jArray($0.values) } ?? "null"),\
    "candidates":[\(candidateJSON)],\
    "tension":\(j(tension)),\
    "selectionTemperature":\(j(tau)),\
    "probabilities":\(jArray(probs)),\
    "draw":\(j(c.draw)),\
    "margin":\(j(result.margin)),\
    "decisive":\(result.decisive),\
    "outcome":\(j(outcome)),\
    "spokenText":\(j(spoken))}
    """)
}

print("""
{"schemaId":"neuralcompose.hypnagogic.dialectic-conformance.v1",\
"modelId":\(j(F.modelID)),\
"dimension":\(F.dimension),\
"note":"Generated by Sources/DialecticFixture. Draws are recorded, never seeds. Regenerate with: swift run dialectic-fixture",\
"drawsConsumed":[\(drawsConsumed.map { j($0) }.joined(separator: ","))],\
"cases":[\(out.joined(separator: ","))]}
""")
