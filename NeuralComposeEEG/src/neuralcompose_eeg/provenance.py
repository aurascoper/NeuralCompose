"""Small deterministic provenance helpers shared by all benchmark artifacts."""

from __future__ import annotations

import hashlib
import importlib
import json
import platform
import resource
import subprocess
import sys
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def stable_json_bytes(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def sha256_json(value: Any) -> str:
    return sha256_bytes(stable_json_bytes(value))


def sha256_string_set(values: list[str] | tuple[str, ...]) -> str:
    """Hash an unordered set of canonical identifiers without raw content."""
    return sha256_json(sorted(str(value) for value in values))


def git_commit(root: Path) -> str | None:
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def runtime_provenance(root: Path) -> dict[str, str | None]:
    """Return stable environment facts without making them scientific inputs."""
    return {
        "python_version": sys.version.split()[0],
        "platform": platform.platform(),
        "machine": platform.machine(),
        "git_commit": git_commit(root),
    }


def package_versions() -> dict[str, str | None]:
    versions: dict[str, str | None] = {}
    for name in ("numpy", "scipy", "sklearn", "torch"):
        try:
            module = importlib.import_module(name)
            versions[name] = str(getattr(module, "__version__", "unknown"))
        except ImportError:
            versions[name] = None
    return versions


def accelerator_provenance() -> dict[str, str | int | None]:
    """Report what is actually available; never assume the Neural Engine trains PyTorch."""
    try:
        import torch
    except ImportError:
        return {"accelerator": None, "accelerator_memory_bytes": None, "cuda_or_mps_version": None}
    if torch.cuda.is_available():
        properties = torch.cuda.get_device_properties(0)
        return {
            "accelerator": torch.cuda.get_device_name(0),
            "accelerator_memory_bytes": int(properties.total_memory),
            "cuda_or_mps_version": str(torch.version.cuda),
        }
    if torch.backends.mps.is_available():
        return {
            "accelerator": "apple-mps-gpu",
            "accelerator_memory_bytes": None,
            "cuda_or_mps_version": f"mps-via-torch-{torch.__version__}",
        }
    return {"accelerator": "cpu", "accelerator_memory_bytes": None, "cuda_or_mps_version": None}


def peak_process_memory_bytes() -> int | None:
    """Return the process high-water mark with an explicit macOS/Linux unit rule."""
    try:
        value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    except (AttributeError, ValueError):
        return None
    return value if sys.platform == "darwin" else value * 1024


def _mean_available(values: list[float | int | None]) -> float | None:
    numeric = [float(value) for value in values if value is not None]
    return float(sum(numeric) / len(numeric)) if numeric else None


def offline_deployment_outcome() -> dict[str, Any]:
    """Describe intentionally deferred deployment measurements without inferring them."""
    return {
        "coreml_conversion": {
            "attempted": False,
            "success": None,
            "status": "not_attempted",
            "reason": "Offline encoder evidence must select a compact candidate before Core ML conversion.",
        },
        "execution_assignment": {
            "cpu": "not_measured",
            "gpu": "not_measured",
            "neural_engine": "not_measured",
            "reason": "No Core ML deployment candidate exists during the offline encoder pilot.",
        },
    }


def summarize_runtime_outcomes(
    fold_fits: list[dict[str, Any]],
    *,
    elapsed_seconds: float,
) -> dict[str, Any]:
    """Summarize comparable local worker measurements without inventing energy data."""
    return {
        "elapsed_seconds": round(float(elapsed_seconds), 6),
        "peak_process_memory_bytes": peak_process_memory_bytes(),
        "mean_training_seconds": _mean_available([fit.get("training_seconds") for fit in fold_fits]),
        "mean_per_window_inference_ms": _mean_available([fit.get("per_window_inference_ms") for fit in fold_fits]),
        "mean_checkpoint_size_bytes": _mean_available([fit.get("checkpoint_size_bytes") for fit in fold_fits]),
        "energy_impact_proxy": None,
        "energy_impact_note": "No portable energy counter is available in the local Python benchmark.",
    }
