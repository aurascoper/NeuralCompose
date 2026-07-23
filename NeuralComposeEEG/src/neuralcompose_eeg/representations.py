"""Bridge frozen EEGPT/BENDR embeddings into the canonical session splits.

The benchmark does not fabricate a pretrained encoder. CUDA/Kaggle/Colab
workers may generate embeddings, but they must come back with enough evidence
to identify exact windows, weight revision, and channel treatment.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .contracts import ContractError, validate_external_embedding_metadata
from .dataset import CanonicalDataset


@dataclass(frozen=True)
class ExternalEmbeddings:
    values: np.ndarray
    metadata: dict


def load_external_embeddings(
    npz_path: Path,
    metadata_path: Path,
    dataset: CanonicalDataset,
    *,
    dataset_archive_sha256: str | None = None,
) -> ExternalEmbeddings:
    try:
        metadata = json.loads(metadata_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ContractError(f"cannot read external embedding metadata: {exc}") from exc
    validate_external_embedding_metadata(metadata, dataset_sha256=dataset.artifact_sha256())
    if metadata["adapter_training_scope"] == "fold_train_only":
        raise ContractError(
            "precomputed embeddings cannot prove a fold-trained adapter; use the external fold-evaluation contract instead"
        )
    if dataset_archive_sha256 is not None and metadata["input_archive_sha256"] != dataset_archive_sha256:
        raise ContractError("external embeddings were extracted from a different dataset archive")
    try:
        with np.load(npz_path, allow_pickle=False) as archive:
            hashes = archive["raw_window_hashes"].astype("U64")
            values = archive["embeddings"].astype(np.float32)
    except (OSError, KeyError, ValueError) as exc:
        raise ContractError(f"invalid external embedding archive: {exc}") from exc
    if values.ndim != 2 or len(values) != len(hashes) or values.shape[1] < 1:
        raise ContractError("external embeddings must be [window, embedding_dimension]")
    if len(set(hashes.tolist())) != len(hashes):
        raise ContractError("external artifact has duplicate window hashes")
    mapping = {window_hash: row for window_hash, row in zip(hashes.tolist(), values, strict=True)}
    expected = dataset.raw_window_hashes.tolist()
    if set(mapping) != set(expected):
        raise ContractError("external artifact must cover exactly the canonical dataset windows")
    ordered = np.vstack([mapping[window_hash] for window_hash in expected]).astype(np.float32)
    if not np.all(np.isfinite(ordered)):
        raise ContractError("external embeddings contain nonfinite values")
    return ExternalEmbeddings(values=ordered, metadata=metadata)
