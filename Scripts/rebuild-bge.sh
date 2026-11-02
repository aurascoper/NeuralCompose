#!/usr/bin/env bash
#
# rebuild-bge.sh: rebuild Models/BGE-small-en-v1.5 from pinned inputs and
# prove the result is the pinned model.
#
# Usage:
#   ./Scripts/rebuild-bge.sh                 unlock, convert, verify, lock
#   ./Scripts/rebuild-bge.sh --verify-only   verify the model already on disk
#   ./Scripts/rebuild-bge.sh --lock          lock the model package and torch's library
#   ./Scripts/rebuild-bge.sh --unlock        unlock them, e.g. before upgrading torch
#
# Locking: the model package and torch's libtorch_cpu.dylib vanished together
# on 2026-07-27 and again on 2026-09-28. macOS's Storage settings list them as
# large files with a Delete button. Locking sets the user-immutable flag
# (chflags uchg), so a deletion fails or has to ask until the flag is cleared.
# It stops accidents, not an owner who clears the flag on purpose.
#
# Inputs, all committed:
#   Scripts/bge-small-en-v1.5.lock.json      Hugging Face revision, expected sha256s
#   Scripts/requirements-bge-conversion.txt  the Python stack
#   Scripts/convert-sentence-embedder.py     the conversion itself
#
# Exit status: 0 verified, 1 a hash differs or a step failed, 64 usage.
#
# Environment:
#   BGE_VENV        virtualenv to use or create (default: <repo>/venv)
#   BGE_OUTPUT_DIR  where the model goes (default: the lock's output_dir)
#   BGE_LOCK        lock file to build from (default: the committed one)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
LOCK="${BGE_LOCK:-Scripts/bge-small-en-v1.5.lock.json}"
REQUIREMENTS="Scripts/requirements-bge-conversion.txt"
VENV="${BGE_VENV:-$REPO_ROOT/venv}"

# The header comment is the usage text: every comment line after the shebang,
# up to the first line of code.
usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

MODE=rebuild
if [ $# -gt 1 ]; then usage >&2; exit 64; fi
case "${1:-}" in
    "")            ;;
    --verify-only) MODE=verify ;;
    --lock)        MODE=lock ;;
    --unlock)      MODE=unlock ;;
    *)             usage >&2; exit 64 ;;
esac

for input in "$LOCK" "$REQUIREMENTS" Scripts/convert-sentence-embedder.py; do
    [ -f "$input" ] || { echo "error: $input not found under $REPO_ROOT" >&2; exit 1; }
done

# Read one value from the lock: lock_get key [subkey ...]
lock_get() {
    /usr/bin/python3 - "$LOCK" "$@" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
for key in sys.argv[2:]:
    value = value[key]
print(value)
PY
}

MODEL="$(lock_get model)"
REVISION="$(lock_get revision)"
OUT="${BGE_OUTPUT_DIR:-$(lock_get output_dir)}"

# The 2 items that get locked, one per line; only those that exist.
lockable_items() {
    local library
    if [ -d "$OUT/model.mlpackage" ]; then printf '%s\n' "$OUT/model.mlpackage"; fi
    for library in "$VENV"/lib/python*/site-packages/torch/lib/libtorch_cpu.dylib; do
        if [ -f "$library" ]; then printf '%s\n' "$library"; fi
    done
}

set_lock() {   # set_lock uchg | nouchg
    local item
    lockable_items | while IFS= read -r item; do chflags -R "$1" "$item"; done
}

report_locks() {
    local item state
    lockable_items | while IFS= read -r item; do
        if ls -ldO "$item" | awk '{print $5}' | grep -q uchg; then state=locked; else state=UNLOCKED; fi
        printf '  %-8s  %s\n' "$state" "$item"
    done
}

ensure_venv() {
    if [ ! -x "$VENV/bin/python" ]; then
        command -v python3.11 >/dev/null || {
            echo "error: python3.11 not found; the conversion stack is pinned to Python 3.11" >&2
            exit 1
        }
        echo "Creating $VENV with python3.11 ..."
        python3.11 -m venv "$VENV"
    fi

    local have want missing=0
    have="$("$VENV/bin/python" -m pip freeze 2>/dev/null | tr 'A-Z_' 'a-z-')"
    while IFS= read -r want; do
        case "$want" in ''|\#*) continue ;; esac
        if ! grep -qxF "$(printf '%s' "$want" | tr 'A-Z_' 'a-z-')" <<<"$have"; then
            missing=1
            break
        fi
    done < "$REQUIREMENTS"
    if [ "$missing" = 1 ]; then
        echo "Installing the pinned conversion stack into $VENV ..."
        "$VENV/bin/python" -m pip install --quiet -r "$REQUIREMENTS" || {
            echo "error: installing $REQUIREMENTS failed" >&2
            exit 1
        }
    fi

    # pip can report torch as installed while its main library is gone: that
    # is the state the 2026-07-27 sweep left behind. Import it to find out.
    if ! "$VENV/bin/python" -c 'import torch; torch.ones(1)' >/dev/null 2>&1; then
        echo "torch is listed but does not load; reinstalling the pinned build ..."
        "$VENV/bin/python" -m pip install --quiet --force-reinstall --no-deps \
            "$(grep -E '^torch==' "$REQUIREMENTS")"
        "$VENV/bin/python" -c 'import torch; torch.ones(1)'
    fi
}

verify() {
    local log status=0
    log="$(mktemp)"
    echo "Verifying $OUT against $LOCK ..."
    "$VENV/bin/python" - "$LOCK" "$OUT" "$MODE" 2>"$log" <<'PY' || status=$?
import hashlib, json, pathlib, sys

lock = json.load(open(sys.argv[1]))
out = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
expected = lock["expected"]
failures = 0


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check(label, actual, wanted):
    global failures
    if actual == wanted:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}")
        print(f"          expected {wanted}")
        print(f"          actual   {actual}")


actual_files = {}
for relative, wanted in expected["files"].items():
    path = out / relative
    actual_files[relative] = sha256_of(path) if path.is_file() else "missing"
    check(relative, actual_files[relative], wanted)

package = out / "model.mlpackage"
if package.is_dir():
    import coremltools
    spec = coremltools.utils.load_spec(str(package))
    canonical = hashlib.sha256(spec.SerializeToString(deterministic=True)).hexdigest()
else:
    canonical = "missing"
check("model.mlmodel, canonical spec digest", canonical, expected["spec_canonical_sha256"])

weights = actual_files.get("model.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "missing")
package_digest = hashlib.sha256(
    f"weight.bin {weights}\nspec {canonical}\n".encode()).hexdigest()
check("model.mlpackage, package digest", package_digest, expected["mlpackage_digest"])

# The source weights are checked whenever the Hugging Face cache holds them.
# After a rebuild it always does, so there a missing file is a failure.
try:
    from huggingface_hub import try_to_load_from_cache
    cached = try_to_load_from_cache(lock["model"], "model.safetensors", revision=lock["revision"])
except Exception:
    cached = None
wanted_source = lock["source"]["model.safetensors"]
if isinstance(cached, str):
    check("source model.safetensors", sha256_of(cached), wanted_source)
elif mode == "rebuild":
    check("source model.safetensors", "not in the Hugging Face cache", wanted_source)
else:
    print("  n/a   source model.safetensors: not in the Hugging Face cache, not checked")

if failures == 0 and mode == "rebuild":
    metadata_path = out / "metadata.json"
    metadata = json.loads(metadata_path.read_text())
    metadata["weights_sha256"] = weights
    metadata["spec_canonical_sha256"] = canonical
    metadata["source_safetensors_sha256"] = wanted_source
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")

sys.exit(1 if failures else 0)
PY
    if [ "$status" -ne 0 ]; then
        # coremltools prints version warnings on every import; show stderr
        # only when something went wrong, so a real error is not buried.
        grep -vE 'scikit-learn version|Torch version .* has not been tested' "$log" >&2 || true
        rm -f "$log"
        echo "FAILED: $OUT is not the pinned model." >&2
        exit 1
    fi
    rm -f "$log"
    echo "Verified: $OUT is $MODEL at $REVISION."
}

if [ "$MODE" = lock ] || [ "$MODE" = unlock ]; then
    if [ "$MODE" = lock ]; then set_lock uchg; else set_lock nouchg; fi
    report_locks
    exit 0
fi

if [ "$MODE" = verify ]; then
    [ -x "$VENV/bin/python" ] || {
        echo "error: no virtualenv at $VENV; run ./Scripts/rebuild-bge.sh to create it" >&2
        exit 1
    }
    verify
    report_locks
    exit 0
fi

# A rebuild overwrites the package, and the torch repair overwrites the
# library, so both are unlocked first and locked again once verified.
set_lock nouchg
ensure_venv
echo "Converting $MODEL at $REVISION into $OUT ..."
# The conversion's stderr is version warnings and progress bars. Keep it out
# of the way on success and show all of it on failure.
convert_log="$(mktemp)"
if ! TOKENIZERS_PARALLELISM=false "$VENV/bin/python" Scripts/convert-sentence-embedder.py \
        --model "$MODEL" --revision "$REVISION" --output-dir "$OUT" 2>"$convert_log"; then
    cat "$convert_log" >&2
    rm -f "$convert_log"
    echo "FAILED: the conversion did not complete." >&2
    exit 1
fi
rm -f "$convert_log"
verify
set_lock uchg
report_locks
echo "Next: swift test --filter SemanticBGEReplayRegressionTests"
