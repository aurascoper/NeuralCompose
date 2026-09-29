# Engineering Runtime — Design Document

> **Status:** Draft (2026-07-22). This doc *scopes* the
> Engineering Runtime layer. It does not implement
> anything. The implementation is gated on the
> architecture review's sequencing:
> LiveRuntimeFactory env-var fix → merge →
> add CodexRuntime behind stable interfaces →
> open `feature/research-hypotheses` *only after*
> the engineering substrate is stable.

## 1. Purpose

NeuralCompose has matured from "an AI application" into
"an experimental platform" with three orthogonal concerns
(see `three-orthogonal-concerns.md`). The **Engineering
Runtime** is the layer that accelerates the *Engineering*
concern without touching the *Science* concern.

Concretely: there is a class of software work —
refactors, test generation, API migrations, documentation
synchronization, boilerplate, interface conformance,
benchmark implementation, code review — that is:

  - **Deterministic** (pass/fail criteria exist)
  - **Bounded** (single-file or single-module scope)
  - **Specifiable** (a human can write down what "done"
    means before invoking the runtime)
  - **Reviewable** (a diff can be inspected in minutes)

These are *engineering* tasks, not *research* tasks. They
have objective validation. They do not invent
hypotheses, design metrics, or interpret experimental
results.

The Engineering Runtime is the layer that handles these
tasks behind a stable interface, with full telemetry,
under a strict usage budget, with mandatory human review
before any output reaches the codebase.

## 2. Scope

### What the Engineering Runtime IS

  - A software-modification backend (analogous to how
    `GenerationRuntime` is a language-generation backend)
  - Bounded by an explicit `Task` schema (target files,
    constraints, acceptance criteria)
  - Produces a `Patch` (focused diff) plus verification
    artifacts (build output, test results, lint output)
  - Fully subordinated to the Engineering concern:
    implements what the human asks, does not decide
    what to ask
  - Telemetry-equivalent: every invocation records
    runtime, model, latency, patch size, build status,
    test pass rate, review iterations
  - Pluggable: Codex, Claude Code, Hermes, MiniMax, and
    a Human-run variant all sit behind the same
    `ImplementationRuntime` interface

### What the Engineering Runtime IS NOT

  - **Not a researcher.** It does not write
    `ResearchHypothesis` YAMLs, choose experiment
    parameters, name research questions, or
    interpret benchmark results.
  - **Not an architect.** It does not modify the runtime
    architecture, change cross-concern contracts (metric
    ids, runtime interfaces, telemetry schema), or
    substitute one `GenerationRuntime` for another.
  - **Not a decision-maker.** It does not approve
    experiments, modify metric contracts, change
    acceptance criteria, or commit to `main`.
  - **Not autonomous.** It does not commit, push, or
    merge. Every output is human-reviewed.
  - **Not a dialogue participant.** It is not a
    `GenerationRuntime`; dialogue metrics do not
    apply to it.

## 3. Non-goals

These are *forbidden* behaviors for any `ImplementationRuntime`:

  - **No merge to `main`** by any implementation runtime
  - **No approving experiments** (an ADR-style approval
    process remains human-only)
  - **No modifying metric contracts** (the four
    behavioral axes in `docs/evaluation/metrics.md` are
    frozen; changes require an ADR-style proposal)
  - **No changing acceptance criteria** (hypotheses
    can be *evaluated* by an implementation runtime,
    but the criteria are human-authored)
  - **No autonomous commits** — every change is
    human-reviewed
  - **No inventing research questions** — the
    Experiment schema in `docs/evaluation/experiments.md`
    is human-authored

The reason for these non-goals: the *scientific judgment*
lives in the Science concern. An implementation runtime
that crosses into the Science concern (e.g., by
interpreting benchmark results) destroys the falsifiability
discipline.

## 4. Interfaces

The interface boundary between the Engineering concern
and the Computation concern is `ImplementationRuntime`:

```text
  Task                  (the input spec)
      │
      ▼
  ImplementationRuntime
      │   (Codex, Claude Code, Hermes, MiniMax, Human)
      │
      ▼
  Patch                 (focused diff)
      │
      ▼
  Build                 (compiler / linker output)
      │
      ▼
  Tests                 (test pass/fail)
      │
      ▼
  Telemetry             (runtime, model, latency, size)
      │
      ▼
  Human Review          (mandatory)
      │
      ▼
  Merge                 (human-only)
```

### `Task` schema

```yaml
task:
  id: TASK-001
  type: refactor | test | docs | api_migration | benchmark | small_fix

  target:
    files: [Sources/Foo/Bar.swift]
    module: BCICore
    preserve_contracts: [protocols/TextGenerating]

  spec: |
    Detailed specification. What the change must do,
    what it must preserve, what it must not touch.

  acceptance:
    - tests_passing: existing test suite
    - new_tests: optional, if added
    - contract_preserved: list of contracts that
      must not change
    - diff_size_max: 200 lines (soft cap)

  forbidden:
    - no_runtime_architecture_changes
    - no_metric_contract_changes
    - no_new_dependencies
```

### `Patch` schema

```yaml
patch:
  task_id: TASK-001
  runtime: codex | claude-code | hermes | minimax | human
  model: gpt-5-codex | claude-sonnet-5 | ... | human-aurascoper
  created_at: 2026-07-22T00:30:00Z

  diff: |
    unified diff text

  artifacts:
    build:
      status: success | failure
      output: build log
    tests:
      passed: 350
      failed: 0
      skipped: 1
    lint:
      warnings: 1
      errors: 0

  summary: |
    One-paragraph description of what changed.
```

### Telemetry

Every `ImplementationRuntime` invocation emits:

  - `runtime` (codex, claude-code, hermes, etc.)
  - `model` (the specific model used)
  - `latency_ms` (time from task submission to patch)
  - `patch_lines` (diff size)
  - `build_status` (success/failure)
  - `tests_passed`, `tests_failed`, `tests_skipped`
  - `review_iterations` (how many human review cycles)
  - `merge_status` (merged / rejected / pending)

This telemetry is *parallel* to the four-axis behavioral
fingerprint of the dialogue runtime. It enables
comparative evaluation of engineering runtimes (see §6).

## 5. Governance

### Usage budget

```yaml
engineering_runtime:

  codex:
    weekly_budget:
      requests: 25          # explicit ceiling
    monthly_budget:
      requests: 100         # explicit ceiling

    allowed_tasks:
      - refactor
      - tests
      - docs
      - benchmarks
      - api_migration
      - small_fix
      - code_review
      - static_analysis

    prohibited:
      - merge_to_main
      - approve_experiment
      - modify_metric_contracts
      - change_acceptance_criteria
      - invent_research_question
      - autonomous_commit
      - push_to_remote
```

The budget is *explicit* and *auditable*. The
implementation runtime's telemetry can be checked
against the budget weekly. A runtime that exceeds
its budget is paused for review.

### Review requirement

Every `Patch` from any `ImplementationRuntime` requires
human review before merge. The review is:

  - **Mandatory** — no exceptions
  - **Diff-based** — the reviewer reads the diff, not
    the runtime's narrative summary
  - **Test-verified** — the reviewer confirms the
    `tests` artifact shows the expected pass/fail
    pattern
  - **Contract-verified** — the reviewer confirms the
    `preserve_contracts` list is honored

A patch that fails any of these checks is rejected,
not modified by the runtime. The next patch is a
*new* task, not a continuation.

### Telemetry retention

All `Patch` records are committed to the repository
(under `docs/implementation-responses/` or similar) for
auditability. Telemetry is a public artifact of the
process, not a private log.

## 6. Evaluation

The Engineering Runtime layer has its own evaluation
framework, *parallel* to (and intentionally separate
from) the four-axis behavioral fingerprint of the
dialogue runtime.

### Engineering metrics

| metric                  | what it measures                          |
|-------------------------|-------------------------------------------|
| `build_success_rate`    | patches that build without errors         |
| `test_pass_rate`        | patches that pass the existing test suite |
| `regression_rate`       | patches that introduce new test failures   |
| `review_iterations`     | how many review cycles before merge       |
| `time_to_completion`    | latency from task to merged patch         |
| `patch_size`            | diff line count (proxy for invasiveness)  |
| `contract_violations`   | patches that break preserved contracts    |
| `budget_utilization`    | requests used vs budget                   |

### Comparative evaluation

Once multiple `ImplementationRuntime`s are in use
(Codex, Claude Code, Hermes, Human), they can be
compared on these metrics. The framing mirrors the
cross-model RRB / motifs / LoA comparison for dialogue
runtimes:

| implementation | build | tests | regression | iterations | time | size |
|----------------|------:|------:|-----------:|-----------:|-----:|-----:|
| Codex          |  ...  |  ...  |    ...     |    ...     |  ... |  ... |
| Claude Code    |  ...  |  ...  |    ...     |    ...     |  ... |  ... |
| Hermes         |  ...  |  ...  |    ...     |    ...     |  ... |  ... |
| Human          |  ...  |  ...  |    ...     |    ...     |  ... |  ... |

This is the *long-term evolution* the user named. It
requires multiple runtimes in active use; the
*initial* rollout is just Codex (gated on the
sequencing in §7).

### What evaluation is NOT

  - **Not scientific conclusions.** Engineering
    metrics measure engineering quality, not
    scientific quality. A patch that makes the
    build faster is not a scientific result.
  - **Not a substitute for the four-axis behavioral
    fingerprint.** Dialogue metrics measure dialogue
    behavior; engineering metrics measure engineering
    behavior. They are *parallel*, not interchangeable.
  - **Not a permission to override the human.** A
    runtime with high `build_success_rate` and low
    `regression_rate` is still not allowed to merge
    autonomously.

## 7. Sequencing

Per the architecture review (2026-07-21), the rollout
is:

  1. **Finish the `LiveRuntimeFactory` env-var fix** —
     the live app and harness share the same runtime
     selection path.
  2. **Merge `feature/pluggable-generators` into
     `main`** — the runtime path is unified.
  3. **Add `CodexRuntime` behind the existing
     `ImplementationRuntime` interface** with the
     strict usage budget and full telemetry defined
     in §4-5.
  4. **Open `feature/research-hypotheses`** only
     after the engineering substrate is stable.

Codex joins an already-mature system. It does not
become a moving part during stabilization.

## 8. Why this is not just "another AI tool"

The Engineering Runtime is a *layer* with stable
interfaces, measurable outcomes, and human oversight.
It is not:

  - A replacement for human engineering judgment
  - A source of architectural decisions
  - A shortcut past the experimental framework
  - A privileged component of the research platform

The four hard limits (no merge, no approve, no metric
modification, no autonomous commit) are what keep it
*useful* rather than *disruptive*. An engineering
runtime that crosses any of those limits stops being
a tool and starts being a stakeholder — and the
platform has no mechanism for managing AI stakeholders.

The Engineering Runtime stays a tool by staying
subordinate to the human engineering process.

Refs: `docs/architecture/three-orthogonal-concerns.md`;
`docs/evaluation/metrics.md`; `docs/evaluation/experiments.md`;
the architecture review on 2026-07-21; the proposed
sequencing in `feature/pluggable-generators`'s open
issue list.
