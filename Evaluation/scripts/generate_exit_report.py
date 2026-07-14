#!/usr/bin/env python3
"""
Stage 3.4 exit report — the canonical handoff between the scientific
evaluation phase (Stage 3.4) and the engineering phase (Stage 3.5).

Generated from primary artifacts only (hypothesis registry, leaderboards,
stage_3_4 analyses, validator, repro report) — it never invents a verdict a
source artifact can't support, and it states explicitly when evidence is
incomplete. Regenerate after any change to the evidence base:

  python3 Evaluation/scripts/generate_exit_report.py

Output: Evaluation/reports/STAGE_3_4_EXIT_REPORT.md

Verdict semantics (per research question):
  GO                  — evidence collected, success criterion evaluable,
                        no unresolved caveat blocks reliance on it
  GO-WITH-CONDITIONS  — evidence exists but carries recorded caveats
                        (pilot N, missing models); usable with the caveat
                        attached to every downstream decision
  NO-GO               — evidence absent or untrustworthy; the RQ returns
                        to Gate A (collection), it does not proceed
  DEFERRED            — explicitly out of scope for Stage 3.4 by design
                        (RQ5: joint embeddings / fusion)
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from provenance import collect_provenance

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
CORPORA_DIR = EVAL_DIR / "corpora"
RESULTS_DIR = EVAL_DIR / "results"
EMBEDDINGS_DIR = RESULTS_DIR / "embeddings"
CANDIDATES_DIR = RESULTS_DIR / "candidates"
STAGE_DIR = RESULTS_DIR / "stage_3_4"
REPORT_PATH = EVAL_DIR / "reports" / "STAGE_3_4_EXIT_REPORT.md"

# RQ -> hypothesis ids (docs/evaluation/STAGE_3_4_3_5_DESIGN.md work packages)
RQ_MAP = [
    ("RQ1", "Runtime equivalence", ["3.4-A-runtime-consistency"]),
    ("RQ2", "Embedding-space geometry", ["3.4-C-embedding-space"]),
    ("RQ3", "Cross-model agreement", ["3.4-D-cross-model-agreement"]),
    ("RQ4", "Generator comparison", ["3.4-E-generator-comparison"]),
    ("RQ5", "Joint representations (deferred by design)",
     ["3.4-B-joint-embeddings", "3.4-F-offline-fusion"]),
]


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def run_validator():
    import validate_checkpoints as vc
    report = vc.Report(strict=False)
    vc.check_corpora(report)
    vc.check_embedding_checkpoints(report)
    vc.check_generation_checkpoints(report)
    vc.check_embedding_traceability(report)
    vc.check_generation_traceability(report)
    return report


def rq_verdict(rq_id, hypotheses, cross_runtime):
    """Deterministic verdict from registry status + analysis artifacts."""
    if rq_id == "RQ5":
        return "DEFERRED", "pre-registered by design; joint_embeddings.py not yet implemented"
    statuses = {h["id"]: h for h in hypotheses}
    if rq_id == "RQ1":
        h = statuses.get("3.4-A-runtime-consistency", {})
        n = (cross_runtime or {}).get("n_comparisons", 0)
        if h.get("status") == "blocked" and not n:
            return "NO-GO", h.get("status_note", "blocked, no comparisons")
        if n:
            caveat = h.get("status_note")
            return ("GO-WITH-CONDITIONS" if caveat else "GO",
                    f"{n} cross-runtime comparison(s) on disk"
                    + (f"; {caveat}" if caveat else ""))
        return "NO-GO", "no cross-runtime comparisons on disk"
    # RQ2-4: single hypothesis each
    h = hypotheses[0]
    status = h.get("status")
    note = h.get("status_note", "")
    if status == "evaluated":
        if note:
            return "GO-WITH-CONDITIONS", note
        return "GO", "evaluated, no recorded caveats"
    if status == "blocked":
        return "NO-GO", note or "blocked"
    return "NO-GO", f"status is '{status}' — evidence not collected"


def track_completion():
    emb_fixture = load_json(CORPORA_DIR / "embedding_bench_candidates_v1.json") or {}
    emb_total = len(emb_fixture.get("candidates", []))
    emb_eval, emb_failed = [], []
    for cand in emb_fixture.get("candidates", []):
        name = cand["name"]
        results = list((EMBEDDINGS_DIR / name).glob("*/benchmark.json"))
        if any(str((load_json(p) or {}).get("status")) == "evaluated" for p in results):
            emb_eval.append(name)
        elif results:
            causes = {(load_json(p) or {}).get("failure_reason")
                      or str((load_json(p) or {}).get("status", ""))[:60]
                      for p in results}
            emb_failed.append((name, "; ".join(sorted(str(c) for c in causes))))
    gen_fixtures = sorted(CORPORA_DIR.glob("generation_eval_candidates_v*.json"),
                          reverse=True)
    gen_fixture = load_json(gen_fixtures[0]) if gen_fixtures else {}
    gen_eval, gen_failed = [], []
    for cand in (gen_fixture or {}).get("candidates", []):
        name = cand["name"]
        raw = load_json(CANDIDATES_DIR / name / "raw.json")
        if raw and raw.get("candidates") and raw["candidates"][0].get("status") == "evaluated":
            gen_eval.append(name)
        else:
            meta = load_json(CANDIDATES_DIR / name / "metadata.json") or {}
            reason = ("unavailable: " + cand.get("unavailable_reason", "")[:60]
                      if cand.get("unavailable") else meta.get("error") or "pending")
            gen_failed.append((name, str(reason)))
    return {
        "embedding": {"total": emb_total, "evaluated": emb_eval, "failed": emb_failed},
        "generation": {"total": len((gen_fixture or {}).get("candidates", [])),
                       "evaluated": gen_eval, "failed": gen_failed},
    }


def main():
    registry = load_json(CORPORA_DIR / "hypothesis_registry.json") or {}
    by_id = {h["id"]: h for h in registry.get("stage_3_4", [])}
    cross_runtime = load_json(STAGE_DIR / "cross_runtime_consistency.json")
    emb_lb = load_json(EMBEDDINGS_DIR / "leaderboard.json") or {}
    gen_lb = load_json(RESULTS_DIR / "leaderboard.json") or {}
    repro = load_json(RESULTS_DIR / "repro" / "repro_report.json")
    completion = track_completion()
    validator = run_validator()
    prov = collect_provenance()

    lines = ["# Stage 3.4 Exit Report", ""]
    lines.append(f"**Generated:** {datetime.now(timezone.utc).isoformat()} — by "
                 f"`generate_exit_report.py` from primary artifacts (do not hand-edit)")
    lines.append(f"**Git:** `{prov['git_commit'][:12]}` on `{prov['git_branch']}`"
                 + (" (dirty)" if prov["git_dirty"] else ""))
    lines.append(f"**Machine:** {prov['device']}, macOS {prov['macos_version']}, "
                 f"{prov['ram_gb']} GB")
    lines.append("")

    # --- RQ status ---
    lines.append("## Research question status")
    lines.append("")
    lines.append("| RQ | Question | Verdict | Basis |")
    lines.append("|----|----------|---------|-------|")
    verdicts = {}
    for rq_id, title, hyp_ids in RQ_MAP:
        hyps = [by_id[h] for h in hyp_ids if h in by_id]
        verdict, basis = rq_verdict(rq_id, hyps, cross_runtime)
        verdicts[rq_id] = verdict
        lines.append(f"| {rq_id} | {title} | **{verdict}** | {basis} |")
    lines.append("")

    # --- Hypothesis status ---
    lines.append("## Hypothesis status (Stage 3.4 registry)")
    lines.append("")
    lines.append("| Hypothesis | Status | Success criterion | Note |")
    lines.append("|------------|--------|-------------------|------|")
    for h in registry.get("stage_3_4", []):
        lines.append(f"| {h['id']} | {h['status']} | {h['success_criterion']} "
                     f"| {h.get('status_note', '')} |")
    lines.append("")

    # --- Evidence summary ---
    emb, gen = completion["embedding"], completion["generation"]
    lines.append("## Evidence summary")
    lines.append("")
    lines.append(f"- **Embedding track:** {len(emb['evaluated'])} of {emb['total']} "
                 f"candidates evaluated; {len(emb['failed'])} terminal failures "
                 f"(recorded with causes below)")
    lines.append(f"- **Generation track:** {len(gen['evaluated'])} of {gen['total']} "
                 f"candidates evaluated; {len(gen['failed'])} failed/unavailable/pending")
    if emb_lb.get("candidates"):
        top = emb_lb["candidates"][0]
        lines.append(f"- **Embedding leaderboard #1:** {top['name']} ({top['runtime']}), "
                     f"score {top.get('overall_score', 0):.3f} of "
                     f"{emb_lb.get('n_candidates')} entries")
    if gen_lb.get("candidates"):
        top = gen_lb["candidates"][0]
        lines.append(f"- **Generation leaderboard #1:** {top['name']}, "
                     f"score {top.get('overall_score', 0):.3f} of "
                     f"{gen_lb.get('n_candidates')} entries")
    for name in ("cross_runtime_consistency", "cross_model_agreement",
                 "embedding_space_analysis", "generator_comparison"):
        exists = (STAGE_DIR / f"{name}.md").exists()
        lines.append(f"- `results/stage_3_4/{name}.md`"
                     + ("" if exists else " *(missing)*"))
    lines.append("")

    # --- Blocked work ---
    lines.append("## Blocked / failed work (recorded evidence, not silently dropped)")
    lines.append("")
    for name, cause in emb["failed"]:
        lines.append(f"- embedding/{name}: {cause}")
    for name, cause in gen["failed"]:
        lines.append(f"- generation/{name}: {cause}")
    if not emb["failed"] and not gen["failed"]:
        lines.append("- none")
    lines.append("")

    # --- Deferred work ---
    lines.append("## Deferred work (by design)")
    lines.append("")
    lines.append("- RQ5 (3.4-B joint embeddings, 3.4-F offline fusion): deferred until "
                 "the embedding benchmark is complete so fusion candidates are chosen "
                 "from full evidence; `joint_embeddings.py` intentionally not implemented "
                 "(`run_stage_3_4.py --include-deferred` must not be used)")
    lines.append("- Stage 3.5 policy execution (Fast/Balanced/Quality/Adaptive): "
                 "pre-registered in `policy_registry`, no implementation")
    lines.append("")

    # --- Audit findings ---
    lines.append("## Audit findings (validator)")
    lines.append("")
    lines.append(f"**{'FAIL' if validator.n_fail else 'PASS'}** — "
                 f"{validator.n_fail} failure(s), {validator.n_warn} warning(s)")
    fails = [f for f in validator.findings if f["level"] == "FAIL"]
    for f in fails[:10]:
        lines.append(f"- [{f['category']}] {f['message'][:140]}")
    if len(fails) > 10:
        lines.append(f"- … {len(fails) - 10} more (run validate_checkpoints.py)")
    lines.append("")

    # --- Reproducibility ---
    lines.append("## Reproducibility")
    lines.append("")
    if repro:
        lines.append(f"**{repro['status']}** — controlled side-by-side reruns vs canonical "
                     f"checkpoints, tolerances quality |Δ|≤"
                     f"{repro['tolerances']['quality_abs']} abs / perf ±"
                     f"{repro['tolerances']['perf_rel']*100:.0f}% rel "
                     f"(`results/repro/repro_report.md`)")
    else:
        lines.append("*Not yet run* — `compare_repro.py` after the controlled reruns "
                     "(requires a quiescent machine).")
    lines.append("")

    # --- Stage 3.5 prerequisites ---
    emb_done = len(emb["evaluated"]) + len(emb["failed"]) >= emb["total"]
    gen_done = len(gen["evaluated"]) + len(gen["failed"]) >= gen["total"]
    checks = [
        ("Embedding benchmark complete (every candidate terminal)", emb_done),
        ("Generation benchmark complete (every candidate terminal)", gen_done),
        ("RQ1 evidence exists (≥1 cross-runtime comparison)",
         bool((cross_runtime or {}).get("n_comparisons"))),
        ("Validator passes (no FAIL findings)", validator.n_fail == 0),
        ("Reproducibility report PASS", bool(repro and repro.get("status") == "PASS")),
        ("Corpora frozen (MANIFEST.sha256)",
         (CORPORA_DIR / "MANIFEST.sha256").exists()),
        ("Evidence frozen (Evaluation/stage_3_4/frozen/)",
         (EVAL_DIR / "stage_3_4" / "frozen" / "manifest.json").exists()),
    ]
    lines.append("## Stage 3.5 prerequisites")
    lines.append("")
    for label, ok in checks:
        lines.append(f"- [{'x' if ok else ' '}] {label}")
    lines.append("")

    # --- Final recommendation ---
    lines.append("## Final recommendation")
    lines.append("")
    hard_blocks = [label for label, ok in checks if not ok]
    bad_rqs = [rq for rq, v in verdicts.items() if v == "NO-GO"]
    if not hard_blocks and not bad_rqs:
        lines.append("All Stage 3.4 exit criteria tracked here are satisfied. "
                     "Proceed to Gate C (evidence freeze) and Gate D (documentation "
                     "sync); Stage 3.5 may begin after both.")
    else:
        lines.append("Stage 3.4 is **not ready to close**. Remaining:")
        for rq in bad_rqs:
            lines.append(f"- {rq} is NO-GO — return to evidence collection")
        for blocker in hard_blocks:
            lines.append(f"- {blocker}")
    lines.append("")

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines))
    print(f"Wrote {REPORT_PATH}")
    print(f"Verdicts: {verdicts}")


if __name__ == "__main__":
    main()
