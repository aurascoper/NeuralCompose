#!/usr/bin/env python3
"""Convert Recordings/muse_validation_*.csv into the dotted golden-session
directory convention Scripts/train_joint_embedding.py's load_session_windows()
already understands (*eeg.csv + *metadata.json) — zero changes to the
trainer's already-tested loading contract.

Input:  Recordings/muse_validation_<timestamp>.csv
          columns: package_num,TP9,AF7,AF8,TP10,AUX_R,timestamp,segment
        (the matching .json sidecar is a per-file QC/validation report —
        alpha_pass/blink_pass/contact_pass/etc — a different schema
        entirely, not session metadata, and is not read here)

Output: Recordings/muse_validation_converted/<name>/
          <name>.eeg.csv        (t_seconds,TP9,AF7,AF8,TP10 — golden's exact
                                  column convention)
          <name>.metadata.json  (session_id/window_seconds/stride_seconds/
                                  sample_rate — golden's exact key convention)
          <name>.segments.csv   (t_seconds,segment — informational only,
                                  provenance for spot-checking the self-
                                  supervised PSD labels later; NOT read by
                                  the trainer)

Usage:
  python Scripts/convert_muse_validation_recordings.py
  python Scripts/convert_muse_validation_recordings.py --input-dir Recordings --output-dir Recordings/muse_validation_converted
"""
import argparse
import csv
import json
from pathlib import Path

SAMPLE_RATE = 256.0
WINDOW_SECONDS = 2.0
STRIDE_SECONDS = 1.0


def convert_one(csv_path: Path, output_root: Path) -> Path:
    name = csv_path.stem
    session_dir = output_root / name
    session_dir.mkdir(parents=True, exist_ok=True)
    eeg_out = session_dir / f"{name}.eeg.csv"
    meta_out = session_dir / f"{name}.metadata.json"
    segments_out = session_dir / f"{name}.segments.csv"

    row_count = 0
    with csv_path.open(newline="") as f_in, \
            eeg_out.open("w", newline="") as f_eeg, \
            segments_out.open("w", newline="") as f_seg:
        reader = csv.DictReader(f_in)
        eeg_writer = csv.writer(f_eeg)
        seg_writer = csv.writer(f_seg)
        eeg_writer.writerow(["t_seconds", "TP9", "AF7", "AF8", "TP10"])
        seg_writer.writerow(["t_seconds", "segment"])
        for row in reader:
            eeg_writer.writerow(
                [row["timestamp"], row["TP9"], row["AF7"], row["AF8"], row["TP10"]]
            )
            seg_writer.writerow([row["timestamp"], row.get("segment", "")])
            row_count += 1

    metadata = {
        "session_id": name,
        "window_seconds": WINDOW_SECONDS,
        "stride_seconds": STRIDE_SECONDS,
        "sample_rate": SAMPLE_RATE,
        "source": "converted from muse_validation_*.csv by convert_muse_validation_recordings.py",
        "row_count": row_count,
    }
    meta_out.write_text(json.dumps(metadata, indent=2))
    return session_dir


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input-dir", default="Recordings")
    ap.add_argument("--output-dir", default="Recordings/muse_validation_converted")
    args = ap.parse_args()

    input_dir = Path(args.input_dir)
    output_dir = Path(args.output_dir)
    csv_paths = sorted(input_dir.glob("muse_validation_*.csv"))
    if not csv_paths:
        raise SystemExit(f"no muse_validation_*.csv files found under {input_dir}")

    converted = []
    for csv_path in csv_paths:
        session_dir = convert_one(csv_path, output_dir)
        converted.append(session_dir)
        print(f"converted {csv_path.name} -> {session_dir}")

    print("\nTrain against golden + converted muse_validation sessions:")
    session_args = " ".join(str(p) for p in [Path("Recordings/golden")] + converted)
    print(f"  venv/bin/python3 Scripts/train_joint_embedding.py {session_args} --output Models/EEGEncoder")


if __name__ == "__main__":
    main()
