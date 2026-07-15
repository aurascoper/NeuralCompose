#!/usr/bin/env python3
"""
Runtime compatibility classification for embedding model candidates.

Probes each candidate and classifies it into:
  - coreml_only   — Core ML convertible, no MLX
  - mlx_only      — MLX available, no Core ML
  - both          — both runtimes available
  - python_only   — neither Core ML nor MLX, but runnable via sentence-transformers
  - unsupported   — cannot run locally (gated + no token, architecture mismatch, etc.)

Output:
  Evaluation/results/embeddings/compatibility_matrix.json
  Evaluation/results/embeddings/compatibility_matrix.md

Usage:
  python3 Evaluation/scripts/classify_compatibility.py [--hf-token TOKEN]
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
RESULTS_DIR = EVAL_DIR / "results" / "embeddings"
FIXTURE_PATH = EVAL_DIR / "corpora" / "embedding_bench_candidates_v1.json"


def load_candidates():
    with open(FIXTURE_PATH) as f:
        return json.load(f)


def check_hf_availability(repo_id, hf_token=None):
    """Check if a model repo exists on HuggingFace and is accessible."""
    try:
        from huggingface_hub import HfApi
        api = HfApi(token=hf_token)
        info = api.model_info(repo_id)
        return True, {
            "downloads": getattr(info, "downloads", 0),
            "likes": getattr(info, "likes", 0),
            "pipeline_tag": getattr(info, "pipeline_tag", None),
            "library_name": getattr(info, "library_name", None),
            "gated": getattr(info, "gated", False),
        }
    except Exception as e:
        return False, {"error": str(e)}


def check_coreml_compatibility(candidate):
    """
    Determine if a model is Core ML convertible.

    Heuristics:
    - BERT-family models (BGE, E5, MiniLM, GTE) with dim <= 768 and
      max_seq <= 512: convertible via coremltools
    - Models with custom architectures (Qwen3, Jina v3 with late interaction,
      Nomic with specialized tokenizer): not convertible
    - Models > 768 dim: technically convertible but ANE memory constraints
      make it impractical on 16GB
    """
    dim = candidate.get("dimension", 0)
    max_seq = candidate.get("max_seq_length", 0)
    family = candidate.get("family", "")
    coreml_flag = candidate.get("coreml_convertible", False)

    reasons = []

    if not coreml_flag:
        reasons.append("marked not coreml_convertible in fixture")
        return False, reasons

    if dim > 768:
        reasons.append(f"dimension {dim} > 768 — ANE memory impractical on 16GB")
        return False, reasons

    if max_seq > 512:
        reasons.append(f"max_seq {max_seq} > 512 — Core ML fixed-shape constraint")
        return False, reasons

    # BERT-family check
    convertible_families = {"BGE", "E5", "MiniLM", "GTE"}
    if family in convertible_families:
        return True, reasons

    reasons.append(f"family {family} not in known convertible set {convertible_families}")
    return False, reasons


def check_mlx_compatibility(candidate, hf_token=None):
    """
    Determine if a model has an MLX-converted version available.

    Checks:
    1. If the candidate itself is from mlx-community (already MLX)
    2. If mlx-community has a converted version of the same model
    """
    repo_id = candidate["repo_id"]
    mlx_flag = candidate.get("mlx_available", False)

    if not mlx_flag:
        return False, ["marked mlx_available=false in fixture"]

    if "mlx-community" in repo_id:
        return True, ["candidate is already mlx-community"]

    # Check if mlx-community has a converted version
    mlx_repo = f"mlx-community/{candidate['name']}"
    available, info = check_hf_availability(mlx_repo, hf_token)
    if available:
        return True, [f"mlx-community/{candidate['name']} exists"]

    # Also check common naming patterns
    for pattern in [
        f"mlx-community/{candidate['name']}-4bit",
        f"mlx-community/{candidate['name']}-float16",
        f"mlx-community/{repo_id.replace('/', '-')}",
    ]:
        available, _ = check_hf_availability(pattern, hf_token)
        if available:
            return True, [f"{pattern} exists"]

    # Mark as theoretically compatible but no pre-converted version
    return False, ["no mlx-community conversion found, but architecture is MLX-compatible"]


def classify_one(candidate, hf_token=None):
    """Classify a single candidate."""
    name = candidate["name"]
    repo_id = candidate["repo_id"]

    print(f"\n  {name} ({repo_id})")

    # Check HF availability
    hf_ok, hf_info = check_hf_availability(repo_id, hf_token)
    if not hf_ok:
        print(f"    HF: UNAVAILABLE ({hf_info.get('error', 'unknown')})")
        return {
            "name": name,
            "repo_id": repo_id,
            "classification": "unsupported",
            "hf_available": False,
            "hf_error": hf_info.get("error"),
            "coreml": {"supported": False, "reasons": ["HF unavailable"]},
            "mlx": {"supported": False, "reasons": ["HF unavailable"]},
            "python": {"supported": False, "reasons": ["HF unavailable"]},
            "runtimes": [],
        }

    print(f"    HF: available (downloads={hf_info.get('downloads', '?')}, "
          f"gated={hf_info.get('gated', False)})")

    # Check Core ML
    coreml_ok, coreml_reasons = check_coreml_compatibility(candidate)
    print(f"    Core ML: {'yes' if coreml_ok else 'no'} — {'; '.join(coreml_reasons) or 'OK'}")

    # Check MLX
    mlx_ok, mlx_reasons = check_mlx_compatibility(candidate, hf_token)
    print(f"    MLX: {'yes' if mlx_ok else 'no'} — {'; '.join(mlx_reasons)}")

    # Python (sentence-transformers) is always available if HF is accessible
    python_ok = True

    # Classify
    if coreml_ok and mlx_ok:
        classification = "both"
    elif coreml_ok and not mlx_ok:
        classification = "coreml_only"
    elif mlx_ok and not coreml_ok:
        classification = "mlx_only"
    elif python_ok:
        classification = "python_only"
    else:
        classification = "unsupported"

    runtimes = []
    if coreml_ok:
        runtimes.append("coreml")
    if mlx_ok:
        runtimes.append("mlx")
    if python_ok:
        runtimes.append("python")

    print(f"    Classification: {classification} (runtimes: {', '.join(runtimes)})")

    return {
        "name": name,
        "repo_id": repo_id,
        "classification": classification,
        "hf_available": True,
        "hf_info": {k: v for k, v in hf_info.items() if k != "error"},
        "coreml": {"supported": coreml_ok, "reasons": coreml_reasons},
        "mlx": {"supported": mlx_ok, "reasons": mlx_reasons},
        "python": {"supported": python_ok, "reasons": []},
        "runtimes": runtimes,
        "family": candidate.get("family"),
        "dimension": candidate.get("dimension"),
        "size_category": candidate.get("size_category"),
        "estimated_size_mb": candidate.get("estimated_size_mb"),
        "license": candidate.get("license"),
        "languages": candidate.get("languages"),
    }


def generate_matrix_md(results):
    """Generate markdown compatibility matrix."""
    lines = []
    lines.append("# Embedding Model Compatibility Matrix")
    lines.append("")
    lines.append(f"**Generated:** {results['generated_at']}")
    lines.append(f"**Candidates:** {len(results['candidates'])}")
    lines.append("")

    # Summary counts
    counts = {}
    for c in results["candidates"]:
        cls = c["classification"]
        counts[cls] = counts.get(cls, 0) + 1

    lines.append("## Summary")
    lines.append("")
    lines.append("| Classification | Count |")
    lines.append("|----------------|-------|")
    for cls in ["both", "coreml_only", "mlx_only", "python_only", "unsupported"]:
        lines.append(f"| {cls} | {counts.get(cls, 0)} |")
    lines.append("")

    # Full matrix
    lines.append("## Full Matrix")
    lines.append("")
    lines.append("| Model | Family | Core ML | MLX | Python | Classification | Dim | Size | License |")
    lines.append("|-------|--------|---------|-----|--------|----------------|-----|------|---------|")
    for c in results["candidates"]:
        coreml = "✓" if c["coreml"]["supported"] else "✗"
        mlx = "✓" if c["mlx"]["supported"] else "✗"
        python = "✓" if c["python"]["supported"] else "✗"
        lines.append(
            f"| {c['name']} | {c.get('family', '?')} | {coreml} | {mlx} | {python} "
            f"| {c['classification']} | {c.get('dimension', '?')} "
            f"| {c.get('size_category', '?')} | {c.get('license', '?')} |"
        )
    lines.append("")

    # Per-model details
    lines.append("## Details")
    lines.append("")
    for c in results["candidates"]:
        lines.append(f"### {c['name']}")
        lines.append(f"- **Repo:** {c['repo_id']}")
        lines.append(f"- **Classification:** {c['classification']}")
        lines.append(f"- **Runtimes:** {', '.join(c['runtimes']) or 'none'}")
        if c["coreml"]["reasons"]:
            lines.append(f"- **Core ML:** {'supported' if c['coreml']['supported'] else 'not supported'} — {'; '.join(c['coreml']['reasons'])}")
        if c["mlx"]["reasons"]:
            lines.append(f"- **MLX:** {'supported' if c['mlx']['supported'] else 'not supported'} — {'; '.join(c['mlx']['reasons'])}")
        if not c.get("hf_available", True):
            lines.append(f"- **HF Error:** {c.get('hf_error', 'unknown')}")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Classify embedding model runtime compatibility")
    parser.add_argument("--hf-token", default=None, help="HuggingFace token (for gated models)")
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

    if hf_token:
        print("HF token loaded (not displayed)")
    else:
        print("No HF token found — gated models will be classified as unsupported")

    fixture = load_candidates()
    print(f"\n=== Compatibility Classification ===")
    print(f"Candidates: {len(fixture['candidates'])}")

    results = []
    for c in fixture["candidates"]:
        result = classify_one(c, hf_token)
        results.append(result)

    # Write output
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    matrix = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "fixture_version": fixture["version"],
        "candidates": results,
    }

    json_path = RESULTS_DIR / "compatibility_matrix.json"
    with open(json_path, "w") as f:
        json.dump(matrix, f, indent=2, default=str)
    print(f"\nWrote: {json_path}")

    md_path = RESULTS_DIR / "compatibility_matrix.md"
    md_content = generate_matrix_md(matrix)
    with open(md_path, "w") as f:
        f.write(md_content)
    print(f"Wrote: {md_path}")

    # Print summary
    counts = {}
    for r in results:
        cls = r["classification"]
        counts[cls] = counts.get(cls, 0) + 1
    print(f"\nSummary: {counts}")


if __name__ == "__main__":
    main()