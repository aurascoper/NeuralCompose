# Seed 004 — 2026-07-21

*Human-readable render of `architecture.json` · `research.json` ·
`runtime.json`.
Rung on the work ladder: **Generation Runtime architecture** — the
dialectical engine's provider-neutral runtime surface. Branched from
`main` at `611b07e`. The WorldModel branch (`worldmodel/overnight-transform-ab`)
is the historical record of the JEPA+MPC investigation; this branch
does not depend on it.*

## Why this seed exists

The Claude CLI rate limit hit on 2026-07-21 made visible an
*architectural coupling* that had been latent: the dialectical
engine's cloud-generation path is a single provider (Claude), the
system prompts are defined on the generator, and the telemetry
does not record generator identity. The rate limit is the
trigger; the architecture it revealed is the motivation.

This seed captures the open decision, the keep-bar, the constraints,
and the success criteria *before* implementation starts. The
seven-step plan below is the order of work; the architectural holds
in it are pre-registered with default implementations so the
implementation can flow without a stop on every decision.

## Architecture (v1)

- **GenerationRuntime** is the provider-neutral runtime surface the
  dialectical engine depends on. Not `LanguageModelRuntime` (bakes in
  the assumption that the runtime is a single model producing
  language); not `InferenceRuntime` (implies a model doing
  classification or prediction). `GenerationRuntime` matches the
  engine's own terminology: a generator produces a response to a
  competition.
- **GenerationRuntime is composed over a GenerationTransport.**
  Transports are HTTP / subprocess / local-process shapes. Each
  `XxxGenerationRuntime` conforms to `GenerationRuntime` and holds a
  single `XxxTransport` that conforms to `GenerationTransport`. A
  new model behind an existing transport is a configuration change;
  a new transport is a new conformer.
- **GenerationRuntime defaults: `generate(...) + metadata`.** Smaller
  surface, easier to extend. `GenerationRequest` / `GenerationResponse`
  structs can be added later without breaking the protocol.
- **TextGenerating is preserved as a legacy compatibility shim.**
  `ClaudeCLIGenerator` conforms to *both* `TextGenerating` and
  `GenerationRuntime` during the transition. `TextGenerating` is
  deprecated once the harness, app, and tests all depend solely on
  `GenerationRuntime`.
- **Prompt profiles are repository resources.** `Sources/BCICloudBridge/Prompts/*.md`
  (Markdown files, versioned, loaded at startup). The runtime
  consumes them; the runtime does not own them. The dialectical
  engine owns semantics; the runtime owns transport.
- **GeneratorFingerprint** (struct) on `DialecticalTurnEvent`:
  `runtime`, `transport`, `provider`, `model`, `prompt_profile`,
  `interaction_style`, `prompt_hash`, `generation_parameters`.
  Optional field; old logs continue to decode.

## Research (v1)

- **`provider-substitution-equivalence` (KEEP-BAR, pre-registered).**
  Provider substitution is an architectural equivalence, not a
  behavioral identity. Claude is the reference implementation;
  alternative providers are *characterized* on `benchmark-001-grounding`,
  not required to imitate Claude output. A lower-cost / lower-latency /
  slightly-different-dialogue is a tradeoff to record, not a
  regression to reject.
- **`runtime-is-transport-invariant` (ADR-009 invariant #2).** The
  runtime SHALL NOT modify semantic intent: no prompt rewriting, no
  temperature adjustment, no hidden system prompts, no response
  interpretation. Tested by code review + a test asserting the
  Ollama runtime does not perform any of those actions.
- **`prompt-portability`.** A `PromptProfile`, once defined, produces
  byte-identical prompt text on every runtime. Tested by sha256
  match across Claude and Ollama on the same profile.

## Runtime (v1)

- **Runtime selection precedence:** CLI flag (`--runtime <name>`) >
  environment variable (`NEURALCOMPOSE_RUNTIME=<name>`) > Claude
  (default).
- **Benchmarks:** build (`PASS` 9s on the WorldModel branch — to be
  re-verified on this branch), Ollama probe (`PASS`, 5 models
  available), Claude rate-limit (`RATE LIMITED`).
- **Top risks:** cross-provider comparison is not apples-to-apples
  (kept; this is the keep-bar choice); Ollama `:cloud` is its own
  network-egress surface (mitigated by per-transport opt-in); the
  fingerprint schema change is a small downstream consumer update;
  local Ollama startup races and model-not-pulled errors need
  initial implementation care.
- **Open architectural holds** (each with a default; see architecture.json
  + research.json for the full list): protocol surface
  (`generate(...) + metadata` — approved), transport-composition shape
  (composed over a `GenerationTransport` — approved), fingerprint
  schema (the rich struct — approved), default runtime selection
  mechanism (CLI flag → env var → Claude — approved).

## The seven-step plan (in dependency order)

1. **Draft ADR-009** (this branch's first deliverable) with the five
   invariants, the naming rationale, the Done-means list, and the
   benchmark-governance reference. Provenance: the initial scope
   was drafted on `worldmodel/overnight-transform-ab@28a0d20`; the
   canonical copy lands here.
2. **Prompt extraction.** Move `hypnagogicSystemPrompt`,
   `wakingDialecticalSystemPrompt`, `witnessSystemPrompt` out of
   `ClaudeCLIGenerator` into `Sources/BCICloudBridge/Prompts/*.md`.
   Add a loader; add tests asserting byte-identity across runtimes.
3. **GenerationRuntime + GenerationTransport protocols.** New files
   under `Sources/BCICore/Protocols/`. `ClaudeCLIGenerator` refactored
   to `ClaudeCLIGenerationRuntime` composed over `ClaudeCLITransport`,
   conforming to both `TextGenerating` (legacy) and `GenerationRuntime`
   (new) so no behavior changes.
4. **OllamaGenerationRuntime.** Composed over `OllamaHTTPTransport`;
   model name as a config field. Verify against the 5 models
   `ollama list` reports.
5. **GeneratorFingerprint in telemetry.** Add the struct as an
   optional field on `DialecticalTurnEvent`; update codec; update
   `Scripts/session-seed.py` rollup keys.
6. **Harness migration.** `dialectic-session --runtime <name>
   --model <model>`; env-var fallback. Add `--dry-run` for wiring
   verification before live calls.
7. **Benchmark run + comparison.** `benchmark-001-grounding` × 3
   profiles × 3 runtimes × 3 seeds. Compare against seed-002
   Reflective reference numbers. Characterize tradeoffs per keep-bar.

**Next checkpoint** is after step 2 (prompt extraction) and a
successful build, per the user's instruction.

## Where to resume

1. Step 1: draft ADR-009.
2. Step 2: prompt extraction + tests + build.
3. Steps 3-7 in order, with the next checkpoint after step 2.
4. Update `seed-004/runtime.json` after each step with the result
   (success / null result / blocker).
5. When the benchmark run is complete, update this `SEED.md` with
   the final characterization and close the seed.

## Slow context (unchanged framing)

Architecture invariants hold: MLX only in `BCILLM`; the no-network-at-runtime
principle is preserved (each non-local runtime is its own opt-in surface and
its own banner disclosure); stub-by-default; `SpectralState` is a bias/gloss,
never a decode; the Opus/Sonnet co-dev loop. The WorldModel branch and
`Sources/` remain decoupled from each other and from this branch's work.

---

*Regenerate the machine parts with `Scripts/session-seed.py refresh 004`; edit the
JSON by hand for architecture/research changes and bump the relevant `content_version`.*
