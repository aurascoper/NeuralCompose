#!/usr/bin/env python3
"""
analyze_state_trajectory.py - Goal 1 for NeuralComposeScience.

This script consumes a Goal 0 state-trajectory artifact and performs a
model-free trajectory analysis. It does not solve an ODE or fit parameters.
Its job is to decide whether a reconstructed run is strong enough to become
a candidate dynamical-modeling question.

Initial candidate hypothesis:

    Continuation pressure creates stable attractors.

Operationally, that is split into two falsifiable claims:

    H1: The trajectory approaches a local attractor.
    H2: Higher continuation pressure predicts smaller next-step movement.

Dependency policy: stdlib only.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "state-trajectory-analysis-v0"
DEFAULT_MIN_TURNS = 6
DEFAULT_MAX_LATE_STEP_RATIO = 0.80
DEFAULT_MAX_LATE_RADIUS_RATIO = 0.80
DEFAULT_MIN_PRESSURE_SAMPLES = 6
DEFAULT_MIN_NEGATIVE_CORRELATION = 0.25
EPSILON = 1e-9


def finite_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def load_trajectory(path: Path) -> dict[str, Any]:
    with path.open() as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path} is not a trajectory object")
    return data


def trajectory_rows(data: dict[str, Any]) -> list[dict[str, Any]]:
    rows = data.get("rows", [])
    return [row for row in rows if isinstance(row, dict)]


def trajectory_axis_order(data: dict[str, Any], rows: list[dict[str, Any]]) -> list[str]:
    declared = data.get("axis_order")
    if isinstance(declared, list):
        axes = [str(axis) for axis in declared if isinstance(axis, str)]
        if axes:
            return axes

    discovered: list[str] = []
    for row in rows:
        state = row.get("state")
        if not isinstance(state, dict):
            continue
        for axis in state:
            if axis not in discovered:
                discovered.append(str(axis))
    return discovered


def compute_axis_stats(
    rows: list[dict[str, Any]],
    axis_order: list[str],
) -> dict[str, dict[str, float | None]]:
    stats: dict[str, dict[str, float | None]] = {}
    for axis in axis_order:
        values: list[float] = []
        for row in rows:
            state = row.get("state")
            if isinstance(state, dict):
                value = finite_float(state.get(axis))
                if value is not None:
                    values.append(value)

        if values:
            stats[axis] = {
                "min": min(values),
                "max": max(values),
                "variance": statistics.pvariance(values) if len(values) > 1 else 0.0,
            }
        else:
            stats[axis] = {"min": None, "max": None, "variance": None}
    return stats


def merged_axis_stats(
    data: dict[str, Any],
    rows: list[dict[str, Any]],
    axis_order: list[str],
) -> dict[str, dict[str, float | None]]:
    computed = compute_axis_stats(rows, axis_order)
    artifact_stats = (
        data.get("diagnostics", {}).get("axis_stats", {})
        if isinstance(data.get("diagnostics"), dict)
        else {}
    )
    if not isinstance(artifact_stats, dict):
        return computed

    stats: dict[str, dict[str, float | None]] = {}
    for axis in axis_order:
        raw = artifact_stats.get(axis)
        if isinstance(raw, dict):
            lo = finite_float(raw.get("min"))
            hi = finite_float(raw.get("max"))
            variance = finite_float(raw.get("variance"))
            if lo is not None and hi is not None:
                stats[axis] = {
                    "min": lo,
                    "max": hi,
                    "variance": variance,
                }
                continue
        stats[axis] = computed[axis]
    return stats


def active_axes(
    data: dict[str, Any],
    rows: list[dict[str, Any]],
    axis_order: list[str],
    stats: dict[str, dict[str, float | None]],
) -> list[str]:
    declared = data.get("diagnostics", {}).get("active_axes", [])
    if isinstance(declared, list):
        active = [
            axis for axis in axis_order
            if axis in declared
            and (stats.get(axis, {}).get("variance") or 0.0) > EPSILON
        ]
        if active:
            return active

    return [
        axis for axis in axis_order
        if (stats.get(axis, {}).get("variance") or 0.0) > EPSILON
    ]


def normalized_value(value: float, stats: dict[str, float | None]) -> float | None:
    lo = stats.get("min")
    hi = stats.get("max")
    if lo is None or hi is None or abs(hi - lo) <= EPSILON:
        return None
    return (value - lo) / (hi - lo)


def row_axis_value(row: dict[str, Any], axis: str) -> float | None:
    state = row.get("state")
    if not isinstance(state, dict):
        return None
    return finite_float(state.get(axis))


def row_distance(
    a: dict[str, Any],
    b: dict[str, Any],
    stats: dict[str, dict[str, float | None]],
    axes: list[str],
) -> float | None:
    diffs: list[float] = []
    for axis in axes:
        av = row_axis_value(a, axis)
        bv = row_axis_value(b, axis)
        if av is None or bv is None:
            continue
        na = normalized_value(av, stats[axis])
        nb = normalized_value(bv, stats[axis])
        if na is None or nb is None:
            continue
        diffs.append((na - nb) ** 2)
    if not diffs:
        return None
    return math.sqrt(sum(diffs) / len(diffs))


def step_distances(
    rows: list[dict[str, Any]],
    stats: dict[str, dict[str, float | None]],
    axes: list[str],
) -> list[float | None]:
    return [
        row_distance(prev, curr, stats, axes)
        for prev, curr in zip(rows, rows[1:])
    ]


def finite_values(values: list[float | None]) -> list[float]:
    return [v for v in values if v is not None and math.isfinite(v)]


def mean_or_none(values: list[float | None] | list[float]) -> float | None:
    finite = finite_values(list(values))
    return statistics.fmean(finite) if finite else None


def ratio_or_none(numerator: float | None, denominator: float | None) -> float | None:
    if numerator is None or denominator is None or abs(denominator) <= EPSILON:
        return None
    return numerator / denominator


def analysis_window_size(turn_count: int) -> int:
    if turn_count <= 1:
        return 0
    return min(5, max(2, turn_count // 4))


def row_to_normalized_vector(
    row: dict[str, Any],
    stats: dict[str, dict[str, float | None]],
    axes: list[str],
) -> dict[str, float]:
    vector: dict[str, float] = {}
    for axis in axes:
        value = row_axis_value(row, axis)
        if value is None:
            continue
        normalized = normalized_value(value, stats[axis])
        if normalized is not None:
            vector[axis] = normalized
    return vector


def window_radius(
    rows: list[dict[str, Any]],
    stats: dict[str, dict[str, float | None]],
    axes: list[str],
) -> float | None:
    vectors = [row_to_normalized_vector(row, stats, axes) for row in rows]
    vectors = [vector for vector in vectors if vector]
    if not vectors:
        return None

    centroid: dict[str, float] = {}
    for axis in axes:
        values = [vector[axis] for vector in vectors if axis in vector]
        if values:
            centroid[axis] = statistics.fmean(values)
    if not centroid:
        return None

    distances: list[float] = []
    for vector in vectors:
        diffs = [
            (value - centroid[axis]) ** 2
            for axis, value in vector.items()
            if axis in centroid
        ]
        if diffs:
            distances.append(math.sqrt(sum(diffs) / len(diffs)))
    return statistics.fmean(distances) if distances else None


def linear_slope(values: list[float | None]) -> float | None:
    pairs = [
        (float(index), value)
        for index, value in enumerate(values)
        if value is not None and math.isfinite(value)
    ]
    if len(pairs) < 2:
        return None
    mean_x = statistics.fmean(x for x, _ in pairs)
    mean_y = statistics.fmean(y for _, y in pairs)
    denominator = sum((x - mean_x) ** 2 for x, _ in pairs)
    if denominator <= EPSILON:
        return None
    numerator = sum((x - mean_x) * (y - mean_y) for x, y in pairs)
    return numerator / denominator


def pearson(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) != len(ys) or len(xs) < 2:
        return None
    mean_x = statistics.fmean(xs)
    mean_y = statistics.fmean(ys)
    dx = [x - mean_x for x in xs]
    dy = [y - mean_y for y in ys]
    denom_x = math.sqrt(sum(x * x for x in dx))
    denom_y = math.sqrt(sum(y * y for y in dy))
    if denom_x <= EPSILON or denom_y <= EPSILON:
        return None
    return sum(x * y for x, y in zip(dx, dy)) / (denom_x * denom_y)


def pressure_step_pairs(
    rows: list[dict[str, Any]],
    steps: list[float | None],
) -> list[tuple[float, float]]:
    pairs: list[tuple[float, float]] = []
    for row, step in zip(rows, steps):
        pressure = row_axis_value(row, "continuation_pressure")
        if pressure is None or step is None or not math.isfinite(step):
            continue
        pairs.append((pressure, step))
    return pairs


def pressure_group_metrics(
    pairs: list[tuple[float, float]],
) -> dict[str, float | int | None]:
    if len(pairs) < 3:
        return {
            "group_size": 0,
            "low_pressure_mean_next_step": None,
            "high_pressure_mean_next_step": None,
            "high_minus_low_mean_next_step": None,
        }

    ordered = sorted(pairs, key=lambda pair: pair[0])
    group_size = max(2, len(ordered) // 3)
    low_steps = [step for _, step in ordered[:group_size]]
    high_steps = [step for _, step in ordered[-group_size:]]
    low_mean = statistics.fmean(low_steps)
    high_mean = statistics.fmean(high_steps)
    return {
        "group_size": group_size,
        "low_pressure_mean_next_step": low_mean,
        "high_pressure_mean_next_step": high_mean,
        "high_minus_low_mean_next_step": high_mean - low_mean,
    }


def local_attractor_analysis(
    *,
    data: dict[str, Any],
    rows: list[dict[str, Any]],
    steps: list[float | None],
    stats: dict[str, dict[str, float | None]],
    axes: list[str],
    min_turns: int,
    max_late_step_ratio: float,
    max_late_radius_ratio: float,
) -> dict[str, Any]:
    representable = bool(data.get("diagnostics", {}).get("representable"))
    window = analysis_window_size(len(rows))
    early_steps = finite_values(steps[:window])
    late_steps = finite_values(steps[-window:])
    early_mean_step = statistics.fmean(early_steps) if early_steps else None
    late_mean_step = statistics.fmean(late_steps) if late_steps else None
    step_ratio = ratio_or_none(late_mean_step, early_mean_step)

    point_window = min(len(rows), window + 1)
    early_radius = window_radius(rows[:point_window], stats, axes)
    late_radius = window_radius(rows[-point_window:], stats, axes)
    radius_ratio = ratio_or_none(late_radius, early_radius)

    setup_flags: list[str] = []
    if not representable:
        setup_flags.append("input trajectory is not representable")
    if len(rows) < min_turns:
        setup_flags.append(f"requires at least {min_turns} turns")
    if len(early_steps) < 2 or len(late_steps) < 2:
        setup_flags.append("requires at least two early and late finite steps")
    if step_ratio is None:
        setup_flags.append("cannot compare early and late step distance")
    if radius_ratio is None:
        setup_flags.append("cannot compare early and late window radius")

    falsification_flags: list[str] = []
    if not setup_flags:
        if step_ratio is not None and step_ratio > max_late_step_ratio:
            falsification_flags.append(
                f"late/early step ratio {step_ratio:.3f} exceeds {max_late_step_ratio:.3f}"
            )
        if radius_ratio is not None and radius_ratio > max_late_radius_ratio:
            falsification_flags.append(
                f"late/early radius ratio {radius_ratio:.3f} exceeds {max_late_radius_ratio:.3f}"
            )

    if setup_flags:
        decision = "not_testable"
    elif falsification_flags:
        decision = "rejected"
    else:
        decision = "supported"

    return {
        "id": "H1_local_attractor_proxy",
        "claim": "The reconstructed dialogue trajectory approaches a local attractor.",
        "operationalization": (
            "The late trajectory window has lower normalized step distance and "
            "lower radius than the early window."
        ),
        "decision": decision,
        "metrics": {
            "turn_count": len(rows),
            "active_axes": axes,
            "analysis_window_size": window,
            "early_mean_step_distance": early_mean_step,
            "late_mean_step_distance": late_mean_step,
            "late_early_step_ratio": step_ratio,
            "early_window_radius": early_radius,
            "late_window_radius": late_radius,
            "late_early_radius_ratio": radius_ratio,
            "step_trend_slope": linear_slope(steps),
        },
        "criteria": {
            "min_turns": min_turns,
            "max_late_early_step_ratio": max_late_step_ratio,
            "max_late_early_radius_ratio": max_late_radius_ratio,
        },
        "falsification_flags": setup_flags + falsification_flags,
    }


def continuation_pressure_analysis(
    *,
    rows: list[dict[str, Any]],
    steps: list[float | None],
    min_pressure_samples: int,
    min_negative_correlation: float,
) -> dict[str, Any]:
    pairs = pressure_step_pairs(rows, steps)
    pressures = [pressure for pressure, _ in pairs]
    next_steps = [step for _, step in pairs]
    correlation = pearson(pressures, next_steps)
    group_metrics = pressure_group_metrics(pairs)

    setup_flags: list[str] = []
    if len(pairs) < min_pressure_samples:
        setup_flags.append(f"requires at least {min_pressure_samples} pressure/step pairs")
    if correlation is None:
        setup_flags.append("continuation_pressure or next-step movement has no measurable variance")

    falsification_flags: list[str] = []
    high_mean = finite_float(group_metrics["high_pressure_mean_next_step"])
    low_mean = finite_float(group_metrics["low_pressure_mean_next_step"])
    if not setup_flags:
        threshold = -abs(min_negative_correlation)
        if correlation is not None and correlation > threshold:
            falsification_flags.append(
                f"pressure/next-step correlation {correlation:.3f} is not <= {threshold:.3f}"
            )
        if high_mean is not None and low_mean is not None and high_mean >= low_mean:
            falsification_flags.append(
                "high-pressure turns do not have lower next-step movement than low-pressure turns"
            )

    if setup_flags:
        decision = "not_testable"
    elif falsification_flags:
        decision = "rejected"
    else:
        decision = "supported"

    return {
        "id": "H2_continuation_pressure_stabilizes_motion",
        "claim": "Higher continuation pressure predicts smaller next-step movement.",
        "operationalization": (
            "Continuation pressure at turn t should be negatively correlated "
            "with normalized state movement from t to t+1."
        ),
        "decision": decision,
        "metrics": {
            "sample_count": len(pairs),
            "pressure_range": (
                [min(pressures), max(pressures)] if pressures else None
            ),
            "pressure_next_step_correlation": correlation,
            **group_metrics,
        },
        "criteria": {
            "min_pressure_samples": min_pressure_samples,
            "min_negative_correlation": min_negative_correlation,
        },
        "falsification_flags": setup_flags + falsification_flags,
    }


def combined_hypothesis(
    local_attractor: dict[str, Any],
    pressure: dict[str, Any],
) -> dict[str, Any]:
    decisions = [local_attractor["decision"], pressure["decision"]]
    if "not_testable" in decisions:
        decision = "not_testable"
        next_stage = "collect_or_reconstruct_more_telemetry"
    elif decisions == ["supported", "supported"]:
        decision = "supported"
        next_stage = "promote_to_dynamical_modeling"
    elif "rejected" in decisions:
        decision = "rejected"
        next_stage = "revise_or_reject_hypothesis"
    else:
        decision = "inconclusive"
        next_stage = "collect_more_telemetry"

    return {
        "id": "H_continuation_pressure_attractor_v0",
        "claim": "Continuation pressure creates stable attractors.",
        "decision": decision,
        "next_stage": next_stage,
        "promotion_boundary": (
            "A supported result only promotes the question to Julia dynamical "
            "modeling. It does not justify a Rust production kernel."
        ),
    }


def analyze(
    data: dict[str, Any],
    *,
    source: Path,
    min_turns: int = DEFAULT_MIN_TURNS,
    max_late_step_ratio: float = DEFAULT_MAX_LATE_STEP_RATIO,
    max_late_radius_ratio: float = DEFAULT_MAX_LATE_RADIUS_RATIO,
    min_pressure_samples: int = DEFAULT_MIN_PRESSURE_SAMPLES,
    min_negative_correlation: float = DEFAULT_MIN_NEGATIVE_CORRELATION,
) -> dict[str, Any]:
    rows = trajectory_rows(data)
    axis_order = trajectory_axis_order(data, rows)
    stats = merged_axis_stats(data, rows, axis_order)
    axes = active_axes(data, rows, axis_order, stats)
    steps = step_distances(rows, stats, axes)

    local_attractor = local_attractor_analysis(
        data=data,
        rows=rows,
        steps=steps,
        stats=stats,
        axes=axes,
        min_turns=min_turns,
        max_late_step_ratio=max_late_step_ratio,
        max_late_radius_ratio=max_late_radius_ratio,
    )
    pressure = continuation_pressure_analysis(
        rows=rows,
        steps=steps,
        min_pressure_samples=min_pressure_samples,
        min_negative_correlation=min_negative_correlation,
    )
    combined = combined_hypothesis(local_attractor, pressure)

    return {
        "schema_version": SCHEMA_VERSION,
        "source": str(source),
        "source_schema_version": data.get("schema_version"),
        "hypothesis_stage": "goal_1_trajectory_analysis",
        "question": (
            "Does the reconstructed trajectory contain model-free evidence "
            "that continuation pressure creates stable attractors?"
        ),
        "axis_order": axis_order,
        "active_axes": axes,
        "step_distances": steps,
        "hypotheses": [local_attractor, pressure],
        "combined_hypothesis": combined,
        "decision": combined["decision"],
        "next_stage": combined["next_stage"],
    }


def write_json(result: dict[str, Any], path: Path, *, pretty: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        if pretty:
            json.dump(result, f, indent=2, sort_keys=True)
        else:
            json.dump(result, f, separators=(",", ":"), sort_keys=True)
        f.write("\n")


def render_summary(result: dict[str, Any]) -> str:
    combined = result["combined_hypothesis"]
    lines = [
        "STATE TRAJECTORY ANALYSIS",
        f"  source: {result['source']}",
        f"  schema: {result['schema_version']}",
        f"  combined hypothesis: {combined['id']}",
        f"  decision: {combined['decision']}",
        f"  next stage: {combined['next_stage']}",
    ]

    for hypothesis in result["hypotheses"]:
        lines.append(f"  {hypothesis['id']}: {hypothesis['decision']}")
        for flag in hypothesis["falsification_flags"]:
            lines.append(f"    - {flag}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Analyze a Goal 0 state-trajectory artifact for candidate dynamical hypotheses."
    )
    parser.add_argument("--input", required=True, type=Path, help="state trajectory JSON")
    parser.add_argument("--output", type=Path, help="write analysis JSON")
    parser.add_argument("--pretty", action="store_true", help="pretty-print JSON output")
    parser.add_argument("--quiet", action="store_true", help="suppress the human summary")
    parser.add_argument("--min-turns", type=int, default=DEFAULT_MIN_TURNS)
    parser.add_argument("--max-late-step-ratio", type=float, default=DEFAULT_MAX_LATE_STEP_RATIO)
    parser.add_argument("--max-late-radius-ratio", type=float, default=DEFAULT_MAX_LATE_RADIUS_RATIO)
    parser.add_argument("--min-pressure-samples", type=int, default=DEFAULT_MIN_PRESSURE_SAMPLES)
    parser.add_argument("--min-negative-correlation", type=float, default=DEFAULT_MIN_NEGATIVE_CORRELATION)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    data = load_trajectory(args.input)
    result = analyze(
        data,
        source=args.input,
        min_turns=args.min_turns,
        max_late_step_ratio=args.max_late_step_ratio,
        max_late_radius_ratio=args.max_late_radius_ratio,
        min_pressure_samples=args.min_pressure_samples,
        min_negative_correlation=args.min_negative_correlation,
    )

    if args.output:
        write_json(result, args.output, pretty=args.pretty)
    else:
        json.dump(result, sys.stdout, indent=2 if args.pretty else None, sort_keys=True)
        print()

    if args.output and not args.quiet:
        print(render_summary(result))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
