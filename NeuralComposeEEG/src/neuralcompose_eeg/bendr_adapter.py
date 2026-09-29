"""Pinned BENDR encoder and explicit four-channel Muse input adapter.

M4 uses the official BENDR release's frozen convolutional feature encoder.
The historic DN3 implementation is deliberately not a project dependency: the
small checkpoint-compatible architecture below is checked strictly against the
pinned state dict before any experiment can run.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import torch
import torch.nn as nn

from .contracts import CHANNELS, WINDOW_SAMPLES, ContractError
from .provenance import sha256_file


BENDR_SCHEMA = "nc-bendr-encoder-v0"
DEFAULT_BENDR_CONFIG_PATH = Path(__file__).resolve().parents[2] / "configs" / "bendr-20ch-v0.json"


@dataclass(frozen=True)
class BENDRGeometry:
    target_channels: tuple[str, ...]
    target_indices: tuple[int, ...]
    upstream_revision: str
    checkpoint_sha256: str
    widths: tuple[int, ...]
    strides: tuple[int, ...]


def load_bendr_geometry(path: Path = DEFAULT_BENDR_CONFIG_PATH) -> BENDRGeometry:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read BENDR config: {exc}") from exc
    if value.get("schema_version") != BENDR_SCHEMA or value.get("model_id") != "bendr":
        raise ContractError("invalid BENDR encoder configuration")
    geometry = value.get("geometry")
    channels = value.get("target_channels")
    mapping = value.get("approximate_target_mapping")
    upstream = value.get("upstream")
    checkpoint = value.get("checkpoint")
    adaptation = value.get("input_adaptation")
    if not isinstance(geometry, dict) or geometry.get("sample_rate_hz") != 256 or geometry.get("window_samples") != WINDOW_SAMPLES:
        raise ContractError("BENDR geometry must preserve the 256 Hz, four-second window")
    if not isinstance(channels, list) or len(channels) != 20 or len(set(channels)) != 20 or channels[-1] != "SCALE":
        raise ContractError("BENDR configuration must declare the 19 scalp channels and SCALE input")
    if tuple(value.get("muse_source_channels") or ()) != CHANNELS:
        raise ContractError(f"BENDR config must use Muse channels {list(CHANNELS)}")
    if not isinstance(mapping, dict) or set(mapping) != set(CHANNELS) or any(target not in channels for target in mapping.values()):
        raise ContractError("BENDR mapping must explicitly map every Muse channel to a declared target")
    if not isinstance(upstream, dict) or not isinstance(upstream.get("revision"), str) or len(upstream["revision"]) != 40:
        raise ContractError("BENDR config must pin the upstream revision")
    if not isinstance(checkpoint, dict) or not isinstance(checkpoint.get("sha256"), str) or len(checkpoint["sha256"]) != 64:
        raise ContractError("BENDR config must pin the encoder checkpoint hash")
    if not isinstance(adaptation, dict) or adaptation.get("canonical_input") != "causal_calibration_zscore_windows":
        raise ContractError("BENDR config must declare the canonical input adaptation")
    if adaptation.get("original_deep1010_minmax_reconstruction") != "not_claimed":
        raise ContractError("BENDR config must not claim a Deep1010 normalization reconstruction")
    widths = tuple(geometry.get("encoder_widths", ()))
    strides = tuple(geometry.get("encoder_strides", ()))
    if widths != (3, 3, 3, 3, 3, 3) or strides != (3, 2, 2, 2, 2, 2):
        raise ContractError("BENDR config does not match the pinned encoder stack")
    return BENDRGeometry(
        target_channels=tuple(channels),
        target_indices=tuple(channels.index(mapping[channel]) for channel in CHANNELS),
        upstream_revision=upstream["revision"],
        checkpoint_sha256=checkpoint["sha256"],
        widths=widths,
        strides=strides,
    )


class FrozenBENDRConvEncoder(nn.Module):
    """Strictly checkpoint-compatible BENDR convolutional feature encoder."""

    def __init__(self, geometry: BENDRGeometry | None = None) -> None:
        super().__init__()
        self.geometry = geometry or load_bendr_geometry()
        stack = nn.Sequential()
        input_channels = len(self.geometry.target_channels)
        for index, (width, stride) in enumerate(zip(self.geometry.widths, self.geometry.strides, strict=True)):
            stack.add_module(
                f"Encoder_{index}",
                nn.Sequential(
                    nn.Conv1d(input_channels, 512, width, stride=stride, padding=width // 2),
                    # The pinned encoder uses Dropout2d(0.0). M4 freezes it
                    # in evaluation mode, where an identity is exactly the
                    # same computation without PyTorch's legacy 3D warning.
                    nn.Identity(),
                    nn.GroupNorm(256, 512),
                    nn.GELU(),
                ),
            )
            input_channels = 512
        self.encoder = stack

    def forward(self, values: torch.Tensor) -> torch.Tensor:
        return self.encoder(values)

    def load_pinned_checkpoint(self, path: Path) -> str:
        if not path.is_file():
            raise ContractError(f"BENDR encoder checkpoint is missing: {path}")
        observed_hash = sha256_file(path)
        if observed_hash != self.geometry.checkpoint_sha256:
            raise ContractError("BENDR encoder checkpoint hash does not match the pinned release artifact")
        try:
            state = torch.load(path, map_location="cpu", weights_only=True)
        except (OSError, RuntimeError, ValueError) as exc:
            raise ContractError(f"cannot load BENDR encoder checkpoint: {exc}") from exc
        if not isinstance(state, dict):
            raise ContractError("BENDR encoder checkpoint must contain a state dictionary")
        try:
            self.load_state_dict(state, strict=True)
        except RuntimeError as exc:
            raise ContractError(f"BENDR checkpoint does not match the pinned encoder architecture: {exc}") from exc
        for parameter in self.parameters():
            parameter.requires_grad_(False)
        self.eval()
        return observed_hash


class LearnedMuseToBENDRAdapter(nn.Module):
    """Fold-local 4-to-20 adapter with an explicit absent-target representation."""

    def __init__(self, geometry: BENDRGeometry | None = None) -> None:
        super().__init__()
        self.geometry = geometry or load_bendr_geometry()
        target_count = len(self.geometry.target_channels)
        self.projection = nn.Conv1d(len(CHANNELS) * 2, target_count, kernel_size=1, bias=True)
        self.missing_target_embedding = nn.Parameter(torch.empty(target_count))
        fixed = torch.zeros(target_count, len(CHANNELS), dtype=torch.float32)
        for source_index, target_index in enumerate(self.geometry.target_indices):
            fixed[target_index, source_index] = 1.0
        self.register_buffer("fixed_mapping", fixed, persistent=True)
        self.reset_parameters()

    def reset_parameters(self) -> None:
        nn.init.zeros_(self.projection.weight)
        nn.init.zeros_(self.projection.bias)
        for source_index, target_index in enumerate(self.geometry.target_indices):
            self.projection.weight.data[target_index, source_index, 0] = 1.0
        nn.init.normal_(self.missing_target_embedding, mean=0.0, std=0.02)

    def forward(self, windows: torch.Tensor, observed_channels: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        _validate_muse_input(windows, observed_channels)
        observed = observed_channels.to(dtype=windows.dtype)
        mask_features = observed.unsqueeze(-1).expand(-1, -1, windows.shape[-1])
        values = self.projection(torch.cat((windows * mask_features, mask_features), dim=1))
        target_mask = torch.einsum("rc,bc->br", self.fixed_mapping, observed).clamp(max=1.0)
        values = values + (1.0 - target_mask).unsqueeze(-1) * self.missing_target_embedding.view(1, -1, 1)
        return values, target_mask


def _validate_muse_input(windows: torch.Tensor, observed_channels: torch.Tensor) -> None:
    if windows.ndim != 3 or windows.shape[1:] != (len(CHANNELS), WINDOW_SAMPLES):
        raise ValueError(f"windows must be [batch, {len(CHANNELS)}, {WINDOW_SAMPLES}]")
    if observed_channels.shape != windows.shape[:2]:
        raise ValueError("observed_channels must be [batch, four Muse channels]")
    if not torch.isfinite(windows).all() or not torch.isfinite(observed_channels).all():
        raise ValueError("BENDR adapter inputs must be finite")
    if torch.any(observed_channels < 0) or torch.any(observed_channels > 1):
        raise ValueError("observed_channels must be values in [0, 1]")
