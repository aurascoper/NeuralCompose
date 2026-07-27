# EEG Methods Staging Integration Manifest

Status: Draft
Direct staging-to-main merge: Prohibited

Main snapshot: `d0f38673cfcf724e9c3b5f9c3bc63688a0c19541`
Staging snapshot: `41f559a8aed538c7fe71016590fdc19de4627a9d`
Merge base: `611b07e0b6a1030cc01f27b3cf80dfd24286931f`
Staging-only commits: 72
Main-only commits: 9

This manifest is an integration classification, not authorization to merge,
promote a model, enable live control, or revive parked Shadow Lab work.

Snapshots are pinned. Any commit landing on either branch after the SHAs above
invalidates the row counts and requires a refresh. A refresh is already expected
after PR #32 merges.

## Two findings that shape everything below

**The lineages are file-disjoint.** All 9 main-only commits are WorldModel work
from PR #22, and staging changes zero files under `WorldModel/`. No integration
branch cut from current `main` can conflict with main's divergence.

**Nothing has already landed.** `git cherry -v origin/main origin/docs/eeg-methods-scope`
reports 59 `+` and zero `-`: no staging commit is patch-equivalent to anything in
main. There are therefore no `ALREADY_IN_MAIN` or `PATCH_EQUIVALENT_IN_MAIN` rows,
and every substantive commit needs a disposition of its own.

Evidence: `.handoff/integration/eeg-methods-scope/` (untracked).

## How merge commits are treated

Staging carries 13 merge commits and 59 substantive commits. Merge commits are
classified `KEEP_STAGING_ONLY` as lineage markers: integration branches re-land
their constituent commits onto a clean base cut from `main`, so staging's merge
topology is never replayed. Each merge commit's constituents carry the
substantive classification.

## Not present in this lineage

- **PR #32 (A2 runtime identity)** is unmerged. Its A–G commits are not among
  the 72 and will be classified `PENDING_PR_32` when its final accepted head
  exists. Integration A cannot be cut until then.
- **Issue #34 (Shadow Lab)** lives on `docs/eeg-offline-encoder-boundary` at
  `1251b5b` and is absent here. Nothing in this manifest may be classified
  `INTEGRATE` on its behalf.

---

## Classification — 72 of 72 staging commits

### RUNTIME_A2 — 15 substantive, 1 merge

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `24989b8` | — | seed-004 v1 — Generation Runtime architecture | — | INTEGRATE | none (doc) | Design record for the runtime it precedes; follows its implementation lane |
| `84e5dee` | — | decouple system prompts into repository resources | PACKAGING_AND_RESOURCES | INTEGRATE | BCICloudBridgeTests | Introduces the resource bundle that `0d03e76` later packages |
| `b9b166a` | — | GenerationRuntime + GenerationTransport protocols | — | INTEGRATE | BCICloudBridgeTests, BCICoreTests | Protocol floor for the whole lane |
| `ce68a53` | — | OllamaHTTPTransport + OllamaGenerationRuntime | — | INTEGRATE | BCICloudBridgeTests | Second runtime behind the protocol |
| `dc518b9` | — | GeneratorFingerprint on DialecticalTurnEvent | — | INTEGRATE | BCICoreTests | Telemetry contract consumed by #32's Witness fingerprints |
| `4002d3e` | — | runtime selection for dialectic-session | — | INTEGRATE | DialecticSessionTests | Harness-side selection |
| `a155af5` | — | log a silent turn when both voices return empty | — | INTEGRATE | BCICoreTests | Prevents a silent turn vanishing from the rollup |
| `b9c09fd` | — | thread generator metadata via adapter onMetadata | — | INTEGRATE | BCICloudBridgeTests | End-to-end metadata path |
| `eb1e373` | — | wire LiveRuntimeFactory into AppViewModel | — | INTEGRATE | BCICloudBridgeTests | Completes the two-layer metadata path |
| `d354fe9` | — | wire attachMetadataCaptureFromAdapter in live path | — | INTEGRATE | manual/live | App-side capture |
| `94541a3` | — | MetadataCallbackBox across existential copies | — | INTEGRATE | BCICloudBridgeTests | Fixes metadata loss through existential copy |
| `3e1f88e` | #29 | fail closed when prompt resources are unavailable | PACKAGING_AND_RESOURCES | INTEGRATE | BCICloudBridgeTests | Fail-closed resource loading |
| `8072247` | #31 | resolve Claude CLI without env-wrapper execution | — | INTEGRATE | BCICloudBridgeTests | R7 |
| `a6751e7` | #31 | make fail-closed runtime resolution testable | — | INTEGRATE | NeuralComposeAppTests | Seam for R2 |
| `6b8d1e4` | #31 | pin the R2 call site, remove vacuous assertions | — | INTEGRATE | BCICloudBridgeTests, DialecticSessionTests | Removes assertions that passed vacuously |
| `23c56ea` | #31 | *merge* PR #31 A1 runtime-trust foundation | — | KEEP_STAGING_ONLY | — | Lineage marker |

### PACKAGING_AND_RESOURCES — 1 substantive

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `0d03e76` | #29 | include SwiftPM resource bundles in macOS app | RUNTIME_A2 | INTEGRATE | `smoke-packaged-resources.sh`, `package-app-bundle.sh` | Packaged-app gate for #32; must precede A2 acceptance |

### EEG_FOUNDATION — 4 substantive

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `1c0410c` | — | EEG encoder re-alignment scoping | — | INTEGRATE | none (doc) | Records the "gloss only High load" thread |
| `0441c1c` | — | scope mathematics, physics, methods research | — | INTEGRATE | none (doc) | Scope contract for the EEG package |
| `a90a56f` | — | offline encoder benchmark contract | — | INTEGRATE | `NeuralComposeEEG.tests` | Creates the `NeuralComposeEEG` package; base of lane B |
| `3e1b55b` | — | record scope contract audit | — | INTEGRATE | none (doc) | Audit of the above |

### EEG_CAPTURE_CONTRACTS — 1 substantive, 1 merge

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `9726626` | #24 | validate encoder pilot capture integrity | EEG_FOUNDATION | INTEGRATE | `CaptureManifestTests`, `test_session_consume`, `CalibrationRecorderTests` | Capture provenance + protocol runner |
| `47dfdfe` | #24 | *merge* PR #24 | — | KEEP_STAGING_ONLY | — | Lineage marker |

### STRUCTURED_STATE — 2 substantive, 2 merge

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `5a72fd1` | #35 | fail-closed structured-state shadow artifacts | EEG_FOUNDATION | INTEGRATE | `test_structured_state` | Shadow bridge; `shadow_only`/`live_control:false` enforced on write and read |
| `bbeb979` | #35 | immutable and provenance-consistent shadow replay | — | INTEGRATE | `test_structured_state` (20) | Record/manifest binding + pair-level publication |
| `7d1493a` | #35 | *merge* base into structured-state branch | — | KEEP_STAGING_ONLY | — | Lineage marker |
| `54080a6` | #35 | *merge* PR #35 | — | KEEP_STAGING_ONLY | — | Lineage marker |

### QUARANTINE_REVIEW_GOVERNANCE — 6 substantive, 3 merge

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `b8c1336` | #25 | quarantine dialectic replay corpus | — | INTEGRATE | `test_dialectic_corpus_quarantine` | Metadata-only derivatives; content fields only ever SHA-256 digested |
| `c007c2b` | #33 | add local dialectic review | — | INTEGRATE | `test_local_dialectic_review` | Review cascade, commit 1 of 4 |
| `6ae9b96` | #33 | fail closed on review citations | — | INTEGRATE | `test_local_dialectic_review` | Review cascade, commit 2 of 4 |
| `76a90e2` | #33 | fail-closed local review cascade | STRUCTURED_STATE | INTEGRATE | `test_local_open_weight_review` | Review cascade, commit 3 of 4; adds `eligible_for_science:false` |
| `2a8869e` | #33 | record local review governance | — | INTEGRATE | none (doc) | Review cascade, commit 4 of 4 |
| `5117a9e` | #33 | publish shadow replay artifacts outside fixture root | STRUCTURED_STATE | INTEGRATE | `test_local_open_weight_review` | Fixes a fixture collision exposed by `bbeb979` |
| `54e0458` | #25 | *merge* PR #25 | — | KEEP_STAGING_ONLY | — | Lineage marker |
| `13599e4` | #33 | *merge* base into review-clean branch | — | KEEP_STAGING_ONLY | — | Lineage marker |
| `48652e9` | #33 | *merge* PR #33 | — | KEEP_STAGING_ONLY | — | Lineage marker |

### EVAL_CI_STATISTICS — 6 substantive, 5 merge

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `ed843bd` | #36 | resolve NumPy trapezoid compatibility lazily | — | INTEGRATE | `test_eeg_spectral_compat` | Eager `getattr` default broke import on numpy≥2; blocks CI otherwise |
| `bb7dff4` | #37 | run the Python contract suites | all Python lanes | INTEGRATE | self (`python-contracts`) | First Python CI; must precede B–D so they are gated |
| `09ac18a` | #37 | reference issue #38 for deselected eval cases | — | INTEGRATE | none (comment) | Superseded in content by `c1aba1a`, retained as lineage |
| `5f2cf64` | #39 | zero-variance Cohen's d | — | INTEGRATE | `test_eval_stats` | Implementation defect; consolidates 4 duplicate copies |
| `b0695c3` | #40 | attainable exact Mann-Whitney case | — | INTEGRATE | `test_eval_stats` | Test-only; n=3 made the assertion unsatisfiable |
| `c1aba1a` | #41 | pin biased linear CKA across regimes | — | INTEGRATE | `test_embedding_space` | Test + docstring; estimator deliberately unchanged |
| `5488951` | #36 | *merge* PR #36 | — | KEEP_STAGING_ONLY | — | Lineage marker |
| `80d8d8e` | #37 | *merge* PR #37 | — | KEEP_STAGING_ONLY | — | Lineage marker |
| `b8894ee` | #39 | *merge* PR #39 | — | KEEP_STAGING_ONLY | — | Lineage marker |
| `c064bcb` | #40 | *merge* PR #40 | — | KEEP_STAGING_ONLY | — | Lineage marker |
| `41f559a` | #41 | *merge* PR #41 | — | KEEP_STAGING_ONLY | — | Lineage marker |

### TRAJECTORY_AND_SOAK_RESEARCH — 17 substantive

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `4bdc4d5` | — | `analyze_dialectic.py` quantitative baseline | RUNTIME_A2 | INTEGRATE | none committed | Baseline analyzer for ResearchHypothesis |
| `80e9945` | — | soak-001-findings + 8 acceptance criteria | — | INTEGRATE | none (doc) | Durable negative/positive soak evidence |
| `09d0775` | — | `soak-matrix.sh` empirical test matrix | — | INTEGRATE | none committed | Harness for the matrix runs |
| `83cdc67` | — | soak-002-matrix results | — | INTEGRATE | none (doc) | Results record |
| `5ad39d0` | — | Soak 002 matrix aggregate + leak audit | — | INTEGRATE | none | 3 files / 56 KB aggregate JSON, not raw capture; the evidence the findings cite |
| `6e0ce59` | — | inertia + critical-slowing-down | — | INTEGRATE | none committed | Analyzer metric |
| `75dcc1c` | — | Pareto frontier analysis | — | INTEGRATE | none committed | Analyzer metric |
| `2bb1601` | — | soak-003-inertia-pareto | — | INTEGRATE | none (doc) | Results record |
| `b9b902a` | — | `symbolic_drift` (H₂) | — | INTEGRATE | none committed | Hypothesis test |
| `bc4820c` | — | soak-004-symbolic-drift | — | INTEGRATE | none (doc) | Preliminary result |
| `6271ce8` | — | RRB cross-model metric | — | INTEGRATE | none committed | Hypothesis test |
| `f718c61` | — | rhetorical motifs + epistemic orientation (H₃) | — | INTEGRATE | none committed | Hypothesis seed |
| `2258daf` | — | Level of Abstraction (H₄) | — | INTEGRATE | none committed | Hypothesis test |
| `e40fd37` | — | gitignore 1-cell smoke-test runs | — | INTEGRATE | none | Prevents smoke-run artifacts entering history |
| `9fc7fed` | — | state reconstruction goal | — | INTEGRATE | none (doc) | Goal record |
| `c2fa51a` | — | telemetry trajectory reconstruction | — | INTEGRATE | `test_state_reconstruction` | Reconstruction tooling |
| `9fa1850` | — | trajectory hypothesis analysis | — | INTEGRATE | `test_state_trajectory_analysis` | Analysis tooling |

Coverage caveat: most analyzer commits in this lane carry **no committed tests**.
Integration E must not claim a test gate it does not have; see its entry below.

### RUST_PROSODY — 3 substantive

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `b6a60a0` | — | prosody prediction trace contract | RUNTIME_A2 | INTEGRATE | BCICoreTests | Contract lives in `Sources/BCICore`; edits a lane-A-owned tree |
| `ce9799d` | — | trace requested prosody features | RUNTIME_A2 | INTEGRATE | BCICoreTests | Same |
| `3abc2e8` | — | deterministic prosody feature kernel (Rust) | RUNTIME_A2 | INTEGRATE | Rust kernel tests, BCICoreTests | Adds `Rust/prosody_features`; also touches `Sources/BCICore` |

### ARCHITECTURE_DOCUMENTATION — 4 substantive, 1 merge

| SHA | PR | Subject | Dependency lane | Disposition | Validation | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| `0461070` | — | three orthogonal concerns + metric/experiment schema | — | INTEGRATE | none (doc) | Genuinely cross-cutting; not owned by one lane |
| `3e7361a` | — | engineering runtime design (Codex scope) | RUNTIME_A2 | INTEGRATE | none (doc) | Design record preceding the runtime |
| `a29e180` | — | Julia science workspace boundary | — | INTEGRATE | none (doc) | Cross-cutting boundary statement |
| `efde475` | #23 | repair principles links | — | INTEGRATE | link check | Two-line doc repair |
| `900e19e` | #23 | *merge* PR #23 | — | KEEP_STAGING_ONLY | — | Lineage marker |

### Reconciliation

```
RUNTIME_A2                     15 + 1 merge  = 16
PACKAGING_AND_RESOURCES         1            =  1
EEG_FOUNDATION                  4            =  4
EEG_CAPTURE_CONTRACTS           1 + 1 merge  =  2
STRUCTURED_STATE                2 + 2 merge  =  4
QUARANTINE_REVIEW_GOVERNANCE    6 + 3 merge  =  9
EVAL_CI_STATISTICS              6 + 5 merge  = 11
TRAJECTORY_AND_SOAK_RESEARCH   17            = 17
RUST_PROSODY                    3            =  3
ARCHITECTURE_DOCUMENTATION      4 + 1 merge  =  5
                               --------------------
                               59 + 13       = 72
```

Dispositions used: `INTEGRATE` (59), `KEEP_STAGING_ONLY` (13).
Unused: `INTEGRATE_WITH_OWNER_LANE`, `ALREADY_IN_MAIN`, `PATCH_EQUIVALENT_IN_MAIN`,
`SUPERSEDED`, `PARKED_ISSUE_34`, `PENDING_PR_32`, `DROP_GENERATED_ARTIFACT`,
`REQUIRES_DECISION` — see below for why each is empty.

- `ALREADY_IN_MAIN` / `PATCH_EQUIVALENT_IN_MAIN`: `git cherry` found no equivalence.
- `SUPERSEDED`: `09ac18a`'s comment is rewritten by `c1aba1a`, but the commit is
  still integrated as part of the CI lane; no commit is wholly replaced.
- `DROP_GENERATED_ARTIFACT`: the only committed artifacts (`5ad39d0`, `75dcc1c`)
  are 56 KB of aggregate JSON that the soak findings cite as evidence. Dropping
  them would orphan the conclusions.
- `PARKED_ISSUE_34` / `PENDING_PR_32`: neither body of work is in this lineage.
- `REQUIRES_DECISION`: no commit resisted classification.

## Main-only commits — 9 of 9 assessed

All from PR #22 (`worldmodel/overnight-transform-ab`), all under `WorldModel/`.

| SHA | Subject | Conflict risk vs staging |
| --- | --- | --- |
| `9c0807c` | ledger node 7 — standardize arm is the baseline | None — no staging commit touches `WorldModel/` |
| `64506f9` | integrate symlog input-space arm (node 8) | None |
| `eed39d4` | ledger node 9 — symlog A/B forward-metric-neutral | None |
| `d5feeb6` | expose CEM knobs, pivot to MPC (node 10) | None |
| `59ff263` | ledger node 11 — CEM budget not the bottleneck | None |
| `385c72c` | ledger node 12 — more predictor capacity HURTS control | None |
| `5a0d4ed` | ledger node 13 — epochs vs latent dissociate | None |
| `54bc076` | PR #22 code-review — provenance + real-data symlog | None |
| `d0f3867` | *merge* PR #22 | None |

Staging is 9 behind main solely because of this lane. Integration branches cut
from current `main` inherit it automatically; no forward-merge of main into
staging is required for this manifest to hold.

## File-ownership matrix

| Path or path family | Primary lane | Secondary consumers | Conflict risk | Required tests |
| --- | --- | --- | --- | --- |
| `Package.swift` | RUNTIME_A2 | RUST_PROSODY, PACKAGING | **High** — touched by `84e5dee` and `6b8d1e4`; any lane adding a target edits it | `swift build` |
| `README.md` | ARCHITECTURE_DOCUMENTATION | TRAJECTORY, RUST_PROSODY, EEG_FOUNDATION | **High** — 5 commits across 4 lanes append sections | none |
| `.github/workflows/ci.yml` | EVAL_CI_STATISTICS | every lane | **High** — `bb7dff4`, `09ac18a`, `5f2cf64`, `b0695c3`, `c1aba1a` all edit it serially | self |
| `Scripts/package-app-bundle.sh`, `smoke-packaged-resources.sh` | PACKAGING_AND_RESOURCES | RUNTIME_A2 | Low | packaged-resource smoke |
| `Sources/BCICloudBridge/` | RUNTIME_A2 | — | Low — single-lane | BCICloudBridgeTests |
| `Sources/BCICore/Composition/` | RUNTIME_A2 | — | Low | BCICoreTests |
| `Sources/BCICore/Protocols/` | RUNTIME_A2 | RUST_PROSODY | **Medium** — prosody trace contract lands here | BCICoreTests |
| `Sources/BCICore/Telemetry/` | RUNTIME_A2 | QUARANTINE (reads `DialecticalTurnEvent`) | Medium | BCICoreTests |
| `Sources/NeuralComposeApp/AppViewModel.swift` | RUNTIME_A2 | — | **Medium** — `eb1e373`, `d354fe9`, `a6751e7`; also carries local uncommitted work | NeuralComposeAppTests |
| `Sources/DialecticSession/` | RUNTIME_A2 | — | Low | DialecticSessionTests |
| `Sources/DialecticSmoke/` | RUNTIME_A2 | — | Low | — |
| `NeuralComposeEEG/` | EEG_FOUNDATION | CAPTURE_CONTRACTS, STRUCTURED_STATE | Medium — three lanes extend one package | `NeuralComposeEEG.tests` (53) |
| `Evaluation/scripts/` | EVAL_CI_STATISTICS | TRAJECTORY | Medium — `eval_stats.py` is now the shared home for `cohens_d` | `test_eval_stats`, `test_embedding_space` |
| `Tests/eval/` | EVAL_CI_STATISTICS | QUARANTINE, STRUCTURED_STATE, TRAJECTORY, CAPTURE | **High** — 9 commits from 5 lanes | `pytest Tests/eval` (89) |
| `Scripts/analyze_dialectic.py` | TRAJECTORY_AND_SOAK_RESEARCH | — | Low — single-lane, 5 sequential commits | none committed |
| `SoakRuns/` | TRAJECTORY_AND_SOAK_RESEARCH | — | Low | none |
| `Rust/prosody_features/` | RUST_PROSODY | — | Low | Rust kernel tests |
| `docs/architecture/` | ARCHITECTURE_DOCUMENTATION | all | Medium — 10 commits, several lane-specific | none |
| `docs/evaluation/` | ARCHITECTURE_DOCUMENTATION | RUNTIME_A2 (`a2-apple-silicon-acceptance.md` is #32's) | Medium | none |
| `docs/science/`, `docs/scoping/`, `docs/rvs/`, `docs/seeds/`, `docs/reviews/` | ARCHITECTURE_DOCUMENTATION | owning lanes | Low | none |

**Cross-lane owners.** Three files need a single named owner before any
integration PR opens, because independently reasonable lanes would otherwise
edit them concurrently:

| File | Integration owner | Rule for other lanes |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Integration D | A–C and E–G may not edit it; D lands the final job definition once |
| `Package.swift` | Integration A | Any later lane adding a target appends in its own PR after A merges |
| `README.md` | Integration G | Earlier lanes omit their README hunks; G reconciles all sections last |

## Proposed integration graph

Proposed only. No branch below exists yet, and none may be cut before PR #32
merges and this manifest's staging snapshot is refreshed.

```
current main
│
├── Integration A: runtime foundation + packaging + A2
│
├── Integration B: NeuralComposeEEG foundation and capture contracts
│   │
│   ├── Integration C: structured-state + quarantine + review governance
│   │
│   └── Integration D: Python CI + evaluation/statistics corrections
│
├── Integration E: trajectory, soak, and offline analysis tooling
│
├── Integration F: Rust prosody research kernel
│
└── Integration G: remaining architecture/research documentation
```

| Integration | Lanes | Commits | Test gate |
| --- | --- | ---: | --- |
| A | RUNTIME_A2, PACKAGING_AND_RESOURCES, + PR #32 A–G | 16 + #32 | `swift build`; BCICore/BCICloudBridge/DialecticSession/NeuralComposeApp suites; `package-app-bundle.sh`; `smoke-packaged-resources.sh`; `codesign --verify --deep --strict`; #32 operator matrix |
| B | EEG_FOUNDATION, EEG_CAPTURE_CONTRACTS | 8 | `NeuralComposeEEG.tests`; `test_session_consume`; `CalibrationRecorderTests` |
| C | STRUCTURED_STATE, QUARANTINE_REVIEW_GOVERNANCE | 13 | `test_structured_state`; `test_dialectic_corpus_quarantine`; `test_local_dialectic_review`; `test_local_open_weight_review` |
| D | EVAL_CI_STATISTICS | 11 | `pytest Tests/eval` with **zero** deselections; `python-contracts` job green |
| E | TRAJECTORY_AND_SOAK_RESEARCH | 17 | `test_state_reconstruction`; `test_state_trajectory_analysis` — **and nothing else; see below** |
| F | RUST_PROSODY | 3 | Rust kernel tests; BCICoreTests |
| G | ARCHITECTURE_DOCUMENTATION | 5 | none; README reconciliation |

**Ordering constraints, not preferences.**

- D must land before or with B and C in CI terms: without `bb7dff4` no Python
  suite runs at all, so B and C would merge ungated. If D cannot precede them,
  B and C must carry their own temporary CI wiring rather than merge unverified.
- D also depends on `ed843bd`: `Tests/eval` cannot even import `eeg_spectral`
  on numpy≥2 without it.
- C depends on B (`NeuralComposeEEG` package) and on `5a72fd1` for the review
  cascade's replay test.
- A must include PR #32; splitting #32 across integrations would break its
  bisect-safe A–G identities, which its acceptance record names.
- F edits `Sources/BCICore`, owned by A. F follows A.

**Splits this inventory recommends.**

- **E should split.** Seventeen commits spanning a soak harness, six analyzer
  metrics, four findings documents, and two trajectory tools is not one
  reviewable change. Suggested: E1 harness + artifacts (`09d0775`, `5ad39d0`,
  `e40fd37`, `75dcc1c`), E2 analyzer metrics (`4bdc4d5`, `6e0ce59`, `b9b902a`,
  `6271ce8`, `f718c61`, `2258daf`), E3 trajectory tooling (`9fc7fed`, `c2fa51a`,
  `9fa1850`), E4 findings documents (`80e9945`, `83cdc67`, `2bb1601`, `bc4820c`).
- **C may split** along its two lanes if review load warrants; the dependency
  runs one way (review cascade → structured state), so C1 structured-state and
  C2 quarantine/review is safe.

A–D may not be collapsed into one PR merely because they share staging history.

## Known coverage gap, recorded rather than hidden

Integration E's analyzer commits ship **no committed tests**. `analyze_dialectic.py`
accumulated six metrics (`6e0ce59`, `b9b902a`, `6271ce8`, `f718c61`, `2258daf`,
and the Pareto work in `75dcc1c`) across five commits with no test file, and the
findings documents in `docs/rvs/` cite their numeric output.

That is not a blocker for integration — the work is research tooling and its
outputs are already published as findings — but E's PR description must state
the gap rather than list a test gate it does not have. If a gate is wanted
before mainline, it should be a separate follow-up, not an unstated assumption.

## Inventory acceptance criteria

| Criterion | Status |
| --- | --- |
| 72 of 72 staging commits classified | Met — see reconciliation |
| 9 of 9 main-only commits assessed for conflicts | Met — all `WorldModel/`, zero overlap |
| All changed files have a primary lane | Met — file-ownership matrix |
| All cross-lane files have an integration owner | Met — `ci.yml` → D, `Package.swift` → A, `README.md` → G |
| All superseded work names its replacement | Met — no wholly-superseded commits; `09ac18a`'s comment rewrite noted |
| All parked work names its tracking issue | Met — issue #34, not in this lineage |
| All proposed PRs list their exact test gates | Met — integration table; E's gap stated |
| No direct staging merge proposed | Met |
| No code cherry-picked | Met — classification only |
| No source branch modified | Met — worktree cut from `origin/main`, read-only against staging |

## Refresh triggers

This manifest is invalidated by any of:

- PR #32 merging (expected; adds A–G to Integration A)
- any new commit on `docs/eeg-methods-scope` (soft freeze in effect)
- any new commit on `main`
- issue #34 being unparked

On refresh, re-run the capture commands in
`.handoff/integration/eeg-methods-scope/` and update the snapshot SHAs, the
staging/main commit counts, and any affected rows.
