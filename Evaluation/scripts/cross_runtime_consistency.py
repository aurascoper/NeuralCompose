#!/usr/bin/env python3
"""
Stage 3.4-A: Cross-runtime embedding consistency.

For models benchmarked in multiple runtimes, compares:
  - Cosine drift between embeddings of the same text
  - Per-dimension numerical stability (std across runtimes)
  - Latency differences (cold load, warm encode, throughput)

Uses the stored embedding_sample in each benchmark.json (first 10 corpus texts).
No model re-loading needed — purely reads existing benchmark results.

Reads:  Evaluation/results/embeddings/<model>/<runtime>/benchmark.json
Writes: Evaluation/results/stage_3_4/cross_runtime_consistency.json
        Evaluation/results/stage_3_4/cross_runtime_consistency.md
"""
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from eval_stats import bootstrap_ci

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
EMB_RESULTS = EVAL_DIR / "results" / "embeddings"
OUTPUT_DIR = EVAL_DIR / "results" / "stage_3_4"


def load_all_benchmarks():
    by_model = defaultdict(dict)
    if not EMB_RESULTS.exists():
        return by_model
    for model_dir in sorted(EMB_RESULTS.iterdir()):
        if not model_dir.is_dir() or model_dir.name in ("plots",):
            continue
        for runtime_dir in model_dir.iterdir():
            if not runtime_dir.is_dir():
                continue
            bench_path = runtime_dir / "benchmark.json"
            if not bench_path.exists():
                continue
            with open(bench_path) as f:
                data = json.load(f)
            if data.get("status") == "evaluated" and data.get("embedding_sample"):
                by_model[model_dir.name][runtime_dir.name] = data
    return by_model


def cosine_similarity(a, b):
    a, b = np.array(a, dtype=np.float32), np.array(b, dtype=np.float32)
    dot = float(np.dot(a, b))
    na, nb = float(np.linalg.norm(a)), float(np.linalg.norm(b))
    if na < 1e-9 or nb < 1e-9:
        return 0.0
    return dot / (na * nb)


def compare_runtimes(model_name, runtime_data):
    runtime_names = list(runtime_data.keys())
    if len(runtime_names) < 2:
        return None
    comparisons = []
    for i in range(len(runtime_names)):
        for j in range(i + 1, len(runtime_names)):
            rt_a, rt_b = runtime_names[i], runtime_names[j]
            embs_a = runtime_data[rt_a]["embedding_sample"]["embeddings"]
            embs_b = runtime_data[rt_b]["embedding_sample"]["embeddings"]
            texts = runtime_data[rt_a]["embedding_sample"]["texts"]
            cosines = [cosine_similarity(ea, eb) for ea, eb in zip(embs_a, embs_b)]
            arr = np.array(cosines)
            dim_a = np.array(embs_a, dtype=np.float32)
            dim_b = np.array(embs_b, dtype=np.float32)
            per_dim_diff = np.abs(dim_a - dim_b)
            per_dim_std = per_dim_diff.std(axis=0) if len(per_dim_diff) > 1 else np.zeros(1)
            load_a = runtime_data[rt_a].get("cold_load_time", 0)
            load_b = runtime_data[rt_b].get("cold_load_time", 0)
            eps_a = runtime_data[rt_a].get("embeddings_per_second", 0)
            eps_b = runtime_data[rt_b].get("embeddings_per_second", 0)
            comparisons.append({
                "model": model_name,
                "runtime_a": rt_a,
                "runtime_b": rt_b,
                "mean_cosine": float(arr.mean()),
                "min_cosine": float(arr.min()),
                "max_cosine": float(arr.max()),
                "std_cosine": float(arr.std()),
                "ci_95_lo": bootstrap_ci(cosines)[0],
                "ci_95_hi": bootstrap_ci(cosines)[1],
                "n_texts": len(cosines),
                "drift_detected": float(arr.mean()) < 0.999,
                "per_dim_std_mean": float(per_dim_std.mean()),
                "per_dim_std_max": float(per_dim_std.max()),
                "latency_diff_s": load_a - load_b,
                "throughput_ratio": eps_a / eps_b if eps_b > 0 else 0,
            })
    return comparisons


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    all_benchmarks = load_all_benchmarks()
    print("=== Stage 3.4-A: Cross-Runtime Consistency ===")
    print("Models with multi-runtime data:")
    for name, runtimes in sorted(all_benchmarks.items()):
        if len(runtimes) >= 2:
            print(f"  {name}: {list(runtimes.keys())}")
    all_comparisons = []
    for model_name, runtime_data in sorted(all_benchmarks.items()):
        if len(runtime_data) < 2:
            continue
        print(f"\n  Comparing {model_name}...")
        result = compare_runtimes(model_name, runtime_data)
        if result:
            all_comparisons.extend(result)
            for r in result:
                print(f"    {r['runtime_a']} vs {r['runtime_b']}: "
                      f"cosine={r['mean_cosine']:.6f} drift={'YES' if r['drift_detected'] else 'no'}")
    output = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "n_comparisons": len(all_comparisons),
        "comparisons": all_comparisons,
    }
    out_path = OUTPUT_DIR / "cross_runtime_consistency.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2, default=str)
    print(f"\nWrote {out_path}")
    lines = ["# Stage 3.4-A: Cross-Runtime Embedding Consistency", ""]
    lines.append(f"**Generated:** {output['generated_at']}")
    lines.append(f"**Comparisons:** {len(all_comparisons)}")
    lines.append("")
    if all_comparisons:
        lines.append("| Model | Runtime A | Runtime B | Mean Cosine | Min | Max | Std | Drift? | Latency Δ |")
        lines.append("|-------|-----------|-----------|-------------|-----|-----|-----|--------|-----------|")
        for c in all_comparisons:
            drift = "⚠ YES" if c["drift_detected"] else "✓ no"
            lines.append(
                f"| {c['model']} | {c['runtime_a']} | {c['runtime_b']} "
                f"| {c['mean_cosine']:.6f} | {c['min_cosine']:.6f} "
                f"| {c['max_cosine']:.6f} | {c['std_cosine']:.6f} "
                f"| {drift} | {c['latency_diff_s']:+.2f}s |"
            )
    else:
        lines.append("No models have been benchmarked in multiple runtimes yet.")
    lines.append("")
    md_path = OUTPUT_DIR / "cross_runtime_consistency.md"
    with open(md_path, "w") as f:
        f.write("\n".join(lines))
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
