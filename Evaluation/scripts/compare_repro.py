#!/usr/bin/env python3
"""
Reproducibility comparison — controlled rerun vs canonical checkpoint.

Side-by-side design: the rerun is written to Evaluation/results/repro/ and
compared against the canonical checkpoint. Canonical evidence is NEVER
replaced — deletion-and-rerun is exactly how the MiniLM 1980-vs-1015
throughput mystery was created (reports/throughput_discrepancy.md).

Tolerance bands (approved 2026-07-14, configurable via --tolerances):
  quality metrics  |Δ| ≤ 0.005 absolute — deterministic encoders on CPU
                   should be near-exact
  perf metrics     ±20% relative — absorbs machine-state noise (thermal,
                   cache, background load)

A metric outside its band is a reproducibility FAILURE of the pipeline —
it means either the harness changed between runs, the environment changed
in a way provenance should have captured, or the measurement itself is not
stable enough to support the claims built on it.

Usage:
  python3 Evaluation/scripts/compare_repro.py \
      [--repro-dir Evaluation/results/repro] \
      [--tolerances PATH.json] \
      [--output Evaluation/results/repro/repro_report]

Compares whatever it finds:
  repro/<model>/<runtime>/benchmark.json  vs  results/embeddings/<model>/<runtime>/benchmark.json
  repro/<name>/raw.json                   vs  results/candidates/<name>/raw.json
"""
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
RESULTS_DIR = EVAL_DIR / "results"
EMBEDDINGS_DIR = RESULTS_DIR / "embeddings"
CANDIDATES_DIR = RESULTS_DIR / "candidates"
DEFAULT_REPRO_DIR = RESULTS_DIR / "repro"

# metric name -> (kind, tolerance). kind: "abs" or "rel"
DEFAULT_TOLERANCES = {
    "quality_abs": 0.005,
    "perf_rel": 0.20,
}

EMBEDDING_QUALITY_METRICS = [
    ("paraphrase_mean", "paraphrase_pairs.mean"),
    ("antonym_mean", "antonym_pairs.mean"),
    ("separation_ratio", "command_groups.separation_ratio"),
    ("retrieval_top1", "retrieval.mean_top1_similarity"),
    ("stability_mean", "stability.overall.mean"),
    ("semantic_stability_mean", "stability.semantic_overall.mean"),
    ("nn_consistency", "nn_consistency.mean_consistency"),
]
EMBEDDING_PERF_METRICS = [
    ("cold_load_time", "cold_load_time"),
    ("warm_encode_time_ms", "warm_encode_time_ms"),
    ("embeddings_per_second", "embeddings_per_second"),
    ("peak_rss_mb", "peak_rss_mb"),
]

GENERATION_QUALITY_METRICS = [
    ("meaning_cosine_mean", None),   # via extract_metrics
    ("stability", None),
    ("instruction_following", None),
    ("word_count_ratio_mean", None),
]
GENERATION_PERF_METRICS = [
    ("cold_load_time", None),
    ("peak_rss_mb", None),
    ("generate_time_mean", None),
    ("tokens_per_second_mean", None),
]

# separation_ratio is on a ~1-5 scale, not [0,1]; a 0.005 absolute band is
# unreasonably tight there. It gets the relative band instead.
QUALITY_METRICS_ON_RATIO_SCALE = {"separation_ratio", "word_count_ratio_mean"}


def get_path(data, dotted):
    cur = data
    for k in dotted.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def compare_metric(name, canonical, repro, kind, tolerances):
    if canonical is None or repro is None:
        return {
            "metric": name, "canonical": canonical, "repro": repro,
            "kind": kind, "status": "MISSING",
            "detail": "value absent on one side",
        }
    canonical, repro = float(canonical), float(repro)
    delta = repro - canonical
    if kind == "abs":
        tol = tolerances["quality_abs"]
        ok = abs(delta) <= tol
        detail = f"|Δ|={abs(delta):.6f} vs abs tol {tol}"
    else:
        tol = tolerances["perf_rel"]
        base = abs(canonical) if canonical != 0 else 1e-12
        rel = abs(delta) / base
        ok = rel <= tol
        detail = f"|Δ|/canonical={rel:.3f} vs rel tol {tol}"
    return {
        "metric": name, "canonical": canonical, "repro": repro,
        "delta": delta, "kind": kind,
        "status": "PASS" if ok else "FAIL", "detail": detail,
    }


def compare_embedding(model, runtime, repro_bench_path, tolerances):
    canonical_path = EMBEDDINGS_DIR / model / runtime / "benchmark.json"
    if not canonical_path.exists():
        return {"target": f"{model} ({runtime})", "kind": "embedding",
                "status": "NO_CANONICAL", "comparisons": []}
    with open(canonical_path) as f:
        canonical = json.load(f)
    with open(repro_bench_path) as f:
        repro = json.load(f)
    comparisons = []
    for name, dotted in EMBEDDING_QUALITY_METRICS:
        kind = "rel" if name in QUALITY_METRICS_ON_RATIO_SCALE else "abs"
        comparisons.append(compare_metric(
            name, get_path(canonical, dotted), get_path(repro, dotted),
            kind, tolerances))
    for name, dotted in EMBEDDING_PERF_METRICS:
        comparisons.append(compare_metric(
            name, get_path(canonical, dotted), get_path(repro, dotted),
            "rel", tolerances))
    status = "PASS" if all(c["status"] == "PASS" for c in comparisons) else "FAIL"
    return {"target": f"{model} ({runtime})", "kind": "embedding",
            "canonical": str(canonical_path), "repro": str(repro_bench_path),
            "status": status, "comparisons": comparisons}


def compare_generation(name, repro_raw_path, tolerances):
    from streaming_benchmark import extract_metrics
    canonical_path = CANDIDATES_DIR / name / "raw.json"
    if not canonical_path.exists():
        return {"target": name, "kind": "generation",
                "status": "NO_CANONICAL", "comparisons": []}
    with open(canonical_path) as f:
        canonical = extract_metrics(json.load(f))
    with open(repro_raw_path) as f:
        repro = extract_metrics(json.load(f))
    if canonical is None or repro is None:
        return {"target": name, "kind": "generation", "status": "NOT_EVALUATED",
                "comparisons": []}
    comparisons = []
    for metric, _ in GENERATION_QUALITY_METRICS:
        kind = "rel" if metric in QUALITY_METRICS_ON_RATIO_SCALE else "abs"
        comparisons.append(compare_metric(
            metric, canonical.get(metric), repro.get(metric), kind, tolerances))
    for metric, _ in GENERATION_PERF_METRICS:
        comparisons.append(compare_metric(
            metric, canonical.get(metric), repro.get(metric), "rel", tolerances))
    status = "PASS" if all(c["status"] == "PASS" for c in comparisons) else "FAIL"
    return {"target": name, "kind": "generation",
            "canonical": str(canonical_path), "repro": str(repro_raw_path),
            "status": status, "comparisons": comparisons}


def render_md(report):
    lines = ["# Reproducibility Report", ""]
    lines.append(f"**Generated:** {report['generated_at']}")
    lines.append(f"**Tolerances:** quality |Δ| ≤ {report['tolerances']['quality_abs']} "
                 f"(absolute); perf ±{report['tolerances']['perf_rel']*100:.0f}% (relative); "
                 f"ratio-scale metrics use the relative band")
    lines.append(f"**Overall:** {report['status']}")
    lines.append("")
    lines.append("Method: side-by-side controlled rerun vs canonical checkpoint — "
                 "canonical evidence is never replaced.")
    lines.append("")
    for target in report["targets"]:
        lines.append(f"## {target['target']} — {target['status']}")
        lines.append("")
        if not target["comparisons"]:
            lines.append(f"({target['status']}: nothing to compare)")
            lines.append("")
            continue
        lines.append("| Metric | Canonical | Repro | Δ | Band | Status |")
        lines.append("|--------|-----------|-------|---|------|--------|")
        for c in target["comparisons"]:
            canon = "—" if c.get("canonical") is None else f"{c['canonical']:.6g}"
            repro = "—" if c.get("repro") is None else f"{c['repro']:.6g}"
            delta = "—" if c.get("delta") is None else f"{c['delta']:+.6g}"
            lines.append(f"| {c['metric']} | {canon} | {repro} | {delta} "
                         f"| {c['detail']} | {c['status']} |")
        lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Compare repro runs vs canonical checkpoints")
    parser.add_argument("--repro-dir", default=str(DEFAULT_REPRO_DIR))
    parser.add_argument("--tolerances", default=None,
                        help="JSON file overriding {quality_abs, perf_rel}")
    parser.add_argument("--output", default=None,
                        help="Output basename (writes .json and .md); default "
                             "<repro-dir>/repro_report")
    args = parser.parse_args()

    repro_dir = Path(args.repro_dir)
    if not repro_dir.exists():
        print(f"ERROR: repro dir not found: {repro_dir}")
        sys.exit(2)

    tolerances = dict(DEFAULT_TOLERANCES)
    if args.tolerances:
        with open(args.tolerances) as f:
            tolerances.update(json.load(f))

    targets = []
    for model_dir in sorted(repro_dir.iterdir()):
        if not model_dir.is_dir():
            continue
        raw = model_dir / "raw.json"
        if raw.exists():
            targets.append(compare_generation(model_dir.name, raw, tolerances))
        for rt_dir in sorted(model_dir.iterdir()):
            if rt_dir.is_dir() and (rt_dir / "benchmark.json").exists():
                targets.append(compare_embedding(
                    model_dir.name, rt_dir.name,
                    rt_dir / "benchmark.json", tolerances))

    if not targets:
        print(f"ERROR: no repro artifacts found under {repro_dir}")
        sys.exit(2)

    overall = "PASS" if all(t["status"] == "PASS" for t in targets) else "FAIL"
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "tolerances": tolerances,
        "status": overall,
        "targets": targets,
    }

    out_base = Path(args.output) if args.output else repro_dir / "repro_report"
    with open(f"{out_base}.json", "w") as f:
        json.dump(report, f, indent=2)
    Path(f"{out_base}.md").write_text(render_md(report))

    print(render_md(report))
    print(f"\nWrote {out_base}.json and {out_base}.md")
    sys.exit(0 if overall == "PASS" else 1)


if __name__ == "__main__":
    main()
