#!/usr/bin/env python3
"""
Single entry point for the Stage 3.4 evaluation state → Evaluation/dashboard.md

Generated, never hand-edited — regenerate after any benchmark or analysis
run. Shows per-track completion (candidate × runtime), validator status, and
links every artifact a reviewer would otherwise hunt for across a dozen
directories.

Usage:
  python3 Evaluation/scripts/generate_dashboard.py
"""
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
CORPORA_DIR = EVAL_DIR / "corpora"
RESULTS_DIR = EVAL_DIR / "results"
EMBEDDINGS_DIR = RESULTS_DIR / "embeddings"
CANDIDATES_DIR = RESULTS_DIR / "candidates"
DASHBOARD_PATH = EVAL_DIR / "dashboard.md"


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def newest_fixture(prefix):
    versions = sorted(CORPORA_DIR.glob(f"{prefix}_v*.json"),
                      key=lambda p: p.name, reverse=True)
    return versions[0] if versions else None


def embedding_rows():
    fixture = load_json(CORPORA_DIR / "embedding_bench_candidates_v1.json") or {}
    rows = []
    for cand in fixture.get("candidates", []):
        name = cand["name"]
        statuses = {}
        model_dir = EMBEDDINGS_DIR / name
        if model_dir.exists():
            for rt_dir in sorted(d for d in model_dir.iterdir() if d.is_dir()):
                bench = load_json(rt_dir / "benchmark.json")
                if bench is None:
                    n_failed = len(list(rt_dir.glob("benchmark.failed-*.json")))
                    statuses[rt_dir.name] = (f"retrying ({n_failed} archived)"
                                             if n_failed else "in progress")
                elif str(bench.get("status", "")) == "evaluated":
                    statuses[rt_dir.name] = "evaluated"
                else:
                    statuses[rt_dir.name] = (f"failed: "
                                             f"{bench.get('failure_reason') or 'unclassified'}")
        rows.append((name, cand.get("priority", "?"), statuses))
    return rows


def generation_rows():
    fixture_path = newest_fixture("generation_eval_candidates")
    fixture = load_json(fixture_path) or {}
    rows = []
    for cand in fixture.get("candidates", []):
        name = cand["name"]
        cdir = CANDIDATES_DIR / name
        if cand.get("unavailable"):
            status = f"unavailable: {cand.get('unavailable_reason', '')[:60]}…"
        elif (cdir / "raw.json").exists():
            raw = load_json(cdir / "raw.json") or {}
            cands = raw.get("candidates", [{}])
            status = cands[0].get("status", "unknown") if cands else "unknown"
        elif (cdir / "metadata.json").exists():
            meta = load_json(cdir / "metadata.json") or {}
            status = f"failed: {meta.get('error') or 'no error recorded'}"
        else:
            status = "pending"
        rows.append((name, cand.get("directory", ""), status))
    return rows, fixture_path


def run_validator():
    try:
        import validate_checkpoints as vc
        report = vc.Report(strict=False)
        vc.check_corpora(report)
        vc.check_embedding_checkpoints(report)
        vc.check_generation_checkpoints(report)
        vc.check_embedding_traceability(report)
        vc.check_generation_traceability(report)
        return report
    except Exception as e:
        return e


def main():
    lines = ["# NeuralCompose Evaluation Dashboard", ""]
    lines.append(f"**Generated:** {datetime.now(timezone.utc).isoformat()} — "
                 f"by `Evaluation/scripts/generate_dashboard.py` (do not hand-edit)")
    lines.append("")

    # --- Validator status ---
    report = run_validator()
    lines.append("## Validation status")
    lines.append("")
    if isinstance(report, Exception):
        lines.append(f"Validator crashed: `{report}`")
    else:
        verdict = "FAIL" if report.n_fail else "PASS"
        lines.append(f"**{verdict}** — {report.n_fail} failure(s), "
                     f"{report.n_warn} warning(s) "
                     f"(`validate_checkpoints.py` for details)")
    lines.append("")

    # --- Embedding track ---
    rows = embedding_rows()
    n_eval = sum(1 for _, _, s in rows if "evaluated" in s.values())
    lines.append(f"## Embedding track — {n_eval} of {len(rows)} candidates evaluated")
    lines.append("")
    lines.append("| Candidate | Priority | Runtime status |")
    lines.append("|-----------|----------|----------------|")
    for name, priority, statuses in sorted(rows, key=lambda r: str(r[1])):
        status_str = ("; ".join(f"{rt}: {s}" for rt, s in sorted(statuses.items()))
                      or "pending")
        lines.append(f"| {name} | {priority} | {status_str} |")
    lines.append("")

    # --- Generation track ---
    gen_rows, gen_fixture = generation_rows()
    n_eval = sum(1 for _, _, s in gen_rows if s == "evaluated")
    lines.append(f"## Generation track — {n_eval} of {len(gen_rows)} candidates evaluated "
                 f"(fixture: `{gen_fixture.name if gen_fixture else '?'}`)")
    lines.append("")
    lines.append("| Candidate | Directory | Status |")
    lines.append("|-----------|-----------|--------|")
    for name, directory, status in gen_rows:
        lines.append(f"| {name} | {directory} | {status} |")
    lines.append("")

    # --- Artifact links ---
    lines.append("## Artifacts")
    lines.append("")
    artifact_groups = [
        ("Leaderboards", [
            "results/embeddings/leaderboard.md",
            "results/leaderboard.md",
        ]),
        ("Summaries & statistics", [
            "results/embeddings/summary.md",
            "results/embeddings/statistical_analysis.md",
            "results/summary.md",
            "results/statistical_analysis.json",
            "results/embeddings/compatibility_matrix.md",
        ]),
        ("Stage 3.4 analyses", [
            "results/stage_3_4/cross_runtime_consistency.md",
            "results/stage_3_4/cross_model_agreement.md",
            "results/stage_3_4/embedding_space_analysis.md",
            "results/stage_3_4/generator_comparison.md",
        ]),
        ("Registries & reports", [
            "corpora/hypothesis_registry.json",
            "reports/decision_registry.md",
            "reports/final_recommendation.md",
            "reports/model_survey.md",
            "reports/statistical_analysis.md",
            "reports/stage_3_4_audit.md",
            "reports/throughput_discrepancy.md",
        ]),
        ("Reproducibility", [
            "results/repro/repro_report.md",
        ]),
        ("Plots", [
            "plots/",
            "results/embeddings/plots/",
        ]),
    ]
    for group, paths in artifact_groups:
        lines.append(f"### {group}")
        lines.append("")
        for p in paths:
            full = EVAL_DIR / p
            marker = "" if full.exists() else " *(not yet generated)*"
            lines.append(f"- [{p}]({p}){marker}")
        lines.append("")

    DASHBOARD_PATH.write_text("\n".join(lines))
    print(f"Wrote {DASHBOARD_PATH}")


if __name__ == "__main__":
    main()
