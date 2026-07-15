#!/usr/bin/env python3
"""
consume-session.py — next-day physiological consumer for a capture session.

Bridges a raw recording to Phase 3.6/4.0: recovers the manual 5-hard-blink
markers from the EEG, segments the session (focus / drowsy / sleep), tunes the
`eeg_spectral.py` β/α & θ/α cut-points against the *behavioral* blocks, and
emits a first (heuristic, UNVALIDATED) look at sleep architecture.

Complements the existing engineering tools (overnight-review.py etc.), which
never touch the raw EEG physiologically. Reuses analyze-eeg-session.py's loaders
and detectors via importlib (that script is left untouched), plus the shared
eeg_channel_quality and eeg_spectral modules.

Usage:
  ./Scripts/consume-session.py <session-dir-or-eeg.csv>
  ./Scripts/consume-session.py <path> --labels focus drowsy sleep --protocol <protocol-*.json>
  ./Scripts/consume-session.py <path> --active-split        # Part 1 only
  ./Scripts/consume-session.py <path> --sleep-timeline      # Part 2 only
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import sys
from collections import Counter
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from eeg_channel_quality import substitute_bad_channels, summarize_substitutions
from eeg_spectral import welch_band_powers, spectral_ratios, descriptor_for_ratios

DEFAULT_LABELS = ["focus", "drowsy", "sleep"]
DEFAULT_MODEL_DIR = "Models/EEGEncoder"


def _load_analyzer():
    """Import the hyphenated analyze-eeg-session.py as a module (leaves it untouched)."""
    path = Path(__file__).resolve().parent / "analyze-eeg-session.py"
    spec = importlib.util.spec_from_file_location("analyze_eeg_session", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ── Marker recovery + segmentation ───────────────────────────────────────

def cluster_blink_bursts(blink_events: list[dict], min_blinks: int = 4,
                         max_gap_s: float = 2.0) -> list[dict]:
    """Cluster consecutive detected blinks into 'tag' bursts (>= min_blinks)."""
    if not blink_events:
        return []
    events = sorted(blink_events, key=lambda e: e["start_s"])
    bursts, cur = [], [events[0]]
    for e in events[1:]:
        if e["start_s"] - cur[-1]["end_s"] <= max_gap_s:
            cur.append(e)
        else:
            bursts.append(cur)
            cur = [e]
    bursts.append(cur)
    markers = []
    for b in bursts:
        if len(b) >= min_blinks:
            markers.append({
                "n_blinks": len(b),
                "start_s": float(b[0]["start_s"]),
                "end_s": float(b[-1]["end_s"]),
                "center_s": float(0.5 * (b[0]["start_s"] + b[-1]["end_s"])),
            })
    return markers


def segment_from_markers(markers: list[dict], labels: list[str], total_s: float) -> list[dict]:
    """Each marker precedes a labeled segment; segment i spans marker[i] → marker[i+1]."""
    segs = []
    for i, label in enumerate(labels):
        if i >= len(markers):
            break
        start = markers[i]["end_s"]
        end = markers[i + 1]["start_s"] if i + 1 < len(markers) else total_s
        if end > start:
            segs.append({"label": label, "start_s": start, "end_s": end})
    return segs


# ── Part 1: threshold tuning against behavioral blocks ───────────────────

def balanced_accuracy(y_true: list[str], y_pred: list[str], classes: list[str]) -> float:
    recalls = []
    for c in classes:
        idx = [i for i, y in enumerate(y_true) if y == c]
        if not idx:
            continue
        recalls.append(sum(1 for i in idx if y_pred[i] == c) / len(idx))
    return sum(recalls) / len(recalls) if recalls else 0.0


def sweep_threshold(values: list[float], labels: list[str], high_label: str,
                    low_label: str, n: int = 60) -> tuple[float, float]:
    """Predict high_label if value>=tau else low_label; return (best_tau, balanced_acc)."""
    if not values:
        return (float("nan"), 0.0)
    lo, hi = float(np.percentile(values, 5)), float(np.percentile(values, 95))
    best_tau, best_acc = float(np.median(values)), -1.0
    for tau in np.linspace(lo, hi, n):
        pred = [high_label if v >= tau else low_label for v in values]
        acc = balanced_accuracy(labels, pred, [high_label, low_label])
        if acc > best_acc:
            best_tau, best_acc = float(tau), acc
    return best_tau, best_acc


def _segment_windows(df, channels, fs, start_s, end_s, window_s, stride_s):
    X = df[channels].to_numpy().T.astype(np.float64)  # [C, N]
    i0 = max(0, int(start_s * fs))
    i1 = min(X.shape[1], int(end_s * fs))
    win_n = int(round(window_s * fs))
    stride_n = max(1, int(round(stride_s * fs)))
    return [X[:, s:s + win_n] for s in range(i0, i1 - win_n + 1, stride_n)]


def _active_split_review(df, channels, fs, segments, window_s, stride_s, model_dir):
    wanted = {"focus", "drowsy"}
    feats = {"theta_alpha": [], "beta_alpha": []}
    y = []
    windows_by_label = {"focus": [], "drowsy": []}
    crosstab = {}
    for seg in segments:
        if seg["label"] not in wanted:
            continue
        for w in _segment_windows(df, channels, fs, seg["start_s"], seg["end_s"], window_s, stride_s):
            r = spectral_ratios(welch_band_powers(w, fs))
            feats["theta_alpha"].append(r["theta_alpha"])
            feats["beta_alpha"].append(r["beta_alpha"])
            y.append(seg["label"])
            windows_by_label[seg["label"]].append(w)
            crosstab.setdefault(seg["label"], Counter())[descriptor_for_ratios(r)] += 1

    result = {"n_windows": len(y), "crosstab": {k: dict(v) for k, v in crosstab.items()}}
    if len(set(y)) < 2:
        result["note"] = "need both a focus and a drowsy segment to tune thresholds"
        return result

    ba_tau, ba_acc = sweep_threshold(feats["beta_alpha"], y, "focus", "drowsy")
    ta_tau, ta_acc = sweep_threshold(feats["theta_alpha"], y, "drowsy", "focus")
    result["threshold_suggestions"] = {
        "beta_alpha_cut": {"tau": round(ba_tau, 3), "balanced_acc": round(ba_acc, 3),
                           "rule": "beta_alpha >= tau -> focus/engaged", "current_default": 0.9},
        "theta_alpha_cut": {"tau": round(ta_tau, 3), "balanced_acc": round(ta_acc, 3),
                            "rule": "theta_alpha >= tau -> drowsy", "current_default": 1.2},
        "how_to_apply": "Review, then edit Scripts/eeg_spectral.py::descriptor_for_ratios "
                        "cut-points. Not auto-applied — one session, your brain, your call.",
    }
    sil = _latent_silhouette(windows_by_label, len(channels), model_dir)
    if sil is not None:
        result["latent_silhouette"] = sil
        result["latent_caveat"] = ("Descriptors are a function of these same ratios, so latent "
                                   "focus/drowsy separation is partly circular — the behavioral "
                                   "crosstab + sweep above are the real test.")
    return result


def _latent_silhouette(windows_by_label, n_channels, model_dir):
    """Optional: encode focus/drowsy windows with the Phase 3.6 encoder → silhouette."""
    if not model_dir:
        return None
    mdir = Path(model_dir)
    if not (mdir / "encoder.safetensors").exists():
        return None
    try:
        import mlx.core as mx
        from mlx.utils import tree_unflatten
        from sklearn.metrics import silhouette_score
        import train_joint_embedding as tje

        cfg = json.loads((mdir / "config.json").read_text()) if (mdir / "config.json").exists() else {}
        model = tje.SpectralEncoder(in_channels=n_channels,
                                    out_dim=cfg.get("out_dim", 384), hidden=cfg.get("hidden", 64))
        model.update(tree_unflatten(list(mx.load(str(mdir / "encoder.safetensors")).items())))
        mx.eval(model.parameters())
        emb, lab = [], []
        for label, wins in windows_by_label.items():
            if not wins:
                continue
            xcl = np.transpose(np.stack(wins), (0, 2, 1)).astype(np.float32)  # [B, N, C]
            emb.append(np.asarray(model(mx.array(xcl))))
            lab += [label] * len(wins)
        if len(set(lab)) < 2:
            return None
        return {"silhouette": round(float(silhouette_score(np.concatenate(emb), lab)), 3)}
    except Exception as e:  # noqa: BLE001 — optional diagnostic, never fatal
        return {"error": f"latent silhouette skipped: {e}"}


# ── Part 2: rough sleep hypnogram (heuristic, UNVALIDATED) ───────────────

def _eog_transients(x, fs, t, ana) -> int:
    filt = ana.bandpass(x, fs, 1.0, 15.0)
    med = np.median(filt)
    mad = np.median(np.abs(filt - med)) + 1e-9
    z = np.abs(filt - med) / (1.4826 * mad)
    above = (z > 6.0) & (np.abs(filt) > 40.0)
    return len(ana.runs_from_bool(above, t, min_dur_s=0.05))


def epoch_stage(ep: np.ndarray, fs: float, channels: list[str], frontal: list[str], ana) -> str:
    """Coarse 4-state label for one epoch [C, N]. HEURISTIC / UNVALIDATED."""
    bp = welch_band_powers(ep, fs)
    total = sum(bp.values()) + 1e-8
    delta_frac = bp["delta"] / total
    beta_frac = bp["beta"] / total
    slow_frac = (bp["delta"] + bp["theta"]) / total

    hf_rms = 0.0
    for ci in range(ep.shape[0]):
        hf = ana.bandpass(ep[ci], fs, 20.0, min(60.0, fs / 2 - 1))
        hf_rms = max(hf_rms, float(np.sqrt(np.mean(hf ** 2))))

    t_rel = np.arange(ep.shape[1]) / fs
    eog = sum(_eog_transients(ep[channels.index(c)], fs, t_rel, ana) for c in frontal)
    eog_rate = eog / max(ep.shape[1] / fs, 1e-6)

    # REM is phasic — frontal eye movements on a desynchronized, low-amplitude
    # background; deep sleep is *sustained* high delta. Large EOG deflections
    # dump energy into the delta band, so REM must be tested (via its eye-movement
    # rate) BEFORE the delta-dominant deep-sleep check, or a few big saccades in an
    # otherwise light epoch read as deep.
    if hf_rms > 30.0 and beta_frac > 0.25:
        return "wake"
    if eog_rate > 0.15:
        return "rem"
    if delta_frac > 0.45 and slow_frac > 0.6:
        return "deep"
    return "light"


def _ascii_hypnogram(stages: list[dict], width: int = 120) -> str:
    if not stages:
        return "(no epochs)"
    order = ["wake", "rem", "light", "deep"]
    labels = {"wake": "Wake ", "rem": "REM  ", "light": "Light", "deep": "Deep "}
    step = max(1, math.ceil(len(stages) / width))
    binned = [Counter(s["stage"] for s in stages[i:i + step]).most_common(1)[0][0]
              for i in range(0, len(stages), step)]
    return "\n".join(labels[st] + "|" + "".join("#" if b == st else " " for b in binned)
                     for st in order)


def _sleep_review(df, channels, fs, segments, epoch_s, ana):
    sleep_seg = next((s for s in segments if s["label"] == "sleep"), None)
    if sleep_seg:
        i0, i1 = int(sleep_seg["start_s"] * fs), int(sleep_seg["end_s"] * fs)
        region = "sleep segment"
    else:
        i0, i1, region = 0, len(df), "whole recording (no sleep segment found)"
    X = df[channels].to_numpy().T.astype(np.float64)
    frontal = [c for c in ("AF7", "AF8") if c in channels]
    epoch_n = int(epoch_s * fs)
    stages, counts = [], Counter()
    for s in range(i0, i1 - epoch_n + 1, epoch_n):
        stage = epoch_stage(X[:, s:s + epoch_n], fs, channels, frontal, ana)
        stages.append({"start_s": round(s / fs, 1), "stage": stage})
        counts[stage] += 1
    return {
        "region": region, "epoch_s": epoch_s, "n_epochs": len(stages),
        "stage_counts": dict(counts),
        "hypnogram_ascii": _ascii_hypnogram(stages),
        "stages": stages,
        "caveat": "Heuristic 4-state hypnogram (wake/light/deep/rem) — UNVALIDATED on a dry "
                  "4-channel frontal montage. Not clinical sleep staging.",
    }


# ── Orchestration ─────────────────────────────────────────────────────────

def review_session(df, channels, fs, *, labels, protocol_log=None, do_active=True,
                   do_sleep=True, model_dir=DEFAULT_MODEL_DIR, window_s=2.0,
                   stride_s=1.0, epoch_s=30.0) -> dict:
    ana = _load_analyzer()
    total_s = len(df) / fs
    t_rel = np.arange(len(df)) / fs

    df_sub, sub_events = substitute_bad_channels(df.copy(), channels, fs)

    clip = ana.detect_clipping(df_sub, channels, t_rel)
    blinks = ana.detect_blinks(df_sub, channels, fs, t_rel, clip["pct_by_channel"])
    markers = cluster_blink_bursts(blinks)
    segments = segment_from_markers(markers, labels, total_s) if markers else []

    review = {
        "disclaimer": "Descriptors + sleep stages here are heuristic and UNVALIDATED on this "
                      "montage; exploratory only.",
        "duration_s": round(total_s, 1), "fs": fs, "channels": channels,
        "channel_substitutions": summarize_substitutions(sub_events),
        "n_blinks_detected": len(blinks),
        "markers": markers, "segments": segments,
    }
    if protocol_log is not None:
        planned = protocol_log.get("segments", [])
        review["protocol_reconciliation"] = {
            "n_markers_detected": len(markers), "n_planned_segments": len(planned),
            "match": len(markers) == len(planned),
        }
    if do_active and segments:
        review["active_split"] = _active_split_review(df_sub, channels, fs, segments,
                                                      window_s, stride_s, model_dir)
    elif do_active:
        review["active_split"] = {"note": "no markers/segments found — cannot tune thresholds"}
    if do_sleep:
        review["sleep_timeline"] = _sleep_review(df_sub, channels, fs, segments, epoch_s, ana)
    return review


def _print_summary(review: dict) -> None:
    print("=== Session Review ===")
    print(review["disclaimer"])
    print(f"duration={review['duration_s']}s  fs={review['fs']}Hz  channels={review['channels']}")
    print(f"blinks detected: {review['n_blinks_detected']}  markers: {len(review['markers'])}")
    for seg in review["segments"]:
        print(f"  segment {seg['label']:8s} {seg['start_s']:.1f}s → {seg['end_s']:.1f}s")
    act = review.get("active_split", {})
    if "threshold_suggestions" in act:
        print("\n-- Part 1: threshold tuning (focus vs drowsy) --")
        print("  crosstab:", act["crosstab"])
        for k, v in act["threshold_suggestions"].items():
            if isinstance(v, dict):
                print(f"  {k}: {v}")
        if "latent_silhouette" in act:
            print("  latent silhouette:", act["latent_silhouette"], "—", act.get("latent_caveat", ""))
    elif "note" in act:
        print("\n-- Part 1 --", act["note"])
    sleep = review.get("sleep_timeline")
    if sleep:
        print(f"\n-- Part 2: sleep timeline ({sleep['region']}, {sleep['n_epochs']} epochs) --")
        print("  stage counts:", sleep["stage_counts"])
        print(sleep["hypnogram_ascii"])
        print(" ", sleep["caveat"])


def main() -> None:
    ap = argparse.ArgumentParser(description="Consume a capture session (segment, tune, sleep-review)")
    ap.add_argument("input", type=Path, help="session directory or eeg.csv path")
    ap.add_argument("--labels", nargs="*", default=DEFAULT_LABELS,
                    help="segment labels in order (default: focus drowsy sleep)")
    ap.add_argument("--protocol", type=Path, default=None, help="protocol-*.json from run-session-protocol.py")
    ap.add_argument("--active-split", action="store_true", help="Part 1 only")
    ap.add_argument("--sleep-timeline", action="store_true", help="Part 2 only")
    ap.add_argument("--model-dir", default=DEFAULT_MODEL_DIR)
    ap.add_argument("--epoch-s", type=float, default=30.0)
    ap.add_argument("--out", type=Path, default=None, help="session-review.json path (default: next to input)")
    args = ap.parse_args()

    do_active = args.active_split or not args.sleep_timeline
    do_sleep = args.sleep_timeline or not args.active_split

    ana = _load_analyzer()
    df, channels, fs, name = ana.load_session(args.input)
    protocol_log = json.loads(args.protocol.read_text()) if args.protocol else None

    review = review_session(df, channels, fs, labels=args.labels, protocol_log=protocol_log,
                            do_active=do_active, do_sleep=do_sleep, model_dir=args.model_dir,
                            epoch_s=args.epoch_s)
    _print_summary(review)

    out_path = args.out or (args.input.parent if args.input.is_file() else args.input) / "session-review.json"
    out_path.write_text(json.dumps(review, indent=2))
    print(f"\nwrote {out_path}")


if __name__ == "__main__":
    main()
