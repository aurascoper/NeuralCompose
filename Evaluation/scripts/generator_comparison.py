#!/usr/bin/env python3
"""
Stage 3.4-E: Generator comparison.

Reads the existing generation benchmark raw.json and computes pairwise agreement:
  - Output cosine similarity (via sentence-transformers, using MiniLM as reference)
  - BLEU-4 between outputs
  - Exact match rate
  - Per-category agreement breakdown

Reads:  Evaluation/results/raw.json
        Evaluation/corpora/generation_eval_prompts_v1.json
Writes: Evaluation/results/stage_3_4/generator_comparison.json
        Evaluation/results/stage_3_4/generator_comparison.md
"""
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from itertools import combinations
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from eval_stats import bootstrap_ci

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
RAW_DIR = EVAL_DIR / "results" / "candidates"
PROMPTS_PATH = EVAL_DIR / "corpora" / "generation_eval_prompts_v1.json"
OUTPUT_DIR = EVAL_DIR / "results" / "stage_3_4"


def load_raw():
    """Load all per-candidate raw.json files and merge into a single structure."""
    if not RAW_DIR.exists():
        raise FileNotFoundError(f"No candidates directory: {RAW_DIR}")
    all_candidates = []
    for cand_dir in sorted(RAW_DIR.iterdir()):
        raw_path = cand_dir / "raw.json"
        if not raw_path.exists():
            continue
        with open(raw_path) as f:
            data = json.load(f)
        for c in data.get("candidates", []):
            if c.get("status") != "evaluated" and c.get("generated_text") is None and not c.get("prompts"):
                continue
            all_candidates.append(c)
    return {"candidates": all_candidates}


def load_prompts():
    with open(PROMPTS_PATH) as f:
        return json.load(f)["prompts"]


def cosine_sim(a, b):
    a, b = np.array(a, dtype=np.float32), np.array(b, dtype=np.float32)
    dot = float(np.dot(a, b))
    na, nb = float(np.linalg.norm(a)), float(np.linalg.norm(b))
    return dot / (na * nb) if na > 1e-9 and nb > 1e-9 else 0.0


def bleu4(reference, hypothesis):
    ref_tokens = reference.lower().split()
    hyp_tokens = hypothesis.lower().split()
    if len(hyp_tokens) == 0:
        return 0.0
    ref_len = len(ref_tokens)
    hyp_len = len(hyp_tokens)
    bp = 1.0 if hyp_len > ref_len else math.exp(1 - ref_len / hyp_len) if hyp_len > 0 else 0.0
    precisions = []
    for n in range(1, 5):
        ref_ngrams = defaultdict(int)
        hyp_ngrams = defaultdict(int)
        for i in range(len(ref_tokens) - n + 1):
            ref_ngrams[tuple(ref_tokens[i:i+n])] += 1
        for i in range(len(hyp_tokens) - n + 1):
            hyp_ngrams[tuple(hyp_tokens[i:i+n])] += 1
        if not hyp_ngrams:
            precisions.append(0.0)
            continue
        matches = sum(min(hyp_ngrams[g], ref_ngrams.get(g, 0)) for g in hyp_ngrams)
        total = sum(hyp_ngrams.values())
        precisions.append(matches / total if total > 0 else 0.0)
    if any(p == 0 for p in precisions):
        return 0.0
    log_avg = sum(math.log(p) for p in precisions) / 4
    return float(bp * math.exp(log_avg))


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    raw = load_raw()
    prompts = load_prompts()
    prompt_map = {p["id"]: p for p in prompts}

    gen_outputs = {}
    for candidate in raw.get("candidates", []):
        name = candidate.get("name", candidate.get("candidate", "?"))
        if candidate.get("status") != "evaluated":
            continue
        gen_outputs[name] = {}
        for p in candidate.get("prompts", []):
            gen_outputs[name][p.get("prompt_id", p.get("promptID", ""))] = {
                "text": p.get("generated_text", p.get("generatedText", "")),
                "category": p.get("category", ""),
            }

    if len(gen_outputs) < 2:
        print("ERROR: Need >= 2 evaluated generators in raw.json")
        sys.exit(1)

    print(f"=== Stage 3.4-E: Generator Comparison ===")
    print(f"Generators: {list(gen_outputs.keys())}")

    from sentence_transformers import SentenceTransformer
    miniLM_path = REPO_ROOT / "Models" / "all-MiniLM-L6-v2"
    if not miniLM_path.exists():
        miniLM_path = REPO_ROOT / "Models" / "all-MiniLM-L6-v2-hf"
    if not miniLM_path.exists():
        print("ERROR: MiniLM not found on disk for cosine comparison.")
        sys.exit(1)

    model = SentenceTransformer(str(miniLM_path), device='cpu')
    gen_names = list(gen_outputs.keys())
    prompt_ids = list(gen_outputs[gen_names[0]].keys())

    all_texts = []
    text_map = []
    for gen in gen_names:
        for pid in prompt_ids:
            all_texts.append(gen_outputs[gen][pid]["text"])
            text_map.append((gen, pid))
    embeddings = model.encode(all_texts, convert_to_numpy=True,
                               normalize_embeddings=True, show_progress_bar=False)
    emb_map = {(gen, pid): embeddings[i] for i, (gen, pid) in enumerate(text_map)}
    del model

    pair_results = []
    for gen_a, gen_b in combinations(gen_names, 2):
        common_pids = set(gen_outputs[gen_a].keys()) & set(gen_outputs[gen_b].keys())
        cosines = []
        bleus = []
        exact_matches = 0
        per_category = defaultdict(lambda: {"cosines": [], "bleus": []})

        for pid in common_pids:
            text_a = gen_outputs[gen_a][pid]["text"]
            text_b = gen_outputs[gen_b][pid]["text"]
            cat = gen_outputs[gen_a][pid].get("category", "unknown")
            cos = cosine_sim(emb_map[(gen_a, pid)], emb_map[(gen_b, pid)])
            bleu = bleu4(text_a, text_b)
            cosines.append(cos)
            bleus.append(bleu)
            if text_a.strip().lower() == text_b.strip().lower():
                exact_matches += 1
            per_category[cat]["cosines"].append(cos)
            per_category[cat]["bleus"].append(bleu)

        cos_arr = np.array(cosines)
        bleu_arr = np.array(bleus)
        pair_results.append({
            "generator_a": gen_a,
            "generator_b": gen_b,
            "mean_output_cosine": float(cos_arr.mean()),
            "std_output_cosine": float(cos_arr.std()),
            "mean_bleu4": float(bleu_arr.mean()),
            "exact_match_rate": exact_matches / len(common_pids) if common_pids else 0.0,
            "n_prompts": len(common_pids),
            "per_category": {
                cat: {
                    "mean_cosine": float(np.mean(v["cosines"])) if v["cosines"] else 0.0,
                    "mean_bleu4": float(np.mean(v["bleus"])) if v["bleus"] else 0.0,
                    "n": len(v["cosines"]),
                }
                for cat, v in per_category.items()
            },
        })
        print(f"  {gen_a} vs {gen_b}: cosine={cos_arr.mean():.4f} bleu4={bleu_arr.mean():.4f} exact={exact_matches}/{len(common_pids)}")

    output = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "generators": gen_names,
        "pairwise": pair_results,
    }
    out_path = OUTPUT_DIR / "generator_comparison.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2, default=str)
    print(f"\nWrote {out_path}")

    lines = ["# Stage 3.4-E: Generator Comparison", ""]
    lines.append(f"**Generated:** {output['generated_at']}")
    lines.append(f"**Generators:** {', '.join(gen_names)}")
    lines.append("")
    lines.append("## Pairwise Output Agreement")
    lines.append("| Pair | Mean Cosine | Std | Mean BLEU-4 | Exact Match | n |")
    lines.append("|------|------------|-----|-------------|-------------|---|")
    for r in pair_results:
        lines.append(
            f"| {r['generator_a']} vs {r['generator_b']} "
            f"| {r['mean_output_cosine']:.4f} | {r['std_output_cosine']:.4f} "
            f"| {r['mean_bleu4']:.4f} | {r['exact_match_rate']:.4f} "
            f"| {r['n_prompts']} |"
        )
    lines.append("")

    md_path = OUTPUT_DIR / "generator_comparison.md"
    with open(md_path, "w") as f:
        f.write("\n".join(lines))
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
