#!/usr/bin/env python3
"""
generate-semantic-eval-artifacts.py — derive Stage 3.3 evidence from a
SemanticEval run.

Input: an `Evaluation/<date>-<modelID>/data.json` produced by
  `swift run SemanticEval --model <name>` (Sources/SemanticEval/) — raw
  embeddings and cosine-similarity relationships only. Plus every
  `Benchmarks/*.json` file (Stage 3.1's EmbeddingBench output), for the
  benchmark-history table.

Output (written into the same directory `data.json` lives in):
  - trajectory_<name>.png   — two orthogonal 2D projections (XY, XZ) of
                              each trajectory's path through embedding
                              space, plus a step-cosine-similarity subplot
  - neighbors_<query>.md    — one markdown table per query, score-sorted
  - summary.md              — human-readable: benchmark history,
                              paraphrase/antonym tables, command-group
                              cohesion, clustering metrics
  - semantic-summary.json   — compact, machine-comparable scores (for
                              Stage 3.5's BGE-vs-E5-vs-MiniLM comparison)

No HTML. JSON/PNG/Markdown are the evidence; HTML is always regenerable
and isn't checked for this stage (per review feedback on the first draft
of this stage's plan).

The 3D->2D projection here is a **bit-exact Python port** of
`RandomProjectionProjector` (Sources/BCICore/Protocols/EmbeddingProjecting.swift)
— same SplitMix64 PRNG, same Rademacher matrix construction, same default
seed (0x5EED_C0DE). Verified against `Tests/Fixtures/semantic_bge_small_v1.json`'s
committed embedding/projection pairs (computed by the real Swift code)
before any plot is trusted — see `_verify_projection_port()`.

Usage:
  ./Scripts/generate-semantic-eval-artifacts.py
  ./Scripts/generate-semantic-eval-artifacts.py --input Evaluation/2026-07-12-bge-small-en-v1.5/data.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from sklearn.metrics import davies_bouldin_score, silhouette_score

REPO_ROOT = Path(__file__).resolve().parent.parent
GOLDEN_FIXTURE = REPO_ROOT / "Tests" / "Fixtures" / "semantic_bge_small_v1.json"
MASK64 = (1 << 64) - 1


# ── Bit-exact port of Sources/BCICore/Protocols/EmbeddingProjecting.swift ──

class SplitMix64:
    def __init__(self, seed: int):
        self.state = seed & MASK64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)


def build_projection_matrix(dimension: int, seed: int) -> np.ndarray:
    """Rademacher matrix scaled by 1/sqrt(dimension) — same construction as
    `RandomProjectionProjector.buildMatrix`, same iteration order (axis
    outer, component inner)."""
    scale = 1.0 / np.sqrt(dimension)
    gen = SplitMix64(seed)
    matrix = np.empty((3, dimension), dtype=np.float64)
    for axis in range(3):
        for i in range(dimension):
            matrix[axis, i] = scale if gen.next() % 2 == 0 else -scale
    return matrix


def project(embedding: np.ndarray, matrix: np.ndarray) -> np.ndarray:
    return matrix @ embedding


def _verify_projection_port() -> None:
    """Fails loudly if the Python port doesn't reproduce the real Swift
    `RandomProjectionProjector`'s committed output. Must pass before any
    plot in this script is trusted."""
    if not GOLDEN_FIXTURE.exists():
        print(f"warning: golden fixture not found at {GOLDEN_FIXTURE}, skipping projection-port verification", file=sys.stderr)
        return
    fixture = json.loads(GOLDEN_FIXTURE.read_text())
    dimension = fixture["dimension"]
    seed = fixture["projectionSeed"]
    matrix = build_projection_matrix(dimension, seed)

    max_error = 0.0
    for sentence in fixture["sentences"]:
        embedding = np.array(sentence["embedding"], dtype=np.float64)
        expected = np.array(sentence["projection"], dtype=np.float64)
        actual = project(embedding, matrix)
        max_error = max(max_error, float(np.max(np.abs(actual - expected))))

    if max_error > 1e-4:
        print(
            f"error: projection port diverges from the committed golden fixture "
            f"(max abs error {max_error:.6f} > 1e-4) — do not trust any plot "
            f"from this script until this is fixed",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"Projection port verified against {GOLDEN_FIXTURE.name} (max abs error {max_error:.2e})")


# ── Loading ──────────────────────────────────────────────────────────────

def find_latest_data_json() -> Path:
    candidates = sorted((REPO_ROOT / "Evaluation").glob("*/data.json"))
    if not candidates:
        raise FileNotFoundError("No Evaluation/*/data.json found — run `swift run SemanticEval --model bge` first.")
    return candidates[-1]


def load_benchmark_history() -> list[dict]:
    rows = []
    for path in sorted((REPO_ROOT / "Benchmarks").glob("*.json")):
        entry = json.loads(path.read_text())
        rows.append(entry)
    return rows


# ── Trajectory plots ─────────────────────────────────────────────────────

def plot_trajectory(name: str, trajectory: dict, matrix: np.ndarray, out_dir: Path) -> Path:
    phrases = trajectory["phrases"]
    embeddings = np.array(trajectory["embeddings"], dtype=np.float64)
    coords = np.array([project(e, matrix) for e in embeddings])
    steps = trajectory["step_cosine_similarities"]

    fig, axes = plt.subplots(1, 3, figsize=(15, 5))

    for ax, (i, j, xlabel, ylabel) in zip(
        axes[:2], [(0, 1, "x", "y"), (0, 2, "x", "z")]
    ):
        ax.plot(coords[:, i], coords[:, j], "-o", color="tab:blue")
        for idx, phrase in enumerate(phrases):
            ax.annotate(f"{idx}: {phrase}", (coords[idx, i], coords[idx, j]), fontsize=8)
        ax.set_xlabel(xlabel)
        ax.set_ylabel(ylabel)
        ax.set_title(f"{name} ({xlabel}{ylabel})")

    axes[2].plot(range(len(steps)), steps, "-o", color="tab:orange")
    axes[2].set_xticks(range(len(steps)))
    axes[2].set_xticklabels([f"{phrases[i]}\n↓\n{phrases[i+1]}" for i in range(len(steps))], fontsize=7)
    axes[2].set_ylabel("cosine similarity")
    axes[2].set_title("step-to-step similarity")
    axes[2].set_ylim(-1, 1)

    fig.tight_layout()
    out_path = out_dir / f"trajectory_{name}.png"
    fig.savefig(out_path, dpi=120)
    plt.close(fig)
    return out_path


# ── Markdown tables ──────────────────────────────────────────────────────

def write_neighbor_tables(data: dict, out_dir: Path) -> list[Path]:
    paths = []
    for query, neighbors in data["neighbors"].items():
        safe_name = query.replace(" ", "-")
        path = out_dir / f"neighbors_{safe_name}.md"
        lines = [f"# Nearest neighbors for \"{query}\"", "", "| rank | text | cosine similarity |", "|---|---|---|"]
        for rank, neighbor in enumerate(neighbors, start=1):
            lines.append(f"| {rank} | {neighbor['text']} | {neighbor['score']:.4f} |")
        path.write_text("\n".join(lines) + "\n")
        paths.append(path)
    return paths


def _pair_table(pairs: list[dict], label_a: str, label_b: str) -> str:
    lines = [f"| {label_a} | {label_b} | cosine similarity |", "|---|---|---|"]
    for pair in pairs:
        lines.append(f"| {pair['a']} | {pair['b']} | {pair['score']:.4f} |")
    return "\n".join(lines)


# ── Clustering metrics ───────────────────────────────────────────────────

def compute_clustering_metrics(data: dict) -> tuple[float, float]:
    embedding_by_text = {p["text"]: p["embedding"] for p in data["phrases"]}
    X, y = [], []
    for group_name, group in data["command_groups"].items():
        for phrase in group["phrases"]:
            X.append(embedding_by_text[phrase])
            y.append(group_name)
    X = np.array(X, dtype=np.float64)
    silhouette = float(silhouette_score(X, y))
    davies_bouldin = float(davies_bouldin_score(X, y))
    return silhouette, davies_bouldin


# ── Summary ──────────────────────────────────────────────────────────────

def build_summary_md(data: dict, benchmark_history: list[dict], silhouette: float, davies_bouldin: float) -> str:
    lines = ["# Stage 3.3 Semantic Evaluation Summary", ""]

    lines.append("## Benchmark history")
    lines.append("")
    lines.append("| date/model | runtime | pooling | cold_load_ms | warm_encode_ms | embeddings_per_second |")
    lines.append("|---|---|---|---|---|---|")
    for entry in benchmark_history:
        lines.append(
            f"| {entry['model_id']} | {entry['runtime']} | {entry.get('pooling', 'n/a')} | "
            f"{entry['cold_load_ms']:.2f} | {entry['warm_encode_ms']:.2f} | {entry['embeddings_per_second']:.2f} |"
        )
    lines.append("")

    lines.append("## Paraphrase pairs (expect high similarity)")
    lines.append("")
    lines.append(_pair_table(data["paraphrase_pairs"], "phrase A", "phrase B"))
    lines.append("")

    lines.append("## Antonym pairs (expect low similarity — should NOT collapse with paraphrases above)")
    lines.append("")
    lines.append(_pair_table(data["antonym_pairs"], "phrase A", "phrase B"))
    lines.append("")

    lines.append("## Command-alias cohesion")
    lines.append("")
    lines.append(f"Cross-command mean similarity: **{data['cross_command_mean_similarity']:.4f}**")
    lines.append("")
    lines.append("| command | intra-group mean similarity | gap vs. cross-command |")
    lines.append("|---|---|---|")
    for name, group in sorted(data["command_groups"].items()):
        gap = group["intra_mean_similarity"] - data["cross_command_mean_similarity"]
        lines.append(f"| {name} | {group['intra_mean_similarity']:.4f} | {gap:+.4f} |")
    lines.append("")

    lines.append("## Clustering metrics (over command-group-labeled embeddings)")
    lines.append("")
    lines.append(f"- Silhouette score (higher is better): **{silhouette:.4f}**")
    lines.append(f"- Davies-Bouldin index (**lower** is better): **{davies_bouldin:.4f}**")
    lines.append("")

    lines.append("## Trajectories")
    lines.append("")
    for name, trajectory in data["trajectories"].items():
        mean_step = float(np.mean(trajectory["step_cosine_similarities"]))
        lines.append(f"- `{name}`: {' -> '.join(trajectory['phrases'])}")
        lines.append(f"  - mean step-to-step similarity: {mean_step:.4f}")
        lines.append(f"  - see `trajectory_{name}.png`")
    lines.append("")

    return "\n".join(lines)


def build_semantic_summary(data: dict, silhouette: float, davies_bouldin: float) -> dict:
    retrieval_scores = [n[0]["score"] for n in data["neighbors"].values() if n]
    paraphrase_scores = [p["score"] for p in data["paraphrase_pairs"]]
    antonym_scores = [p["score"] for p in data["antonym_pairs"]]
    trajectory_steps = [s for t in data["trajectories"].values() for s in t["step_cosine_similarities"]]
    intra_scores = [g["intra_mean_similarity"] for g in data["command_groups"].values()]

    intra_mean = float(np.mean(intra_scores))
    cross_mean = float(data["cross_command_mean_similarity"])

    return {
        "model_id": data["provenance"]["model_id"],
        "retrieval_mean_top1_similarity": float(np.mean(retrieval_scores)),
        "paraphrase_mean_similarity": float(np.mean(paraphrase_scores)),
        "antonym_mean_similarity": float(np.mean(antonym_scores)),
        "alias_intra_command_similarity": intra_mean,
        "alias_inter_command_similarity": cross_mean,
        "alias_cohesion_gap": intra_mean - cross_mean,
        "trajectory_mean_step_similarity": float(np.mean(trajectory_steps)),
        "silhouette_score": silhouette,
        "davies_bouldin_index": davies_bouldin,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, default=None, help="Path to a SemanticEval data.json (default: newest under Evaluation/)")
    args = parser.parse_args()

    _verify_projection_port()

    input_path = args.input or find_latest_data_json()
    data = json.loads(input_path.read_text())
    out_dir = input_path.parent

    matrix = build_projection_matrix(data["provenance"]["dimension"], data["provenance"]["projection_seed"])

    for name, trajectory in data["trajectories"].items():
        path = plot_trajectory(name, trajectory, matrix, out_dir)
        print(f"Wrote {path}")

    for path in write_neighbor_tables(data, out_dir):
        print(f"Wrote {path}")

    benchmark_history = load_benchmark_history()
    silhouette, davies_bouldin = compute_clustering_metrics(data)

    summary_md_path = out_dir / "summary.md"
    summary_md_path.write_text(build_summary_md(data, benchmark_history, silhouette, davies_bouldin))
    print(f"Wrote {summary_md_path}")

    semantic_summary_path = out_dir / "semantic-summary.json"
    semantic_summary = build_semantic_summary(data, silhouette, davies_bouldin)
    semantic_summary_path.write_text(json.dumps(semantic_summary, indent=2) + "\n")
    print(f"Wrote {semantic_summary_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
