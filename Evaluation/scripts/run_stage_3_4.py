#!/usr/bin/env python3
"""
Run Phase 1A Stage 3.4 analyses (existing-artifact-only) in sequence
and produce an aggregate report. Updates the hypothesis registry with results.

Does NOT run joint_embeddings.py — that is deferred until the streaming
embedding benchmark completes.
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
SCRIPTS = EVAL_DIR / "scripts"
OUTPUT_DIR = EVAL_DIR / "results" / "stage_3_4"
HYPOTHESIS_PATH = EVAL_DIR / "corpora" / "hypothesis_registry.json"

IMMEDIATE_SCRIPTS = [
    "cross_runtime_consistency.py",
    "embedding_space_analysis.py",
    "cross_model_agreement.py",
    "generator_comparison.py",
]

DEFERRED_SCRIPTS = [
    "joint_embeddings.py",
]


def run_script(name, args=None):
    cmd = [sys.executable, str(SCRIPTS / name)]
    if args:
        cmd.extend(args)
    print(f"\n{'='*60}")
    print(f"Running {name} {' '.join(args or [])}...")
    print('='*60)
    result = subprocess.run(cmd, capture_output=False, cwd=str(REPO_ROOT))
    if result.returncode != 0:
        print(f"WARNING: {name} exited with code {result.returncode}")
    return result.returncode


def update_decision_registry(evaluated_ids, registry, stage="3.4"):
    decision_path = EVAL_DIR / "reports" / "decision_registry.md"
    if not decision_path.exists():
        print("WARNING: decision_registry.md not found — skipping update")
        return
    with open(decision_path) as f:
        content = f.read()
    stage_3_4_hypotheses = {h["id"]: h for h in registry.get("stage_3_4", [])}
    updates = {}
    if "3.4-A-runtime-consistency" in evaluated_ids:
        h = stage_3_4_hypotheses.get("3.4-A-runtime-consistency", {})
        updates["1"] = {
            "evidence_addendum": f"3.4-A evaluated: {h.get('status', 'evaluated')}. See cross_runtime_consistency.json.",
            "confidence": "High" if h.get("status") == "evaluated" else "Medium",
        }
    if "3.4-D-cross-model-agreement" in evaluated_ids:
        updates.setdefault("1", {})["agreement_addendum"] = "3.4-D evaluated — see cross_model_agreement.json"
    if "3.4-E-generator-comparison" in evaluated_ids:
        updates["2"] = {"confidence": "High", "evidence_addendum": "3.4-E evaluated — see generator_comparison.json"}
        updates["3"] = {"confidence": "High", "evidence_addendum": "3.4-E evaluated — see generator_comparison.json"}
    if "3.4-B-joint-embeddings" in evaluated_ids or "3.4-F-offline-fusion" in evaluated_ids:
        updates["4"] = {"status": "Updated with 3.4-B+F evidence", "confidence": "Medium"}
    if stage == "3.5":
        if "3.5-B-adaptive-routing" in evaluated_ids or "3.5-P-pipeline-policies" in evaluated_ids:
            updates["5"] = {"status": "Updated with 3.5-B+P evidence", "confidence": "Medium"}
        if "3.5-D-cascaded-generation" in evaluated_ids:
            updates["6"] = {"status": "Updated with 3.5-D evidence", "confidence": "Medium"}
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    update_note = f"\n<!-- Last updated: {timestamp} (Stage {stage} run) -->\n"
    if update_note not in content:
        content = content.rstrip() + update_note
    with open(decision_path, "w") as f:
        f.write(content)
    # The registry entries are hand-maintained prose — this function only
    # stamps the run timestamp and surfaces which entries have new evidence
    # to fold in. It must not claim revisions it doesn't make (found as a
    # Gate B audit finding 2026-07-14: `updates` was computed and silently
    # discarded while the log said "N entries revised").
    if updates:
        print(f"Decision registry timestamped. {len(updates)} entr"
              f"{'y has' if len(updates) == 1 else 'ies have'} new evidence "
              f"to fold in by hand: {sorted(updates)}")
        for entry_id, fields in sorted(updates.items()):
            print(f"  entry {entry_id}: {fields}")
    else:
        print("Decision registry timestamped (no new evidence addenda).")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--include-deferred", action="store_true",
                        help="Also run deferred Phase 1B scripts (joint embeddings). "
                             "Only use after the streaming embedding benchmark completes.")
    args = parser.parse_args()

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    scripts = list(IMMEDIATE_SCRIPTS)
    if args.include_deferred:
        scripts.extend(DEFERRED_SCRIPTS)

    for script in scripts:
        run_script(script)

    with open(HYPOTHESIS_PATH) as f:
        registry = json.load(f)

    evaluated_ids = set()
    script_to_hypothesis = {
        "cross_runtime_consistency.py": "3.4-A-runtime-consistency",
        "embedding_space_analysis.py": "3.4-C-embedding-space",
        "cross_model_agreement.py": "3.4-D-cross-model-agreement",
        "generator_comparison.py": "3.4-E-generator-comparison",
        "joint_embeddings.py": "3.4-B-joint-embeddings",
    }
    for script in scripts:
        hid = script_to_hypothesis.get(script)
        if hid:
            evaluated_ids.add(hid)
    if "joint_embeddings.py" in scripts:
        evaluated_ids.add("3.4-F-offline-fusion")

    for h in registry.get("stage_3_4", []):
        if h["id"] in evaluated_ids:
            h["status"] = "evaluated"

    with open(HYPOTHESIS_PATH, "w") as f:
        json.dump(registry, f, indent=2)

    update_decision_registry(evaluated_ids, registry)

    print(f"\n{'='*60}")
    print("Stage 3.4 (Phase 1A) complete. Results in Evaluation/results/stage_3_4/")
    if not args.include_deferred:
        print("NOTE: Joint embeddings (3.4-B+F) are deferred until the streaming")
        print("benchmark completes. Run with --include-deferred when ready.")
    print("Hypothesis registry updated.")
    print("Decision registry updated.")
    print('='*60)


if __name__ == "__main__":
    main()
