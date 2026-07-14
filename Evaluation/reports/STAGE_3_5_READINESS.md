# Stage 3.5 Readiness Assessment

**Date:** 2026-07-14
**Question:** Is the program ready to begin Stage 3.5 (pipeline engineering — routing, cascades, confidence gating, policy comparison)?

## Verdict: YES — with two conditions requiring human sign-off first

All structural prerequisites are met: both benchmark tracks terminal (17/17 embedding, 18/18 generation), RQ1 runtime equivalence confirmed (4/4 comparisons, cosine 1.000000), validator clean (0 failures), corpora and evidence frozen and checksummed (`Evaluation/stage_3_4/frozen/`), registries synchronized, docs synced to frozen numbers.

**Condition 1 — accept or extend the reproducibility finding.** Generation quality metrics are nondeterministic beyond the approved 0.005 tolerance (Δinstruction-following up to 0.2 run-to-run; `repro_report.md`). The mechanical exit report therefore refuses to declare closure. Either (a) sign off that the variance is a documented condition and close Stage 3.4, or (b) request a variance-characterization addendum (≈5 repro runs, ~30 min machine time) before closing. Stage 3.5 design must respect the band either way — see Risks.

**Condition 2 — resolve decision-registry entry #2.** The frozen leaderboard ranks tinyllama-1.1b #1 (0.843) over the current default qwen2.5-0.5b (0.801), but the gap sits inside the observed quality-metric variance and qwen has half the RSS (707 vs 1455 MB). Stage 3.5 policy work binds `auto:*` roles to leaderboard positions, so this default should be settled (or explicitly delegated to the policy layer) before routing experiments encode it.

## Justification

- Stage 3.5's core need is a trustworthy, frozen, traceable evidence base to bind policies against. That now exists, machine-verified end to end (checkpoint → leaderboard within 1e-6; frozen checksums verify).
- The policy registry is internally complete (4 policies, latency budgets 2.0/5.0/15.0/per-query, abstract `auto:*` bindings) and versioned inside the frozen registry snapshot.
- RQ1 removes the biggest architectural unknown for routing: runtimes agree numerically, so a router can treat backend choice as a pure perf/memory decision, not a semantics risk (within the tested fp32 scope).

## Risks

1. **Quality-delta illusions.** Any 3.5 experiment that selects models on quality deltas smaller than the observed variance bands (±0.014 meaning, ±0.06 stability, ±0.2 instruction-following) will chase noise. Mitigation: multi-run medians for generation metrics, or restrict routing signals to the reproducible metrics (latency, RSS, embedding quality).
2. **Perf numbers are load-dependent** (2.5× throughput swing observed). Policies with latency budgets must be validated under realistic concurrent load (EEG pipeline + classifier running), not quiescent-machine numbers.
3. **RQ2/RQ3 are pilots** — geometry/agreement conclusions are not decision-grade; do not let 3.5 routing heuristics silently assume them.
4. **Uncommitted GenerationEval source** (tech-debt #1) — commit before 3.5 builds on that harness.

## Suggested ordering (effort → payoff)

1. Human sign-offs above (minutes; unblocks everything).
2. Commit `Sources/GenerationEval/` + Package.swift hunks (small; closes the reproducibility gap).
3. 3.5-P policy comparison offline (uses only frozen evidence + registry bindings; no production code) — highest payoff/effort ratio, and it operationalizes the frozen leaderboards.
4. 3.5-B adaptive routing offline study (needs 3.5-P baselines).
5. 3.5-D cascade evaluation (candidate set from the frozen leaderboard, not assumed gemma-3n-e2b — see decision registry entry #3).
6. Optionally revisit 3.4-B/F (joint embeddings) — still deferred, becomes more attractive once 3.5-P quantifies retrieval-quality headroom.

**Confidence in this assessment:** Medium-high. The evidence base is strong and verified; the two open conditions are judgment calls that belong to the program owner, and nothing in Stage 3.5's first step (offline policy comparison) is technically blocked once they are made.

**Hard boundary honored:** no Stage 3.5 implementation exists — no routing, cascades, confidence gating, or policy execution code was written during closure.
