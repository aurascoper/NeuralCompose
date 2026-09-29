"""Explicit four-channel Muse adapters for the pinned EEGPT 58-channel geometry.

These adapters are reference components for CUDA workers, never NeuralCompose
runtime code. They make the four-to-58 montage approximation visible and keep
the zero-fill/no-mask condition available only as a negative control.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
import torch
import torch.nn as nn

from .contracts import CHANNELS, WINDOW_SAMPLES, ContractError


MONTAGE_SCHEMA = "nc-eegpt-montage-v0"
DEFAULT_MONTAGE_PATH = Path(__file__).resolve().parents[2] / "configs" / "eegpt-58ch-montage-v0.json"


@dataclass(frozen=True)
class EEGPTMontage:
    target_channels: tuple[str, ...]
    source_channels: tuple[str, ...]
    target_indices: tuple[int, ...]
    upstream_revision: str


def load_eegpt_montage(path: Path = DEFAULT_MONTAGE_PATH) -> EEGPTMontage:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read EEGPT montage config: {exc}") from exc
    if value.get("schema_version") != MONTAGE_SCHEMA or value.get("model_id") != "eegpt":
        raise ContractError("invalid EEGPT montage configuration")
    geometry = value.get("geometry")
    target_channels = value.get("target_channels")
    source_channels = value.get("muse_source_channels")
    mapping = value.get("approximate_target_mapping")
    if not isinstance(geometry, dict) or geometry.get("sample_rate_hz") != 256 or geometry.get("window_samples") != WINDOW_SAMPLES:
        raise ContractError("EEGPT montage must preserve the 256 Hz, four-second window")
    if not isinstance(target_channels, list) or len(target_channels) != 58 or len(set(target_channels)) != 58:
        raise ContractError("EEGPT montage must declare exactly 58 distinct target channels")
    if tuple(source_channels or ()) != CHANNELS:
        raise ContractError(f"EEGPT montage must use Muse channels {list(CHANNELS)}")
    if not isinstance(mapping, dict) or set(mapping) != set(CHANNELS):
        raise ContractError("EEGPT montage must map every Muse source channel")
    if any(target not in target_channels for target in mapping.values()):
        raise ContractError("EEGPT montage maps a Muse channel outside the pretrained geometry")
    upstream = value.get("upstream")
    if not isinstance(upstream, dict) or not isinstance(upstream.get("revision"), str) or not upstream["revision"]:
        raise ContractError("EEGPT montage must pin an upstream revision")
    return EEGPTMontage(
        target_channels=tuple(target_channels),
        source_channels=tuple(source_channels),
        target_indices=tuple(target_channels.index(mapping[channel]) for channel in CHANNELS),
        upstream_revision=upstream["revision"],
    )


class FixedMuseToEEGPTMapping(nn.Module):
    """A2: deterministic approximate mapping with an explicit 58-channel mask."""

    def __init__(self, montage: EEGPTMontage | None = None, *, source_order: tuple[int, ...] = (0, 1, 2, 3)) -> None:
        super().__init__()
        self.montage = montage or load_eegpt_montage()
        if tuple(sorted(source_order)) != tuple(range(len(CHANNELS))):
            raise ValueError("source_order must be a permutation of the four Muse channels")
        self.source_order = source_order
        matrix = torch.zeros(len(self.montage.target_channels), len(CHANNELS), dtype=torch.float32)
        for source_index, target_index in enumerate(self.montage.target_indices):
            matrix[target_index, source_order[source_index]] = 1.0
        self.register_buffer("mapping_matrix", matrix, persistent=True)

    def forward(self, windows: torch.Tensor, observed_channels: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        _validate_input(windows, observed_channels)
        observed = observed_channels.to(dtype=windows.dtype)
        values = torch.einsum("rc,bct->brt", self.mapping_matrix, windows * observed.unsqueeze(-1))
        target_mask = torch.einsum("rc,bc->br", self.mapping_matrix, observed).clamp(max=1.0)
        return values, target_mask


class LearnedMuseToEEGPTAdapter(nn.Module):
    """A1/A3: a fold-trainable adapter that embeds missing-target information.

    The adapter consumes both signal and source-observation channels. Its
    missing-target embedding prevents an absent electrode from being silently
    indistinguishable from a measured zero-valued trace.
    """

    def __init__(self, montage: EEGPTMontage | None = None) -> None:
        super().__init__()
        self.montage = montage or load_eegpt_montage()
        self.projection = nn.Conv1d(len(CHANNELS) * 2, len(self.montage.target_channels), kernel_size=1, bias=True)
        self.missing_target_embedding = nn.Parameter(torch.empty(len(self.montage.target_channels)))
        self.register_buffer("fixed_mapping", FixedMuseToEEGPTMapping(self.montage).mapping_matrix, persistent=True)
        self.reset_parameters()

    def reset_parameters(self) -> None:
        nn.init.zeros_(self.projection.weight)
        nn.init.zeros_(self.projection.bias)
        for source_index, target_index in enumerate(self.montage.target_indices):
            self.projection.weight.data[target_index, source_index, 0] = 1.0
        nn.init.normal_(self.missing_target_embedding, mean=0.0, std=0.02)

    def forward(self, windows: torch.Tensor, observed_channels: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        _validate_input(windows, observed_channels)
        observed = observed_channels.to(dtype=windows.dtype)
        mask_features = observed.unsqueeze(-1).expand(-1, -1, windows.shape[-1])
        values = self.projection(torch.cat((windows * mask_features, mask_features), dim=1))
        target_mask = torch.einsum("rc,bc->br", self.fixed_mapping, observed).clamp(max=1.0)
        values = values + (1.0 - target_mask).unsqueeze(-1) * self.missing_target_embedding.view(1, -1, 1)
        return values, target_mask


class ZeroFillNoMaskControl(nn.Module):
    """A4: intentionally invalid transfer control, retained for falsification."""

    def __init__(self, montage: EEGPTMontage | None = None) -> None:
        super().__init__()
        self.mapping = FixedMuseToEEGPTMapping(montage)

    def forward(self, windows: torch.Tensor, observed_channels: torch.Tensor | None = None) -> torch.Tensor:
        if observed_channels is None:
            observed_channels = torch.ones(
                windows.shape[0], len(CHANNELS), dtype=windows.dtype, device=windows.device
            )
        _validate_input(windows, observed_channels)
        observed = observed_channels.to(dtype=windows.dtype)
        values, _ = self.mapping(windows, observed)
        return values


def _validate_input(windows: torch.Tensor, observed_channels: torch.Tensor) -> None:
    if windows.ndim != 3 or windows.shape[1:] != (len(CHANNELS), WINDOW_SAMPLES):
        raise ValueError(f"windows must be [batch, {len(CHANNELS)}, {WINDOW_SAMPLES}]")
    if observed_channels.shape != windows.shape[:2]:
        raise ValueError("observed_channels must be [batch, four Muse channels]")
    if not torch.isfinite(windows).all() or not torch.isfinite(observed_channels).all():
        raise ValueError("adapter inputs must be finite")
    if torch.any(observed_channels < 0) or torch.any(observed_channels > 1):
        raise ValueError("observed_channels must be values in [0, 1]")
