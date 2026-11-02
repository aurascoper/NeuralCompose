#!/usr/bin/env python3
"""
analyze_prosody_hypothesis.py - Prosody MVP hypothesis gate.

Consumes joined NeuralCompose telemetry streams:

    dialectic-turns-YYYY-MM-DD.jsonl
    prosody-trace-YYYY-MM-DD.jsonl

and evaluates the preregistered `reflective_prosody_v1` claim:

    Long measured pauses before voiced dialectical turns predict synthesis.

This is an offline Science/Engineering bridge. It does not call a model, parse
raw audio, change dialogue behavior, or promote anything into the runtime.

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


SCHEMA_VERSION = "prosody-hypothesis-analysis-v0"
HYPOTHESIS_ID = "reflective_prosody_v1"
DEFAULT_AUC_THRESHOLD = 0.70
DEFAULT_PAUSE_THRESHOLD_SECONDS = 0.600
DEFAULT_MIN_SAMPLES = 100
DEFAULT_MIN_SYNTHESIS = 10


def finite_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


def int_like(value: Any) -> int | None:
    f = finite_float(value)
    if f is None:
        return None
    i = int(f)
    return i if abs(f - i) <= 1e-9 else None


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as f:
        for line_number, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {exc}") from exc
            if not isinstance(value, dict):
                raise ValueError(f"{path}:{line_number}: JSONL row is not an object")
            rows.append(value)
    return rows


def dialectic_index(turns: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    indexed: dict[int, dict[str, Any]] = {}
    for turn in turns:
        idx = int_like(turn.get("index"))
        if idx is not None:
            indexed[idx] = turn
    return indexed


def phase_vector(event: dict[str, Any], phase: str) -> dict[str, Any] | None:
    raw = event.get(phase)
    return raw if isinstance(raw, dict) else None


def prosody_turn_index(event: dict[str, Any]) -> int | None:
    state = event.get("dialogue_state")
    if not isinstance(state, dict):
        return None
    return int_like(state.get("turn_index"))


def is_synthesis_outcome(outcome: Any) -> bool:
    return isinstance(outcome, str) and outcome.startswith("synthesized:")


def is_silent_outcome(outcome: Any) -> bool:
    return outcome == "silent"


def join_samples(
    turns: list[dict[str, Any]],
    prosody_events: list[dict[str, Any]],
    *,
    phase: str,
) -> tuple[list[dict[str, Any]], dict[str, int]]:
    by_turn = dialectic_index(turns)
    samples: list[dict[str, Any]] = []
    counters = {
        "prosody_without_turn_index": 0,
        "prosody_without_joined_turn": 0,
        "prosody_without_phase": 0,
        "prosody_without_pause_before": 0,
        "silent_turns_skipped": 0,
    }

    for event in prosody_events:
        turn_index = prosody_turn_index(event)
        if turn_index is None:
            counters["prosody_without_turn_index"] += 1
            continue

        turn = by_turn.get(turn_index)
        if turn is None:
            counters["prosody_without_joined_turn"] += 1
            continue

        outcome = turn.get("outcome")
        if is_silent_outcome(outcome):
            counters["silent_turns_skipped"] += 1
            continue

        vector = phase_vector(event, phase)
        if vector is None:
            counters["prosody_without_phase"] += 1
            continue

        pause_before = finite_float(vector.get("pause_before"))
        if pause_before is None:
            counters["prosody_without_pause_before"] += 1
            continue

        samples.append({
            "turn_index": turn_index,
            "prosody_index": int_like(event.get("index")),
            "source_kind": event.get("source_kind"),
            "outcome": outcome,
            "label": 1 if is_synthesis_outcome(outcome) else 0,
            "pause_before": pause_before,
        })

    samples.sort(key=lambda row: (row["turn_index"], row["prosody_index"] or -1))
    return samples, counters


def roc_auc(scores: list[float], labels: list[int]) -> float | None:
    positives = [score for score, label in zip(scores, labels) if label == 1]
    negatives = [score for score, label in zip(scores, labels) if label == 0]
    if not positives or not negatives:
        return None

    wins = 0.0
    total = 0
    for pos in positives:
        for neg in negatives:
            total += 1
            if pos > neg:
                wins += 1.0
            elif pos == neg:
                wins += 0.5
    return wins / total if total else None


def threshold_probe(samples: list[dict[str, Any]], threshold: float) -> dict[str, Any]:
    high = [row for row in samples if row["pause_before"] > threshold]
    low = [row for row in samples if row["pause_before"] <= threshold]

    def rate(rows: list[dict[str, Any]]) -> float | None:
        if not rows:
            return None
        return sum(row["label"] for row in rows) / len(rows)

    high_rate = rate(high)
    low_rate = rate(low)
    delta = (
        high_rate - low_rate
        if high_rate is not None and low_rate is not None
        else None
    )
    return {
        "threshold_seconds": threshold,
        "high_count": len(high),
        "low_count": len(low),
        "high_synthesis_count": sum(row["label"] for row in high),
        "low_synthesis_count": sum(row["label"] for row in low),
        "high_synthesis_rate": high_rate,
        "low_synthesis_rate": low_rate,
        "delta": delta,
    }


def summarize_samples(samples: list[dict[str, Any]]) -> dict[str, Any]:
    pauses = [row["pause_before"] for row in samples]
    if not pauses:
        return {
            "pause_before_mean": None,
            "pause_before_median": None,
            "pause_before_min": None,
            "pause_before_max": None,
        }
    return {
        "pause_before_mean": statistics.fmean(pauses),
        "pause_before_median": statistics.median(pauses),
        "pause_before_min": min(pauses),
        "pause_before_max": max(pauses),
    }


def analyze(
    turns: list[dict[str, Any]],
    prosody_events: list[dict[str, Any]],
    *,
    dialectic_source: Path | str,
    prosody_source: Path | str,
    phase: str = "measured",
    auc_threshold: float = DEFAULT_AUC_THRESHOLD,
    pause_threshold: float = DEFAULT_PAUSE_THRESHOLD_SECONDS,
    min_samples: int = DEFAULT_MIN_SAMPLES,
    min_synthesis: int = DEFAULT_MIN_SYNTHESIS,
    include_samples: bool = False,
) -> dict[str, Any]:
    samples, join_counters = join_samples(turns, prosody_events, phase=phase)
    labels = [row["label"] for row in samples]
    scores = [row["pause_before"] for row in samples]
    synthesis_count = sum(labels)
    non_synthesis_count = len(labels) - synthesis_count
    auc = roc_auc(scores, labels)
    probe = threshold_probe(samples, pause_threshold)

    flags: list[str] = []
    decision = "not_testable"
    next_stage = "collect_measured_prosody"

    if phase != "measured":
        flags.append(
            f"phase '{phase}' is pipeline validation only; acceptance requires measured prosody"
        )
    if len(samples) < min_samples:
        flags.append(
            f"eligible spoken turns {len(samples)} < required minimum {min_samples}"
        )
    if synthesis_count < min_synthesis:
        flags.append(
            f"synthesis turns {synthesis_count} < required minimum {min_synthesis}"
        )
    if non_synthesis_count <= 0:
        flags.append("no non-synthesis spoken turns available for ROC AUC")
    if auc is None:
        flags.append("ROC AUC is not computable")

    testable = (
        phase == "measured"
        and len(samples) >= min_samples
        and synthesis_count >= min_synthesis
        and non_synthesis_count > 0
        and auc is not None
    )

    if testable:
        if auc < 0.5:
            flags.append(f"effect direction is negative: roc_auc {auc:.6f} < 0.500000")
        if auc < auc_threshold:
            flags.append(
                f"roc_auc {auc:.6f} < acceptance threshold {auc_threshold:.6f}"
            )
        if flags:
            decision = "rejected"
            next_stage = "revise_or_reject_hypothesis"
        else:
            decision = "supported"
            next_stage = "promote_to_julia_reference_modeling"

    result: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "hypothesis_id": HYPOTHESIS_ID,
        "source": {
            "dialectical_turns": str(dialectic_source),
            "prosody_trace": str(prosody_source),
        },
        "feature": f"{phase}.pause_before",
        "label": "DialecticalTurnEvent.outcome starts with 'synthesized:'",
        "phase": phase,
        "acceptance": {
            "primary_metric": "roc_auc",
            "criterion": f"roc_auc >= {auc_threshold:.2f}",
            "minimum_sample_size": {
                "eligible_spoken_turns": min_samples,
                "synthesis_turns": min_synthesis,
            },
            "measured_prosody_required": True,
        },
        "sample_counts": {
            "dialectical_turns": len(turns),
            "prosody_events": len(prosody_events),
            "eligible_spoken_turns": len(samples),
            "synthesis_turns": synthesis_count,
            "non_synthesis_turns": non_synthesis_count,
            **join_counters,
        },
        "metrics": {
            "roc_auc": auc,
            **summarize_samples(samples),
        },
        "threshold_probe": probe,
        "decision": decision,
        "next_stage": next_stage,
        "falsification_flags": flags,
        "non_goals_preserved": [
            "no dialogue behavior change",
            "no voice cloning",
            "no Julia runtime integration",
            "no Rust production promotion",
        ],
    }
    if include_samples:
        result["samples"] = samples
    return result


def write_json(payload: dict[str, Any], path: Path | None, pretty: bool) -> None:
    text = json.dumps(payload, indent=2 if pretty else None, sort_keys=pretty)
    if path is None:
        print(text)
    else:
        path.write_text(text + "\n", encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Evaluate reflective_prosody_v1 over joined NeuralCompose JSONL telemetry."
    )
    parser.add_argument("--dialectic-turns", required=True, type=Path)
    parser.add_argument("--prosody-trace", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--phase",
        choices=("measured", "requested", "predicted"),
        default="measured",
        help="Prosody vector phase to evaluate. Only measured can satisfy acceptance.",
    )
    parser.add_argument("--auc-threshold", type=float, default=DEFAULT_AUC_THRESHOLD)
    parser.add_argument("--pause-threshold", type=float, default=DEFAULT_PAUSE_THRESHOLD_SECONDS)
    parser.add_argument("--min-samples", type=int, default=DEFAULT_MIN_SAMPLES)
    parser.add_argument("--min-synthesis", type=int, default=DEFAULT_MIN_SYNTHESIS)
    parser.add_argument("--include-samples", action="store_true")
    parser.add_argument("--pretty", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        turns = load_jsonl(args.dialectic_turns)
        prosody_events = load_jsonl(args.prosody_trace)
        result = analyze(
            turns,
            prosody_events,
            dialectic_source=args.dialectic_turns,
            prosody_source=args.prosody_trace,
            phase=args.phase,
            auc_threshold=args.auc_threshold,
            pause_threshold=args.pause_threshold,
            min_samples=args.min_samples,
            min_synthesis=args.min_synthesis,
            include_samples=args.include_samples,
        )
        if not args.quiet:
            write_json(result, args.output, args.pretty)
        elif args.output is not None:
            write_json(result, args.output, args.pretty)
        return 0
    except Exception as exc:  # pragma: no cover - exercised by shell users.
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
