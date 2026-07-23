"""CLI entry point for canonical EXP-NC-EEG-ENC-001 dataset construction."""

from __future__ import annotations

import argparse
from pathlib import Path

from .dataset import build_canonical_dataset, save_dataset


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--preprocessing", type=Path, default=Path("configs/muse-four-channel-v0.json"))
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--metadata-output", required=True, type=Path)
    args = parser.parse_args(argv)
    dataset, metadata = build_canonical_dataset(args.manifest, args.preprocessing)
    save_dataset(dataset, metadata, args.output, args.metadata_output)
    print(
        f"wrote {args.output} ({metadata['window_count']} windows across "
        f"{metadata['session_count']} sessions; dataset_sha256={metadata['dataset_sha256']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
