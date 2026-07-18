#!/usr/bin/env python3
"""
classify-session.py — run the trained IntentClassifier.mlpackage over an entire
capture session and report the predicted-intent timeline.

First offline application of the real Core ML intent classifier outside the
live app/Swift pipeline. Preprocessing mirrors
Sources/BCICore/Preprocessing/EEGWindowing.swift and
Sources/BCIClassifier/CoreMLIntentClassifier.swift exactly: raw, unfiltered,
un-normalized 512-sample windows (2s @ nominal 256Hz), 256-sample stride (1s),
channel order TP9/AF7/AF8/TP10, softmax applied client-side (the model outputs
raw logits). Window size is fixed at the model's nominal-rate sample counts —
NOT derived from a session's measured sample rate — because that's what both
training and the live pipeline actually use, and the model's input shape is a
hard [1,4,512] regardless.

Caveat (real, not hypothetical, found while building this): reconstructing
Scripts/train-intent-classifier.py's own windowing against its actual training
session found ZERO singleBlink/select windows in the training set. This
model has likely never seen an example of those two classes — treat
predictions of singleBlink/select as noise, not signal. See
project_overnight_capture_pipeline_broken memory.

There is no ground truth for exploratory sessions like an overnight capture
(labels.csv is uniformly "none"), so this cannot report accuracy — only the
predicted-class timeline, for a human to sanity-check against what they
remember doing.

Usage:
  ./Scripts/classify-session.py <eeg.csv-or-session-dir>
  ./Scripts/classify-session.py <path> --protocol <protocol-*.json>   # overlay focus/drowsy/sleep segments
  ./Scripts/classify-session.py <path> --model Models/IntentClassifier.mlpackage --out predictions.json
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MODEL = REPO_ROOT / "Models" / "IntentClassifier.mlpackage"

# Fixed by the model's input shape [1, 4, 512] and the live pipeline's nominal
# 256Hz config (Sources/BCICore/Preprocessing/EEGWindowing.swift) — NOT the
# session's measured sample rate.
WIN_N = 512
STRIDE_N = 256
CHANNEL_ORDER = ["TP9", "AF7", "AF8", "TP10"]
CLASS_ORDER = ["rest", "jawClench", "singleBlink", "doubleBlink", "select"]
# select is deliberately inert downstream (dwell-based selection replaced it,
# see Sources/BCICore/Intent/IntentSmoother.swift); flagged here, not hidden.
THIN_TRAINING_CLASSES = {"singleBlink", "select"}


def _load_analyzer():
    """Import the hyphenated analyze-eeg-session.py as a module (leaves it untouched)."""
    path = Path(__file__).resolve().parent / "analyze-eeg-session.py"
    spec = importlib.util.spec_from_file_location("analyze_eeg_session", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def softmax(logits: np.ndarray) -> np.ndarray:
    e = np.exp(logits - np.max(logits))
    return e / e.sum()


def build_windows(df, channels, win_n=WIN_N, stride_n=STRIDE_N):
    """Slide raw, unfiltered windows over the whole recording. Yields (center_t, [C,N])."""
    ordered = [c for c in CHANNEL_ORDER if c in channels]
    X = df[ordered].to_numpy(dtype=np.float32).T  # [C, N]
    t = df["t_seconds"].to_numpy(dtype=np.float64)
    n = X.shape[1]
    for s in range(0, n - win_n + 1, stride_n):
        center_t = float(t[s + win_n // 2])
        yield center_t, X[:, s:s + win_n]


def segment_lookup(protocol_log: dict | None):
    """Build a t(unix) -> label function from a protocol log's own cue times.

    Uses the protocol's authoritative start_unix per segment directly, rather
    than re-deriving segment boundaries from blink-marker detection (which has
    its own failure modes — see project_overnight_capture_pipeline_broken
    memory) — the protocol log is ground truth for when each cue fired.
    """
    if not protocol_log:
        return lambda t: None
    bounds = sorted(
        ((seg["label"], seg["start_unix"]) for seg in protocol_log.get("segments", [])),
        key=lambda s: s[1],
    )
    if not bounds:
        return lambda t: None

    def lookup(t):
        label = None
        for lbl, start in bounds:
            if t >= start:
                label = lbl
            else:
                break
        return label
    return lookup


def classify_session(eeg_path: Path, model_path: Path, protocol_log: dict | None = None):
    import coremltools as ct

    ana = _load_analyzer()
    df, channels, measured_fs, name = ana.load_session(eeg_path)
    model = ct.models.MLModel(str(model_path))
    label_for = segment_lookup(protocol_log)

    results = []
    windows = list(build_windows(df, channels))
    total = len(windows)
    for i, (center_t, window) in enumerate(windows):
        if i % 500 == 0:
            print(f"  classifying window {i}/{total}...", file=sys.stderr, end="\r")
        out = model.predict({"eeg_window": window[np.newaxis, :, :]})
        logits = np.asarray(out["intent_logits"]).reshape(-1)
        probs = softmax(logits)
        idx = int(np.argmax(probs))
        results.append({
            "t": center_t,
            "pred": CLASS_ORDER[idx],
            "confidence": round(float(probs[idx]), 4),
            "segment": label_for(center_t),
        })
    print(f"  classified {total}/{total} windows.        ", file=sys.stderr)
    return {
        "session": name,
        "measured_fs": measured_fs,
        "window_samples": WIN_N,
        "stride_samples": STRIDE_N,
        "n_windows": total,
        "thin_training_classes": sorted(THIN_TRAINING_CLASSES),
        "predictions": results,
    }


def summarize(review: dict) -> None:
    preds = review["predictions"]
    print(f"=== Intent Classification: {review['session']} ===")
    if not preds:
        print("No windows classified — the session is too short to produce even one "
              "512-sample window at the 256-sample stride. Nothing to summarize.")
        return
    print(f"{review['n_windows']} windows (512 samples / 256 stride, nominal 256Hz)")
    print("CAVEAT: no ground truth for this session (labels.csv is uniformly 'none') — "
          "exploratory only. singleBlink/select predictions are UNRELIABLE — the training "
          "set had zero examples of either class.\n")

    overall = Counter(p["pred"] for p in preds)
    print("-- overall class distribution --")
    for cls in CLASS_ORDER:
        n = overall.get(cls, 0)
        flag = "  (thin/no training data)" if cls in THIN_TRAINING_CLASSES else ""
        print(f"  {cls:12s} {n:6d}  ({100 * n / len(preds):5.1f}%){flag}")

    by_segment: dict[str, Counter] = {}
    for p in preds:
        by_segment.setdefault(p["segment"] or "(unlabeled)", Counter())[p["pred"]] += 1
    if len(by_segment) > 1 or "(unlabeled)" not in by_segment:
        print("\n-- by protocol segment --")
        for seg, counts in by_segment.items():
            n = sum(counts.values())
            top = counts.most_common(3)
            top_str = ", ".join(f"{c}={v} ({100*v/n:.0f}%)" for c, v in top)
            print(f"  {seg:10s} n={n:5d}  top: {top_str}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Run the trained IntentClassifier over a full session")
    ap.add_argument("input", type=Path, help="session directory or eeg.csv path")
    ap.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    ap.add_argument("--protocol", type=Path, default=None,
                    help="protocol-*.json from run-session-protocol.py, to overlay segment labels")
    ap.add_argument("--out", type=Path, default=None,
                    help="predictions JSON path (default: next to input)")
    args = ap.parse_args()

    if not args.model.exists():
        raise SystemExit(f"Model not found: {args.model}")

    protocol_log = json.loads(args.protocol.read_text()) if args.protocol else None
    review = classify_session(args.input, args.model, protocol_log)
    summarize(review)

    out_path = args.out or (args.input.parent if args.input.is_file() else args.input) / "intent-predictions.json"
    out_path.write_text(json.dumps(review, indent=2))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
