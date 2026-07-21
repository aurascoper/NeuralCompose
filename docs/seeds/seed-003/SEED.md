# Seed 003 — 2026-07-21

*Human-readable render of `architecture.json` · `research.json` · `runtime.json`.
Rung on the mode ladder: **Reflective (validated) → Contemplative next**. A clean
hand-off after a large session — three PRs merged. The three things that matter
(per the dialectic): current state, the one open decision, where to resume.*

## Current state (merged on `main` this session)

- **PR #14 (`7205b2c`) — the voice de-robotify arc.** rhythm → Premium/Enhanced
  neural selector → confidence-**wobble** prosody → the user's on-device
  **Personal Voice** (`AVSpeechSynthesizerService.bestPersonalVoiceIdentifier`;
  an ad-hoc-signed app CAN use it, no restricted entitlement) → `voice-profile.json`
  persistence → the `neuralcompose://` **Siri-Shortcut** URL scheme. Fully local.
- **PR #15 (`78efe7f`) — the Reflective Witness.** A non-voiced post-compete
  observer that names what both poles avoided; **reflective vs reflexive as two
  metrics, not one dial** (`witnessDistance` + on-device `selfSimilarity`);
  Reflective's `Tuning` stays `== .default`. Contract in `WITNESS.md`.
- **PR #16 (`b80f3d6`) — the `dialectic-session` harness + live validation.** A
  headless scripted runner of the full loop with real Sonnet calls (+ the Witness);
  it **confirmed** the seed-002 hypothesis: Focused `reflective_active=False` /
  `witness_attempts=0` vs Reflective `True` / `=3`, `mean_witness_distance=0.345`,
  no `witness_silent_warn`. The Witness named a shared blind spot both poles missed.
- Full suite **443 / 0 / 5-skip**. Every PR reviewed (code-reviewer +
  silent-failure-hunter) before merge; real findings fixed each time.

## The one open decision (next experiment)

**The Contemplative rung.** The tool exists now — run
`.build/debug/dialectic-session contemplative <out.jsonl> <heard...>` on the SAME
input as Focused/Reflective and compare rollups. Does its reluctant-synthesis /
high-silence tuning behave *differently*, or is it (like pre-Witness Reflective) a
cadence reskin? Secondary, now sharper: today's telemetry already shows real
`glossScalar` variance (0.1–0.5, `spectralState` on 44/182 turns — a real estimator
ran), so the open item is no longer "variance > 0". It's **attribution** — the log
has no per-turn liveness field, so the rollup's `live_eeg_influence` (= variance>0)
can't tell live from synthetic. Add a source marker to `DialecticalTurnEvent`, then
capture a *labeled* live Muse-S session.

## Where to resume

1. `.build/debug/dialectic-session contemplative out.jsonl "<3 lines>"`, then roll
   up + compare against a Focused run (self-contained python or `session-seed.py`).
2. Or triage ONE new dialectic thread into a spec (all *named-unspecified* in
   `research.json`, do not build blind): **self-reshaping learning device** (the
   core loop generalizes to any skill-with-feedback; language as the first test
   case, not the destination), **ARC per-instance abstraction** (induce, don't
   look up — cross-links `~/Developer/arc_agi`), **MPC demos as a wind tunnel**,
   **adversarial > random recognition set**.

## Slow context (unchanged framing)

Architecture invariants hold: MLX only in `BCILLM`; the one runtime egress is
`BCICloudBridge/ClaudeCLIGenerator` (now 2 calls/turn, **3 for Reflective**, banner
discloses per profile); stub-by-default; `SpectralState` is a bias/gloss, never a
decode; the Opus/Sonnet co-dev loop. `fieldEnergy` v2 stays spec-only
(`FIELD_V2.md`); `DialecticalField.target()` calibration still open.

---
*Regenerate the machine parts with `Scripts/session-seed.py refresh 003`; edit the
JSON by hand for architecture/research changes and bump the relevant `content_version`.*
