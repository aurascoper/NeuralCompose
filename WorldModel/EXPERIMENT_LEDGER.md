# WorldModel Experiment Ledger

The durable, reviewable record for the WorldModel `/loop` (see
`~/.claude/plans/check-recent-commits-and-cosmic-babbage.md` for the contract). One entry per milestone —
captures *why* the work happened, not just *what* changed. A **negative result is a successful experiment.**

Sequence: **Integrate → Benchmark → Optimize → Stop.** The loop resumes from the last entry below.

Entry template:
```
## <n> — <short title>  (<date>, commit <sha>)
- Category: Integrate | Benchmark | Test | Optimize | Document
- Hypothesis:
- Prediction:
- Implementation:      (files touched; provenance: ported-from / reason / differences)
- Evidence:            (measured numbers — smoke-test result and/or benchmark metric vs baseline)
- Decision:            (kept / rejected / deferred — and why)
- Next question:
```

---

## 0 — Groundwork (2026-07-20, commit <pending>)
- Category: Document
- Hypothesis: n/a — establishing the scientific grounding + ledger before touching code.
- Implementation: added `WorldModel/RESEARCH_spectral_geometry.md` (the deep-research brief distilled: 1/f may
  be *signal*; the forward metric panel; the decision rule; geometry as a future/out-of-scope direction) and
  this ledger.
- Evidence: n/a (docs only).
- Decision: kept — the loop reads the research doc rather than re-deriving it.
- Next question: Phase A — cherry-pick the backward-validated 1/f transform (`0102e19` clip_sigma → `d3898c2`
  1/f) onto the working branch, prove default-off = identity, and document that "validated" is *backward
  only* (safe, not beneficial).

## 1 — Integrate the 1/f transform (Phase A) (2026-07-20, commits fa7647b + ea0afbc)
- Category: Integrate
- Hypothesis: the transform can be brought onto the working branch without changing default behavior
  ("default-off = identity"), preserving its backward-validation guards.
- Prediction: cherry-picks apply cleanly (both touch only `eeg_jepa.py`); smoke-test stays green; default
  outputs are unchanged for well-behaved data.
- Implementation: `git cherry-pick 0102e19` (clip_sigma cap) → `git cherry-pick d3898c2` (1/f log-transform),
  authorship preserved. Provenance: ported-from `fix/preflight-gates-2-3`; reason = reuse the
  backward-validated normalizer; differences = none (clean cherry-pick, no conflicts).
- Evidence:
  - `python WorldModel/eeg_jepa.py --smoke-test` → **passed** (finite under log(0), bounded by clip_sigma,
    export round-trip — the log-feature path included).
  - Golden-vector identity: on deterministic `_smoke_record` data, `default(clip=8, log=off)` ≡ `no-clip`
    (**identical=True**, `max|z|=1.617 ≪ 8`); mean/std raw-space identical (log off). → **default = identity in
    practice**; `clip_sigma` fires only for >8σ near-dead-channel outliers (its intended guard).
- Decision: **kept** (default-off, integrated). Status labelled **"hypothesis under test," not "validated"** —
  the only evidence is *backward* (safe), never *forward* (beneficial). README + research doc updated to say so.
- Next question: Phase B — build a controllable synthetic 1/f generator (dial-able aperiodic exponent + known
  latent factors) and the forward metric panel, so the transform can finally be A/B'd on a *forward* number,
  with the aperiodic-exponent-recovery guard. **A negative result ("log-compression hurts on 1/f-dependent
  factors") is the target-quality outcome.**
