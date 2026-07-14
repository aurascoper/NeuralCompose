#!/usr/bin/env python3
"""
Stage 3.4-C: Embedding-space analysis.

Representation similarity metrics between embedding models:
  - CKA (Centered Kernel Alignment) — linear
  - SVCCA (Singular Variable CCA) — top-K singular directions
  - Procrustes alignment — orthogonal rotation + disparity
  - Neighborhood overlap — Jaccard of top-k neighbors
  - Cluster purity — do k-means clusters align across models?
  - Intrinsic dimensionality — via participation ratio

Reads:  Evaluation/results/embeddings/<model>/<runtime>/benchmark.json
Writes: Evaluation/results/stage_3_4/embedding_space_analysis.json
        Evaluation/results/stage_3_4/embedding_space_analysis.md
"""
import json
import sys
from datetime import datetime, timezone
from itertools import combinations
from pathlib import Path

import numpy as np
from scipy.spatial import procrustes as scipy_procrustes

sys.path.insert(0, str(Path(__file__).parent))
from eval_stats import bootstrap_ci
from select_top_k import select_top_embeddings, load_stored_embeddings

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
OUTPUT_DIR = EVAL_DIR / "results" / "stage_3_4"


def cka(X, Y):
    X = np.array(X, dtype=np.float64)
    Y = np.array(Y, dtype=np.float64)
    X = X - X.mean(axis=0)
    Y = Y - Y.mean(axis=0)
    K = X @ X.T
    L = Y @ Y.T
    n = X.shape[0]
    hsic_xy = np.trace(K @ L) / (n - 1) ** 2
    hsic_xx = np.trace(K @ K) / (n - 1) ** 2
    hsic_yy = np.trace(L @ L) / (n - 1) ** 2
    denom = np.sqrt(hsic_xx * hsic_yy)
    if denom < 1e-12:
        return 0.0
    return float(hsic_xy / denom)


def svcca(X, Y, n_directions=4):
    X = np.array(X, dtype=np.float64)
    Y = np.array(Y, dtype=np.float64)
    X = X - X.mean(axis=0)
    Y = Y - Y.mean(axis=0)
    Ux, Sx, _ = np.linalg.svd(X, full_matrices=False)
    Uy, Sy, _ = np.linalg.svd(Y, full_matrices=False)
    k = min(n_directions, len(Sx), len(Sy))
    X_proj = Ux[:, :k]
    Y_proj = Uy[:, :k]
    C = X_proj.T @ Y_proj
    s = np.linalg.svd(C, compute_uv=False)
    return float(np.mean(s[:k]))


def procrustes_alignment(X, Y):
    X = np.array(X, dtype=np.float64)
    Y = np.array(Y, dtype=np.float64)
    if X.shape[1] != Y.shape[1]:
        min_dim = min(X.shape[1], Y.shape[1])
        X = X[:, :min_dim]
        Y = Y[:, :min_dim]
    mtx1, mtx2, disparity = scipy_procrustes(X, Y)
    return {"disparity": float(disparity), "n_samples": X.shape[0], "n_dims": X.shape[1]}


def neighborhood_overlap(X, Y, top_k=5):
    X = np.array(X, dtype=np.float32)
    Y = np.array(Y, dtype=np.float32)
    n = X.shape[0]
    X_norm = X / np.linalg.norm(X, axis=1, keepdims=True)
    Y_norm = Y / np.linalg.norm(Y, axis=1, keepdims=True)
    sim_X = X_norm @ X_norm.T
    sim_Y = Y_norm @ Y_norm.T
    np.fill_diagonal(sim_X, -np.inf)
    np.fill_diagonal(sim_Y, -np.inf)
    jaccards = []
    for i in range(n):
        top_X = set(np.argsort(sim_X[i])[::-1][:top_k])
        top_Y = set(np.argsort(sim_Y[i])[::-1][:top_k])
        union = top_X | top_Y
        if union:
            jaccards.append(len(top_X & top_Y) / len(union))
    return float(np.mean(jaccards)) if jaccards else 0.0


def cluster_purity(X, Y, n_clusters=5):
    from sklearn.cluster import KMeans
    X = np.array(X, dtype=np.float32)
    Y = np.array(Y, dtype=np.float32)
    if X.shape[0] != Y.shape[0]:
        return 0.0
    km_X = KMeans(n_clusters=min(n_clusters, X.shape[0] - 1), random_state=42, n_init=10)
    km_Y = KMeans(n_clusters=min(n_clusters, Y.shape[0] - 1), random_state=42, n_init=10)
    labels_X = km_X.fit_predict(X)
    labels_Y = km_Y.fit_predict(Y)
    purity = 0.0
    n = len(labels_X)
    for lx in set(labels_X):
        mask = labels_X == lx
        y_labels = labels_Y[mask]
        if len(y_labels) > 0:
            purity += max(np.sum(y_labels == ly) for ly in set(y_labels)) / n
    return float(purity)


def intrinsic_dimensionality(X):
    X = np.array(X, dtype=np.float64)
    X = X - X.mean(axis=0)
    cov = np.cov(X.T)
    eigenvalues = np.linalg.eigvalsh(cov)
    eigenvalues = eigenvalues[eigenvalues > 1e-10]
    if len(eigenvalues) == 0:
        return 0.0
    pr = float(np.sum(eigenvalues) ** 2 / np.sum(eigenvalues ** 2))
    return pr


def analyze_pair(name_a, embs_a, name_b, embs_b):
    return {
        "model_a": name_a,
        "model_b": name_b,
        "cka": cka(embs_a, embs_b),
        "svcca": svcca(embs_a, embs_b),
        "procrustes_disparity": procrustes_alignment(embs_a, embs_b)["disparity"],
        "neighborhood_overlap": neighborhood_overlap(embs_a, embs_b),
        "cluster_purity": cluster_purity(embs_a, embs_b),
        "intrinsic_dim_a": intrinsic_dimensionality(embs_a),
        "intrinsic_dim_b": intrinsic_dimensionality(embs_b),
    }


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    top_models = select_top_embeddings(k=5)
    print("=== Stage 3.4-C: Embedding-Space Analysis ===")
    print(f"Analyzing top-{len(top_models)} models")
    model_embeddings = {}
    for m in top_models:
        name = m["name"]
        try:
            sample = load_stored_embeddings(name, m.get("runtime", "python"))
            model_embeddings[name] = np.array(sample["embeddings"], dtype=np.float32)
            print(f"  Loaded {name}: {len(model_embeddings[name])} samples, dim={model_embeddings[name].shape[1]}")
        except (FileNotFoundError, ValueError) as e:
            print(f"  SKIP {name}: {e}")
    if len(model_embeddings) < 2:
        print("\nERROR: Need at least 2 models with stored embeddings.")
        sys.exit(1)
    model_names = list(model_embeddings.keys())
    pair_results = []
    for a, b in combinations(model_names, 2):
        print(f"\n  Comparing {a} vs {b}...")
        result = analyze_pair(a, model_embeddings[a], b, model_embeddings[b])
        pair_results.append(result)
        print(f"    CKA={result['cka']:.4f} SVCCA={result['svcca']:.4f} "
              f"Procrustes={result['procrustes_disparity']:.4f} "
              f"NN_overlap={result['neighborhood_overlap']:.4f} "
              f"cluster_purity={result['cluster_purity']:.4f}")
    dims = {name: intrinsic_dimensionality(embs) for name, embs in model_embeddings.items()}
    output = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "models": model_names,
        "pairwise": pair_results,
        "intrinsic_dimensionality": dims,
    }
    out_path = OUTPUT_DIR / "embedding_space_analysis.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2, default=str)
    print(f"\nWrote {out_path}")
    lines = ["# Stage 3.4-C: Embedding-Space Analysis", ""]
    lines.append(f"**Generated:** {output['generated_at']}")
    lines.append(f"**Models:** {', '.join(model_names)}")
    lines.append("")
    lines.append("## Intrinsic Dimensionality (Participation Ratio)")
    lines.append("| Model | Intrinsic Dim |")
    lines.append("|-------|---------------|")
    for name, dim in dims.items():
        lines.append(f"| {name} | {dim:.2f} |")
    lines.append("")
    lines.append("## Pairwise Analysis")
    lines.append("| Pair | CKA | SVCCA | Procrustes | NN Overlap | Cluster Purity |")
    lines.append("|------|-----|-------|------------|------------|-----------------|")
    for r in pair_results:
        lines.append(
            f"| {r['model_a']} vs {r['model_b']} "
            f"| {r['cka']:.4f} | {r['svcca']:.4f} "
            f"| {r['procrustes_disparity']:.4f} "
            f"| {r['neighborhood_overlap']:.4f} "
            f"| {r['cluster_purity']:.4f} |"
        )
    lines.append("")
    md_path = OUTPUT_DIR / "embedding_space_analysis.md"
    with open(md_path, "w") as f:
        f.write("\n".join(lines))
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
