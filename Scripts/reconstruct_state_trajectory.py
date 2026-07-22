#!/usr/bin/env python3
"""
reconstruct_state_trajectory.py - Goal 0 for NeuralComposeScience.

This script consumes dialectical turn JSONL telemetry and reconstructs a
measured state trajectory. It does not solve an ODE, fit parameters, call a
model, or touch the application runtime. Its job is narrower and earlier:

    Can one soak/run be represented as a coherent path through state space?

The output is designed as an artifact bridge for a future Julia workspace:
JSON for reproducible metadata and CSV for quick notebooks/plots.

Dependency policy: stdlib only.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "state-trajectory-v0"

AXIS_ORDER = [
    "coherence",
    "resonance",
    "novelty",
    "semantic_energy",
    "continuation_pressure",
    "tension",
    "margin",
    "selection_temperature",
    "gloss_scalar",
    "self_similarity",
]

DEFAULT_MIN_TURNS = 3
DEFAULT_MIN_COMPLETENESS = 0.75
DEFAULT_MIN_ACTIVE_AXES = 2
EPSILON = 1e-9


def finite_float(value: Any) -> float | None:
    """Return a finite float or None for absent/non-numeric values."""
    if value is None:
        return None
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def load_events(path: Path) -> tuple[list[dict[str, Any]], int]:
    """Load JSONL turn events, skipping malformed shutdown fragments."""
    events: list[dict[str, Any]] = []
    skipped = 0
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            if isinstance(event, dict):
                events.append(event)
            else:
                skipped += 1
    def sort_key(event: dict[str, Any]) -> tuple[bool, float]:
        idx = finite_float(event.get("index"))
        return (idx is None, idx if idx is not None else 0.0)

    events.sort(key=sort_key)
    return events, skipped


def role_from_outcome(outcome: str | None) -> str | None:
    if not outcome or outcome == "silent" or ":" not in outcome:
        return None
    return outcome.split(":", 1)[1]


def candidate_text(candidate: dict[str, Any]) -> str:
    return str(candidate.get("text") or "")


def candidate_potential(candidate: dict[str, Any]) -> float:
    return finite_float(candidate.get("potential")) or 0.0


def representative_candidate(event: dict[str, Any]) -> tuple[dict[str, Any] | None, str]:
    """Choose the event's representative point in candidate-energy space.

    Spoken/synthesized turns prefer the resolved role/text. Silent turns still
    need a state, so they use the highest-potential candidate as the field's
    unresolved local basin.
    """
    candidates = [
        c for c in event.get("candidates", []) or []
        if isinstance(c, dict)
    ]
    if not candidates:
        return None, "missing"

    outcome = str(event.get("outcome") or "")
    role = role_from_outcome(outcome)
    spoken = str(event.get("spokenText") or "")

    if role and spoken:
        for c in candidates:
            if str(c.get("roleID") or "") == role and candidate_text(c) == spoken:
                return c, "resolved_role_and_text"
    if role:
        for c in candidates:
            if str(c.get("roleID") or "") == role:
                return c, "resolved_role"
    if spoken:
        for c in candidates:
            if candidate_text(c) == spoken:
                return c, "spoken_text"

    return max(candidates, key=candidate_potential), "best_potential"


def softmax(values: list[float], tau: float | None) -> list[float]:
    if not values:
        return []
    if tau is None or tau <= 0:
        return [1.0 / len(values)] * len(values)
    max_v = max(values)
    exps = [math.exp((v - max_v) / tau) for v in values]
    total = sum(exps)
    if total <= 0 or not math.isfinite(total):
        return [1.0 / len(values)] * len(values)
    return [v / total for v in exps]


def entropy_pressure(probabilities: list[float]) -> float | None:
    """Return 1 - normalized entropy, where 1 is a single dominant basin."""
    if not probabilities:
        return None
    if len(probabilities) == 1:
        return 1.0
    entropy = 0.0
    for p in probabilities:
        if p > 0:
            entropy -= p * math.log2(p)
    max_entropy = math.log2(len(probabilities))
    if max_entropy <= 0:
        return 1.0
    pressure = 1.0 - (entropy / max_entropy)
    return min(1.0, max(0.0, pressure))


def state_from_event(event: dict[str, Any]) -> dict[str, Any]:
    candidate, source = representative_candidate(event)
    tau = finite_float(event.get("selectionTemperature"))
    candidates = [
        c for c in event.get("candidates", []) or []
        if isinstance(c, dict)
    ]
    probabilities = softmax([candidate_potential(c) for c in candidates], tau)

    state = {
        "coherence": None,
        "resonance": None,
        "novelty": None,
        "semantic_energy": None,
        "continuation_pressure": entropy_pressure(probabilities),
        "tension": finite_float(event.get("tension")),
        "margin": finite_float(event.get("margin")),
        "selection_temperature": tau,
        "gloss_scalar": finite_float(event.get("glossScalar")),
        "self_similarity": finite_float(event.get("selfSimilarity")),
    }

    if candidate is not None:
        state["coherence"] = finite_float(candidate.get("coherence"))
        state["resonance"] = finite_float(candidate.get("resonance"))
        state["novelty"] = finite_float(candidate.get("novelty"))
        state["semantic_energy"] = finite_float(candidate.get("potential"))

    missing_axes = [axis for axis in AXIS_ORDER if state[axis] is None]
    completeness = 1.0 - (len(missing_axes) / len(AXIS_ORDER))

    return {
        "index": int(finite_float(event.get("index")) or 0),
        "outcome": str(event.get("outcome") or "unknown"),
        "representative_candidate_source": source,
        "representative_role_id": (
            str(candidate.get("roleID"))
            if isinstance(candidate, dict) and candidate.get("roleID") is not None
            else None
        ),
        "state": state,
        "missing_axes": missing_axes,
        "axis_completeness": completeness,
        "candidate_probabilities": probabilities,
    }


def axis_stats(rows: list[dict[str, Any]]) -> dict[str, dict[str, float | None]]:
    stats: dict[str, dict[str, float | None]] = {}
    for axis in AXIS_ORDER:
        values = [
            row["state"][axis] for row in rows
            if row["state"].get(axis) is not None
        ]
        if values:
            lo = min(values)
            hi = max(values)
            stats[axis] = {
                "min": lo,
                "max": hi,
                "mean": statistics.fmean(values),
                "variance": statistics.pvariance(values) if len(values) > 1 else 0.0,
                "missing_rate": 1.0 - (len(values) / len(rows)) if rows else 1.0,
            }
        else:
            stats[axis] = {
                "min": None,
                "max": None,
                "mean": None,
                "variance": None,
                "missing_rate": 1.0,
            }
    return stats


def normalized_value(value: float, stats: dict[str, float | None]) -> float:
    lo = stats["min"]
    hi = stats["max"]
    if lo is None or hi is None or abs(hi - lo) <= EPSILON:
        return 0.0
    return (value - lo) / (hi - lo)


def row_distance(
    a: dict[str, Any],
    b: dict[str, Any],
    stats: dict[str, dict[str, float | None]],
) -> float | None:
    diffs: list[float] = []
    for axis in AXIS_ORDER:
        av = a["state"].get(axis)
        bv = b["state"].get(axis)
        if av is None or bv is None:
            continue
        na = normalized_value(av, stats[axis])
        nb = normalized_value(bv, stats[axis])
        diffs.append((na - nb) ** 2)
    if not diffs:
        return None
    return math.sqrt(sum(diffs) / len(diffs))


def trajectory_diagnostics(
    rows: list[dict[str, Any]],
    *,
    min_turns: int = DEFAULT_MIN_TURNS,
    min_completeness: float = DEFAULT_MIN_COMPLETENESS,
    min_active_axes: int = DEFAULT_MIN_ACTIVE_AXES,
) -> dict[str, Any]:
    stats = axis_stats(rows)
    active_axes = [
        axis for axis, s in stats.items()
        if (s["variance"] or 0.0) > EPSILON
    ]
    step_distances = [
        row_distance(prev, curr, stats)
        for prev, curr in zip(rows, rows[1:])
    ]
    finite_steps = [d for d in step_distances if d is not None and math.isfinite(d)]
    path_length = sum(finite_steps)
    net_displacement = (
        row_distance(rows[0], rows[-1], stats)
        if len(rows) >= 2 else None
    )
    mean_completeness = (
        statistics.fmean(row["axis_completeness"] for row in rows)
        if rows else 0.0
    )
    zero_step_rate = (
        sum(1 for d in finite_steps if d <= EPSILON) / len(finite_steps)
        if finite_steps else 1.0
    )

    flags: list[str] = []
    if len(rows) < min_turns:
        flags.append(f"requires at least {min_turns} turns")
    if mean_completeness < min_completeness:
        flags.append(
            f"mean state completeness {mean_completeness:.3f} below {min_completeness:.3f}"
        )
    if len(active_axes) < min_active_axes:
        flags.append(f"requires at least {min_active_axes} active axes")
    if path_length <= EPSILON:
        flags.append("trajectory has no measurable movement")

    representable = not flags

    return {
        "turn_count": len(rows),
        "axis_order": AXIS_ORDER,
        "axis_stats": stats,
        "active_axes": active_axes,
        "active_axis_count": len(active_axes),
        "mean_state_completeness": mean_completeness,
        "step_distances": step_distances,
        "mean_step_distance": statistics.fmean(finite_steps) if finite_steps else 0.0,
        "max_step_distance": max(finite_steps) if finite_steps else 0.0,
        "zero_step_rate": zero_step_rate,
        "path_length": path_length,
        "net_displacement": net_displacement,
        "tortuosity": (
            path_length / net_displacement
            if net_displacement is not None and net_displacement > EPSILON
            else None
        ),
        "representable": representable,
        "verdict": "representable" if representable else "not_representable",
        "falsification_flags": flags,
        "criteria": {
            "min_turns": min_turns,
            "min_completeness": min_completeness,
            "min_active_axes": min_active_axes,
        },
    }


def reconstruct(
    events: list[dict[str, Any]],
    *,
    source: Path,
    skipped_malformed: int = 0,
    min_turns: int = DEFAULT_MIN_TURNS,
    min_completeness: float = DEFAULT_MIN_COMPLETENESS,
    min_active_axes: int = DEFAULT_MIN_ACTIVE_AXES,
) -> dict[str, Any]:
    rows = [state_from_event(event) for event in events]
    diagnostics = trajectory_diagnostics(
        rows,
        min_turns=min_turns,
        min_completeness=min_completeness,
        min_active_axes=min_active_axes,
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "source": str(source),
        "source_kind": "dialectical_turn_jsonl",
        "skipped_malformed_lines": skipped_malformed,
        "axis_order": AXIS_ORDER,
        "hypothesis_stage": "goal_0_state_reconstruction",
        "question": "Can this run be represented as a coherent trajectory through measured state space?",
        "rows": rows,
        "diagnostics": diagnostics,
    }


def write_json(result: dict[str, Any], path: Path, *, pretty: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        if pretty:
            json.dump(result, f, indent=2, sort_keys=True)
        else:
            json.dump(result, f, separators=(",", ":"), sort_keys=True)
        f.write("\n")


def write_csv(result: dict[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "index",
        "outcome",
        "representative_candidate_source",
        "representative_role_id",
        "axis_completeness",
        *AXIS_ORDER,
        "missing_axes",
    ]
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in result["rows"]:
            out = {
                "index": row["index"],
                "outcome": row["outcome"],
                "representative_candidate_source": row["representative_candidate_source"],
                "representative_role_id": row["representative_role_id"],
                "axis_completeness": row["axis_completeness"],
                "missing_axes": ";".join(row["missing_axes"]),
            }
            out.update(row["state"])
            writer.writerow(out)


def render_summary(result: dict[str, Any]) -> str:
    d = result["diagnostics"]
    flags = d["falsification_flags"]
    lines = [
        "STATE TRAJECTORY RECONSTRUCTION",
        f"  source: {result['source']}",
        f"  schema: {result['schema_version']}",
        f"  turns: {d['turn_count']}",
        f"  verdict: {d['verdict']}",
        f"  mean completeness: {d['mean_state_completeness']:.3f}",
        f"  active axes: {d['active_axis_count']} ({', '.join(d['active_axes'])})",
        f"  path length: {d['path_length']:.6f}",
        f"  mean step distance: {d['mean_step_distance']:.6f}",
    ]
    if d["net_displacement"] is not None:
        lines.append(f"  net displacement: {d['net_displacement']:.6f}")
    if d["tortuosity"] is not None:
        lines.append(f"  tortuosity: {d['tortuosity']:.6f}")
    if result["skipped_malformed_lines"]:
        lines.append(f"  skipped malformed lines: {result['skipped_malformed_lines']}")
    if flags:
        lines.append("  falsification flags:")
        lines.extend(f"    - {flag}" for flag in flags)
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Reconstruct a Goal 0 measured state trajectory from dialectic JSONL telemetry."
    )
    parser.add_argument("--input", required=True, type=Path, help="dialectical turn JSONL")
    parser.add_argument("--output", type=Path, help="write trajectory JSON")
    parser.add_argument("--csv", type=Path, help="write trajectory CSV")
    parser.add_argument("--pretty", action="store_true", help="pretty-print JSON output")
    parser.add_argument("--quiet", action="store_true", help="suppress the human summary")
    parser.add_argument("--min-turns", type=int, default=DEFAULT_MIN_TURNS)
    parser.add_argument("--min-completeness", type=float, default=DEFAULT_MIN_COMPLETENESS)
    parser.add_argument("--min-active-axes", type=int, default=DEFAULT_MIN_ACTIVE_AXES)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    events, skipped = load_events(args.input)
    result = reconstruct(
        events,
        source=args.input,
        skipped_malformed=skipped,
        min_turns=args.min_turns,
        min_completeness=args.min_completeness,
        min_active_axes=args.min_active_axes,
    )

    if args.output:
        write_json(result, args.output, pretty=args.pretty)
    if args.csv:
        write_csv(result, args.csv)
    if not args.output and not args.csv:
        json.dump(result, sys.stdout, indent=2 if args.pretty else None, sort_keys=True)
        print()
    elif not args.quiet:
        print(render_summary(result))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
