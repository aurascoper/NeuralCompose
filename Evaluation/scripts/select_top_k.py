"""
Select top-K embedding models and top-K generators from existing
Stage 3.3 benchmark results. Used by Stage 3.4/3.5 scripts to
parameterize which models to compose.

Usage:
    from select_top_k import select_top_embeddings, select_top_generators
    top_emb = select_top_embeddings(k=3)  # from leaderboard.json
    top_gen = select_top_generators(k=3)  # from generation leaderboard
"""
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
EMB_LEADERBOARD = EVAL_DIR / "results" / "embeddings" / "leaderboard.json"
GEN_LEADERBOARD = EVAL_DIR / "results" / "leaderboard.json"


def select_top_embeddings(k=3):
    """Return top-K embedding models by overall_score from leaderboard.json."""
    if not EMB_LEADERBOARD.exists():
        raise FileNotFoundError(f"Run embedding benchmark first: {EMB_LEADERBOARD}")
    with open(EMB_LEADERBOARD) as f:
        data = json.load(f)
    valid = [c for c in data["candidates"] if c.get("failure_rate", 0) < 1]
    valid.sort(key=lambda c: c.get("overall_score", 0), reverse=True)
    return valid[:k]


def select_top_generators(k=3):
    """Return top-K generators by score from generation leaderboard.json."""
    if not GEN_LEADERBOARD.exists():
        raise FileNotFoundError(f"Run generation benchmark first: {GEN_LEADERBOARD}")
    with open(GEN_LEADERBOARD) as f:
        data = json.load(f)
    candidates = data.get("candidates", data.get("rankings", []))
    if isinstance(candidates, dict):
        candidates = candidates.get("rankings", [])
    valid = [c for c in candidates if c.get("score", c.get("overall_score", 0)) > 0]
    valid.sort(key=lambda c: c.get("score", c.get("overall_score", 0)), reverse=True)
    return valid[:k]


def load_stored_embeddings(model_name, runtime="python"):
    """Load the stored embedding_sample (first 10 corpus texts) from benchmark.json."""
    bench_path = EVAL_DIR / "results" / "embeddings" / model_name / runtime / "benchmark.json"
    if not bench_path.exists():
        raise FileNotFoundError(f"No benchmark.json at {bench_path}")
    with open(bench_path) as f:
        data = json.load(f)
    sample = data.get("embedding_sample")
    if not sample or not sample.get("embeddings"):
        raise ValueError(f"No embedding_sample in {bench_path}")
    return sample


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--emb-k", type=int, default=3)
    parser.add_argument("--gen-k", type=int, default=3)
    args = parser.parse_args()

    print("=== Top Embedding Models ===")
    for m in select_top_embeddings(args.emb_k):
        print(f"  {m['name']:30s} score={m.get('overall_score', 0):.4f} dim={m.get('dimension')}")

    print("\n=== Top Generator Models ===")
    for m in select_top_generators(args.gen_k):
        print(f"  {m.get('name', m.get('candidate', '?')):30s} score={m.get('score', m.get('overall_score', 0)):.4f}")
