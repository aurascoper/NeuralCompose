#!/usr/bin/env bash
# soak-matrix.sh — empirical test matrix for the dialectic runtime
#
# Runs the dialectic-session harness across a matrix of (runtime, model, profile)
# combinations with a FIXED set of heard lines so the only variable is the
# configuration. Per-run baseline JSONs are produced by
# Scripts/analyze_dialectic.py; the matrix script also runs a leakage audit
# and writes a per-run summary.
#
# This is the empirical test environment the user named: generate a diverse
# corpus of conversations across runtimes/models, analyze with the same
# metrics as the SOAK 001 baseline, and use the resulting numbers as the
# baseline that future ResearchHypothesis YAMLs must beat.
#
# Usage:
#   ./Scripts/soak-matrix.sh                          # full default matrix
#   ./Scripts/soak-matrix.sh --quick                  # 1 turn per run (smoke)
#   ./Scripts/soak-matrix.sh --runs 5                 # 5 turns per run
#   ./Scripts/soak-matrix.sh --cells "F_qwen_15b"     # subset of cells
#   ./Scripts/soak-matrix.sh --base-dir /tmp/soak002  # output dir
#
# Output:
#   $base-dir/runs/<cell-name>.jsonl        raw turns
#   $base-dir/baselines/<cell-name>.json    analyze_dialectic.py output
#   $base-dir/matrix.json                   aggregate across all cells
#   $base-dir/leakage.json                  aggregate leakage audit

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
RUNS_PER_CELL=30
BASE_DIR="$HOME/Developer/NeuralCompose/SoakRuns/soak-002-$(date +%Y%m%d-%H%M%S)"
SELECTED_CELLS=""
QUICK=0
DIALECTIC_SESSION=".build/debug/dialectic-session"
ANALYZE_SCRIPT="Scripts/analyze_dialectic.py"

# ── Args ────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)        QUICK=1; RUNS_PER_CELL=1; shift ;;
        --runs)         RUNS_PER_CELL="$2"; shift 2 ;;
        --cells)        SELECTED_CELLS="$2"; shift 2 ;;
        --base-dir)     BASE_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *)              echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ── Heard-line corpus ───────────────────────────────────────────────────────
# 30 lines sampled from the SOAK 001 dialectic turns (organic user input).
# The set is fixed across all matrix cells so the only variable is
# (runtime, model, profile). Each line is what the user typed or said to
# the running app.
HEARD_LINES=(
    "Sinking slowly warm"
    "In a live dialogue the other person just said"
    "Drifting soft"
    "The dynamic iterative approach to problem-solving is a key principle"
    "Quite is like a mirror in which I see myself"
    "Progress comes with stagnation; embrace change and grow in continuous process"
    "Let's think about this differently"
    "Embrace change and continuous process can you imagine what it might mean"
    "Constraints progress comes with stagnation"
    "Do you have any specific ideas for alternative approaches"
    "For true wisdom and harmony and interactions it is essential to listen"
    "Let's start by examining what innovative approaches might bring to bear"
    "We should consider whether there might be another variable influencing"
    "The quiet is like a mirror in which I see myself, reflecting my thoughts"
    "Constraints shape attention and focus"
    "Surplus value is essentially surplus and enjoyment for consumers"
    "Lacan would say the same as Wolf Ramp. The point is not to align ourselves"
    "We cannot contemplate on the excess abundance of joy in this sense"
    "The other perspective isn't quite right, as we're discussing a live conversation"
    "When you look at something in motion, even if it is just breeze, it has momentum"
    "The dynamic is the constant change in motion and progress toward a conclusion"
    "Innovation comes from novel perturbations of established patterns"
    "A moment of stillness often reveals more than sustained motion"
    "Two perspectives can coexist without resolution"
    "What is the relationship between silence and synthesis"
    "Synthesis happens when two voices converge on shared meaning"
    "The witness observes without participating in the dialogue"
    "Each turn is a fresh commitment to a specific meaning"
    "The carousel cycles through candidates at a steady cadence"
    "The user drives the system through selection and dwell"
)

if [[ "$QUICK" -eq 1 ]]; then
    HEARD_LINES=("${HEARD_LINES[0]}")
fi

# ── Cell matrix ─────────────────────────────────────────────────────────────
# Each cell is a (runtime, model, profile) triple. The label is a short
# human-readable name. The matrix runner walks the cells in order and
# invokes the harness once per cell with the full heard-line corpus.
#
# Tunings:
#   num_predict: 256 default. DeepSeek cloud uses ~60 tokens on `thinking`,
#                so 256 leaves ~196 for the response — sufficient.
#   temperature: not set here; the harness uses the model's default
#                (Ollama's 0.7 default for Qwen 0.5B).
#
# Selection rationale:
#   - 0.5b/1.5b/3b (qwen2.5): model-size sweep within the same family.
#   - deepseek-r1:1.5b: local reasoning model. The SOAK 001 used
#                   qwen2.5:0.5b as the baseline; deepseek-r1 lets us
#                   see whether the architecture's behavior is
#                   model-specific or family-specific.
#   - deepseek-v4-flash:cloud: cloud model via Ollama's cloud routing.
#                          This is the same model that was the
#                          silent-turn-failure case in RVS-001; the
#                          test now confirms the fix holds across
#                          the longer heard-line corpus.
CELLS=(
    "F_qwen05b   ollama qwen2.5:0.5b         focused"
    "R_qwen05b   ollama qwen2.5:0.5b         reflective"
    "C_qwen05b   ollama qwen2.5:0.5b         contemplative"
    "F_qwen15b   ollama qwen2.5:1.5b         focused"
    "R_qwen15b   ollama qwen2.5:1.5b         reflective"
    "F_qwen3b    ollama qwen2.5:3b           focused"
    "F_deepseek_r1 ollama deepseek-r1:1.5b   focused"
    "R_deepseek_r1 ollama deepseek-r1:1.5b   reflective"
    "F_deepseek_flash ollama deepseek-v4-flash:cloud focused"
    "R_deepseek_flash ollama deepseek-v4-flash:cloud reflective"
)

# ── Filter cells if --cells is given ────────────────────────────────────────
if [[ -n "$SELECTED_CELLS" ]]; then
    FILTERED=()
    for cell in "${CELLS[@]}"; do
        name=$(echo "$cell" | awk '{print $1}')
        if [[ " $SELECTED_CELLS " == *" $name "* ]]; then
            FILTERED+=("$cell")
        fi
    done
    CELLS=("${FILTERED[@]}")
fi

# ── Setup ───────────────────────────────────────────────────────────────────
mkdir -p "$BASE_DIR/runs" "$BASE_DIR/baselines"
echo "soak-matrix run @ $(date)" > "$BASE_DIR/meta.txt"
echo "base_dir: $BASE_DIR" >> "$BASE_DIR/meta.txt"
echo "runs_per_cell: $RUNS_PER_CELL" >> "$BASE_DIR/meta.txt"
echo "cells: ${#CELLS[@]}" >> "$BASE_DIR/meta.txt"
echo "heard_lines: ${#HEARD_LINES[@]}" >> "$BASE_DIR/meta.txt"
echo "branch: $(git rev-parse --abbrev-ref HEAD)" >> "$BASE_DIR/meta.txt"
echo "commit: $(git rev-parse HEAD)" >> "$BASE_DIR/meta.txt"
echo "binary: $DIALECTIC_SESSION" >> "$BASE_DIR/meta.txt"

# Verify the binary exists and the harness reports healthy.
if [[ ! -x "$DIALECTIC_SESSION" ]]; then
    echo "error: $DIALECTIC_SESSION not found or not executable; build first" >&2
    exit 1
fi

# ── Run a single cell ───────────────────────────────────────────────────────
run_cell() {
    local label="$1" runtime="$2" model="$3" profile="$4"
    local out_jsonl="$BASE_DIR/runs/${label}.jsonl"
    local out_baseline="$BASE_DIR/baselines/${label}.json"
    local log="$BASE_DIR/runs/${label}.log"

    echo "── $label ── $runtime / $model / $profile"
    rm -f "$out_jsonl"

    local start=$(date +%s)
    if "$DIALECTIC_SESSION" \
        --runtime "$runtime" \
        --model "$model" \
        "$profile" \
        "$out_jsonl" \
        "${HEARD_LINES[@]}" > "$log" 2>&1; then
        local end=$(date +%s)
        local elapsed=$((end - start))
        local line_count
        line_count=$(wc -l < "$out_jsonl" 2>/dev/null | tr -d ' ' || echo 0)
        echo "  ok: ${elapsed}s, ${line_count} turns"

        # Run the analyzer
        if "$ANALYZE_SCRIPT" --input "$out_jsonl" --output "$out_baseline" > /dev/null 2>&1; then
            local silent_count
            silent_count=$(python3 -c "
import json
try:
    d = json.load(open('$out_baseline'))
    print(d.get('outcomes', {}).get('silent', 0))
except Exception:
    print('?')
" 2>/dev/null || echo '?')
            echo "  baseline: ${out_baseline}; silent=$silent_count"
        else
            echo "  warning: analyzer failed for $label; see $log"
        fi
    else
        local end=$(date +%s)
        local elapsed=$((end - start))
        echo "  FAILED: $log (${elapsed}s)"
    fi
}

# ── Run the matrix ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  SOAK MATRIX — base: $BASE_DIR"
echo "════════════════════════════════════════════════════════════════════"
echo ""

# Limit heard lines to RUNS_PER_CELL
if [[ "${#HEARD_LINES[@]}" -gt "$RUNS_PER_CELL" ]]; then
    HEARD_LINES=("${HEARD_LINES[@]:0:$RUNS_PER_CELL}")
fi

for cell in "${CELLS[@]}"; do
    read -r label runtime model profile <<< "$cell"
    run_cell "$label" "$runtime" "$model" "$profile"
done

# ── Aggregate matrix.json ───────────────────────────────────────────────────
echo ""
echo "── aggregating matrix.json ──"
python3 - <<PY > "$BASE_DIR/matrix.json"
import json, os, glob, sys

base_dir = "$BASE_DIR"
matrix = {
    "base_dir": base_dir,
    "cells": [],
}

for path in sorted(glob.glob(os.path.join(base_dir, "baselines", "*.json"))):
    cell_name = os.path.splitext(os.path.basename(path))[0]
    try:
        data = json.load(open(path))
    except Exception as e:
        print(f"  warning: {cell_name}: {e}", file=sys.stderr)
        continue
    matrix["cells"].append({
        "label": cell_name,
        "path": path,
        "outcomes": data.get("outcome_counts", {}),
        "metrics": {
            "ngram_diversity": (data.get("repetition", {}) or {}).get("trigram_diversity"),
            "opening_diversity": (data.get("opening_diversity", {}) or {}).get("opening_diversity"),
            "self_similarity": ((data.get("self_distance", {}) or {}).get("mean_existing_self_similarity")),
            "witness_count": (data.get("witness_frequency", {}) or {}).get("witness_count"),
            "synthesis_rate": (data.get("outcome_counts", {}) or {}).get("synthesized_synthesis", 0) / max(1, data.get("turn_count", 0)),
            "silent_rate": (data.get("outcome_counts", {}) or {}).get("silent", 0) / max(1, data.get("turn_count", 0)),
            "fp_rate": (data.get("provenance", {}) or {}).get("turns_with_fingerprint", 0) / max(1, data.get("turn_count", 0)),
            "entropy_first": ((data.get("entropy", {}) or {}).get("first_half_mean")),
            "entropy_second": ((data.get("entropy", {}) or {}).get("second_half_mean")),
        },
        "named_phrases": data.get("named_phrases", {}),
    })

print(json.dumps(matrix, indent=2))
PY

# ── Leakage audit ───────────────────────────────────────────────────────────
echo "── leakage audit ──"
python3 - <<PY > "$BASE_DIR/leakage.json"
import json, os, glob, re

base_dir = "$BASE_DIR"
audit = {
    "base_dir": base_dir,
    "patterns": {
        "live_dialogue_scaffold":  r"in a live dialogue",
        "we_should_consider":      r"we should consider whether there might be another variable",
        "as_an_ai":                r"\bas an ai\b",
        "i_should":                r"\bi should\b",
        "i_dont":                  r"\bi don'?t have (feelings|personal)\b",
        "system_prompt_leak":      r"(neuralcompose|dialectic|hypnagogic|witness system|coherence role|displacement role)",
        "scene_kit_leak":          r"(scenekit|scnvector|scnmatrix)",
        "internal_state_leak":     r"(turn_index|generatorFingerprint|onMetadata|attachMetadata|loop_attached)",
    },
    "cells": [],
}

for path in sorted(glob.glob(os.path.join(base_dir, "runs", "*.jsonl"))):
    cell_name = os.path.splitext(os.path.basename(path))[0]
    counts = {k: 0 for k in audit["patterns"]}
    total_spoken = 0
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except Exception:
                continue
            spoken = (d.get("spokenText") or "").lower()
            total_spoken += 1
            for key, pat in audit["patterns"].items():
                if re.search(pat, spoken, re.IGNORECASE):
                    counts[key] += 1
    audit["cells"].append({
        "label": cell_name,
        "total_turns": total_spoken,
        "matches": counts,
    })

print(json.dumps(audit, indent=2))
PY

# ── Render the matrix report ────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  MATRIX SUMMARY"
echo "════════════════════════════════════════════════════════════════════"
python3 - <<PY
import json
m = json.load(open("$BASE_DIR/matrix.json"))
print()
print(f"{'cell':<22} {'silent':>7} {'synth':>7} {'fp':>7} {'ngram':>7} {'open':>7} {'entropy_2nd':>11}")
print("─" * 78)
for c in m["cells"]:
    name = c["label"]
    metrics = c["metrics"]
    silent = metrics.get("silent_rate") or 0
    synth = metrics.get("synthesis_rate") or 0
    fp = metrics.get("fp_rate") or 0
    ngram = metrics.get("ngram_diversity") or 0
    opening = metrics.get("opening_diversity") or 0
    entropy_2nd = metrics.get("entropy_second")
    entropy_str = f"{entropy_2nd:.2f}" if entropy_2nd is not None else "—"
    print(f"{name:<22} {silent:>7.2%} {synth:>7.2%} {fp:>7.2%} {ngram:>7.3f} {opening:>7.3f} {entropy_str:>11}")
print()
print(f"matrix: $BASE_DIR/matrix.json")
print(f"leakage: $BASE_DIR/leakage.json")
PY
