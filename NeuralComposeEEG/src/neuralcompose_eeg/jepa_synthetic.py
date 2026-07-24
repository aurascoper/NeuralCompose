"""Deterministic synthetic rehearsal for the offline four-channel JEPA pipeline.

This module cannot consume physical capture manifests. It generates its own
fully reproducible fixtures, trains only the separately preregistered synthetic
conditions, and emits pipeline-evidence artifacts under a distinct schema.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

from .contracts import ContractError, SOURCE_MANIFEST_SCHEMA, load_source_manifest
from .provenance import package_versions, runtime_provenance, sha256_file, sha256_json


CONFIG_SCHEMA = "nc-eeg-jepa-synthetic-config-v0"
GENERATOR_SCHEMA = "nc-eeg-jepa-synthetic-generators-v0"
SOURCE_SCHEMA = "nc-eeg-jepa-synthetic-source-v0"
REPORT_SCHEMA = "nc-eeg-jepa-synthetic-rehearsal-v0"
MODE_REPORT_SCHEMA = "nc-eeg-jepa-synthetic-mode-rehearsal-v0"
EXPERIMENT_ID = "EXP-NC-EEG-JEPA-SYN-000"
MODE_EXPERIMENT_ID = "EXP-NC-EEG-JEPA-SYN-MODE-000"
CONDITIONS = ("T0", "T1", "T2", "T3", "T4", "T5")
MODE_CONTROLS = ("C0", "C1", "C2", "C3", "C4", "C5")
MODES = ("mirror", "focus", "reflective", "contemplative")


@dataclass(frozen=True)
class SyntheticSession:
    session_id: str
    generator_id: str
    windows: np.ndarray
    state_labels: np.ndarray
    mode: str | None
    nuisance: dict[str, Any]
    missing_channel_provenance: str | None = None

    def validate(self, *, channels: int, window_samples: int) -> None:
        if not self.session_id.startswith("synthetic:"):
            raise ContractError("synthetic session IDs must begin with synthetic:")
        if self.windows.ndim != 3 or self.windows.shape[1:] != (
            channels,
            window_samples,
        ):
            raise ContractError(
                f"{self.session_id}: expected windows [window,{channels},{window_samples}]"
            )
        if len(self.windows) != len(self.state_labels):
            raise ContractError(f"{self.session_id}: state-label count mismatch")
        if len(self.windows) < 2:
            raise ContractError(f"{self.session_id}: at least two windows are required")
        if not np.all(np.isfinite(self.windows)):
            raise ContractError(f"{self.session_id}: synthetic windows contain nonfinite values")
        if not np.all(np.isfinite(self.state_labels)):
            raise ContractError(f"{self.session_id}: synthetic labels contain nonfinite values")
        if self.mode is not None and self.mode not in MODES:
            raise ContractError(f"{self.session_id}: unknown synthetic mode {self.mode}")


@dataclass(frozen=True)
class PairSet:
    context: np.ndarray
    target: np.ndarray
    labels: np.ndarray
    session_ids: np.ndarray
    modes: np.ndarray
    pair_ids: np.ndarray

    def subset(self, session_ids: set[str]) -> "PairSet":
        indices = np.flatnonzero(np.isin(self.session_ids, sorted(session_ids)))
        return PairSet(
            context=self.context[indices],
            target=self.target[indices],
            labels=self.labels[indices],
            session_ids=self.session_ids[indices],
            modes=self.modes[indices],
            pair_ids=self.pair_ids[indices],
        )


@dataclass(frozen=True)
class Fold:
    fold_id: str
    train_sessions: tuple[str, ...]
    validation_sessions: tuple[str, ...]
    test_sessions: tuple[str, ...]


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read JSON contract {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"{path} must contain an object")
    return value


def load_contracts(config_path: Path, generator_path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    config = _read_json(config_path)
    generators = _read_json(generator_path)
    if config.get("schema_version") != CONFIG_SCHEMA:
        raise ContractError(f"expected config schema {CONFIG_SCHEMA}")
    if generators.get("schema_version") != GENERATOR_SCHEMA:
        raise ContractError(f"expected generator schema {GENERATOR_SCHEMA}")
    if config.get("experiment_id") != EXPERIMENT_ID:
        raise ContractError(f"synthetic config must use {EXPERIMENT_ID}")
    if generators.get("experiment_id") != EXPERIMENT_ID:
        raise ContractError(f"generator contract must use {EXPERIMENT_ID}")
    if config.get("mode_experiment_id") != MODE_EXPERIMENT_ID:
        raise ContractError(f"mode extension must use {MODE_EXPERIMENT_ID}")
    source = config.get("source", {})
    if source.get("schema_version") != SOURCE_SCHEMA:
        raise ContractError(f"synthetic source must use {SOURCE_SCHEMA}")
    if source.get("source_type") != "deterministic_synthetic_fixture":
        raise ContractError("only deterministic_synthetic_fixture is admitted")
    if source.get("physical_capture_eligible") is not False:
        raise ContractError("synthetic fixtures must be physically ineligible")
    if source.get("fallback_capture_allowed") is not False:
        raise ContractError("fallback acquisition must remain prohibited")
    if tuple(config["training"]["conditions"]) != CONDITIONS:
        raise ContractError(f"conditions must be {list(CONDITIONS)}")
    if tuple(config["mode_extension"]["controls"]) != MODE_CONTROLS:
        raise ContractError(f"mode controls must be {list(MODE_CONTROLS)}")
    if tuple(config["mode_extension"]["modes"]) != MODES:
        raise ContractError(f"modes must be {list(MODES)}")
    if config.get("device") != "cpu":
        raise ContractError("v0 pins CPU execution for deterministic rehearsal")
    if generators["fallback_acquisition_stream"].get("accepted") is not False:
        raise ContractError("generator contract must reject fallback acquisition")
    registered = {entry["id"] for entry in generators.get("generators", [])}
    if registered != set(config["data"]["generator_ids"]):
        raise ContractError("config and generator registry disagree")
    return config, generators


def _seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.use_deterministic_algorithms(True)
    torch.set_num_threads(1)


def _mixing_matrix(rng: np.random.Generator, channels: int, latent_dim: int) -> np.ndarray:
    matrix = rng.normal(size=(channels, latent_dim))
    q, _ = np.linalg.qr(matrix)
    return q[:, :latent_dim].astype(np.float32)


def _session_hash(session: SyntheticSession) -> str:
    digest = hashlib.sha256()
    digest.update(session.session_id.encode("ascii"))
    digest.update(session.generator_id.encode("ascii"))
    digest.update((session.mode or "").encode("ascii"))
    digest.update(np.ascontiguousarray(session.windows).tobytes())
    digest.update(np.ascontiguousarray(session.state_labels).tobytes())
    digest.update(json.dumps(session.nuisance, sort_keys=True, separators=(",", ":")).encode("ascii"))
    digest.update((session.missing_channel_provenance or "").encode("ascii"))
    return digest.hexdigest()


def _window_time(window_index: int, window_samples: int, sample_rate: int) -> np.ndarray:
    start = window_index * window_samples
    return (start + np.arange(window_samples, dtype=np.float64)) / sample_rate


def _generate_base_session(
    generator_id: str,
    session_index: int,
    *,
    windows_per_session: int,
    channels: int,
    window_samples: int,
    sample_rate: int,
    seed: int,
) -> SyntheticSession:
    rng = np.random.default_rng(seed + 1009 * session_index)
    session_id = f"synthetic:{generator_id}:session-{session_index:02d}"
    values = np.zeros((windows_per_session, channels, window_samples), dtype=np.float32)
    labels = np.zeros(windows_per_session, dtype=np.int64)
    nuisance: dict[str, Any] = {
        "seed": seed + 1009 * session_index,
        "mixing_family": session_index % 4,
        "noise_family": session_index % 3,
    }
    missing: str | None = None

    if generator_id == "S0":
        # S0 registers a globally known rank-two observation process. Session
        # phases and noise vary, but the mixing basis is fixed by the generator
        # seed so pooling complete sessions cannot manufacture extra rank.
        mixing = _mixing_matrix(np.random.default_rng(seed), channels, 2)
        phase = rng.uniform(-math.pi, math.pi, size=2)
        frequencies = np.asarray([4.3, 7.1])
        for index in range(windows_per_session):
            t = _window_time(index, window_samples, sample_rate)
            latent = np.vstack(
                [np.sin(2 * np.pi * frequencies[k] * t + phase[k]) for k in range(2)]
            )
            values[index] = mixing @ latent + rng.normal(
                scale=0.015, size=(channels, window_samples)
            )
            labels[index] = int(np.sin(2 * np.pi * 0.17 * index + phase[0]) > 0)
        nuisance["latent_rank"] = 2
    elif generator_id == "S1":
        values[:] = rng.normal(size=values.shape)
        labels[:] = rng.integers(0, 2, size=windows_per_session)
        nuisance["latent_rank"] = 4
    elif generator_id == "S2":
        mixing = _mixing_matrix(rng, channels, 2)
        common_vector = np.ones((channels, 1), dtype=np.float64)
        for index in range(windows_per_session):
            t = _window_time(index, window_samples, sample_rate)
            latent = np.vstack(
                [
                    np.sin(2 * np.pi * 5.2 * t),
                    0.6 * np.cos(2 * np.pi * 8.4 * t + 0.2 * session_index),
                ]
            )
            signal = 0.25 * (mixing @ latent)
            center = (13 * index + 7 * session_index) % window_samples
            sample_axis = np.arange(window_samples)
            transient = 10.0 * np.exp(-0.5 * ((sample_axis - center) / 2.2) ** 2)
            values[index] = signal + common_vector @ transient[None, :] + rng.normal(
                scale=0.03, size=(channels, window_samples)
            )
            labels[index] = index % 2
        nuisance["artifact_probability"] = 1.0
    elif generator_id == "S3":
        signature_frequency = 2.2 + 0.8 * session_index
        offsets = rng.normal(scale=4.0, size=(channels, 1))
        signature_amplitude = rng.uniform(2.0, 4.0, size=(channels, 1))
        for index in range(windows_per_session):
            local_t = np.arange(window_samples, dtype=np.float64) / sample_rate
            signature = signature_amplitude * np.sin(
                2 * np.pi * signature_frequency * local_t[None, :]
                + np.arange(channels)[:, None] * 0.3
            )
            values[index] = offsets + signature + rng.normal(
                scale=0.25, size=(channels, window_samples)
            )
            labels[index] = rng.integers(0, 2)
        nuisance["session_offset_norm"] = float(np.linalg.norm(offsets))
    elif generator_id == "S4":
        for index in range(windows_per_session):
            local_t = np.arange(window_samples, dtype=np.float64) / sample_rate
            base = np.vstack(
                [
                    np.sin(2 * np.pi * (3.1 + channel) * local_t + 0.1 * index)
                    for channel in range(channels)
                ]
            )
            values[index] = base + rng.normal(scale=0.01, size=base.shape)
            labels[index] = index % 2
        pattern = session_index % 3
        if pattern == 0:
            values[:, 3, :] = values[:, 2, :]
            missing = "TP10_copied_from_AF8"
        elif pattern == 1:
            values[:, 3, :] = 0.0
            missing = "TP10_flat_zero"
        else:
            values[:, 1, :] = values[:, 0, :]
            missing = "AF7_copied_from_TP9"
        nuisance["missing_channel_pattern"] = missing
    elif generator_id == "S5":
        mixing = _mixing_matrix(rng, channels, 2)
        state = int(session_index % 2)
        for index in range(windows_per_session):
            if rng.random() > 0.86:
                state = 1 - state
            local_t = np.arange(window_samples, dtype=np.float64) / sample_rate
            frequency = 4.0 if state == 0 else 9.0
            latent = np.vstack(
                [
                    np.sin(2 * np.pi * frequency * local_t + 0.15 * index),
                    (2 * state - 1) * np.cos(2 * np.pi * 2.5 * local_t),
                ]
            )
            values[index] = mixing @ latent + rng.normal(
                scale=0.05, size=(channels, window_samples)
            )
            labels[index] = state
        nuisance["state_stay_probability"] = 0.86
    elif generator_id == "S6":
        mixing = _mixing_matrix(rng, channels, 2)
        latent_state = rng.normal(scale=0.05)
        for index in range(windows_per_session):
            latent_state = 0.97 * latent_state + rng.normal(scale=0.015)
            local_t = np.arange(window_samples, dtype=np.float64) / sample_rate
            common = np.sin(2 * np.pi * 5.5 * local_t)
            weak = latent_state * np.cos(2 * np.pi * 1.7 * local_t + 0.2 * index)
            latent = np.vstack([common, weak])
            values[index] = mixing @ latent + rng.normal(
                scale=0.002, size=(channels, window_samples)
            )
            labels[index] = int(latent_state > 0)
        nuisance["collapse_trap_signal_scale"] = 0.015
    else:
        raise ContractError(f"unknown generator {generator_id}")

    session = SyntheticSession(
        session_id=session_id,
        generator_id=generator_id,
        windows=values,
        state_labels=labels,
        mode=None,
        nuisance=nuisance,
        missing_channel_provenance=missing,
    )
    session.validate(channels=channels, window_samples=window_samples)
    return session


def generate_base_sessions(config: dict[str, Any]) -> dict[str, list[SyntheticSession]]:
    data = config["data"]
    output: dict[str, list[SyntheticSession]] = {}
    for generator_position, generator_id in enumerate(data["generator_ids"]):
        generator_seed = int(config["seed"]) + 10_000 * generator_position
        output[generator_id] = [
            _generate_base_session(
                generator_id,
                session_index,
                windows_per_session=int(data["windows_per_session"]),
                channels=int(data["channel_count"]),
                window_samples=int(data["window_samples"]),
                sample_rate=int(data["sample_rate_hz"]),
                seed=generator_seed,
            )
            for session_index in range(int(data["sessions_per_generator"]))
        ]
    return output


def _mode_dynamics(mode: str, history: list[float], rng: np.random.Generator, index: int) -> float:
    previous = history[-1] if history else rng.normal(scale=0.2)
    if mode == "mirror":
        return 0.55 * previous + 0.45 * math.sin(0.55 * index) + rng.normal(scale=0.08)
    if mode == "focus":
        return 0.96 * previous + rng.normal(scale=0.035)
    if mode == "reflective":
        delayed = history[-3] if len(history) >= 3 else previous
        return 0.25 * previous + 0.68 * delayed + rng.normal(scale=0.05)
    if mode == "contemplative":
        return 0.985 * previous + 0.08 * math.sin(0.12 * index) + rng.normal(scale=0.02)
    raise ContractError(f"unknown mode {mode}")


def generate_mode_sessions(config: dict[str, Any]) -> list[SyntheticSession]:
    data = config["data"]
    mode_config = config["mode_extension"]
    sessions: list[SyntheticSession] = []
    nuisance_grid = [
        {"latent_rank": 2, "noise_strength": 0.03, "frequency": 4.1, "artifact_probability": 0.00},
        {"latent_rank": 3, "noise_strength": 0.07, "frequency": 6.3, "artifact_probability": 0.08},
        {"latent_rank": 2, "noise_strength": 0.12, "frequency": 8.2, "artifact_probability": 0.03},
        {"latent_rank": 3, "noise_strength": 0.05, "frequency": 5.4, "artifact_probability": 0.12},
    ]
    for mode_index, mode in enumerate(mode_config["modes"]):
        for session_index in range(int(mode_config["sessions_per_mode"])):
            seed = int(config["seed"]) + 200_000 + mode_index * 10_000 + session_index
            rng = np.random.default_rng(seed)
            nuisance = dict(nuisance_grid[session_index % len(nuisance_grid)])
            nuisance.update(
                {
                    "seed": seed,
                    "mixing_family": session_index,
                    "session_offset": float(rng.normal(scale=0.15)),
                    "missing_channel_pattern": "none",
                }
            )
            mixing = _mixing_matrix(
                rng,
                int(data["channel_count"]),
                int(nuisance["latent_rank"]),
            )
            windows = np.zeros(
                (
                    int(data["windows_per_session"]),
                    int(data["channel_count"]),
                    int(data["window_samples"]),
                ),
                dtype=np.float32,
            )
            labels = np.zeros(int(data["windows_per_session"]), dtype=np.int64)
            history: list[float] = []
            for window_index in range(int(data["windows_per_session"])):
                state = _mode_dynamics(mode, history, rng, window_index)
                history.append(state)
                local_t = np.arange(int(data["window_samples"])) / int(data["sample_rate_hz"])
                latent_rows = [
                    state * np.sin(2 * np.pi * nuisance["frequency"] * local_t + 0.1 * window_index),
                    np.cos(2 * np.pi * (2.0 + 0.2 * session_index) * local_t + state),
                ]
                if int(nuisance["latent_rank"]) == 3:
                    latent_rows.append(0.5 * np.sin(2 * np.pi * 10.0 * local_t + 0.3 * state))
                latent = np.vstack(latent_rows)
                signal = mixing @ latent + nuisance["session_offset"]
                signal += rng.normal(scale=nuisance["noise_strength"], size=signal.shape)
                if rng.random() < nuisance["artifact_probability"]:
                    center = rng.integers(4, int(data["window_samples"]) - 4)
                    pulse = 2.0 * np.exp(
                        -0.5
                        * (
                            (np.arange(int(data["window_samples"])) - center)
                            / 1.5
                        )
                        ** 2
                    )
                    signal += pulse
                windows[window_index] = signal
                labels[window_index] = int(state > 0)
            session = SyntheticSession(
                session_id=f"synthetic:MODE:{mode}:session-{session_index:02d}",
                generator_id="MODE",
                windows=windows,
                state_labels=labels,
                mode=mode,
                nuisance=nuisance,
            )
            session.validate(
                channels=int(data["channel_count"]),
                window_samples=int(data["window_samples"]),
            )
            sessions.append(session)
    return sessions


def make_pairs(sessions: Sequence[SyntheticSession]) -> PairSet:
    contexts: list[np.ndarray] = []
    targets: list[np.ndarray] = []
    labels: list[int] = []
    session_ids: list[str] = []
    modes: list[str] = []
    pair_ids: list[str] = []
    for session in sessions:
        for index in range(len(session.windows) - 1):
            contexts.append(session.windows[index])
            targets.append(session.windows[index + 1])
            labels.append(int(session.state_labels[index + 1]))
            session_ids.append(session.session_id)
            modes.append(session.mode or "")
            pair_ids.append(f"{session.session_id}:pair-{index:03d}")
    return PairSet(
        context=np.asarray(contexts, dtype=np.float32),
        target=np.asarray(targets, dtype=np.float32),
        labels=np.asarray(labels, dtype=np.int64),
        session_ids=np.asarray(session_ids, dtype="U96"),
        modes=np.asarray(modes, dtype="U24"),
        pair_ids=np.asarray(pair_ids, dtype="U128"),
    )


def grouped_folds(session_ids: Sequence[str], config: dict[str, Any]) -> list[Fold]:
    ordered = tuple(sorted(set(session_ids)))
    test_count = int(config["split"]["outer_test_sessions"])
    validation_count = int(config["split"]["inner_validation_sessions"])
    fold_count = int(config["split"]["outer_fold_count"])
    if len(ordered) < test_count + validation_count + 1:
        raise ContractError("not enough complete synthetic sessions for grouped folds")
    folds: list[Fold] = []
    for fold_index in range(fold_count):
        rotated = ordered[fold_index * test_count :] + ordered[: fold_index * test_count]
        test = rotated[:test_count]
        validation = rotated[test_count : test_count + validation_count]
        train = tuple(value for value in ordered if value not in set(test + validation))
        folds.append(
            Fold(
                fold_id=f"fold-{fold_index}",
                train_sessions=train,
                validation_sessions=validation,
                test_sessions=test,
            )
        )
    return folds


def mode_grouped_fold(sessions: Sequence[SyntheticSession]) -> Fold:
    grouped = {mode: sorted(s.session_id for s in sessions if s.mode == mode) for mode in MODES}
    if any(len(values) < 4 for values in grouped.values()):
        raise ContractError("mode rehearsal requires at least four complete sessions per mode")
    train = tuple(value for mode in MODES for value in grouped[mode][:2])
    validation = tuple(grouped[mode][2] for mode in MODES)
    test = tuple(grouped[mode][3] for mode in MODES)
    return Fold("mode-grouped", train, validation, test)


def leave_one_mode_out_folds(sessions: Sequence[SyntheticSession]) -> list[Fold]:
    folds: list[Fold] = []
    for held_out in MODES:
        test = tuple(sorted(s.session_id for s in sessions if s.mode == held_out))
        remaining = {mode: sorted(s.session_id for s in sessions if s.mode == mode) for mode in MODES if mode != held_out}
        validation = tuple(values[-1] for values in remaining.values())
        train = tuple(value for values in remaining.values() for value in values[:-1])
        folds.append(Fold(f"leave-{held_out}-out", train, validation, test))
    return folds


def fit_normalization(train: PairSet) -> tuple[np.ndarray, np.ndarray]:
    joined = np.concatenate([train.context, train.target], axis=0)
    mean = joined.mean(axis=(0, 2), keepdims=True).astype(np.float32)
    std = joined.std(axis=(0, 2), keepdims=True).astype(np.float32)
    return mean, np.maximum(std, 1e-6)


def normalize_pairs(pairs: PairSet, mean: np.ndarray, std: np.ndarray) -> PairSet:
    return PairSet(
        context=((pairs.context - mean) / std).astype(np.float32),
        target=((pairs.target - mean) / std).astype(np.float32),
        labels=pairs.labels.copy(),
        session_ids=pairs.session_ids.copy(),
        modes=pairs.modes.copy(),
        pair_ids=pairs.pair_ids.copy(),
    )


def _mask_for_indices(
    pair_indices: np.ndarray,
    *,
    window_samples: int,
    fraction: float,
    seed: int,
    offset: int = 0,
) -> np.ndarray:
    span = max(1, int(round(window_samples * fraction)))
    mask = np.zeros((len(pair_indices), 1, window_samples), dtype=bool)
    available = window_samples - span + 1
    for row, pair_index in enumerate(pair_indices.tolist()):
        start = (seed * 131 + int(pair_index) * 17 + offset * 29) % available
        mask[row, 0, start : start + span] = True
    return mask


def _mode_one_hot(modes: Sequence[str]) -> np.ndarray:
    output = np.zeros((len(modes), len(MODES)), dtype=np.float32)
    for index, mode in enumerate(modes):
        if mode:
            output[index, MODES.index(str(mode))] = 1.0
    return output


def mode_context(modes: np.ndarray, policy: str, seed: int) -> np.ndarray:
    correct = _mode_one_hot(modes)
    if policy in {"C0", "C5", "C4"}:
        return np.zeros_like(correct)
    if policy == "C1":
        return correct
    if policy == "C2":
        rng = np.random.default_rng(seed)
        shuffled = correct.copy()
        rng.shuffle(shuffled, axis=0)
        return shuffled
    if policy == "C3":
        output = np.zeros_like(correct)
        output[:, 0] = 1.0
        return output
    raise ContractError(f"unknown mode-context policy {policy}")


class SyntheticJEPA(nn.Module):
    """One fixed-capacity model instantiated for every synthetic condition."""

    def __init__(
        self,
        channels: int,
        window_samples: int,
        encoder_hidden_dim: int,
        latent_dim: int,
        predictor_hidden_dim: int,
        mode_context_dim: int,
    ):
        super().__init__()
        self.channels = channels
        self.window_samples = window_samples
        self.encoder = nn.Sequential(
            nn.Conv1d(channels, encoder_hidden_dim, kernel_size=7, padding=3),
            nn.GELU(),
            nn.Conv1d(encoder_hidden_dim, encoder_hidden_dim, kernel_size=5, stride=2, padding=2),
            nn.GELU(),
            nn.Flatten(),
            nn.Linear(
                encoder_hidden_dim * math.ceil(window_samples / 2),
                encoder_hidden_dim,
            ),
            nn.GELU(),
        )
        self.projector = nn.Linear(encoder_hidden_dim, latent_dim)
        self.predictor = nn.Sequential(
            nn.Linear(latent_dim + mode_context_dim, predictor_hidden_dim),
            nn.GELU(),
            nn.Linear(predictor_hidden_dim, latent_dim),
        )
        self.decoder = nn.Linear(latent_dim, channels * window_samples)
        self.target_encoder = copy.deepcopy(self.encoder)
        self.target_projector = copy.deepcopy(self.projector)
        for parameter in list(self.target_encoder.parameters()) + list(self.target_projector.parameters()):
            parameter.requires_grad = False
        self.target_encoder.eval()
        self.target_projector.eval()

    def encode(self, window: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        encoder_embedding = self.encoder(window)
        return encoder_embedding, self.projector(encoder_embedding)

    @torch.no_grad()
    def target(self, window: torch.Tensor) -> torch.Tensor:
        return self.target_projector(self.target_encoder(window))

    def predict(self, latent: torch.Tensor, mode: torch.Tensor) -> torch.Tensor:
        return self.predictor(torch.cat([latent, mode], dim=1))

    def reconstruct(self, latent: torch.Tensor) -> torch.Tensor:
        return self.decoder(latent).reshape(-1, self.channels, self.window_samples)

    @torch.no_grad()
    def update_target(self, tau: float) -> None:
        online_modules = (self.encoder, self.projector)
        target_modules = (self.target_encoder, self.target_projector)
        for online_module, target_module in zip(online_modules, target_modules, strict=True):
            for target, online in zip(target_module.parameters(), online_module.parameters(), strict=True):
                target.mul_(tau).add_(online, alpha=1.0 - tau)
            for target, online in zip(target_module.buffers(), online_module.buffers(), strict=True):
                target.copy_(online)


def build_model(config: dict[str, Any]) -> SyntheticJEPA:
    model_config = config["model"]
    data = config["data"]
    return SyntheticJEPA(
        channels=int(data["channel_count"]),
        window_samples=int(data["window_samples"]),
        encoder_hidden_dim=int(model_config["encoder_hidden_dim"]),
        latent_dim=int(model_config["latent_dim"]),
        predictor_hidden_dim=int(model_config["predictor_hidden_dim"]),
        mode_context_dim=int(model_config["mode_context_dim"]),
    )


def sigreg_loss(embedding: torch.Tensor) -> torch.Tensor:
    """Spectral anti-collapse pressure on the registered projector tensor."""
    if embedding.ndim != 2 or embedding.shape[0] < 2:
        raise ValueError("SIGReg requires a two-dimensional batch with at least two rows")
    centered = embedding - embedding.mean(dim=0, keepdim=True)
    singular_values = torch.linalg.svdvals(centered / math.sqrt(embedding.shape[0] - 1))
    return torch.mean((singular_values - 1.0) ** 2) + torch.mean(embedding.mean(dim=0) ** 2)


def vicreg_terms(embedding: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    if embedding.ndim != 2 or embedding.shape[0] < 2:
        raise ValueError("VICReg requires a two-dimensional batch with at least two rows")
    centered = embedding - embedding.mean(dim=0, keepdim=True)
    std = torch.sqrt(embedding.var(dim=0, unbiased=False) + 1e-4)
    variance = torch.mean(F.relu(1.0 - std))
    covariance = centered.T @ centered / (embedding.shape[0] - 1)
    off_diagonal = covariance - torch.diag(torch.diag(covariance))
    covariance_loss = off_diagonal.pow(2).sum() / embedding.shape[1]
    return variance, covariance_loss


def _masked_reconstruction_loss(
    reconstruction: torch.Tensor,
    original: torch.Tensor,
    mask: torch.Tensor,
) -> torch.Tensor:
    expanded = mask.expand_as(original)
    return F.mse_loss(reconstruction[expanded], original[expanded])


def _training_batches(length: int, steps: int, batch_size: int, seed: int) -> list[np.ndarray]:
    if length < 2:
        raise ContractError("training partition requires at least two pairs")
    rng = np.random.default_rng(seed)
    return [
        rng.choice(length, size=batch_size, replace=length < batch_size)
        for _ in range(steps)
    ]


def train_condition(
    condition: str,
    train: PairSet,
    config: dict[str, Any],
    *,
    seed: int,
    mode_policy: str = "C0",
) -> tuple[SyntheticJEPA, dict[str, Any]]:
    if condition not in CONDITIONS:
        raise ContractError(f"unknown condition {condition}")
    _seed_everything(seed)
    model = build_model(config)
    parameter_count = sum(parameter.numel() for parameter in model.parameters())
    trainable_parameter_count = sum(
        parameter.numel() for parameter in model.parameters() if parameter.requires_grad
    )
    if condition == "T0":
        return model, {
            "steps_completed": 0,
            "parameter_count": parameter_count,
            "trainable_parameter_count": trainable_parameter_count,
            "batch_schedule_sha256": None,
            "mask_schedule_sha256": None,
            "last_losses": {},
        }

    training = config["training"]
    optimizer = torch.optim.AdamW(
        [parameter for parameter in model.parameters() if parameter.requires_grad],
        lr=float(training["learning_rate"]),
        weight_decay=float(training["weight_decay"]),
    )
    batches = _training_batches(
        len(train.context),
        int(training["steps"]),
        int(training["batch_size"]),
        seed,
    )
    fraction = float(config["mask"]["fraction"])
    batch_schedule_sha256 = sha256_json(
        [[int(value) for value in batch] for batch in batches]
    )
    mask_digest = hashlib.sha256()
    for indices in batches:
        mask_digest.update(
            _mask_for_indices(
                indices,
                window_samples=int(config["data"]["window_samples"]),
                fraction=fraction,
                seed=seed,
            ).tobytes()
        )
    loss_config = config["loss"][condition]
    last_losses: dict[str, float] = {}
    model.train()
    model.target_encoder.eval()
    model.target_projector.eval()

    for step, indices in enumerate(batches):
        context = torch.from_numpy(train.context[indices])
        target = torch.from_numpy(train.target[indices])
        mask_np = _mask_for_indices(
            indices,
            window_samples=context.shape[2],
            fraction=fraction,
            seed=seed,
        )
        mask = torch.from_numpy(mask_np)
        masked_context = context.masked_fill(mask.expand_as(context), 0.0)
        mode = torch.from_numpy(mode_context(train.modes[indices], mode_policy, seed + step))

        encoder_embedding, projector_embedding = model.encode(masked_context)
        prediction = model.predict(projector_embedding, mode)
        target_embedding = model.target(target)
        reconstruction = model.reconstruct(projector_embedding)

        prediction_loss = F.mse_loss(prediction, target_embedding)
        reconstruction_loss = _masked_reconstruction_loss(reconstruction, context, mask)
        zero = projector_embedding.sum() * 0.0
        regularization_loss = zero
        bounded_reconstruction = zero

        if condition == "T1":
            total = reconstruction_loss
        elif condition == "T2":
            total = prediction_loss
        elif condition == "T3":
            regularization_loss = sigreg_loss(projector_embedding)
            total = prediction_loss + float(loss_config["sigreg_weight"]) * regularization_loss
        elif condition == "T4":
            variance_loss, covariance_loss = vicreg_terms(projector_embedding)
            regularization_loss = (
                float(loss_config["vicreg_variance_weight"]) * variance_loss
                + float(loss_config["vicreg_covariance_weight"]) * covariance_loss
            )
            total = prediction_loss + regularization_loss
        elif condition == "T5":
            weighted = float(loss_config["reconstruction_weight"]) * reconstruction_loss
            cap = (
                float(loss_config["maximum_reconstruction_fraction"])
                * prediction_loss.detach().clamp_min(1e-6)
            )
            bounded_reconstruction = torch.minimum(weighted, cap)
            total = prediction_loss + bounded_reconstruction
        else:
            raise AssertionError(condition)

        if not torch.isfinite(total):
            raise ContractError(f"{condition}: nonfinite training loss at step {step}")
        optimizer.zero_grad(set_to_none=True)
        total.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), float(training["gradient_clip_norm"]))
        optimizer.step()
        model.update_target(float(training["ema_tau"]))
        last_losses = {
            "total": float(total.detach()),
            "prediction": float(prediction_loss.detach()),
            "reconstruction": float(reconstruction_loss.detach()),
            "regularization": float(regularization_loss.detach()),
            "bounded_reconstruction": float(bounded_reconstruction.detach()),
        }

    return model, {
        "steps_completed": len(batches),
        "parameter_count": parameter_count,
        "trainable_parameter_count": trainable_parameter_count,
        "batch_schedule_sha256": batch_schedule_sha256,
        "mask_schedule_sha256": mask_digest.hexdigest(),
        "last_losses": last_losses,
    }


def _checkpoint_content_sha256(model: nn.Module) -> str:
    digest = hashlib.sha256()
    for name, tensor in sorted(model.state_dict().items()):
        array = tensor.detach().cpu().contiguous().numpy()
        digest.update(name.encode("utf-8"))
        digest.update(str(array.dtype).encode("ascii"))
        digest.update(json.dumps(list(array.shape), separators=(",", ":")).encode("ascii"))
        digest.update(array.tobytes())
    return digest.hexdigest()


def save_checkpoint(model: nn.Module, path: Path, metadata: dict[str, Any]) -> dict[str, str]:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "state_dict": model.state_dict(),
        "metadata": metadata,
    }
    torch.save(payload, path)
    return {
        "checkpoint_sha256": sha256_file(path),
        "checkpoint_content_sha256": _checkpoint_content_sha256(model),
    }


def _pairwise_mean(values: np.ndarray, limit: int) -> float:
    selected = values[:limit]
    if len(selected) < 2:
        return 0.0
    differences = selected[:, None, :] - selected[None, :, :]
    distances = np.sqrt(np.sum(differences * differences, axis=2))
    upper = distances[np.triu_indices(len(selected), k=1)]
    return float(upper.mean()) if len(upper) else 0.0


def _nearest_neighbor_identity(values: np.ndarray, identities: np.ndarray) -> float | None:
    if len(values) < 2 or len(set(identities.tolist())) < 2:
        return None
    differences = values[:, None, :] - values[None, :, :]
    distances = np.sum(differences * differences, axis=2)
    np.fill_diagonal(distances, np.inf)
    nearest = np.argmin(distances, axis=1)
    return float(np.mean(identities[nearest] == identities))


def representation_diagnostics(
    values: np.ndarray,
    identities: np.ndarray,
    config: dict[str, Any],
    *,
    modes: np.ndarray | None = None,
) -> dict[str, Any]:
    if values.ndim != 2 or len(values) < 2:
        raise ContractError("diagnostics require a two-dimensional representation matrix")
    if not np.all(np.isfinite(values)):
        raise ContractError("diagnostics reject nonfinite representation values")
    settings = config["diagnostics"]
    centered = values.astype(np.float64) - values.mean(axis=0, keepdims=True)
    singular_values = np.linalg.svd(centered, full_matrices=False, compute_uv=False)
    energy = singular_values**2
    total_energy = float(energy.sum())
    probabilities = energy / total_energy if total_energy > 0 else np.zeros_like(energy)
    positive = probabilities[probabilities > 0]
    effective_rank = float(np.exp(-np.sum(positive * np.log(positive)))) if len(positive) else 0.0
    cumulative = np.cumsum(probabilities)
    energy_rank = (
        int(np.searchsorted(cumulative, float(settings["energy_rank_threshold"])) + 1)
        if total_energy > 0
        else 0
    )
    floor = float(settings["singular_value_floor"])
    retained = singular_values[singular_values > floor]
    condition_number = (
        float(retained[0] / retained[-1])
        if len(retained) == len(singular_values) and len(retained)
        else None
    )
    variances = values.var(axis=0)
    covariance = np.cov(values, rowvar=False, bias=True)
    covariance = np.atleast_2d(covariance)
    off_diagonal = covariance - np.diag(np.diag(covariance))
    max_deviation = float(np.max(np.abs(values - values[0])))
    result: dict[str, Any] = {
        "matrix_shape": list(values.shape),
        "dtype": str(values.dtype),
        "per_dimension_variance": [float(value) for value in variances],
        "covariance_off_diagonal_magnitude": float(np.mean(np.abs(off_diagonal))),
        "singular_value_spectrum": [float(value) for value in singular_values],
        "entropy_effective_rank": effective_rank,
        "energy_rank": energy_rank,
        "condition_number": condition_number,
        "rank_deficient": len(retained) < len(singular_values),
        "mean_pairwise_distance": _pairwise_mean(
            values,
            int(settings["pairwise_sample_limit"]),
        ),
        "nearest_neighbor_session_identity": _nearest_neighbor_identity(values, identities),
        "constant_output": max_deviation <= float(settings["constant_output_tolerance"]),
        "constant_output_max_deviation": max_deviation,
        "feature_utilization_count": int(np.sum(variances > float(settings["variance_floor"]))),
        "feature_utilization_fraction": float(
            np.mean(variances > float(settings["variance_floor"]))
        ),
    }
    if modes is not None and any(str(mode) for mode in modes):
        result["nearest_neighbor_mode_identity"] = _nearest_neighbor_identity(values, modes)
    return result


def raw_generator_diagnostics(
    sessions: Sequence[SyntheticSession],
    config: dict[str, Any],
) -> dict[str, Any]:
    windows = np.concatenate([session.windows for session in sessions], axis=0)
    channel_matrix = windows.transpose(0, 2, 1).reshape(-1, windows.shape[1]).astype(np.float64)
    centered = channel_matrix - channel_matrix.mean(axis=0, keepdims=True)
    singular_values = np.linalg.svd(centered, full_matrices=False, compute_uv=False)
    energy = singular_values**2
    probabilities = energy / energy.sum() if energy.sum() > 0 else np.zeros_like(energy)
    positive = probabilities[probabilities > 0]
    effective_rank = float(np.exp(-np.sum(positive * np.log(positive)))) if len(positive) else 0.0
    raw_features = windows.reshape(len(windows), -1)
    identities = np.concatenate(
        [np.repeat(session.session_id, len(session.windows)) for session in sessions]
    )
    missing = {
        session.session_id: session.missing_channel_provenance
        for session in sessions
        if session.missing_channel_provenance is not None
    }
    session_ranks = {}
    for session in sessions:
        matrix = session.windows.transpose(0, 2, 1).reshape(
            -1,
            session.windows.shape[1],
        )
        matrix = matrix - matrix.mean(axis=0, keepdims=True)
        session_ranks[session.session_id] = int(np.linalg.matrix_rank(matrix, tol=1e-7))
    return {
        "channel_singular_values": [float(value) for value in singular_values],
        "channel_matrix_rank": int(np.linalg.matrix_rank(centered, tol=1e-7)),
        "per_session_channel_matrix_rank": session_ranks,
        "maximum_session_channel_matrix_rank": max(session_ranks.values()),
        "entropy_effective_rank": effective_rank,
        "first_singular_energy": float(probabilities[0]) if len(probabilities) else 0.0,
        "nearest_neighbor_session_identity": _nearest_neighbor_identity(raw_features, identities),
        "missing_channel_provenance": missing,
    }


def _different_session_indices(session_ids: np.ndarray) -> np.ndarray:
    output = np.empty(len(session_ids), dtype=np.int64)
    for index, session_id in enumerate(session_ids):
        candidates = np.flatnonzero(session_ids != session_id)
        if not len(candidates):
            output[index] = index
        else:
            output[index] = candidates[index % len(candidates)]
    return output


def _probe_accuracy(
    train_values: np.ndarray,
    train_labels: np.ndarray,
    test_values: np.ndarray,
    test_labels: np.ndarray,
    config: dict[str, Any],
) -> float | None:
    if len(set(train_labels.tolist())) < 2 or len(test_labels) == 0:
        return None
    probe_config = config["probe"]
    probe = make_pipeline(
        StandardScaler(),
        LogisticRegression(
            C=float(probe_config["regularization_c"]),
            max_iter=int(probe_config["max_iterations"]),
            random_state=int(config["seed"]),
        ),
    )
    probe.fit(train_values, train_labels)
    return float(np.mean(probe.predict(test_values) == test_labels))


def evaluate_condition(
    model: SyntheticJEPA,
    train: PairSet,
    test: PairSet,
    config: dict[str, Any],
    *,
    seed: int,
    mode_policy: str = "C0",
    probe_mode_only: bool = False,
) -> dict[str, Any]:
    model.eval()
    fraction = float(config["mask"]["fraction"])

    def forward(pairs: PairSet, *, mask_offset: int = 0, channel_permutation: Sequence[int] | None = None) -> dict[str, np.ndarray]:
        indices = np.arange(len(pairs.context))
        context_np = pairs.context.copy()
        if channel_permutation is not None:
            context_np = context_np[:, list(channel_permutation), :]
        mask_np = _mask_for_indices(
            indices,
            window_samples=context_np.shape[2],
            fraction=fraction,
            seed=seed,
            offset=mask_offset,
        )
        context = torch.from_numpy(context_np)
        target = torch.from_numpy(pairs.target)
        mask = torch.from_numpy(mask_np)
        masked = context.masked_fill(mask.expand_as(context), 0.0)
        mode = torch.from_numpy(mode_context(pairs.modes, mode_policy, seed + mask_offset))
        with torch.no_grad():
            encoder_embedding, projector_embedding = model.encode(masked)
            predictor_output = model.predict(projector_embedding, mode)
            target_embedding = model.target(target)
        return {
            "encoder": encoder_embedding.numpy(),
            "projector": projector_embedding.numpy(),
            "predictor": predictor_output.numpy(),
            "target": target_embedding.numpy(),
        }

    train_outputs = forward(train)
    outputs = forward(test)
    permutation_rng = np.random.default_rng(seed + 91_337)
    permutation = permutation_rng.permutation(len(outputs["target"]))
    if len(permutation) > 1 and np.all(permutation == np.arange(len(permutation))):
        permutation = np.roll(permutation, 1)
    permuted_target = outputs["target"][permutation]
    different_target = outputs["target"][_different_session_indices(test.session_ids)]
    channel_order = forward(test, channel_permutation=(2, 0, 3, 1))
    coordinate_shuffle = forward(test, channel_permutation=(3, 2, 1, 0))
    mask_shuffle = forward(test, mask_offset=1)

    def mse(left: np.ndarray, right: np.ndarray) -> float:
        return float(np.mean((left - right) ** 2))

    probe_train = train_outputs["projector"]
    probe_test = outputs["projector"]
    if probe_mode_only:
        probe_train = np.concatenate([probe_train, _mode_one_hot(train.modes)], axis=1)
        probe_test = np.concatenate([probe_test, _mode_one_hot(test.modes)], axis=1)
    state_probe = _probe_accuracy(
        probe_train,
        train.labels,
        probe_test,
        test.labels,
        config,
    )
    mode_probe = None
    if any(str(mode) for mode in train.modes) and len(set(train.modes.tolist())) >= 2:
        train_mode_labels = np.asarray([MODES.index(str(mode)) for mode in train.modes])
        test_mode_labels = np.asarray([MODES.index(str(mode)) for mode in test.modes])
        mode_probe = _probe_accuracy(
            probe_train,
            train_mode_labels,
            probe_test,
            test_mode_labels,
            config,
        )

    diagnostics = {
        scope: representation_diagnostics(
            values,
            test.session_ids,
            config,
            modes=test.modes,
        )
        for scope, values in (
            ("encoder_embedding", outputs["encoder"]),
            ("projector_embedding", outputs["projector"]),
            ("predictor_output", outputs["predictor"]),
            ("stopped_gradient_target_embedding", outputs["target"]),
        )
    }
    per_mode = {}
    for mode in MODES:
        indices = np.flatnonzero(test.modes == mode)
        if len(indices) >= 2:
            per_mode[mode] = representation_diagnostics(
                outputs["projector"][indices],
                test.session_ids[indices],
                config,
                modes=test.modes[indices],
            )

    return {
        "control_losses": {
            "correct_target": mse(outputs["predictor"], outputs["target"]),
            "temporal_target_permutation": mse(outputs["predictor"], permuted_target),
            "different_sequence_target": mse(outputs["predictor"], different_target),
            "channel_order_shuffle": mse(channel_order["predictor"], outputs["target"]),
            "channel_coordinate_shuffle": mse(
                coordinate_shuffle["predictor"], outputs["target"]
            ),
            "mask_location_shuffle": mse(mask_shuffle["predictor"], outputs["target"]),
        },
        "state_probe_accuracy": state_probe,
        "mode_probe_accuracy": mode_probe,
        "diagnostics": diagnostics,
        "per_mode_diagnostics": per_mode,
    }


def _mean_metric(folds: Sequence[dict[str, Any]], *path: str) -> float:
    values: list[float] = []
    for fold in folds:
        current: Any = fold
        for key in path:
            current = current[key]
        if current is not None:
            values.append(float(current))
    return float(np.mean(values)) if values else float("nan")


def evaluate_expected_invariants(
    generator_contract: dict[str, Any],
    raw: dict[str, Any],
    condition_reports: dict[str, list[dict[str, Any]]],
) -> list[dict[str, Any]]:
    generator_id = generator_contract["id"]
    expected = generator_contract["expected_invariants"]
    checks: list[dict[str, Any]] = []

    def add(name: str, passed: bool, observed: Any, expected_value: Any) -> None:
        checks.append(
            {
                "id": name,
                "passed": bool(passed),
                "observed": observed,
                "expected": expected_value,
            }
        )

    if "raw_entropy_effective_rank_min" in expected:
        value = raw["entropy_effective_rank"]
        add(
            "raw_entropy_effective_rank_min",
            value >= expected["raw_entropy_effective_rank_min"],
            value,
            expected["raw_entropy_effective_rank_min"],
        )
    if "raw_entropy_effective_rank_max" in expected:
        value = raw["entropy_effective_rank"]
        add(
            "raw_entropy_effective_rank_max",
            value <= expected["raw_entropy_effective_rank_max"],
            value,
            expected["raw_entropy_effective_rank_max"],
        )
    if "first_singular_energy_min" in expected:
        value = raw["first_singular_energy"]
        add(
            "first_singular_energy_min",
            value >= expected["first_singular_energy_min"],
            value,
            expected["first_singular_energy_min"],
        )
    if "raw_nearest_neighbor_session_identity_min" in expected:
        value = raw["nearest_neighbor_session_identity"]
        add(
            "raw_nearest_neighbor_session_identity_min",
            value is not None
            and value >= expected["raw_nearest_neighbor_session_identity_min"],
            value,
            expected["raw_nearest_neighbor_session_identity_min"],
        )
    if "raw_matrix_rank_max" in expected:
        value = raw["maximum_session_channel_matrix_rank"]
        add(
            "raw_matrix_rank_max",
            value <= expected["raw_matrix_rank_max"],
            value,
            expected["raw_matrix_rank_max"],
        )
    if expected.get("missing_channel_provenance_required"):
        value = len(raw["missing_channel_provenance"])
        add("missing_channel_provenance_required", value > 0, value, "nonempty")

    if "correct_targets_should_beat_permutation" in expected:
        correct = _mean_metric(
            condition_reports["T3"], "evaluation", "control_losses", "correct_target"
        )
        permuted = _mean_metric(
            condition_reports["T3"],
            "evaluation",
            "control_losses",
            "temporal_target_permutation",
        )
        should_beat = bool(expected["correct_targets_should_beat_permutation"])
        ratio = correct / permuted if permuted > 0 else float("inf")
        if should_beat:
            threshold = float(expected["correct_to_permuted_ratio_max"])
            passed = ratio <= threshold
            expectation = {"maximum_ratio": threshold}
        else:
            threshold = float(expected["correct_to_permuted_ratio_min"])
            passed = ratio >= threshold
            expectation = {"minimum_ratio": threshold}
        add(
            "correct_targets_should_beat_permutation",
            passed,
            {"correct_to_permuted_ratio": ratio},
            expectation,
        )
    if expected.get("state_probe_above_chance_expected"):
        accuracy = _mean_metric(
            condition_reports["T3"], "evaluation", "state_probe_accuracy"
        )
        threshold = float(expected["state_probe_accuracy_min"])
        add(
            "state_probe_above_chance_expected",
            accuracy >= threshold,
            accuracy,
            {"minimum_accuracy": threshold},
        )
    if expected.get("T2_collapse_expected"):
        t2_rank = _mean_metric(
            condition_reports["T2"],
            "evaluation",
            "diagnostics",
            "projector_embedding",
            "entropy_effective_rank",
        )
        t3_rank = _mean_metric(
            condition_reports["T3"],
            "evaluation",
            "diagnostics",
            "projector_embedding",
            "entropy_effective_rank",
        )
        t4_rank = _mean_metric(
            condition_reports["T4"],
            "evaluation",
            "diagnostics",
            "projector_embedding",
            "entropy_effective_rank",
        )
        collapse_threshold = float(expected["T2_effective_rank_max"])
        gain = float(expected["anti_collapse_effective_rank_gain_min"])
        add(
            "T2_collapse_expected",
            t2_rank <= collapse_threshold,
            t2_rank,
            {"maximum_effective_rank": collapse_threshold},
        )
        add(
            "T3_or_T4_should_reduce_collapse",
            max(t3_rank, t4_rank) >= t2_rank + gain,
            {"T2": t2_rank, "T3": t3_rank, "T4": t4_rank},
            {"minimum_effective_rank_gain": gain},
        )
    return checks


def diagnostic_self_tests(config: dict[str, Any]) -> dict[str, Any]:
    latent_dim = int(config["model"]["latent_dim"])
    constant = np.ones((12, latent_dim), dtype=np.float32)
    identities = np.asarray(
        ["synthetic:self-test:a"] * 6 + ["synthetic:self-test:b"] * 6,
        dtype="U32",
    )
    constant_report = representation_diagnostics(
        constant,
        identities,
        config,
    )
    nonfinite = constant.copy()
    nonfinite[0, 0] = np.nan
    try:
        representation_diagnostics(nonfinite, identities, config)
    except ContractError:
        nonfinite_rejected = True
    else:
        nonfinite_rejected = False
    return {
        "constant_embedding": {
            "passed": bool(
                constant_report["constant_output"]
                and constant_report["entropy_effective_rank"] == 0.0
                and constant_report["feature_utilization_count"] == 0
            ),
            "diagnostics": constant_report,
        },
        "nonfinite_embedding_rejection": {
            "passed": nonfinite_rejected,
        },
    }


def _source_manifest(
    base_sessions: dict[str, list[SyntheticSession]],
    mode_sessions: Sequence[SyntheticSession],
    config: dict[str, Any],
    *,
    config_sha256: str,
    generator_sha256: str,
) -> dict[str, Any]:
    all_sessions = [
        session
        for sessions in base_sessions.values()
        for session in sessions
    ] + list(mode_sessions)
    manifest = {
        "schema_version": SOURCE_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "source_type": "deterministic_synthetic_fixture",
        "device_id": "synthetic-generator",
        "participant_id": None,
        "physical_capture_eligible": False,
        "fallback_capture_used": False,
        "config_sha256": config_sha256,
        "generator_contract_sha256": generator_sha256,
        "seed": int(config["seed"]),
        "sessions": [
            {
                "session_id": session.session_id,
                "generator_id": session.generator_id,
                "mode": session.mode,
                "window_count": len(session.windows),
                "window_shape": list(session.windows.shape[1:]),
                "content_sha256": _session_hash(session),
                "nuisance": session.nuisance,
                "missing_channel_provenance": session.missing_channel_provenance,
                "physical_capture_eligible": False,
            }
            for session in all_sessions
        ],
    }
    manifest["manifest_sha256"] = sha256_json(manifest)
    return manifest


def _condition_fold_report(
    generator_id: str,
    condition: str,
    fold: Fold,
    pairs: PairSet,
    config: dict[str, Any],
    output_dir: Path,
    *,
    seed: int,
    mode_policy: str = "C0",
    probe_mode_only: bool = False,
) -> dict[str, Any]:
    train_raw = pairs.subset(set(fold.train_sessions))
    validation_raw = pairs.subset(set(fold.validation_sessions))
    test_raw = pairs.subset(set(fold.test_sessions))
    if set(train_raw.session_ids) & set(test_raw.session_ids):
        raise ContractError("grouped split leaked a session")
    mean, std = fit_normalization(train_raw)
    train = normalize_pairs(train_raw, mean, std)
    validation = normalize_pairs(validation_raw, mean, std)
    test = normalize_pairs(test_raw, mean, std)
    model, training_report = train_condition(
        condition,
        train,
        config,
        seed=seed,
        mode_policy=mode_policy,
    )
    evaluation = evaluate_condition(
        model,
        train,
        test,
        config,
        seed=seed,
        mode_policy=mode_policy,
        probe_mode_only=probe_mode_only,
    )
    checkpoint_path = (
        output_dir
        / "checkpoints"
        / generator_id
        / condition
        / f"{fold.fold_id}.pt"
    )
    checkpoint = save_checkpoint(
        model,
        checkpoint_path,
        {
            "experiment_id": EXPERIMENT_ID,
            "generator_id": generator_id,
            "condition": condition,
            "fold_id": fold.fold_id,
            "seed": seed,
            "physical_eeg_used": False,
            "promotion_status": "not_eligible",
        },
    )
    return {
        "fold_id": fold.fold_id,
        "train_sessions": list(fold.train_sessions),
        "validation_sessions": list(fold.validation_sessions),
        "test_sessions": list(fold.test_sessions),
        "train_pair_count": len(train.context),
        "validation_pair_count": len(validation.context),
        "test_pair_count": len(test.context),
        "normalization": {
            "fit_scope": "training_sessions_only",
            "mean": mean.reshape(-1).tolist(),
            "std": std.reshape(-1).tolist(),
        },
        "training_window_digest": sha256_json(train_raw.pair_ids.tolist()),
        "training": training_report,
        "evaluation": evaluation,
        **checkpoint,
    }


def run_base_rehearsal(
    base_sessions: dict[str, list[SyntheticSession]],
    generator_contract: dict[str, Any],
    config: dict[str, Any],
    output_dir: Path,
) -> dict[str, Any]:
    registered = {entry["id"]: entry for entry in generator_contract["generators"]}
    generators_report: dict[str, Any] = {}
    parameter_counts: set[int] = set()
    for generator_position, generator_id in enumerate(config["data"]["generator_ids"]):
        sessions = base_sessions[generator_id]
        pairs = make_pairs(sessions)
        folds = grouped_folds(pairs.session_ids.tolist(), config)
        condition_reports: dict[str, list[dict[str, Any]]] = {}
        for condition in CONDITIONS:
            reports = []
            for fold_position, fold in enumerate(folds):
                seed = (
                    int(config["seed"])
                    + generator_position * 100_000
                    + fold_position * 1_000
                )
                report = _condition_fold_report(
                    generator_id,
                    condition,
                    fold,
                    pairs,
                    config,
                    output_dir,
                    seed=seed,
                )
                parameter_counts.add(report["training"]["parameter_count"])
                reports.append(report)
            condition_reports[condition] = reports
        matched_execution = []
        for fold_position, fold in enumerate(folds):
            trained = [
                condition_reports[condition][fold_position]
                for condition in ("T1", "T2", "T3", "T4", "T5")
            ]
            batch_hashes = {
                report["training"]["batch_schedule_sha256"] for report in trained
            }
            mask_hashes = {
                report["training"]["mask_schedule_sha256"] for report in trained
            }
            pair_hashes = {
                report["training_window_digest"] for report in trained
            }
            passed = (
                len(batch_hashes) == 1
                and len(mask_hashes) == 1
                and len(pair_hashes) == 1
            )
            if not passed:
                raise ContractError(
                    f"{generator_id}/{fold.fold_id}: T1-T5 execution schedules differ"
                )
            matched_execution.append(
                {
                    "fold_id": fold.fold_id,
                    "passed": True,
                    "batch_schedule_sha256": next(iter(batch_hashes)),
                    "mask_schedule_sha256": next(iter(mask_hashes)),
                    "training_window_digest": next(iter(pair_hashes)),
                }
            )
        raw = raw_generator_diagnostics(sessions, config)
        checks = evaluate_expected_invariants(
            registered[generator_id],
            raw,
            condition_reports,
        )
        generators_report[generator_id] = {
            "session_count": len(sessions),
            "pair_count": len(pairs.context),
            "raw_diagnostics": raw,
            "conditions": condition_reports,
            "matched_execution": matched_execution,
            "expected_invariants": checks,
            "all_expected_invariants_passed": all(check["passed"] for check in checks),
        }
    if len(parameter_counts) != 1:
        raise ContractError("T0-T5 model parameter counts are not matched")
    return {
        "parameter_count": next(iter(parameter_counts)),
        "generators": generators_report,
        "all_expected_invariants_passed": all(
            report["all_expected_invariants_passed"]
            for report in generators_report.values()
        ),
    }


def run_mode_rehearsal(
    sessions: Sequence[SyntheticSession],
    config: dict[str, Any],
    output_dir: Path,
) -> dict[str, Any]:
    pairs = make_pairs(sessions)
    grouped = mode_grouped_fold(sessions)
    reports: dict[str, Any] = {}
    condition = str(config["mode_extension"]["training_condition"])
    for control in ("C0", "C1", "C2", "C3", "C5"):
        reports[control] = _condition_fold_report(
            f"MODE-{control}",
            condition,
            grouped,
            pairs,
            config,
            output_dir / "mode",
            seed=int(config["seed"]) + 500_000,
            mode_policy=control,
            probe_mode_only=control == "C5",
        )
    leave_out_reports = []
    for fold_position, fold in enumerate(leave_one_mode_out_folds(sessions)):
        leave_out_reports.append(
            _condition_fold_report(
                "MODE-C4",
                condition,
                fold,
                pairs,
                config,
                output_dir / "mode",
                seed=int(config["seed"]) + 510_000 + fold_position,
                mode_policy="C4",
            )
        )
    reports["C4"] = leave_out_reports
    return {
        "schema_version": MODE_REPORT_SCHEMA,
        "experiment_id": MODE_EXPERIMENT_ID,
        "source_type": "deterministic_synthetic_fixture",
        "mode_labels": "externally_assigned_generator_conditions",
        "cognitive_mode_inference": "prohibited",
        "physical_eeg_used": False,
        "physical_eeg_claims": "prohibited",
        "scientific_transfer_claim_allowed": False,
        "fallback_capture_used": False,
        "decision": "pipeline_evidence_only",
        "promotion_status": "not_eligible",
        "runtime_change": "none",
        "mode_transition_diagnostics": {
            "status": "not_applicable_single_mode_sessions",
            "transition_count": 0,
        },
        "controls": reports,
        "comparisons": {
            "C1_vs_C0_correct_target_loss": {
                "C1": reports["C1"]["evaluation"]["control_losses"]["correct_target"],
                "C0": reports["C0"]["evaluation"]["control_losses"]["correct_target"],
            },
            "C1_vs_C2_correct_target_loss": {
                "C1": reports["C1"]["evaluation"]["control_losses"]["correct_target"],
                "C2": reports["C2"]["evaluation"]["control_losses"]["correct_target"],
            },
            "C5_vs_C1_mode_probe_accuracy": {
                "C5": reports["C5"]["evaluation"]["mode_probe_accuracy"],
                "C1": reports["C1"]["evaluation"]["mode_probe_accuracy"],
            },
        },
    }


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def run_rehearsal(
    config_path: Path,
    generator_path: Path,
    output_dir: Path,
    *,
    include_mode: bool = True,
) -> dict[str, Path]:
    config, generator_contract = load_contracts(config_path, generator_path)
    _seed_everything(int(config["seed"]))
    output_dir.mkdir(parents=True, exist_ok=True)
    base_sessions = generate_base_sessions(config)
    mode_sessions = generate_mode_sessions(config) if include_mode else []
    source_manifest = _source_manifest(
        base_sessions,
        mode_sessions,
        config,
        config_sha256=sha256_file(config_path),
        generator_sha256=sha256_file(generator_path),
    )
    source_path = output_dir / "synthetic-source-manifest.json"
    _write_json(source_path, source_manifest)

    # Prove the schema cannot be consumed as a canonical physical source.
    if source_manifest["schema_version"] == SOURCE_MANIFEST_SCHEMA:
        raise ContractError("synthetic source schema collided with physical source schema")
    try:
        load_source_manifest(source_path)
    except ContractError:
        pass
    else:
        raise ContractError("physical source loader accepted a synthetic manifest")

    base = run_base_rehearsal(base_sessions, generator_contract, config, output_dir)
    repo_root = Path(__file__).resolve().parents[3]
    self_tests = diagnostic_self_tests(config)
    if not all(test["passed"] for test in self_tests.values()):
        raise ContractError("synthetic diagnostic self-test failed")
    report: dict[str, Any] = {
        "schema_version": REPORT_SCHEMA,
        "experiment_id": EXPERIMENT_ID,
        "source_type": "deterministic_synthetic_fixture",
        "physical_eeg_used": False,
        "scientific_transfer_claim_allowed": False,
        "decision": "pipeline_evidence_only",
        "promotion_status": "not_eligible",
        "runtime_change": "none",
        "fallback_capture_used": False,
        "source_manifest_sha256": sha256_file(source_path),
        "source_manifest_identity": source_manifest["manifest_sha256"],
        "config_sha256": sha256_file(config_path),
        "generator_contract_sha256": sha256_file(generator_path),
        "runner_sha256": sha256_file(Path(__file__)),
        "runtime_provenance": runtime_provenance(repo_root),
        "package_versions": package_versions(),
        "matched_fields": config["training"]["matched_fields"],
        "base_rehearsal": base,
        "diagnostic_self_tests": self_tests,
    }
    report["report_identity_sha256"] = sha256_json(report)
    report_path = output_dir / "jepa-synthetic-report.json"
    _write_json(report_path, report)

    paths = {
        "source_manifest": source_path,
        "base_report": report_path,
    }
    if include_mode:
        mode_report = run_mode_rehearsal(mode_sessions, config, output_dir)
        mode_report["source_manifest_sha256"] = sha256_file(source_path)
        mode_report["config_sha256"] = sha256_file(config_path)
        mode_report["generator_contract_sha256"] = sha256_file(generator_path)
        mode_report["report_identity_sha256"] = sha256_json(mode_report)
        mode_path = output_dir / "jepa-synthetic-mode-report.json"
        _write_json(mode_path, mode_report)
        paths["mode_report"] = mode_path
    return paths


def _parser() -> argparse.ArgumentParser:
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=root / "NeuralComposeEEG" / "configs" / "jepa-synthetic-v0.json",
    )
    parser.add_argument(
        "--generators",
        type=Path,
        default=root / "docs" / "scoping" / "jepa-synthetic-generators-v0.json",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=root / "NeuralComposeEEG" / "artifacts" / "jepa-synthetic-v0",
    )
    parser.add_argument("--skip-mode", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    paths = run_rehearsal(
        args.config,
        args.generators,
        args.output_dir,
        include_mode=not args.skip_mode,
    )
    print(
        json.dumps(
            {name: str(path) for name, path in paths.items()},
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
