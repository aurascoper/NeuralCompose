#!/usr/bin/env python3
"""Export causal, privacy-preserving rows for EXP-RSP-001.

The command is deliberately an offline scientific artifact builder. It reads
isolated soak JSONL, requires a local pinned semantic encoder, and writes only
numeric features, labels, and provenance. It never changes app behavior and
never writes embeddings or raw dialogue text to the output dataset.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import itertools
import json
import math
import statistics
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol


SCHEMA_VERSION = "rsp-dataset-v0"
EXPERIMENT_ID = "EXP-RSP-001"
ENCODER_ID = "BAAI/bge-small-en-v1.5"
EXTRACTOR_VERSION = "rsp-feature-export-v1"
HORIZON = 5
HISTORY_WINDOW = 5
FEATURE_NAMES = (
    "closure_efficiency",
    "semantic_inertia_delta",
    "policy_inertia_delta_causal",
    "motif_orientation_delta",
    "level_of_abstraction_delta",
    "relational_amplification_delta",
    "candidate_context_distance",
    "candidate_dispersion",
    "winner_margin",
    "response_length",
    "history_dispersion",
    "synthesis_confidence",
)


def load_dialectic_module():
    path = Path(__file__).with_name("analyze_dialectic.py")
    spec = importlib.util.spec_from_file_location("rsp_dialectic_metrics", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load frozen metric vocabulary from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


DIALECTIC = load_dialectic_module()


class Encoder(Protocol):
    provenance: dict[str, Any]

    def encode(self, texts: list[str]) -> dict[str, list[float]]:
        ...


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_directory(path: Path) -> str:
    digest = hashlib.sha256()
    for entry in sorted(p for p in path.rglob("*") if p.is_file()):
        digest.update(entry.relative_to(path).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(entry)))
    return digest.hexdigest()


def normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm <= 0:
        raise ValueError("encoder produced a zero-length vector")
    return [value / norm for value in vector]


class FixtureEncoder:
    """Test-only encoder backed by explicit vectors, never by generated hashes."""

    def __init__(self, path: Path):
        payload = json.loads(path.read_text())
        vectors = payload.get("vectors")
        if not isinstance(vectors, dict):
            raise ValueError("encoder fixture requires a 'vectors' object")
        self.vectors = {
            str(text): normalize([float(value) for value in values])
            for text, values in vectors.items()
        }
        self.provenance = {
            "id": "test-fixture-encoder",
            "revision": "fixture",
            "sha256": sha256_file(path),
            "extractor_version": EXTRACTOR_VERSION,
            "extractor_sha256": sha256_file(Path(__file__)),
            "test_only": True,
        }

    def encode(self, texts: list[str]) -> dict[str, list[float]]:
        missing = sorted(set(texts) - set(self.vectors))
        if missing:
            raise ValueError(f"encoder fixture lacks vectors for: {missing[:3]}")
        return {text: self.vectors[text] for text in texts}


class LocalBGEEncoder:
    def __init__(self, directory: Path, revision: str, coreml_encoder: Path | None = None):
        if not directory.is_dir():
            raise ValueError(f"encoder directory does not exist: {directory}")
        if not revision:
            raise ValueError("--encoder-revision is required for a local BGE run")
        metadata_path = directory / "metadata.json"
        if not metadata_path.is_file():
            raise ValueError(f"Core ML BGE metadata is missing: {metadata_path}")
        metadata = json.loads(metadata_path.read_text())
        if metadata.get("model") != ENCODER_ID:
            raise ValueError(f"encoder metadata must identify {ENCODER_ID}")
        if metadata.get("revision") != revision:
            raise ValueError(
                f"encoder revision mismatch: requested {revision}, metadata records {metadata.get('revision')}"
            )
        self.directory = directory.resolve()
        if coreml_encoder is not None:
            resolved_bridge = coreml_encoder.resolve()
            if not resolved_bridge.is_file():
                raise ValueError(f"Core ML encoder executable does not exist: {resolved_bridge}")
            self.coreml_encoder = resolved_bridge
        else:
            self.coreml_encoder = None
        self.provenance = {
            "id": ENCODER_ID,
            "revision": revision,
            "sha256": sha256_directory(directory),
            "path": str(directory),
            "backend": "neuralcompose-coreml",
            "dimension": metadata.get("dimension"),
            "pooling": metadata.get("pooling"),
            "converted_with": metadata.get("converted_with"),
            "extractor_version": EXTRACTOR_VERSION,
            "extractor_sha256": sha256_file(Path(__file__)),
            "test_only": False,
        }

    def encode(self, texts: list[str]) -> dict[str, list[float]]:
        if not texts:
            return {}
        with tempfile.TemporaryDirectory(prefix="neuralcompose-rsp-") as temporary:
            root = Path(temporary)
            input_path = root / "texts.json"
            output_path = root / "embeddings.json"
            input_path.write_text(json.dumps({"texts": texts}))
            command = (
                [str(self.coreml_encoder)]
                if self.coreml_encoder is not None
                else ["swift", "run", "--quiet", "RSPEmbedding"]
            )
            command += [
                "--model-dir", str(self.directory),
                "--input", str(input_path),
                "--output", str(output_path),
            ]
            try:
                completed = subprocess.run(
                    command,
                    cwd=Path(__file__).resolve().parent.parent,
                    text=True,
                    capture_output=True,
                    check=False,
                )
            except FileNotFoundError as error:
                raise RuntimeError(f"Core ML BGE bridge executable is unavailable: {command[0]}") from error
            if completed.returncode != 0:
                detail = completed.stderr.strip() or completed.stdout.strip()
                raise RuntimeError(f"Core ML BGE bridge failed: {detail}")
            payload = json.loads(output_path.read_text())
        encoder = payload.get("encoder", {})
        vectors = payload.get("embeddings")
        if payload.get("schema_version") != "rsp-embedding-v0" or encoder.get("dimension") != 384:
            raise RuntimeError("Core ML BGE bridge returned an incompatible embedding artifact")
        if not isinstance(vectors, list) or len(vectors) != len(texts):
            raise RuntimeError("Core ML BGE bridge returned the wrong number of embeddings")
        return {text: normalize([float(value) for value in vector]) for text, vector in zip(texts, vectors, strict=True)}


def normalized_similarity(left: list[float], right: list[float]) -> float:
    if len(left) != len(right):
        raise ValueError("encoder vectors have inconsistent dimensions")
    cosine = sum(a * b for a, b in zip(left, right, strict=True))
    return min(1.0, max(0.0, (cosine + 1.0) / 2.0))


def distance(left: list[float], right: list[float]) -> float:
    return 1.0 - normalized_similarity(left, right)


def mean_or_zero(values: list[float]) -> float:
    return statistics.fmean(values) if values else 0.0


def load_events(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    with path.open() as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: malformed JSONL row") from error
            if not isinstance(event, dict):
                raise ValueError(f"{path}:{line_number}: JSONL row is not an object")
            events.append(event)
    if not events:
        raise ValueError(f"{path}: no events")
    indexes = [event.get("index") for event in events]
    if any(not isinstance(index, int) for index in indexes):
        raise ValueError(f"{path}: every event must carry an integer index")
    if any(right <= left for left, right in zip(indexes, indexes[1:])):
        raise ValueError(f"{path}: event indexes must be strictly increasing")
    return events


def raw_outcome(event: dict[str, Any]) -> str:
    return str(event.get("outcome") or "silent")


def normalized_outcome(event: dict[str, Any]) -> str:
    raw = raw_outcome(event)
    if raw == "silent":
        return "silent"
    if raw.startswith("synthesized:"):
        return "synthesis"
    if raw.startswith("spoke:"):
        return raw.split(":", 1)[1]
    return raw


def spoken_text(event: dict[str, Any]) -> str:
    return str(event.get("spokenText") or "").strip()


def heard_text(event: dict[str, Any]) -> str:
    return str(event.get("heard") or "").strip()


def candidate_text(event: dict[str, Any], role_id: str) -> str:
    for candidate in event.get("candidates") or []:
        if isinstance(candidate, dict) and candidate.get("roleID") == role_id:
            text = str(candidate.get("text") or "").strip()
            if text:
                return text
    return ""


def theme_texts(event: dict[str, Any]) -> dict[str, str] | None:
    themes = {
        "heard": heard_text(event),
        "coherence_pole": candidate_text(event, "coherence-seeking"),
        "displacement_pole": candidate_text(event, "displacement-seeking"),
    }
    return themes if all(themes.values()) else None


def all_event_texts(events: list[dict[str, Any]]) -> list[str]:
    texts: set[str] = set()
    for event in events:
        for text in (heard_text(event), spoken_text(event)):
            if text:
                texts.add(text)
        for candidate in event.get("candidates") or []:
            if isinstance(candidate, dict):
                text = str(candidate.get("text") or "").strip()
                if text:
                    texts.add(text)
    return sorted(texts)


def recurrence_labels(
    events: list[dict[str, Any]],
    position: int,
    vectors: dict[str, list[float]],
) -> dict[str, float] | None:
    themes = theme_texts(events[position])
    if themes is None or position + HORIZON >= len(events):
        return None
    future = [spoken_text(events[position + offset]) for offset in range(1, HORIZON + 1)]

    def per_theme(text: str) -> list[float]:
        return [normalized_similarity(vectors[text], vectors[next_text]) if next_text else 0.0 for next_text in future]

    by_theme = {name: per_theme(text) for name, text in themes.items()}
    union = [max(by_theme[name][offset] for name in by_theme) for offset in range(HORIZON)]
    ranked = sorted(union, reverse=True)
    return {
        "recurrence_5": max(union),
        "mean_recurrence_5": mean_or_zero(union),
        "top2_mean_recurrence_5": mean_or_zero(ranked[:2]),
        "recurrence_5_heard": max(by_theme["heard"]),
        "recurrence_5_coherence_pole": max(by_theme["coherence_pole"]),
        "recurrence_5_displacement_pole": max(by_theme["displacement_pole"]),
    }


def jaccard_similarity(left: str, right: str) -> float:
    left_tokens = set(DIALECTIC.tokenize(left))
    right_tokens = set(DIALECTIC.tokenize(right))
    if not left_tokens and not right_tokens:
        return 0.0
    return len(left_tokens & right_tokens) / len(left_tokens | right_tokens)


def policy_inertia(events: list[dict[str, Any]]) -> float:
    outcomes = tuple(DIALECTIC.OUTCOMES)
    counts = {outcome: {next_outcome: 0 for next_outcome in outcomes} for outcome in outcomes}
    for previous, current in zip(events, events[1:]):
        left = normalized_outcome(previous)
        right = normalized_outcome(current)
        if left in counts and right in counts[left]:
            counts[left][right] += 1
    entropies: list[float] = []
    for outcome in outcomes:
        total = sum(counts[outcome].values())
        if total <= 0:
            continue
        entropy = 0.0
        for count in counts[outcome].values():
            probability = count / total
            if probability:
                entropy -= probability * math.log2(probability)
        entropies.append(entropy)
    return 1.0 - mean_or_zero(entropies) / math.log2(len(outcomes)) if entropies else 0.0


def motif_orientation(text: str) -> float:
    tokens = DIALECTIC.tokenize(text)
    if not tokens:
        return 0.0
    teleological = sum(
        token in DIALECTIC.MOTIF_CLASSES["transcendence"] or token in DIALECTIC.MOTIF_CLASSES["inwardness"]
        for token in tokens
    )
    epistemic = sum(
        token in DIALECTIC.MOTIF_CLASSES["observation"] or token in DIALECTIC.MOTIF_CLASSES["investigation"]
        for token in tokens
    )
    return (teleological - epistemic) / len(tokens)


def abstraction_score(text: str) -> float:
    vector = DIALECTIC._loa_vector(text)
    if vector is None:
        return 0.0
    return sum((index / 4.0) * value for index, value in enumerate(vector))


def relational_amplification(event: dict[str, Any]) -> float:
    return DIALECTIC._p_relational(spoken_text(event)) - DIALECTIC._p_relational(heard_text(event))


def feature_row(
    events: list[dict[str, Any]],
    position: int,
    vectors: dict[str, list[float]],
    lagged_recurrence: float | None,
) -> dict[str, Any] | None:
    event = events[position]
    themes = theme_texts(event)
    current_spoken = spoken_text(event)
    if themes is None or not current_spoken or position < HISTORY_WINDOW:
        return None
    theme_vectors = [vectors[text] for text in themes.values()]
    pair_distances = [distance(left, right) for left, right in itertools.combinations(theme_vectors, 2)]
    pre_dispersion = mean_or_zero(pair_distances)
    post_dispersion = mean_or_zero([distance(vectors[current_spoken], vector) for vector in theme_vectors])
    prior = [spoken_text(previous) for previous in events[position - HISTORY_WINDOW:position] if spoken_text(previous)]
    if not prior:
        return None
    coherence = themes["coherence_pole"]
    displacement = themes["displacement_pole"]
    context_distances = [
        distance(vectors[candidate], vectors[history])
        for candidate in (coherence, displacement)
        for history in prior
    ]
    history_distances = [
        distance(vectors[left], vectors[right])
        for left, right in itertools.combinations(prior, 2)
    ]
    current_semantic = jaccard_similarity(heard_text(events[position - 1]), heard_text(event))
    previous_semantic = jaccard_similarity(heard_text(events[position - 2]), heard_text(events[position - 1]))
    current_policy = policy_inertia(events[:position + 1])
    previous_policy = policy_inertia(events[:position])
    tension = float(event.get("tension", 0.0) or 0.0)
    features = {
        "closure_efficiency": pre_dispersion - post_dispersion,
        "semantic_inertia_delta": current_semantic - previous_semantic,
        "policy_inertia_delta_causal": current_policy - previous_policy,
        "motif_orientation_delta": motif_orientation(current_spoken) - motif_orientation(spoken_text(events[position - 1])),
        "level_of_abstraction_delta": abstraction_score(current_spoken) - abstraction_score(spoken_text(events[position - 1])),
        "relational_amplification_delta": relational_amplification(event) - relational_amplification(events[position - 1]),
        "candidate_context_distance": mean_or_zero(context_distances),
        "candidate_dispersion": distance(vectors[coherence], vectors[displacement]),
        "winner_margin": float(event.get("margin", 0.0) or 0.0),
        "response_length": float(len(DIALECTIC.tokenize(current_spoken))),
        "history_dispersion": mean_or_zero(history_distances),
        "synthesis_confidence": 1.0 - min(1.0, max(0.0, tension)),
    }
    if set(features) != set(FEATURE_NAMES) or not all(math.isfinite(value) for value in features.values()):
        raise ValueError(f"turn {event.get('index')}: invalid feature vector")
    return {
        "features": features,
        "baselines": {
            "current_synthesis_theme_similarity": max(
                normalized_similarity(vectors[current_spoken], vector) for vector in theme_vectors
            ),
            "lagged_recurrence_5": lagged_recurrence,
            "response_length": features["response_length"],
            "synthesis_confidence": features["synthesis_confidence"],
            "semantic_inertia_delta": features["semantic_inertia_delta"],
        },
    }


def run_identity(path: Path) -> str:
    return f"{path.parents[1].name}/{path.stem}" if path.parent.name == "runs" else path.stem


def generator_fingerprint(event: dict[str, Any]) -> dict[str, str]:
    fingerprint = event.get("generatorFingerprint")
    if not isinstance(fingerprint, dict):
        raise ValueError("RSP source requires generatorFingerprint on every eligible anchor")
    keys = ("runtime", "transport", "provider", "model", "promptProfile", "interactionStyle", "promptHash")
    return {key: str(fingerprint.get(key) or "") for key in keys}


def build_run_rows(path: Path, encoder: Encoder) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    events = load_events(path)
    vectors = encoder.encode(all_event_texts(events))
    labels_by_position = {position: recurrence_labels(events, position, vectors) for position in range(len(events))}
    rows: list[dict[str, Any]] = []
    for position, event in enumerate(events):
        labels = labels_by_position[position]
        if not raw_outcome(event).startswith("synthesized:") or labels is None:
            continue
        feature_payload = feature_row(
            events,
            position,
            vectors,
            labels_by_position.get(position - HORIZON, {}).get("recurrence_5") if position >= HORIZON and labels_by_position.get(position - HORIZON) else None,
        )
        if feature_payload is None:
            continue
        fingerprint = generator_fingerprint(event)
        configuration_id = "|".join(
            fingerprint[key] for key in ("runtime", "provider", "model", "promptProfile", "interactionStyle", "promptHash")
        )
        rows.append({
            "run_id": run_identity(path),
            "turn_index": event["index"],
            "configuration_id": configuration_id,
            "model_id": fingerprint["model"],
            "generator_fingerprint": fingerprint,
            "labels": labels,
            **feature_payload,
        })
    source = {
        "run_id": run_identity(path),
        "path": str(path),
        "sha256": sha256_file(path),
        "event_count": len(events),
        "eligible_anchor_count": len(rows),
        "matrix_sha256": (
            sha256_file(path.parents[1] / "matrix.json")
            if path.parent.name == "runs" and (path.parents[1] / "matrix.json").is_file()
            else None
        ),
    }
    return rows, source


def build_dataset(paths: list[Path], encoder: Encoder) -> dict[str, Any]:
    if not paths:
        raise ValueError("at least one --run is required")
    rows: list[dict[str, Any]] = []
    sources: list[dict[str, Any]] = []
    for path in paths:
        run_rows, source = build_run_rows(path, encoder)
        rows.extend(run_rows)
        sources.append(source)
    return {
        "schema_version": SCHEMA_VERSION,
        "experiment_id": EXPERIMENT_ID,
        "conditional_estimand": "P(recurrence_5 | apparent_synthesis, X_t)",
        "feature_names": list(FEATURE_NAMES),
        "encoder": encoder.provenance,
        "source_runs": sources,
        "rows": rows,
    }


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", type=Path, action="append", required=True, help="isolated soak JSONL; repeat for each run")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--encoder-dir", type=Path, help="local NeuralCompose Core ML BGE model directory")
    parser.add_argument("--encoder-revision", default="", help="required BGE revision matching metadata.json")
    parser.add_argument("--coreml-encoder", type=Path, help="optional prebuilt RSPEmbedding executable")
    parser.add_argument("--encoder-fixture", type=Path, help="test-only JSON text-to-vector fixture")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args(arguments)
    if bool(args.encoder_dir) == bool(args.encoder_fixture):
        parser.error("provide exactly one of --encoder-dir or --encoder-fixture")
    return args


def main(arguments: list[str] | None = None) -> int:
    args = parse_arguments(arguments or sys.argv[1:])
    encoder: Encoder = FixtureEncoder(args.encoder_fixture) if args.encoder_fixture else LocalBGEEncoder(
        args.encoder_dir, args.encoder_revision, args.coreml_encoder
    )
    dataset = build_dataset(args.run, encoder)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dataset, indent=2 if args.pretty else None, sort_keys=True) + "\n")
    print(f"EXP-RSP-001: wrote {len(dataset['rows'])} eligible anchors to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
