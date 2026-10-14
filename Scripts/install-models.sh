#!/usr/bin/env bash
#
# install-models.sh: copy the repo's models where the installed app finds them.
#
# Usage:
#   ./Scripts/install-models.sh          copy every model under Models/ that has weights
#   ./Scripts/install-models.sh --dry    report what would be copied, copy nothing
#
# The installed app's working directory is /, so it cannot use the repo's
# Models/. It looks in ~/Library/Application Support/NeuralCompose/Models
# (see Sources/BCICore/Models/ModelLocator.swift). swift run from the repo keeps
# using Models/ directly and needs none of this.
#
# A model is copied only if it has weights: a .mlpackage, a .mlmodelc or a
# .safetensors file. A folder holding only tokenizer files (what is left after
# the weights are swept) is reported and skipped.
#
# Nothing is ever deleted or overwritten. A model already installed is left
# alone: reported as up to date if it matches the repo copy, otherwise as
# differing, for you to remove by hand before rerunning.
#
# Exit status: 0 done, 64 usage.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$REPO_ROOT/Models"
DEST="$HOME/Library/Application Support/NeuralCompose/Models"

usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

DRY=0
case "${1:-}" in
    "") ;;
    --dry) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
esac

has_weights() {
    [ -n "$(find "$1" \( -name '*.mlpackage' -o -name '*.mlmodelc' -o -name '*.safetensors' \) -print -quit)" ]
}

[ "$DRY" = 1 ] || mkdir -p "$DEST"
for model in "$SOURCE"/*/; do
    model="${model%/}"
    name="$(basename "$model")"
    target="$DEST/$name"
    if ! has_weights "$model"; then
        echo "skip     $name (no weights in Models/$name)"
    elif [ -e "$target" ]; then
        if diff -rq "$model" "$target" >/dev/null 2>&1; then
            echo "current  $name"
        else
            echo "differs  $name (installed copy differs; remove $target and rerun to replace it)"
        fi
    elif [ "$DRY" = 1 ]; then
        echo "would copy $name"
    else
        ditto "$model" "$target"
        echo "copied   $name -> $target"
    fi
done
