#!/usr/bin/env python3
"""
Per-model embedding benchmark — quality + runtime evaluation.

Measures for each model:
  - Cold load time (first model load + first encode)
  - Warm load time (second encode)
  - Embedding latency (per-text and batch)
  - Embeddings per second
  - Peak RSS
  - Model size on disk
  - Embedding dimension
  - Cosine similarity stability (ASR/typo/hesitation/filler/punctuation/capitalization variants)
  - Semantic replay accuracy (paraphrase pairs, antonym pairs, command groups)
  - Retrieval accuracy (top-k nearest neighbor for queries)
  - Nearest-neighbor consistency
  - Replay benchmark accuracy (corpus cohesion, cross-group separation)
  - Failure rate
  - Unsupported features

Usage:
  python3 Evaluation/scripts/embedding_benchmark.py \
    --repo-id BAAI/bge-small-en-v1.5 \
    --model-name bge-small-en-v1.5 \
    --output-dir Evaluation/results/embeddings/bge-small-en-v1.5 \
    [--runtime python|coreml|mlx] \
    [--hf-token TOKEN]
"""
import argparse
import gc
import json
import math
import os
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import psutil

# Add scripts dir to path for embedding_stability import
sys.path.insert(0, str(Path(__file__).parent))
from embedding_stability import measure_stability, generate_variants, cosine_sim
from provenance import collect_provenance

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
CORPUS_PATH = EVAL_DIR / "corpora" / "embedding_bench_corpus_v1.json"


def load_corpus():
    with open(CORPUS_PATH) as f:
        return json.load(f)


def get_model_size_mb(model_path):
    """Get total size of model directory in MB."""
    total = 0
    for dirpath, dirnames, filenames in os.walk(model_path):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            if not os.path.islink(fp):
                total += os.path.getsize(fp)
    return total / (1024 * 1024)


def peak_rss_mb():
    """Current process RSS in MB."""
    process = psutil.Process(os.getpid())
    return process.memory_info().rss / (1024 * 1024)


# ---------------------------------------------------------------------------
# Embedder backends
# ---------------------------------------------------------------------------

class SentenceTransformersBackend:
    """Primary backend — uses sentence-transformers for all models."""
    def __init__(self, model_path, **kwargs):
        from sentence_transformers import SentenceTransformer
        self.model = SentenceTransformer(
            model_path,
            device='cpu',  # Consistent CPU measurement
            trust_remote_code=True,  # Some models (GTE, Qwen3) require this
            **kwargs
        )
        try:
            self._dim = self.model.get_embedding_dimension()
        except AttributeError:
            self._dim = self.model.get_sentence_embedding_dimension()  # deprecated alias

    def encode(self, texts):
        """Return list of float lists (embeddings)."""
        embs = self.model.encode(
            texts,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=False,
        )
        return [e.tolist() for e in embs]

    @property
    def dimension(self):
        return self._dim

    def close(self):
        del self.model
        gc.collect()


class MLXEmbeddingBackend:
    """MLX backend for models that have mlx-community conversions."""
    def __init__(self, model_path, **kwargs):
        import mlx.core as mx
        import mlx.nn as nn
        from mlx_lm import load
        self.mx = mx
        self.model, self.tokenizer = load(model_path)
        self._dim = None

    def encode(self, texts):
        # Basic MLX embedding: mean pool last hidden states
        results = []
        for text in texts:
            tokens = self.tokenizer.encode(text)
            if not tokens:
                results.append([0.0] * (self._dim or 384))
                continue
            x = self.mx.array([tokens])
            logits = self.model(x)
            # Mean pool
            emb = logits.mean(axis=1)[0]
            # L2 normalize
            norm = self.mx.sqrt((emb * emb).sum())
            if float(norm) > 1e-9:
                emb = emb / norm
            results.append(emb.tolist())
            if self._dim is None:
                self._dim = len(results[0])
        return results

    @property
    def dimension(self):
        return self._dim or 384

    def close(self):
        del self.model
        del self.tokenizer
        gc.collect()


def load_backend(repo_id, model_path, runtime='python', hf_token=None):
    """Load the appropriate backend for the runtime."""
    if runtime == 'mlx':
        return MLXEmbeddingBackend(model_path)
    else:
        # Default: sentence-transformers
        return SentenceTransformersBackend(model_path)


# ---------------------------------------------------------------------------
# Quality evaluation
# ---------------------------------------------------------------------------

def evaluate_paraphrase_pairs(embed_fn, pairs):
    """Evaluate paraphrase pairs — high cosine = good (semantically similar)."""
    all_texts = []
    for a, b in pairs:
        all_texts.extend([a, b])
    embeddings = embed_fn(all_texts)

    results = []
    for i, (a, b) in enumerate(pairs):
        sim = cosine_sim(embeddings[i*2], embeddings[i*2+1])
        results.append({"a": a, "b": b, "cosine_similarity": sim})

    sims = [r["cosine_similarity"] for r in results]
    return {
        "pairs": results,
        "mean": float(np.mean(sims)),
        "median": float(np.median(sims)),
        "std": float(np.std(sims)),
        "min": float(np.min(sims)),
        "max": float(np.max(sims)),
        "n": len(sims),
    }


def evaluate_antonym_pairs(embed_fn, pairs):
    """Evaluate antonym pairs — lower cosine = better discrimination."""
    all_texts = []
    for a, b in pairs:
        all_texts.extend([a, b])
    embeddings = embed_fn(all_texts)

    results = []
    for i, (a, b) in enumerate(pairs):
        sim = cosine_sim(embeddings[i*2], embeddings[i*2+1])
        results.append({"a": a, "b": b, "cosine_similarity": sim})

    sims = [r["cosine_similarity"] for r in results]
    return {
        "pairs": results,
        "mean": float(np.mean(sims)),
        "median": float(np.median(sims)),
        "std": float(np.std(sims)),
        "min": float(np.min(sims)),
        "max": float(np.max(sims)),
        "n": len(sims),
    }


def evaluate_command_groups(embed_fn, command_groups):
    """Evaluate intra-group cohesion and cross-group separation."""
    # Embed all phrases
    all_phrases = []
    group_names = []
    for name, phrases in command_groups.items():
        for p in phrases:
            all_phrases.append(p)
            group_names.append(name)

    embeddings = embed_fn(all_phrases)

    # Group embeddings by name
    group_embs = {}
    for name, emb in zip(group_names, embeddings):
        group_embs.setdefault(name, []).append(emb)

    # Intra-group mean similarity
    intra_results = {}
    for name, embs in group_embs.items():
        if len(embs) < 2:
            intra_results[name] = {"mean": 1.0, "n": len(embs)}
            continue
        sims = []
        for i in range(len(embs)):
            for j in range(i+1, len(embs)):
                sims.append(cosine_sim(embs[i], embs[j]))
        intra_results[name] = {
            "mean": float(np.mean(sims)),
            "std": float(np.std(sims)) if len(sims) > 1 else 0.0,
            "n": len(sims),
            "phrases": command_groups[name],
        }

    # Cross-group mean similarity
    cross_sims = []
    names = list(group_embs.keys())
    for i in range(len(names)):
        for j in range(i+1, len(names)):
            for a in group_embs[names[i]]:
                for b in group_embs[names[j]]:
                    cross_sims.append(cosine_sim(a, b))

    cross_mean = float(np.mean(cross_sims)) if cross_sims else 0.0
    cross_std = float(np.std(cross_sims)) if cross_sims else 0.0

    # Separation ratio: mean intra / mean cross (higher = better)
    intra_means = [r["mean"] for r in intra_results.values()]
    intra_mean = float(np.mean(intra_means)) if intra_means else 0.0
    separation_ratio = intra_mean / cross_mean if cross_mean > 1e-9 else float('inf')

    return {
        "intra_group": intra_results,
        "cross_group_mean": cross_mean,
        "cross_group_std": cross_std,
        "cross_group_n": len(cross_sims),
        "intra_group_mean": intra_mean,
        "separation_ratio": separation_ratio,
    }


def evaluate_retrieval(embed_fn, corpus, queries, top_k=5):
    """Evaluate top-k retrieval accuracy — does the query retrieve semantically similar items?"""
    # Embed corpus and queries
    corpus_embs = embed_fn(corpus)
    query_embs = embed_fn(queries)

    results = {}
    for q_idx, query in enumerate(queries):
        q_emb = query_embs[q_idx]
        # Compute cosine similarities to all corpus items
        sims = []
        for c_idx, text in enumerate(corpus):
            sim = cosine_sim(q_emb, corpus_embs[c_idx])
            sims.append((text, sim))
        # Sort by similarity descending
        sims.sort(key=lambda x: -x[1])
        top_k_results = sims[:top_k]
        results[query] = [
            {"text": t, "cosine_similarity": s}
            for t, s in top_k_results
        ]

    # Retrieval quality: for each query, check if expected items appear in top-k
    # This is a proxy measure — we compute mean reciprocal rank of exact/near matches
    return {
        "queries": results,
        "top_k": top_k,
        "mean_top1_similarity": float(np.mean([
            results[q][0]["cosine_similarity"] for q in queries
        ])),
        "mean_top5_similarity": float(np.mean([
            np.mean([r["cosine_similarity"] for r in results[q][:5]])
            for q in queries
        ])),
    }


def evaluate_nn_consistency(embed_fn, corpus, queries, top_k=5):
    """Evaluate nearest-neighbor consistency — are the same items always nearest?"""
    # Run embedding twice and check if top-k neighbors are the same
    corpus_embs_1 = embed_fn(corpus)
    corpus_embs_2 = embed_fn(corpus)
    query_embs = embed_fn(queries)

    def get_top_k(q_emb, corpus_embs):
        sims = [(i, cosine_sim(q_emb, corpus_embs[i]))
                for i in range(len(corpus))]
        sims.sort(key=lambda x: -x[1])
        return set(i for i, _ in sims[:top_k])

    consistencies = []
    for q_idx, query in enumerate(queries):
        top1 = get_top_k(query_embs[q_idx], corpus_embs_1)
        top2 = get_top_k(query_embs[q_idx], corpus_embs_2)
        overlap = len(top1 & top2) / top_k
        consistencies.append(overlap)

    return {
        "mean_consistency": float(np.mean(consistencies)),
        "std_consistency": float(np.std(consistencies)),
        "per_query": consistencies,
        "top_k": top_k,
    }


def evaluate_neighborhood_stability(embed_fn, corpus, stability_test_set, top_k=5):
    """
    Evaluate neighborhood stability under perturbation.

    For each test text:
      1. Compute top-k corpus neighbors of the original embedding
      2. Compute top-k corpus neighbors of each variant's embedding
      3. Measure Jaccard overlap between original and variant neighbor sets

    This is a FIRST-CLASS metric: retrieval pipelines care more about
    preserving neighborhood structure than about preserving cosine magnitude.

    Returns per-text, per-variant-type, and overall Jaccard overlap statistics.
    """
    from embedding_stability import generate_variants, generate_semantic_variants

    # Embed the full corpus once
    corpus_embs = embed_fn(corpus)

    def get_top_k_neighbors(emb, corpus_embeddings, k):
        sims = [(i, cosine_sim(emb, corpus_embeddings[i]))
                for i in range(len(corpus))]
        sims.sort(key=lambda x: -x[1])
        return set(i for i, _ in sims[:k])

    # For each test text, compute original + variant neighbor sets
    all_texts = []
    text_map = []  # (test_idx, variant_type, text)

    for i, text in enumerate(stability_test_set):
        all_texts.append(text)
        text_map.append((i, "original", text))
        noise_variants = generate_variants(text)
        for vtype, vtext in noise_variants.items():
            all_texts.append(vtext)
            text_map.append((i, vtype, vtext))
        sem_variants = generate_semantic_variants(text)
        for vtype, vtext in sem_variants.items():
            all_texts.append(vtext)
            text_map.append((i, f"semantic_{vtype}", vtext))

    # Embed all test texts + variants
    all_embs = embed_fn(all_texts)

    # Map embeddings
    original_embs = {}
    variant_embs = {}
    for (test_idx, vtype, _), emb in zip(text_map, all_embs):
        if vtype == "original":
            original_embs[test_idx] = emb
        else:
            variant_embs[(test_idx, vtype)] = emb

    # Compute neighbor sets and Jaccard overlap
    per_text = []
    noise_jaccards_by_type = {}
    semantic_jaccards_by_type = {}
    all_noise_jaccards = []
    all_semantic_jaccards = []

    for i, text in enumerate(stability_test_set):
        orig_neighbors = get_top_k_neighbors(original_embs[i], corpus_embs, top_k)
        text_result = {"text": text, "original_neighbors": list(orig_neighbors),
                       "noise_variants": {}, "semantic_variants": {}}

        # Noise variants
        for vtype, _ in [("asr", None), ("typo", None), ("hesitation", None),
                         ("filler", None), ("punctuation", None),
                         ("capitalization", None), ("no_punctuation", None),
                         ("doubled_word", None)]:
            vemb = variant_embs.get((i, vtype))
            if vemb is not None:
                v_neighbors = get_top_k_neighbors(vemb, corpus_embs, top_k)
                jaccard = len(orig_neighbors & v_neighbors) / len(orig_neighbors | v_neighbors) if orig_neighbors | v_neighbors else 1.0
                text_result["noise_variants"][vtype] = {
                    "jaccard_overlap": jaccard,
                    "neighbor_overlap": len(orig_neighbors & v_neighbors) / top_k,
                }
                noise_jaccards_by_type.setdefault(vtype, []).append(jaccard)
                all_noise_jaccards.append(jaccard)

        # Semantic variants
        for vtype, _ in [("politeness", None), ("question", None), ("synonym", None),
                         ("drop_article", None), ("demonstrative", None),
                         ("pluralize", None), ("contraction", None)]:
            key = f"semantic_{vtype}"
            vemb = variant_embs.get((i, key))
            if vemb is not None:
                v_neighbors = get_top_k_neighbors(vemb, corpus_embs, top_k)
                jaccard = len(orig_neighbors & v_neighbors) / len(orig_neighbors | v_neighbors) if orig_neighbors | v_neighbors else 1.0
                text_result["semantic_variants"][vtype] = {
                    "jaccard_overlap": jaccard,
                    "neighbor_overlap": len(orig_neighbors & v_neighbors) / top_k,
                }
                semantic_jaccards_by_type.setdefault(vtype, []).append(jaccard)
                all_semantic_jaccards.append(jaccard)

        per_text.append(text_result)

    # Aggregate stats
    def agg_stats(jaccards):
        if not jaccards:
            return {}
        arr = np.array(jaccards)
        return {
            "mean": float(arr.mean()),
            "median": float(np.median(arr)),
            "std": float(arr.std()),
            "min": float(arr.min()),
            "max": float(arr.max()),
            "n": len(jaccards),
        }

    per_noise_type = {vt: agg_stats(jacs) for vt, jacs in noise_jaccards_by_type.items()}
    per_sem_type = {vt: agg_stats(jacs) for vt, jacs in semantic_jaccards_by_type.items()}

    return {
        "per_text": per_text,
        "per_noise_type": per_noise_type,
        "per_semantic_type": per_sem_type,
        "noise_overall": agg_stats(all_noise_jaccards),
        "semantic_overall": agg_stats(all_semantic_jaccards),
        "top_k": top_k,
    }


def evaluate_trajectories(embed_fn, trajectories):
    """Evaluate trajectory embeddings — step-to-step cosine similarity."""
    all_phrases = []
    for traj in trajectories:
        all_phrases.extend(traj["phrases"])

    embeddings = embed_fn(all_phrases)

    offset = 0
    results = {}
    for traj in trajectories:
        n = len(traj["phrases"])
        traj_embs = embeddings[offset:offset+n]
        offset += n

        step_sims = []
        for i in range(len(traj_embs) - 1):
            step_sims.append(cosine_sim(traj_embs[i], traj_embs[i+1]))

        results[traj["name"]] = {
            "phrases": traj["phrases"],
            "step_cosine_similarities": step_sims,
            "mean_step_similarity": float(np.mean(step_sims)) if step_sims else 0.0,
            "total_drift": 1.0 - cosine_sim(traj_embs[0], traj_embs[-1]) if len(traj_embs) > 1 else 0.0,
        }

    return results


# ---------------------------------------------------------------------------
# Main benchmark
# ---------------------------------------------------------------------------

def run_benchmark(repo_id, model_name, model_path, output_dir, runtime='python',
                  hf_token=None, corpus=None):
    """Run the full benchmark for a single model."""
    if corpus is None:
        corpus = load_corpus()

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    result = {
        "model_name": model_name,
        "repo_id": repo_id,
        "runtime": runtime,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "status": "running",
        # schema_version 2 = provenance + measurement_context added; v1
        # artifacts (pre-2026-07-14) lack both and are flagged as legacy by
        # validate_checkpoints.py, never backfilled.
        "schema_version": 2,
        "provenance": collect_provenance(
            corpus_fixtures={"embedding_bench_corpus": CORPUS_PATH}
        ),
        # The headline embeddings_per_second is the warm batch-128 encode —
        # recorded explicitly so aggregate numbers stay traceable to their
        # measurement condition (see reports/throughput_discrepancy.md).
        "measurement_context": {
            "device": "cpu",
            "throughput_measurement": "warm_batch_encode",
            "throughput_batch_size": 128,
        },
    }

    errors = []
    unsupported_features = []

    try:
        # --- Load model (cold) ---
        print(f"  Loading model (cold)...")
        gc.collect()
        rss_before = peak_rss_mb()
        cold_start = time.time()
        backend = load_backend(repo_id, model_path, runtime, hf_token)
        cold_load_time = time.time() - cold_start
        rss_after_load = peak_rss_mb()
        print(f"  Cold load: {cold_load_time:.2f}s, RSS: {rss_after_load:.0f}MB")

        result["cold_load_time"] = cold_load_time
        result["dimension"] = backend.dimension
        result["model_size_mb"] = get_model_size_mb(model_path)
        result["peak_rss_after_load_mb"] = rss_after_load

        # Embed function wrapper
        def embed_fn(texts):
            return backend.encode(texts)

        # --- Warm encode (single) ---
        print(f"  Warm encode (single)...")
        warm_start = time.time()
        _ = embed_fn(["test sentence for warmup"])
        warm_encode_time = time.time() - warm_start
        result["warm_encode_time_ms"] = warm_encode_time * 1000
        print(f"  Warm encode: {warm_encode_time*1000:.1f}ms")

        # --- Batch latency ---
        print(f"  Batch latency...")
        batch_sizes = [1, 8, 32, 128]
        batch_times = {}
        for size in batch_sizes:
            batch = [f"sentence number {i}" for i in range(size)]
            start = time.time()
            _ = embed_fn(batch)
            elapsed = time.time() - start
            batch_times[str(size)] = {
                "total_ms": elapsed * 1000,
                "per_text_ms": (elapsed / size) * 1000,
                "embeddings_per_second": size / elapsed if elapsed > 0 else 0,
            }
            print(f"    batch={size}: {elapsed*1000:.1f}ms ({size/elapsed:.0f}/s)")

        result["batch_metrics"] = batch_times
        result["embeddings_per_second"] = batch_times.get("128", {}).get("embeddings_per_second", 0)
        result["peak_rss_mb"] = peak_rss_mb()

        # --- Quality: paraphrase pairs ---
        print(f"  Evaluating paraphrase pairs ({len(corpus['paraphrasePairs'])})...")
        result["paraphrase_pairs"] = evaluate_paraphrase_pairs(
            embed_fn, corpus["paraphrasePairs"]
        )

        # --- Quality: antonym pairs ---
        print(f"  Evaluating antonym pairs ({len(corpus['antonymPairs'])})...")
        result["antonym_pairs"] = evaluate_antonym_pairs(
            embed_fn, corpus["antonymPairs"]
        )

        # --- Quality: command groups ---
        print(f"  Evaluating command groups ({len(corpus['commandGroups'])})...")
        result["command_groups"] = evaluate_command_groups(
            embed_fn, corpus["commandGroups"]
        )

        # --- Quality: retrieval ---
        print(f"  Evaluating retrieval ({len(corpus['queries'])} queries, {len(corpus['corpus'])} corpus)...")
        result["retrieval"] = evaluate_retrieval(
            embed_fn, corpus["corpus"], corpus["queries"], corpus.get("topK", 5)
        )

        # --- Quality: NN consistency ---
        print(f"  Evaluating NN consistency...")
        result["nn_consistency"] = evaluate_nn_consistency(
            embed_fn, corpus["corpus"], corpus["queries"], corpus.get("topK", 5)
        )

        # --- Neighborhood stability under perturbation ---
        print(f"  Evaluating neighborhood stability ({len(corpus['stabilityTestSet'])} texts)...")
        result["neighborhood_stability"] = evaluate_neighborhood_stability(
            embed_fn, corpus["corpus"], corpus["stabilityTestSet"], corpus.get("topK", 5)
        )

        # --- Quality: trajectories ---
        print(f"  Evaluating trajectories ({len(corpus['trajectories'])})...")
        result["trajectories"] = evaluate_trajectories(
            embed_fn, corpus["trajectories"]
        )

        # --- Stability benchmark ---
        print(f"  Evaluating embedding stability ({len(corpus['stabilityTestSet'])} texts)...")
        stability_result = measure_stability(
            embed_fn, corpus["stabilityTestSet"]
        )
        result["stability"] = stability_result

        # --- Embedding sample for cross-runtime consistency ---
        # Store first 10 corpus embeddings as a deterministic fingerprint
        # for cross-runtime cosine comparison
        print(f"  Storing embedding sample for cross-runtime comparison...")
        sample_texts = corpus["corpus"][:10]
        sample_embs = embed_fn(sample_texts)
        result["embedding_sample"] = {
            "texts": sample_texts,
            "embeddings": sample_embs,
            "dimension": backend.dimension,
        }

        # --- Failure metrics ---
        result["failure_rate"] = 0.0
        result["crash_rate"] = 0.0
        result["unsupported_features"] = unsupported_features

        # --- Final metrics ---
        result["peak_rss_final_mb"] = peak_rss_mb()
        result["status"] = "evaluated"

        # Cleanup
        backend.close()
        gc.collect()

    except Exception as e:
        import traceback
        error_msg = str(e)
        tb = traceback.format_exc()
        print(f"  BENCHMARK FAILED: {error_msg}")
        print(tb)

        # Classify the failure into a structured category
        failure_class = "unknown"
        failure_reason = error_msg[:200]

        error_lower = error_msg.lower()
        if "size mismatch" in error_lower and "quant" in error_lower:
            failure_class = "runtime_incompatibility"
            failure_reason = "mlx_quantized_weights"
        elif "size mismatch" in error_lower or "mismatch" in error_lower:
            failure_class = "runtime_incompatibility"
            failure_reason = "weight_size_mismatch"
        elif "trust_remote_code" in error_lower:
            failure_class = "model_not_supported"
            failure_reason = "requires_trust_remote_code"
        elif "not found" in error_lower or "404" in error_lower:
            failure_class = "model_not_found"
            failure_reason = "repo_or_file_missing"
        elif "tokenizer" in error_lower:
            failure_class = "tokenizer_error"
            failure_reason = "tokenizer_load_failed"
        elif "timeout" in error_lower:
            failure_class = "timeout"
            failure_reason = "inference_timeout"
        elif "out of memory" in error_lower or "oom" in error_lower:
            failure_class = "resource_exhausted"
            failure_reason = "out_of_memory"
        elif "gated" in error_lower or "401" in error_lower or "403" in error_lower:
            failure_class = "access_denied"
            failure_reason = "gated_or_unauthorized"

        result["status"] = f"failed: {error_msg}"
        result["error"] = error_msg
        result["traceback"] = tb
        result["failure_class"] = failure_class
        result["failure_reason"] = failure_reason
        result["failure_rate"] = 1.0
        result["crash_rate"] = 1.0 if "crash" in error_lower else 0.0

    # Write result
    result_path = output_dir / "benchmark.json"
    with open(result_path, "w") as f:
        json.dump(result, f, indent=2, default=str)
    print(f"  Wrote: {result_path}")

    return result


def main():
    parser = argparse.ArgumentParser(description="Per-model embedding benchmark")
    parser.add_argument("--repo-id", required=True, help="HuggingFace repo ID")
    parser.add_argument("--model-name", required=True, help="Model name for output")
    parser.add_argument("--model-path", required=True, help="Local path to model directory")
    parser.add_argument("--output-dir", required=True, help="Output directory for results")
    parser.add_argument("--runtime", default="python", choices=["python", "mlx"],
                        help="Inference runtime (default: python=sentence-transformers)")
    parser.add_argument("--hf-token", default=None, help="HuggingFace token")
    args = parser.parse_args()

    # Load token from .env if not provided
    hf_token = args.hf_token
    if not hf_token:
        env_path = REPO_ROOT / ".env"
        if env_path.exists():
            with open(env_path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("HF_API_TOKEN="):
                        hf_token = line.split("=", 1)[1].strip().strip('"').strip("'")
                        break

    print(f"=== Embedding Benchmark ===")
    print(f"Model: {args.model_name}")
    print(f"Repo: {args.repo_id}")
    print(f"Path: {args.model_path}")
    print(f"Runtime: {args.runtime}")

    result = run_benchmark(
        repo_id=args.repo_id,
        model_name=args.model_name,
        model_path=args.model_path,
        output_dir=args.output_dir,
        runtime=args.runtime,
        hf_token=hf_token,
    )

    if result["status"] == "evaluated":
        print(f"\nBenchmark completed successfully.")
        print(f"  Dimension: {result.get('dimension')}")
        print(f"  Cold load: {result.get('cold_load_time', 0):.2f}s")
        print(f"  Embeddings/s: {result.get('embeddings_per_second', 0):.0f}")
        print(f"  Peak RSS: {result.get('peak_rss_mb', 0):.0f}MB")
        print(f"  Stability mean: {result.get('stability', {}).get('overall', {}).get('mean', 0):.4f}")
        print(f"  Paraphrase mean: {result.get('paraphrase_pairs', {}).get('mean', 0):.4f}")
        print(f"  Antonym mean: {result.get('antonym_pairs', {}).get('mean', 0):.4f}")
        print(f"  Separation ratio: {result.get('command_groups', {}).get('separation_ratio', 0):.2f}")
    else:
        print(f"\nBenchmark FAILED: {result.get('error', 'unknown')}")
        sys.exit(1)


if __name__ == "__main__":
    main()