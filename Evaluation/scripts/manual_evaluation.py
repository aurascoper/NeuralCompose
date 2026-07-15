#!/usr/bin/env python3
"""
Manual evaluation: multi-rater scoring template and aggregation.

Creates a scoring template CSV with fields for multiple raters, and
aggregates filled-in templates into inter-rater agreement statistics.

Usage:
    # Generate blank scoring template
    python3 Evaluation/scripts/manual_evaluation.py --create-template

    # Aggregate filled templates from multiple raters
    python3 Evaluation/scripts/manual_evaluation.py --aggregate \
        --rater rater1.csv --rater rater2.csv [--rater rater3.csv ...]

Fields (1-5 scale unless noted):
    meaning_preservation  — does output preserve the meaning of input?
    grammar               — is output grammatically correct?
    instruction_following — does output follow the instruction?
    fluency               — is output fluent/natural?
    verbosity             — is output appropriately concise? (5=perfectly concise)
    hallucination         — is output free of hallucinated content? (5=no hallucination)
    overall_preference    — overall quality preference (1-5)
"""
import argparse
import csv
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from scipy import stats as sp_stats

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
RESULTS_DIR = EVAL_DIR / "results"
REPORTS_DIR = EVAL_DIR / "reports"

FIELDS = [
    "meaning_preservation",
    "grammar",
    "instruction_following",
    "fluency",
    "verbosity",
    "hallucination",
    "overall_preference",
]

FIELD_DESCRIPTIONS = {
    "meaning_preservation": "Does output preserve the meaning of the input? (5=perfect, 1=completely lost)",
    "grammar": "Is the output grammatically correct? (5=perfect, 1=broken)",
    "instruction_following": "Does the output follow the instruction? (5=fully, 1=not at all)",
    "fluency": "Is the output fluent and natural? (5=perfectly, 1=broken)",
    "verbosity": "Is the output appropriately concise? (5=perfectly concise, 1=extremely verbose)",
    "hallucination": "Is the output free of hallucinated/fabricated content? (5=no hallucination, 1=heavy)",
    "overall_preference": "Overall quality preference (5=excellent, 1=poor)",
}


def find_scoring_template():
    """Find the most recent scoring-template.csv."""
    # Check results dir first
    p = RESULTS_DIR / "scoring-template.csv"
    if p.exists():
        return p
    # Check eval dirs
    eval_dirs = sorted(
        [d for d in EVAL_DIR.iterdir() if d.is_dir() and "generation-eval" in d.name],
        key=lambda d: d.name, reverse=True
    )
    for d in eval_dirs:
        candidate = d / "scoring-template.csv"
        if candidate.exists():
            return candidate
    return None


def create_template():
    """Create a blank scoring template with rater fields."""
    source = find_scoring_template()
    if not source:
        print("ERROR: No scoring-template.csv found. Run run_benchmark.py first.")
        sys.exit(1)

    output_path = RESULTS_DIR / "manual_scoring_template.csv"

    with open(source) as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    # Add rater columns for each field
    fieldnames = list(reader.fieldnames or [])
    for field in FIELDS:
        fieldnames.append(f"rater1_{field}")
        fieldnames.append(f"rater2_{field}")
        fieldnames.append(f"rater3_{field}")

    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

    print(f"Created scoring template: {output_path}")
    print(f"  {len(rows)} rows (one per candidate×prompt)")
    print(f"  Rater fields (1-5 scale):")
    for field in FIELDS:
        print(f"    rater1_{field}, rater2_{field}, rater3_{field} — {FIELD_DESCRIPTIONS[field]}")
    print()
    print("Instructions for raters:")
    print("  1. Open the CSV in a spreadsheet app")
    print("  2. Fill in the rater1_* columns for all rows")
    print("  3. Save as rater1.csv, then repeat for rater2.csv, rater3.csv")
    print("  4. Run: python3 manual_evaluation.py --aggregate --rater rater1.csv --rater rater2.csv")


def aggregate_raters(rater_files):
    """Aggregate multiple rater files and compute inter-rater agreement."""
    all_rater_data = {}
    for rf in rater_files:
        path = Path(rf)
        if not path.exists():
            print(f"WARNING: {path} not found, skipping")
            continue
        with open(path) as f:
            reader = csv.DictReader(f)
            rows = list(reader)
        rater_name = path.stem
        all_rater_data[rater_name] = {row["candidate"] + "|" + row["prompt_id"]: row
                                       for row in rows}

    if len(all_rater_data) < 2:
        print("ERROR: Need at least 2 raters to compute agreement.")
        sys.exit(1)

    raters = list(all_rater_data.keys())
    print(f"Aggregating {len(raters)} raters: {raters}")

    # Collect per-field scores
    field_scores = {field: defaultdict(list) for field in FIELDS}
    all_keys = set.intersection(*[set(d.keys()) for d in all_rater_data.values()])

    for key in sorted(all_keys):
        for field in FIELDS:
            for rater in raters:
                val = all_rater_data[rater][key].get(f"{rater}_{field}", "")
                if val and val.strip():
                    try:
                        score = int(val.strip())
                        if 1 <= score <= 5:
                            field_scores[field][key].append(score)
                    except ValueError:
                        pass

    # Compute statistics
    results = {}
    for field in FIELDS:
        all_values = []
        per_item = {}
        for key, scores in field_scores[field].items():
            if len(scores) >= 2:
                per_item[key] = {
                    "mean": float(np.mean(scores)),
                    "std": float(np.std(scores, ddof=1)) if len(scores) > 1 else 0,
                    "min": int(min(scores)),
                    "max": int(max(scores)),
                    "n_raters": len(scores),
                }
                all_values.extend(scores)

        # Inter-rater agreement
        agreement = {}
        if len(raters) >= 2:
            # Build matrix per item
            item_scores = {}
            for key, scores in field_scores[field].items():
                if len(scores) == len(raters):
                    item_scores[key] = scores

            if len(item_scores) >= 3:
                score_matrix = np.array(list(item_scores.values()))
                # Cronbach's alpha
                k = score_matrix.shape[1]
                if k > 1:
                    item_vars = score_matrix.var(axis=0, ddof=1)
                    total_var = score_matrix.sum(axis=1).var(ddof=1)
                    if total_var > 0:
                        alpha = (k / (k - 1)) * (1 - item_vars.sum() / total_var)
                        agreement["cronbachs_alpha"] = float(alpha)

                # Krippendorff's alpha approximation via ICC
                if score_matrix.shape[0] >= 3 and k >= 2:
                    try:
                        # ICC(2,k) — two-way random, single measures
                        icc_result = compute_icc(score_matrix)
                        agreement["icc"] = icc_result
                    except Exception:
                        pass

                # Mean absolute difference between rater pairs
                diffs = []
                for i in range(k):
                    for j in range(i + 1, k):
                        diffs.extend(np.abs(score_matrix[:, i] - score_matrix[:, j]).tolist())
                agreement["mean_abs_difference"] = float(np.mean(diffs)) if diffs else None
                agreement["n_items_with_all_raters"] = len(item_scores)

        results[field] = {
            "mean": float(np.mean(all_values)) if all_values else None,
            "std": float(np.std(all_values, ddof=1)) if len(all_values) > 1 else None,
            "median": float(np.median(all_values)) if all_values else None,
            "n_scores": len(all_values),
            "n_items": len(per_item),
            "per_item": per_item,
            "inter_rater_agreement": agreement,
        }

    # Per-candidate aggregation
    candidate_scores = defaultdict(lambda: defaultdict(list))
    for field in FIELDS:
        for key, scores in field_scores[field].items():
            candidate = key.split("|")[0]
            candidate_scores[candidate][field].extend(scores)

    candidate_summary = {}
    for cand, fields in candidate_scores.items():
        candidate_summary[candidate] = {}
        for field in FIELDS:
            vals = fields.get(field, [])
            if vals:
                lo, hi = bootstrap_ci(vals)
                candidate_summary[candidate][field] = {
                    "mean": float(np.mean(vals)),
                    "std": float(np.std(vals, ddof=1)) if len(vals) > 1 else 0,
                    "median": float(np.median(vals)),
                    "ci_lo": lo,
                    "ci_hi": hi,
                    "n": len(vals),
                }

    output = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "raters": raters,
        "fields": FIELDS,
        "field_results": {k: {kk: vv for kk, vv in v.items() if kk != "per_item"}
                         for k, v in results.items()},
        "candidate_summary": candidate_summary,
        "per_item_detail": {field: dict(v.get("per_item", {}))
                           for field, v in results.items()},
    }

    # Write JSON
    json_path = RESULTS_DIR / "manual_evaluation.json"
    with open(json_path, "w") as f:
        json.dump(output, f, indent=2, default=str)
    print(f"Wrote {json_path}")

    # Write markdown
    md = generate_agreement_report(output, results, candidate_summary, raters)
    md_path = REPORTS_DIR / "manual_evaluation.md"
    with open(md_path, "w") as f:
        f.write(md)
    print(f"Wrote {md_path}")


def bootstrap_ci(data, confidence=0.95, n_boot=10000):
    if len(data) < 2:
        return (float("nan"), float("nan"))
    arr = np.array(data, dtype=float)
    rng = np.random.default_rng(42)
    boot_means = np.array([
        rng.choice(arr, size=len(arr), replace=True).mean()
        for _ in range(n_boot)
    ])
    alpha = (1 - confidence) / 2
    return (float(np.percentile(boot_means, alpha * 100)),
            float(np.percentile(boot_means, (1 - alpha) * 100)))


def compute_icc(matrix):
    """Compute ICC(2,1) — two-way random, single measures."""
    n, k = matrix.shape
    grand_mean = matrix.mean()
    ss_between = n * np.sum((matrix.mean(axis=1) - grand_mean) ** 2)
    ss_within = np.sum((matrix - matrix.mean(axis=1, keepdims=True)) ** 2)
    ss_raters = n * np.sum((matrix.mean(axis=0) - grand_mean) ** 2)
    ss_total = np.sum((matrix - grand_mean) ** 2)

    ms_between = ss_between / (n - 1)
    ms_within = ss_within / ((n - 1) * (k - 1))
    ms_raters = ss_raters / (k - 1)

    icc = (ms_between - ms_within) / (ms_between + (k - 1) * ms_within + k * (ms_raters - ms_within) / n)
    return float(icc)


def generate_agreement_report(output, results, candidate_summary, raters):
    lines = []
    lines.append("# Manual Evaluation: Inter-Rater Agreement and Aggregated Scores")
    lines.append("")
    lines.append(f"**Generated:** {output['generated_at']}")
    lines.append(f"**Raters:** {', '.join(raters)}")
    lines.append("")

    # Inter-rater agreement
    lines.append("## Inter-Rater Agreement")
    lines.append("")
    lines.append("| Field | Cronbach's α | ICC | Mean Abs Diff | n Items |")
    lines.append("|-------|-------------|-----|---------------|---------|")
    for field in FIELDS:
        r = results[field]["inter_rater_agreement"]
        alpha = r.get("cronbachs_alpha")
        icc = r.get("icc")
        mad = r.get("mean_abs_difference")
        n = r.get("n_items_with_all_raters", 0)
        a_str = f"{alpha:.3f}" if alpha is not None else "—"
        i_str = f"{icc:.3f}" if icc is not None else "—"
        m_str = f"{mad:.2f}" if mad is not None else "—"
        lines.append(f"| {field} | {a_str} | {i_str} | {m_str} | {n} |")
    lines.append("")
    lines.append("Cronbach's α ≥ 0.7 = acceptable, ≥ 0.8 = good, ≥ 0.9 = excellent.")
    lines.append("")

    # Aggregated scores per candidate
    lines.append("## Aggregated Scores per Candidate")
    lines.append("")
    for field in FIELDS:
        lines.append(f"### {field.replace('_', ' ').title()}")
        lines.append("")
        lines.append("| Candidate | Mean | Std | CI95 | n |")
        lines.append("|-----------|------|-----|------|---|")
        for cand, fields in sorted(candidate_summary.items()):
            vals = fields.get(field)
            if vals:
                lines.append(
                    f"| {cand} | {vals['mean']:.2f} | {vals['std']:.2f} "
                    f"| [{vals['ci_lo']:.2f}, {vals['ci_hi']:.2f}] | {vals['n']} |"
                )
            else:
                lines.append(f"| {cand} | — | — | — | 0 |")
        lines.append("")

    # Interpretation
    lines.append("## Interpretation Notes")
    lines.append("")
    lines.append("- Scores are on a 1-5 scale (5 = best for all fields)")
    lines.append("- Confidence intervals are bootstrap (10,000 resamples)")
    lines.append("- Items with fewer than 2 raters are excluded from agreement calculations")
    lines.append("- Verbosity is scored as conciseness (5 = perfectly concise, 1 = extremely verbose)")
    lines.append("- Hallucination is scored inversely (5 = no hallucination, 1 = heavy hallucination)")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Manual evaluation scoring and aggregation")
    parser.add_argument("--create-template", action="store_true",
                        help="Create blank scoring template CSV")
    parser.add_argument("--aggregate", action="store_true",
                        help="Aggregate filled rater templates")
    parser.add_argument("--rater", action="append", default=[],
                        help="Path to a rater's filled CSV (use multiple times)")
    args = parser.parse_args()

    if args.create_template:
        create_template()
    elif args.aggregate:
        if not args.rater:
            print("ERROR: --aggregate requires at least one --rater file")
            sys.exit(1)
        aggregate_raters(args.rater)
    else:
        parser.print_help()