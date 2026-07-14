#!/usr/bin/env python3
"""
Stage 3.4-D: Cross-model agreement.

For each query in the corpus, compute top-k neighbors according to each
model, then measure pairwise agreement (Jaccard overlap) and consensus.

Reads:  Stored embedding_sample from benchmark.json
Writes: Evaluation/results/stage_3_4/cross_model_agreement.json
        Evaluation/results/stage_3_4/cross_model_agreement.md
"""
import argparse
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from itertools import combinations
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from select_top_k import select_top_embeddings, load_stored_embeddings

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
OUTPUT_DIR = EVAL_DIR / "results" / "stage_3_4"


def cosine_sim(a, b):
    a, b = np.array(a, dtype=np.float32), np.array(b, dtype=np.float32)
    dot = float(np.dot(a, b))
    na, nb = float(np.linalg.norm(a)), float(np.linalg.norm(b))
    return dot / (na * nb) if na > 1e-9 and nb > 1e-9 else 0.0


def top_k_neighbors(query_emb, corpus_embs, k=5):
    sims = [(i, cosine_sim(query_emb, corpus_embs[i]))
            for i in range(len(corpus_embs))]
    sims.sort(key=lambda x: -x[1])
    return set(i for i, _ in sims[:k])


def jaccard(a, b):
    union = a | b
    return len(a & b) / len(union) if union else 1.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--top-k-models", type=int, default=3)
    parser.add_argument("--neighbors-k", type=int, default=5)
    parser.add_argument("--stored-only", action="store_true")
    args = parser.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    top_models = select_top_embeddings(k=args.top_k_models)
    print("=== Stage 3.4-D: Cross-Model Agreement ===")
    print(f"Top-{args.top_k_models} models, k={args.neighbors_k} neighbors")

    model_data = {}
    for m in top_models:
        name = m["name"]
        try:
            sample = load_stored_embeddings(name, m.get("runtime", "python"))
            model_data[name] = {
                "embeddings": sample["embeddings"],
                "texts": sample["texts"],
            }
            print(f"  Loaded {name}: {len(sample['embeddings'])} texts")
        except (FileNotFoundError, ValueError) as e:
            print(f"  SKIP {name}: {e}")

    if len(model_data) < 2:
        print("\nERROR: Need >= 2 models with stored embeddings.")
        sys.exit(1)

    model_names = list(model_data.keys())
    n_texts = len(model_data[model_names[0]]["embeddings"])

    pair_agreements = defaultdict(list)
    per_text_consensus = []

    for text_idx in range(n_texts):
        neighbor_sets = {}
        for name in model_names:
            embs = model_data[name]["embeddings"]
            query_emb = embs[text_idx]
            corpus_embs = [embs[i] for i in range(n_texts) if i != text_idx]
            neighbors = top_k_neighbors(query_emb, corpus_embs, k=args.neighbors_k)
            neighbors = {i if i < text_idx else i + 1 for i in neighbors}
            neighbor_sets[name] = neighbors

        for a, b in combinations(model_names, 2):
            j = jaccard(neighbor_sets[a], neighbor_sets[b])
            pair_agreements[f"{a}+{b}"].append(j)

        consensus_set = set.intersection(*neighbor_sets.values())
        union_set = set.union(*neighbor_sets.values())
        consensus_ratio = len(consensus_set) / len(union_set) if union_set else 0.0
        per_text_consensus.append({
            "text_idx": text_idx,
            "text": model_data[model_names[0]]["texts"][text_idx],
            "consensus_ratio": consensus_ratio,
            "any_model_agreement": len(consensus_set) > 0,
        })

    pair_stats = {}
    for pair, jaccards in pair_agreements.items():
        arr = np.array(jaccards)
        pair_stats[pair] = {
            "mean_jaccard": float(arr.mean()),
            "std": float(arr.std()),
            "min": float(arr.min()),
            "max": float(arr.max()),
            "n": len(jaccards),
        }

    consensus_arr = np.array([t["consensus_ratio"] for t in per_text_consensus])

    output = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "models": model_names,
        "neighbors_k": args.neighbors_k,
        "pairwise_agreement": pair_stats,
        "consensus": {
            "mean_consensus_ratio": float(consensus_arr.mean()),
            "std": float(consensus_arr.std()),
            "per_text": per_text_consensus,
        },
    }
    out_path = OUTPUT_DIR / "cross_model_agreement.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2, default=str)
    print(f"\nWrote {out_path}")

    lines = ["# Stage 3.4-D: Cross-Model Agreement", ""]
    lines.append(f"**Generated:** {output['generated_at']}")
    lines.append(f"**Models:** {', '.join(model_names)}")
    lines.append(f"**Neighbors k:** {args.neighbors_k}")
    lines.append("")
    lines.append("## Pairwise Neighbor Agreement (Jaccard)")
    lines.append("| Pair | Mean Jaccard | Std | Min | Max |")
    lines.append("|------|-------------|-----|-----|-----|")
    for pair, s in pair_stats.items():
        lines.append(f"| {pair} | {s['mean_jaccard']:.4f} | {s['std']:.4f} | {s['min']:.4f} | {s['max']:.4f} |")
    lines.append("")
    lines.append("## Consensus Across All Models")
    lines.append(f"Mean consensus ratio: {output['consensus']['mean_consensus_ratio']:.4f}")
    lines.append("")

    md_path = OUTPUT_DIR / "cross_model_agreement.md"
    with open(md_path, "w") as f:
        f.write("\n".join(lines))
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
