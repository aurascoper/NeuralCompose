#!/usr/bin/env python3
"""Run remaining benchmark candidates with corrected repo names."""
import json, os, subprocess, time, shutil
from pathlib import Path
from huggingface_hub import snapshot_download

REPO = Path("/Users/aurascoper/Developer/NeuralCompose")
MODELS = REPO / "Models"
CANDIDATES_DIR = REPO / "Evaluation/results/candidates"
EVAL_BIN = REPO / ".build/xcode/Build/Products/Debug/GenerationEval"
PROBE_BIN = REPO / ".build/xcode/Build/Products/Debug/MLXProbe"

HF_TOKEN = open(REPO / ".env").read().strip().split("=")[1]

remaining = [
    {"name": "smollm2-1.7b", "repo": "mlx-community/SmolLM2-1.7B-Instruct", "dir": "SmolLM2-1.7B-Instruct", "eos": ["<|im_end|>"], "rp": 1.3},
    {"name": "qwen3-1.7b", "repo": "mlx-community/Qwen3-1.7B-4bit", "dir": "Qwen3-1.7B-4bit", "eos": ["<|im_end|>"], "rp": 1.3},
    {"name": "tinyllama-1.1b", "repo": "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit", "dir": "TinyLlama-1.1B-Chat-v1.0-4bit", "eos": ["</s>"], "rp": 1.3},
    {"name": "openelm-1.1b", "repo": "mlx-community/OpenELM-1_1B-Instruct-4bit", "dir": "OpenELM-1_1B-Instruct-4bit", "eos": ["<|im_end|>"], "rp": 1.3},
    {"name": "gemma-3-4b", "repo": "mlx-community/gemma-3-4b-it-4bit", "dir": "gemma-3-4b-it-4bit", "eos": ["<end_of_turn>"], "rp": 1.3},
]

preexisting = {"Qwen2.5-0.5B-Instruct-4bit", "gemma-3n-E2B-it-lm-4bit", "gemma-3-1b-it-4bit"}

for cand in remaining:
    name = cand["name"]
    model_dir = MODELS / cand["dir"]
    checkpoint = CANDIDATES_DIR / name

    if (checkpoint / "raw.json").exists():
        print(f"SKIP {name} — checkpoint exists")
        continue

    print(f"\n{'='*60}")
    print(f"Candidate: {name}")
    print(f"{'='*60}")
    checkpoint.mkdir(parents=True, exist_ok=True)

    if not model_dir.exists() or not any(model_dir.glob("*.safetensors")):
        print(f"  Downloading {cand['repo']}...")
        try:
            snapshot_download(repo_id=cand["repo"], local_dir=str(model_dir), token=HF_TOKEN)
            print(f"  Download complete.")
        except Exception as e:
            print(f"  Download FAILED: {str(e)[:200]}")
            meta = {"name": name, "error": "download_failed", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ")}
            with open(checkpoint / "metadata.json", "w") as f:
                json.dump(meta, f, indent=2)
            continue
    else:
        print(f"  Model already on disk")

    fixture = {"version": 2, "candidates": [{"name": name, "directory": cand["dir"], "extraEOSTokens": cand["eos"], "repetitionPenalty": cand["rp"]}]}
    fixture_path = checkpoint / "_candidate.json"
    with open(fixture_path, "w") as f:
        json.dump(fixture, f)

    print(f"  Running GenerationEval...")
    start = time.time()
    try:
        proc = subprocess.run(
            [str(EVAL_BIN), "--candidates", str(fixture_path), "--output-dir", str(checkpoint)],
            capture_output=True, text=True, timeout=600, cwd=str(REPO)
        )
        (checkpoint / "stdout.log").write_text(proc.stdout)
        (checkpoint / "stderr.log").write_text(proc.stderr)

        if proc.returncode != 0:
            print(f"  GenerationEval FAILED (exit {proc.returncode})")
            print(f"  stderr: {proc.stderr[:300]}")
            meta = {"name": name, "error": "eval_failed", "elapsed": time.time()-start}
            with open(checkpoint / "metadata.json", "w") as f:
                json.dump(meta, f, indent=2)
        else:
            raw_src = checkpoint / "data.json"
            if raw_src.exists():
                shutil.move(str(raw_src), str(checkpoint / "raw.json"))
                print(f"  GenerationEval OK ({time.time()-start:.1f}s)")
                meta = {"name": name, "eval_completed": True, "elapsed": time.time()-start}
                with open(checkpoint / "metadata.json", "w") as f:
                    json.dump(meta, f, indent=2)
            else:
                print(f"  No data.json produced")
                meta = {"name": name, "error": "no_output", "elapsed": time.time()-start}
                with open(checkpoint / "metadata.json", "w") as f:
                    json.dump(meta, f, indent=2)
    except subprocess.TimeoutExpired:
        print(f"  GenerationEval TIMEOUT")
        meta = {"name": name, "error": "timeout", "elapsed": 600}
        with open(checkpoint / "metadata.json", "w") as f:
            json.dump(meta, f, indent=2)

    fixture_path.unlink(missing_ok=True)

    if cand["dir"] not in preexisting:
        print(f"  Deleting model: {model_dir}")
        shutil.rmtree(model_dir, ignore_errors=True)
        cache_root = Path.home() / ".cache" / "huggingface" / "hub"
        safe_name = cand["repo"].replace("/", "--")
        if cache_root.exists():
            for d in cache_root.iterdir():
                if d.name.startswith(f"models--{safe_name}"):
                    shutil.rmtree(d, ignore_errors=True)
        print(f"  Model evicted.")

print("\nDone with remaining candidates.")