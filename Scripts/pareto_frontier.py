#!/usr/bin/env python3
"""
pareto_frontier.py — compute the Pareto frontier of (hypothesis, metrics) points.

A ResearchHypothesis is a point in an 8-12 dimensional objective space. Each
run of `Scripts/analyze_dialectic.py` produces one such point (a baseline
JSON). This script takes multiple baseline JSONs and identifies which ones
are Pareto-optimal — i.e., not dominated by any other point on every
metric.

The framing is from the architecture review:

    "Instead of asking 'Is contemplative_v3 better?', you ask
     'Does contemplative_v3 dominate contemplative_v2?'"

A point A *dominates* a point B if A is no worse on every objective AND
better on at least one. The Pareto frontier is the set of points that
are not dominated by any other.

**Why a "frontier" instead of a single "best":**

Most objective pairs are competing. The user named the canonical example:
"maximize synthesis while minimizing semantic_inertia." Some hypotheses
will achieve more synthesis at the cost of higher inertia; others will
keep inertia low at the cost of less synthesis. Neither dominates. Both
belong on the frontier.

The frontier is also a *direction-finding* tool: future hypothesis YAMLs
should be designed to push the frontier outward on the axes that matter,
not to "win" a single scalar.

**Inputs:**

One or more baseline JSONs (output of `Scripts/analyze_dialectic.py`).
A baseline JSON has top-level keys including `inertia`, `opening_diversity`,
`outcome_counts`, `repetition`, `witness_influence`, etc.

Each baseline can be labeled with a `--label` argument; otherwise the
filename is used.

**Objectives:**

By default, the script maximizes a set of "good" objectives and minimizes
a set of "bad" objectives:

    maximize: synthesis_rate, opening_diversity, ngram_diversity
    minimize: silent_rate, semantic_inertia, linguistic_inertia,
              policy_inertia, scaffold_leakage, witness_coupling_magnitude

A custom objectives spec can be passed via `--objectives` as JSON. The
spec is a list of (key, direction) pairs, where direction is
"maximize" or "minimize".

**Outputs:**

- A JSON sidecar with the per-point metric vector + the frontier membership
  and the per-point dominated-by list
- A human-readable table rendering the frontier
- An optional ASCII scatter showing the frontier in 2D projection (any
  two objectives on `--scatter-x` and `--scatter-y`)

**Why this is at the *architecture* level, not the *implementation*
level:**

The user named it: "I would elevate Pareto analysis into the
architecture." It belongs above the benchmark layer, between metric
extraction and the next-hypothesis decision. The script is a
prototype; the formal version (when the `ResearchHypothesis` YAML
schema is written) will run automatically after every soak.
"""

import argparse
import json
import math
import statistics
import sys
from collections import Counter
from pathlib import Path

# Default objectives and their directions
DEFAULT_OBJECTIVES: list[tuple[str, str]] = [
    # Good — we want more of these
    ("synthesis_rate", "maximize"),
    ("opening_diversity", "maximize"),
    ("ngram_diversity", "maximize"),
    # Bad — we want less of these
    ("silent_rate", "minimize"),
    ("semantic_inertia", "minimize"),
    ("linguistic_inertia", "minimize"),
    ("policy_inertia", "minimize"),
    ("scaffold_leakage", "minimize"),
    ("witness_coupling_magnitude", "minimize"),
]


def extract_point(baseline: dict, label: str) -> dict:
    """Pull the 8-12 objective metrics from a baseline JSON."""
    inertia = baseline.get("inertia", {})
    op_div = baseline.get("opening_diversity", {})
    rep = baseline.get("repetition", {})
    outcomes = baseline.get("outcome_counts", {})
    turn_count = baseline.get("turn_count", 0) or 1
    named = baseline.get("named_phrases", {})

    # Witness coupling: magnitude of the max |shift| across outcomes.
    # A high magnitude = the witness is steering the dialogue a lot.
    wi = baseline.get("witness_influence", {}) or {}
    shifts = wi.get("per_outcome_shift", {}) or {}
    witness_coupling_magnitude = max(
        (abs(v) for v in shifts.values()), default=0.0
    )

    # Scaffold leakage: count of `in a live dialogue` per turn
    scaffold = (named.get("in a live dialogue") or {}).get("count", 0)
    scaffold_leakage = scaffold / turn_count

    return {
        "label": label,
        "turn_count": turn_count,
        "synthesis_rate": outcomes.get("synthesis", 0) / turn_count,
        "silent_rate": outcomes.get("silent", 0) / turn_count,
        "coherence_rate": outcomes.get("coherence-seeking", 0) / turn_count,
        "displacement_rate": outcomes.get("displacement-seeking", 0) / turn_count,
        "opening_diversity": op_div.get("opening_diversity", 0.0) or 0.0,
        "ngram_diversity": rep.get("trigram_diversity", 0.0) or 0.0,
        "semantic_inertia": inertia.get("semantic_inertia", 0.0) or 0.0,
        "linguistic_inertia": inertia.get("linguistic_inertia", 0.0) or 0.0,
        "policy_inertia": inertia.get("policy_inertia", 0.0) or 0.0,
        "scaffold_leakage": scaffold_leakage,
        "witness_coupling_magnitude": witness_coupling_magnitude,
    }


def dominates(a: dict, b: dict, objectives: list[tuple[str, str]]) -> bool:
    """Return True if point a dominates point b.

    a dominates b if a is no worse on every objective AND strictly
    better on at least one. Ties (a == b on an objective) are
    treated as "not worse" — strict improvement is required only
    on at least one objective.
    """
    better_on_any = False
    for key, direction in objectives:
        av = a.get(key, 0.0)
        bv = b.get(key, 0.0)
        if direction == "maximize":
            if av < bv:
                return False
            if av > bv:
                better_on_any = True
        else:  # minimize
            if av > bv:
                return False
            if av < bv:
                better_on_any = True
    return better_on_any


def compute_frontier(
    points: list[dict], objectives: list[tuple[str, str]]
) -> dict:
    """Compute the Pareto frontier + per-point dominated-by list.

    Returns:
    {
      "frontier": [point_label, ...]    (in score-order)
      "dominated_by": {label: [other_label, ...], ...}
      "rank": {label: int, ...}         (1 = on frontier, 2 = dominated by 1 point, ...)
    }
    """
    dominated_by: dict[str, list[str]] = {p["label"]: [] for p in points}
    rank: dict[str, int] = {p["label"]: 0 for p in points}
    for a in points:
        for b in points:
            if a["label"] == b["label"]:
                continue
            if dominates(a, b, objectives):
                dominated_by[b["label"]].append(a["label"])
    # Rank: 1 + (number of points that dominate this one)
    for label in dominated_by:
        rank[label] = 1 + len(dominated_by[label])
    frontier = [p["label"] for p in points if rank[p["label"]] == 1]
    return {
        "frontier": frontier,
        "dominated_by": dominated_by,
        "rank": rank,
    }


def render_table(
    points: list[dict],
    frontier_data: dict,
    objectives: list[tuple[str, str]],
) -> str:
    out: list[str] = []
    out.append("=" * 90)
    out.append("  PARETO FRONTIER ANALYSIS")
    out.append("=" * 90)
    out.append("")
    out.append(
        f"  {len(points)} points, {len(frontier_data['frontier'])} on the frontier"
    )
    out.append("")

    # Column header
    header = f"  {'label':<30} {'rank':>5}  "
    for key, _ in objectives:
        header += f"{key[:12]:>12} "
    out.append(header)
    out.append("  " + "-" * (len(header) - 2))

    # Sort by rank, then by label
    sorted_pts = sorted(
        points, key=lambda p: (frontier_data["rank"][p["label"]], p["label"])
    )
    for p in sorted_pts:
        rank = frontier_data["rank"][p["label"]]
        marker = " ★" if rank == 1 else "  "
        line = f"  {p['label']:<30} {rank:>4}{marker}  "
        for key, _ in objectives:
            v = p.get(key, 0.0)
            line += f"{v:>12.3f} "
        out.append(line)
    out.append("")
    out.append("  ★ = on the Pareto frontier (not dominated by any other point)")
    out.append("")
    return "\n".join(out)


def render_scatter(
    points: list[dict],
    frontier_data: dict,
    x_key: str,
    y_key: str,
    x_dir: str,
    y_dir: str,
    width: int = 60,
    height: int = 18,
) -> str:
    """Render an ASCII scatter plot of the frontier in 2D."""
    out: list[str] = []
    out.append(
        f"  {y_key} ({y_dir}) vs {x_key} ({x_dir}); ★ on frontier, · dominated"
    )
    out.append("")

    if not points:
        return "\n".join(out)
    xs = [p[x_key] for p in points]
    ys = [p[y_key] for p in points]
    if max(xs) == min(xs) or max(ys) == min(ys):
        out.append("  (constant value on one axis — no plot to draw)")
        return "\n".join(out)
    x_min, x_max = min(xs), max(xs)
    y_min, y_max = min(ys), max(ys)
    x_range = x_max - x_min
    y_range = y_max - y_min

    # Build the grid
    grid: list[list[str]] = [[" "] * width for _ in range(height)]
    for p in points:
        col = int((p[x_key] - x_min) / x_range * (width - 1)) if x_range > 0 else 0
        # Y is inverted (top = max if y_dir is maximize, but plot is consistent
        # with screen Y going down). Use:
        # - if y_dir is maximize, top of plot is y_max
        # - if y_dir is minimize, top of plot is y_max (high values at top)
        row = (
            int((y_max - p[y_key]) / y_range * (height - 1))
            if y_range > 0
            else 0
        )
        row = max(0, min(height - 1, row))
        col = max(0, min(width - 1, col))
        is_frontier = frontier_data["rank"][p["label"]] == 1
        grid[row][col] = "★" if is_frontier else "·"

    # X axis labels (top, middle, bottom)
    for r in range(height):
        line = "  " + "".join(grid[r])
        if r == 0:
            line += f"  {y_max:.2f}"
        elif r == height - 1:
            line += f"  {y_min:.2f}"
        elif r == height // 2:
            line += f"  {(y_max + y_min) / 2:.2f}"
        out.append(line)
    out.append("  " + " " * width + f"  {x_min:.2f}    {x_max:.2f}")
    out.append("")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n")[0] if __doc__ else "Pareto frontier analysis"
    )
    parser.add_argument(
        "baselines",
        nargs="+",
        help="One or more baseline JSON files (output of analyze_dialectic.py)",
    )
    parser.add_argument(
        "--label",
        action="append",
        default=[],
        help="Label for the corresponding baseline (repeatable, must match count)",
    )
    parser.add_argument(
        "--objectives",
        help="Custom objectives spec as JSON (list of [key, direction] pairs)",
    )
    parser.add_argument(
        "--output",
        help="JSON sidecar path (default: <baselines-dir>/pareto.json)",
    )
    parser.add_argument(
        "--scatter-x",
        help="Render a 2D scatter with this key on the X axis (e.g. synthesis_rate)",
    )
    parser.add_argument(
        "--scatter-y",
        help="Render a 2D scatter with this key on the Y axis (e.g. semantic_inertia)",
    )
    args = parser.parse_args()

    # Resolve labels
    if args.label:
        if len(args.label) != len(args.baselines):
            print(
                f"error: --label count ({len(args.label)}) doesn't match baselines ({len(args.baselines)})",
                file=sys.stderr,
            )
            return 1
        labels = args.label
    else:
        labels = [Path(b).stem for b in args.baselines]

    # Resolve objectives
    if args.objectives:
        try:
            objectives = json.loads(args.objectives)
            if not isinstance(objectives, list):
                raise ValueError("must be a list")
            for item in objectives:
                if not (
                    isinstance(item, list) and len(item) == 2
                    and item[1] in ("maximize", "minimize")
                ):
                    raise ValueError(f"bad item: {item}")
        except (json.JSONDecodeError, ValueError) as e:
            print(f"error: bad --objectives: {e}", file=sys.stderr)
            return 1
    else:
        objectives = DEFAULT_OBJECTIVES

    # Load and extract
    points: list[dict] = []
    for path, label in zip(args.baselines, labels):
        try:
            with open(path) as f:
                baseline = json.load(f)
        except Exception as e:
            print(f"warning: failed to load {path}: {e}", file=sys.stderr)
            continue
        points.append(extract_point(baseline, label))

    if not points:
        print("error: no points loaded", file=sys.stderr)
        return 1

    # Compute frontier
    frontier_data = compute_frontier(points, objectives)

    # Render
    print(render_table(points, frontier_data, objectives))

    if args.scatter_x and args.scatter_y:
        # Find directions
        x_dir = next((d for k, d in objectives if k == args.scatter_x), "maximize")
        y_dir = next((d for k, d in objectives if k == args.scatter_y), "maximize")
        print(
            render_scatter(
                points, frontier_data, args.scatter_x, args.scatter_y, x_dir, y_dir
            )
        )

    # Output
    output_path = (
        Path(args.output)
        if args.output
        else Path(args.baselines[0]).parent / "pareto.json"
    )
    sidecar = {
        "objectives": objectives,
        "points": points,
        "frontier": frontier_data["frontier"],
        "dominated_by": frontier_data["dominated_by"],
        "rank": frontier_data["rank"],
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(sidecar, f, indent=2)
    print(f"  → wrote {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
