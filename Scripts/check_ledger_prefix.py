#!/usr/bin/env python3
"""Ledger integrity gate: staleness and harness conflation.

Two assertions, one per failure that actually occurred (see node 26).

**Prefix.** A branch's ledger must contain `origin/main`'s as a PREFIX --
node N on this branch must be byte-identical to node N on main. This branch
forked when the ledger ended at node 6, main independently reached 25, and
three entries were appended onto the stale tail. The mismatch was noticed
three times and each time adjudicated between two machines instead of against
their shared upstream, which was one `git fetch` away. Writing onto a stale
tail becomes impossible rather than merely discouraged.

**Provenance.** Every new node must declare `Provenance:` — which checkpoint or
"trained in-process", plus the config that fixes the number. Node 25 records
`150 x 64 x 3 seeds, TRUE-env rollouts` and nothing about WHICH MODEL, so its
rho 0.25 cannot be reproduced and cannot be used as anyone's baseline. A number
without its provenance is not a measurement, it is an anecdote.

**Harness.** Every node must declare `Harness:`. A draft node 26 compared a
rho measured on `ParticleNavigatorEnv`/`mpc.py` against one from
`synthetic_1f`/`forward_eval.py` and read as though they spoke to each other.
Both lines had independently built an oracle and independently repaired their
benchmark, so the vocabulary matched at every level except the code. A third
harness (real EEG) is planned, so this recurs by default rather than by
accident.

Neither check reads results. They are about whether a comparison is ADMISSIBLE,
not whether it is favourable.

Usage:
  ./Scripts/check_ledger_prefix.py
  ./Scripts/check_ledger_prefix.py --base origin/main
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

LEDGER = "WorldModel/EXPERIMENT_LEDGER.md"
NODE_RE = re.compile(r"^## (\d+) — ", re.MULTILINE)


def split_nodes(text: str) -> dict[int, str]:
    """Map node number -> its full body. Later duplicates would overwrite, so
    duplicates are detected separately rather than silently collapsed."""
    marks = [(int(m.group(1)), m.start()) for m in NODE_RE.finditer(text)]
    nodes: dict[int, str] = {}
    for i, (number, start) in enumerate(marks):
        end = marks[i + 1][1] if i + 1 < len(marks) else len(text)
        # Normalize the trailing `---` separator. The LAST node in a file runs
        # to EOF and so keeps no separator, while every earlier node is cut
        # before one -- without this, appending a node makes its predecessor
        # spuriously "differ" from the identical text upstream.
        nodes[number] = text[start:end].strip().rstrip("-").strip()
    return nodes


def node_numbers_in_order(text: str) -> list[int]:
    return [int(m.group(1)) for m in NODE_RE.finditer(text)]


def git_show(ref: str, path: str) -> str | None:
    result = subprocess.run(
        ["git", "show", f"{ref}:{path}"], capture_output=True, text=True
    )
    return result.stdout if result.returncode == 0 else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", default="origin/main")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    local_path = root / LEDGER
    if not local_path.exists():
        print(f"no ledger at {LEDGER}; nothing to check")
        return 0
    local = local_path.read_text()
    local_nodes = split_nodes(local)
    failures: list[str] = []

    # --- duplicates and gaps ------------------------------------------
    ordered = node_numbers_in_order(local)
    seen: set[int] = set()
    for n in ordered:
        if n in seen:
            failures.append(f"node {n} appears more than once")
        seen.add(n)
    expected = list(range(max(ordered) + 1)) if ordered else []
    missing = sorted(set(expected) - seen)
    if missing:
        failures.append(f"gap in node numbering: {missing} absent below the head")

    # --- prefix against the shared upstream ----------------------------
    base = git_show(args.base, LEDGER)
    if base is None:
        print(f"warning: {args.base} unavailable (fetch it); prefix check SKIPPED")
    else:
        base_nodes = split_nodes(base)
        for number, body in sorted(base_nodes.items()):
            if number not in local_nodes:
                failures.append(f"node {number} exists on {args.base} but not here")
            elif local_nodes[number] != body:
                # The exact case that occurred: a different experiment written
                # into an occupied slot.
                head = local_nodes[number].splitlines()[0][:88]
                failures.append(
                    f"node {number} DIFFERS from {args.base} — the tail was stale "
                    f"when this was written. Local: {head}"
                )
    # --- harness declaration, NEW nodes only ---------------------------
    # Applied only beyond the upstream head. The 26 nodes that predate this
    # rule are historical record: retrofitting a field onto them would mean
    # rewriting entries whose authors are not here to say which harness they
    # meant, and guessing that is exactly the error the rule exists to stop.
    highest_base = max(split_nodes(base)) if base else -1
    for number, body in sorted(local_nodes.items()):
        if number <= highest_base:
            continue
        for field in ("Harness", "Provenance"):
            if f"- {field}:" not in body:
                failures.append(
                    f"node {number} does not declare `{field}:` (required for nodes "
                    f"after {highest_base}; earlier ones predate the rule)"
                )

    if failures:
        print("ledger integrity: FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(f"ledger integrity: ok ({len(local_nodes)} nodes, prefix of {args.base} intact)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
