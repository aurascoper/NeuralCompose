# Seed 001 — 2026-07-19

*Human-readable render of `architecture.json` · `research.json` · `runtime.json`.
Rung on the mode ladder: **Focused + Dialectical (waking)**.*

## Architecture (v1)

- **Version:** arch `2026-07-19`; field `v1 implemented, v2 spec-only (FIELD_V2.md)`.
- **Load-bearing invariants:** MLX only in `BCILLM`; no runtime network except
  `BCICloudBridge/ClaudeCLIGenerator` (opt-in hypnagogic loop only); stub-by-default;
  `SpectralState` is a bias/gloss, never a decode.
- **Key seams:** `TextGenerating` (Sonnet 5 via `ClaudeCLIGenerator` | on-device MLX/stub),
  `SpeechSynthesizing`, `SentenceEmbedder` (BGE), `HypnagogicRunnable` (mirror | dialectical).
- **Dialectic engine:** `InteractionStyle{mirror,dialectical} × ContextProfile{focused,
  reflective,contemplative}`. This seed adds a **waking register** — `DialecticalRole.wakingRoles`
  + `ClaudeCLIGenerator.wakingDialecticalSystemPrompt` + waking prosody — used for the three
  (waking) profiles; the sleep-mirror roles/prompt are reserved for future sleep rungs.

## Research (v1)

- **This session's open hypothesis:** *waking-dynamics-baseline* — does silence emerge
  naturally, does synthesis fire sanely, does drift stabilize, does Reflective differ from
  Focused? Measured from `dialectic-turns` telemetry, **before** any sleep mode.
- **Deferred hypotheses:** `field-energy` (spec-only, Stage A gated), `phase` (Stage B,
  unspecified), `profiles-as-initial-conditions` (continuous FieldPreset is v2).
- **Accepted:** Sonnet 5 as runtime generator (validated this session); structured
  non-determinism; synthesis = reconciliation; tension modulates never scores; two clocks;
  commit-the-priors for fieldEnergy; the Opus/Sonnet co-dev loop.
- **Rejected:** "EEG as a field" on 4-ch Muse; "Dreamer++" Contemplative; mixing
  imagined-word labels into the Track A model.

## Runtime (v1)

- **Now targeting:** dialectical / focused.
- **Benchmarks:** Sonnet-5 runtime smoke PASS; 164 tests / 0 failures; BrainFlow build PASS.
- **Next experiment:** Focused+Dialectical live on the Muse S — confirm `glossScalar`
  variance > 0 (live-EEG influence) and inspect the outcome distribution; then compare
  Reflective vs Focused.
- **Top risks:** live EEG only reaches the gloss with `--with-brainflow` + real estimator +
  seated electrodes (else constant 0.5); two Sonnet-5 cloud calls/turn (text egress); the
  `claude` CLI cwd-context leak.
- **Telemetry:** *pending first live session* → run `Scripts/session-seed.py refresh 001`.

---
*Regenerate the machine parts with `Scripts/session-seed.py refresh 001`; edit the JSON by
hand for architecture/research changes and bump the relevant `content_version`.*
