# ADR-008: Opus/Sonnet co-development loop, session seeds, and the mode-progression ladder

**Status**: Accepted
**Date**: 2026-07-19

## Context

The dialectic engine shipped (11 commits; `Sources/BCICore/Dialectic/`,
`InteractionStyle × ContextProfile`, `FIELD_V2.md` spec). Two process problems now
block iterating on it well:

1. **Cross-session continuity.** Each Opus session ends and the next begins from a
   recursively-compressed chat summary — lossy, and it mixes fast-moving
   implementation detail with slow architectural reasoning, so the architecture
   drifts as the summary shrinks.
2. **Mode discipline.** The interaction ladder runs from a plain waking mirror all
   the way to sleep-onset dreaming. Jumping to the sleep rungs before the *waking*
   dynamics are understood would mean tuning against behaviour we have never
   observed — the same trap `FIELD_V2.md` avoids for `fieldEnergy`.

Two facts make a division of labour natural. Sonnet 5 is already the app's runtime
generator (`ClaudeCLIGenerator`, `claude -p --model claude-sonnet-5`, no API key),
validated this session by the `dialectic-smoke` runtime check. And the dialectic
engine's system/role prompts were, until this session, entirely sleep-oriented —
so "run it awake" required a real *waking register*, not just flipping a switch.

## Decision

Adopt an explicit, auditable co-development loop and encode the mode ladder as a
gated contract.

- **Role division.** *Opus* = architect / theorist / specification writer.
  *Sonnet 5* = the runtime generator **and** the day-to-day implementation agent
  in the repo. The loop is `spec → Sonnet implements → tests → telemetry → review
  → next seed → repeat`.

- **Session seeds replace transcript summaries.** `docs/seeds/seed-NNN/` holds three
  parts that evolve at different rates and are kept separate on purpose —
  `architecture.json` (slow), `research.json` (medium), `runtime.json` (fast) —
  plus a `SEED.md` render. One monotonic snapshot id gives one audit chain; each
  part's own `content_version` bumps independently. `Scripts/session-seed.py`
  (offline; never touches an LLM) is the typed loader and assembles the runtime
  part from live git + the `dialectic-turns` telemetry. See
  [`docs/seeds/README.md`](../../seeds/README.md).

- **Waking register.** For the three current (waking) profiles the dialectical loop
  runs `DialecticalRole.wakingRoles` + `ClaudeCLIGenerator.wakingDialecticalSystemPrompt`
  + waking prosody (`SpeechProsody.wakingCoherent` / `.wakingDivergent`). The
  sleep-mirror roles (`DialecticalRole.coherenceSeeking` / `.displacementSeeking`)
  and `hypnagogicSystemPrompt` are **reserved** for the future sleep rungs — not
  deleted, not the default for a waking run. This uses the `[DialecticalRole]`
  extension seam exactly as designed ("adding a role is data, not control flow").

- **Reproducible, still-gated live runs.** A new opt-in launch override
  `NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART=<mode>` (`mirror`|`focused`|`reflective`|`contemplative`;
  default unset → no-op; the legacy `<style>:<profile>` form is still tolerated)
  enables the loop at launch without the UI toggle, so a session is scriptable from
  a seed. It flows through the *same* `reconcileHypnagogicLoop()` path, so every
  existing gate holds: the mic/speech authorization prompt still fires and the red
  cloud-egress banner still shows while active. `NEURALCOMPOSE_INTERACTION_LOG=1`
  separately turns on local turn logging (ADR-005) so a scripted run captures
  telemetry. `Scripts/run-dialectical-waking.sh` wires these together on top of the
  existing TCC-safe `.app` launch.

- **The mode-progression ladder is a gated contract:**

  ```
  Mirror → Focused+Dialectical → Reflective → Contemplative
         → [GATE] → Wind-down → Hypnagogic → Dream
  ```

  The `[GATE]` is: **the waking dynamics must be characterized first** — from seed
  telemetry, does silence emerge naturally (not never / not always)? does synthesis
  fire at a sane rate? does semantic drift stabilize? does *Reflective* actually
  differ from *Focused*? Only then are the sleep rungs (new `ContextProfile`s)
  introduced. No sleep rung is promoted on "looks promising."

## Consequences

- **Enables:** an auditable chain of design decisions in versioned seeds instead of
  ever-shrinking transcripts; a reproducible one-command waking session that yields
  comparable telemetry; a clear seam for Sonnet to implement against a frozen spec
  while Opus reasons over the architecture.
- **Costs:** a small amount of new surface (the `dialectic-smoke` target, two run
  scripts, the seed dir + tool, the autostart override). The autostart override
  touches the network-egress opt-in, so it is written to *preserve* — never bypass —
  the authorization prompt and the egress banner.
- **Deferred (unchanged by this ADR):** `fieldEnergy` stays spec-only
  (`FIELD_V2.md`); the sleep-mode `ContextProfile`s are not built; an autonomous
  `/loop` is not wired — the co-dev loop is run by hand first, which is the point of
  the gate.
- **Honesty boundary.** The ladder's sleep-stage *names* describe interaction design
  only. Nothing here claims the Muse detects, induces, or verifies a cognitive or
  sleep state; `SpectralState` remains a bias/gloss, and the 4-channel montage's
  limits (see `ADR-004-privacy-first-acquisition` and the Track-B risk notes) are
  unchanged. If a rung is named after zazen or hypnagogia, that is inspiration for
  the interaction, not a claim about the user's mind.
