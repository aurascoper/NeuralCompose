#!/usr/bin/env python3
"""Regenerate leaderboard from existing checkpoints."""
import sys, json
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
import embedding_streaming_benchmark as esb

RESULTS_DIR = Path(__file__).resolve().parent.parent / "results" / "embeddings"
all_metrics = []
for d in sorted(RESULTS_DIR.iterdir()):
    if not d.is_dir() or d.name == "plots":
        continue
    for rt_dir in d.iterdir():
        if not rt_dir.is_dir():
            continue
        bench_path = rt_dir / "benchmark.json"
        if bench_path.exists():
            with open(bench_path) as f:
                bench = json.load(f)
            if bench.get("status") == "evaluated":
                m = esb.extract_metrics(bench)
                if m:
                    m["stability_by_type"] = esb.extract_stability_by_type(bench)
                    all_metrics.append(m)

print(f"Found {len(all_metrics)} evaluated models")
for m in all_metrics:
    print(f"  {m['name']:35s} ({m['runtime']:7s}) "
          f"quality={m['quality_score']:.3f} "
          f"stability={m['stability_mean']:.3f} "
          f"neighborhood={m.get('neighborhood_stability_mean', 0):.3f} "
          f"semantic={m.get('semantic_stability_mean', 0):.3f}")

esb.update_leaderboard(all_metrics)
esb.generate_summary_md(all_metrics)
print("Done")