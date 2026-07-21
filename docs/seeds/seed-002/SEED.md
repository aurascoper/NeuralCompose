# Seed 002 — 2026-07-21

*Human-readable render of `architecture.json` · `research.json` · `runtime.json`.
Rung on the mode ladder: **Reflective (waking)** — advanced from seed-001's
Focused+Dialectical by giving Reflective a mechanism Focused lacks.*

## Architecture (v2)

- **Version:** arch `2026-07-19`; field `v1 implemented, v2 spec-only (FIELD_V2.md)`.
- **Load-bearing invariants** (unchanged): MLX only in `BCILLM`; no runtime network
  except `BCICloudBridge/ClaudeCLIGenerator`; stub-by-default; `SpectralState` is a
  bias/gloss, never a decode.
- **NEW — the Reflective Witness** (`Sources/BCICore/Dialectic/WITNESS.md`): a
  **non-voiced** post-compete observer (a separate `TextGenerating` with
  `ClaudeCLIGenerator.witnessSystemPrompt`) that names what *both* poles avoided.
  Gated to Reflective via `ContextProfile.witnessEnabled` → `HypnagogicDialecticLoop.Config.witnessEnabled`.
  **Firewalled** from speech and from the poles' prompts (a 3rd Sonnet call/turn,
  Reflective-only). Reflective's `Tuning` stays `== .default`; the poles' dynamics
  are untouched, so profiles remain **coordinates in one system** — the Witness is
  an orthogonal observation layer.
- **reflective vs reflexive = two metrics, never one dial:** `witnessDistance`
  (reflective, cloud) + `selfSimilarity` (reflexive, on-device via `replyCentroid`).
  Three new optional `DialecticalTurnEvent` fields (old logs still decode).

## Research (v2)

- **`reflective-vs-reflexive` (MECHANISM under test):** reflective (watching from
  outside) and reflexive (the watching collapsing into the watched) are two
  independent failure modes, not one axis. The Witness makes Reflective a real rung
  vs Focused (which runs 0 witness turns). No single "reflectiveness" knob — by design.
- **`waking-dynamics-baseline` (still OPEN):** silence rate, synthesis rate, drift
  stability — to characterize live before any sleep rung. Its "does Reflective
  differ from Focused?" clause is now answered by the mechanism above.
- **Accepted / rejected:** unchanged from seed-001 (Sonnet-5 runtime; structured
  non-determinism; synthesis = reconciliation; tension modulates never scores; two
  clocks; the Opus/Sonnet co-dev loop; "EEG as a field" and "Dreamer++" rejected).

## Runtime (v3)

- **Now targeting:** dialectical / reflective (the Witness rung).
- **Benchmarks:** witness suite green (firewall, gating, `selfSimilarity` collapse,
  telemetry codec, prompt separation); `testReflectiveIsExactlyTheShippedDefault`
  still holds.
- **Next experiment:** run a Focused and a Reflective session on the same input,
  then `session-seed.py refresh 002` — Reflective should show `witness_turns>0` /
  `reflective_active=true` (Focused: 0) + a `mean_witness_distance`; watch
  `mean_self_similarity` for reflexive collapse. Live Muse-S gloss variance still pending.
- **Top risks:** a THIRD Sonnet cloud call/turn for Reflective (text egress; banner
  must show it); `witnessDistance` is necessary-not-sufficient (needs a human read);
  the `claude` CLI cwd-context leak.
- **Telemetry:** live `dialectic-turns` now carries the witness/self-similarity
  fields; `session-seed.py telemetry` rolls them up (`witness_turns`,
  `reflective_active`, `mean_self_similarity`, `reflexive_collapse_warn`).

---
*Regenerate the machine parts with `Scripts/session-seed.py refresh 002`; edit the
JSON by hand for architecture/research changes and bump the relevant `content_version`.*
