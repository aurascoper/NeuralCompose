# The Witness — Reflective introspection (reflective vs reflexive)

*Architectural contract for the Reflective rung on the mode ladder
(`Mirror → Focused+Dialectical → Reflective → Contemplative → [GATE] → sleep`).
Unlike `FIELD_V2.md` (spec-only), this describes **shipped** behavior.*

## Why

`ContextProfile.reflective` was a cadence reskin of Focused — the same two roles,
the same system prompt, `Tuning == .default` (`testReflectiveIsExactlyTheShippedDefault`).
seed-001's open hypothesis — *"does Reflective differ from Focused?"* — answered
"barely." The Witness gives Reflective a mechanism Focused structurally lacks,
following the design dialectic:

- *"Make it accountable to a witness it can't fully model — a second process that
  only asks 'what did you just avoid noticing?' Introspection that only loops
  inward tends to just polish its own priors."*
- *"Reflective = a loop watching itself from outside; reflexive = the watching
  collapsing into the watched. Two different failure modes, not two settings on
  one dial — you're choosing which kind of blindness you can tolerate."*

## Two failure modes, two metrics — never one dial

We refuse to build a single "introspection depth" knob. Reflective and reflexive
fail in **opposite** directions, so each gets its own mechanism and its own scalar:

| | **Reflective** (watching from outside — healthy) | **Reflexive** (watching collapsing into the watched — failure) |
|---|---|---|
| Mechanism | the **Witness** (a non-voiced observer of what both poles avoided) | a **semantic self-similarity** reading (generalizes the verbatim `recentlyVoiced` guard) |
| Its own failure | the witness only echoes the poles (polishing priors) → low `witnessDistance` | replies converge onto their own centroid → high `selfSimilarity` |
| Metric | `witnessDistance` (Reflective-only, cloud) | `selfSimilarity` (every profile, on-device) |

The engine exposes both and trades neither. A future "reflectiveness setting"
request is the trap the second quote warns about — resist it.

## The Witness contract (five load-bearing points)

1. **Not a competitor.** A *post-compete* critic pass in `HypnagogicDialecticLoop.runTurn`
   (between `compete` and the `DialecticalCompetition` record). Never embedded,
   scored, or selectable as the utterance.
2. **Separate, relaxed prompt.** `ClaudeCLIGenerator.witnessSystemPrompt` — a
   distinct constant that *permits* the meta-observation the poles'
   `wakingDialecticalSystemPrompt` (constraint #5) forbids, forbids addressing the
   user, and stays in the waking register.
3. **Separate generator seam.** `HypnagogicDialecticLoop(witness:)` — an optional
   second `TextGenerating`. `AppViewModel` injects it only when
   `ContextProfile.witnessEnabled` (i.e. `.reflective`).
4. **Firewalled from speech.** The finding feeds telemetry (and, later, prosody)
   only. It is **never** passed to `speakChunks`, and **never** re-enters the
   poles' `promptShaper` — so the poles cannot learn to satisfy it. This is the
   literal reading of *"a witness it can't fully model."*
5. **Cost + opt-in.** One extra Sonnet call/turn (2 → **3**) for Reflective only,
   plus one on-device embed. `witnessEnabled` defaults false; `selfSimilarity` is
   logged regardless (no cloud).

## Differentiation without touching the dynamics

Reflective's `Tuning` stays `== .default`. The difference lives entirely in
`ContextProfile.witnessEnabled` (true iff `.reflective`), threaded via `loopConfig`
into `HypnagogicDialecticLoop.Config`. The poles' compete/score/select is
untouched — this preserves the seed principle *"profiles are coordinates in one
dynamical system, not different algorithms"*: the Witness is an orthogonal,
non-voiced **observation** layer, not a new dialogue algorithm.

## Telemetry

Three optional fields on `DialecticalCompetition` → `DialecticalTurnEvent`
(→ `dialectic-turns-<day>.jsonl`), all `Optional` so old logs still decode:
`witnessFinding: String?`, `witnessDistance: Float?`, `selfSimilarity: Float?`.
`Scripts/session-seed.py` rolls them up into `witness_turns`,
`mean_witness_distance`, `mean_self_similarity`, `reflective_active`
(`witness_turns > 0`), and `reflexive_collapse_warn`. "Reflective differs from
Focused" becomes: compare a Focused vs a Reflective session rollup (the former has
`witness_turns == 0`).

## Privacy boundary

The Witness is the one place this change touches egress: a **third** Sonnet call
per turn for Reflective, sending `heard` + both candidate texts off-device (the
same *data* the two role calls already send, but a new round-trip and a new logged
artifact, `witnessFinding`). It is default-off, Reflective-only, and its finding
is only *persisted* when interaction logging is on. The privacy banner reflects
the third call. Nothing else about the boundary changes (`grep -rniE
"claude-mind|mcp__" Sources/` stays empty; the only egress remains
`BCICloudBridge/ClaudeCLIGenerator`).

## Honest gaps

- **"Two failure modes, not one dial" is honored by *refusing* to unify them.**
  There is deliberately no scalar trading reflective against reflexive.
- **`witnessDistance` is necessary-not-sufficient.** A witness that rambles
  off-topic also scores high distance without genuinely noticing anything. The
  scalar cannot certify insight — the logged `witnessFinding` text needs a human
  read. Do **not** auto-gate on `witnessDistance`.
- **"Can't fully model" is *strictly* true only in the telemetry-only variant.**
  The moment witness output nudges prosody (a deferred v1.1 sub-stage) a faint,
  indirect back-channel exists — the poles still can't model it (it never re-enters
  their prompts), but the influence is real.
- **`selfSimilarity` via `replyCentroid` measures collapse-toward-average**, not
  collapse-onto-the-last-utterance; it is complementary to the verbatim
  `recentlyVoiced` guard. A per-pair max against the reply ring (v1.1) closes the
  gap but needs a new memory accessor.
- **The Witness observes candidates, not the resolution or the silence.** It
  critiques the *space of moves*, not which one won — so it cannot yet comment on a
  silence as itself an avoidance. A trajectory-level witness is future work.
