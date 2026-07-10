#!/usr/bin/env python3
"""
analyze-eeg-session.py — offline physiological analysis of a *recorded*
EEG session (a CalibrationRecorder folder or a TrackBRecorder CSV).

Unlike validate-muse-physiology.py (which drives a live Muse session and
runs its own fixed protocol), this tool is a pure offline analyzer: point
it at a folder or CSV that already exists on disk and it produces plots,
a JSON summary, and an HTML report. It does not touch BrainFlow, BLE, or
the app at all.

Usage:
    python3 Scripts/analyze-eeg-session.py <calibration_folder_or_csv> [--out DIR]

Input formats accepted:
  - A CalibrationRecorder session folder (contains eeg.csv with header
    `t_seconds,TP9,AF7,AF8,TP10` or a subset of those channels).
  - A TrackBRecorder CSV (`imagined_eeg.csv`, header
    `wall_time,sample_timestamp,trial_index,target,<channels>`).
  - Any CSV with a time column (t_seconds / sample_timestamp / wall_time)
    and one or more of TP9/AF7/AF8/TP10 as columns.

Output (written to --out, default `Recordings/analysis/<session_name>/`):
  - raw_traces.png       — full-duration per-channel EEG traces
  - psd.png              — Welch PSD per channel
  - band_power.png       — rolling delta/theta/alpha/beta power per channel
  - rms_timeline.png      — rolling per-channel RMS
  - spectrogram.png      — spectrogram for AF7/AF8 (or first two channels)
  - summary.json         — machine-readable stats + detected segments
  - report.html          — human-readable report embedding the plots above
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import signal

CANDIDATE_CHANNELS = ["TP9", "AF7", "AF8", "TP10"]
CANDIDATE_TIME_COLS = ["t_seconds", "sample_timestamp", "wall_time"]
BANDS = {
    "delta": (0.5, 4.0),
    "theta": (4.0, 8.0),
    "alpha": (8.0, 13.0),
    "beta": (13.0, 30.0),
}
# Muse's ADC saturates near +-1000 uV (BrainFlow's uV-scaled Muse output).
CLIP_THRESHOLD_UV = 999.0


# ── Loading ──────────────────────────────────────────────────────────────

def find_eeg_csv(path: Path) -> Path:
    if path.is_file():
        return path
    for name in ("eeg.csv", "imagined_eeg.csv"):
        candidate = path / name
        if candidate.exists():
            return candidate
    csvs = sorted(path.glob("*.csv"))
    if csvs:
        return csvs[0]
    raise FileNotFoundError(f"No EEG CSV found under {path}")


def load_session(path: Path) -> tuple[pd.DataFrame, list[str], float, str]:
    csv_path = find_eeg_csv(path)
    df = pd.read_csv(csv_path)

    # `eeg.csv` / `imagined_eeg.csv` are generic filenames written by the
    # recorders — the containing session folder's name is the meaningful
    # identifier. Fall back to the CSV's own stem when given a bare file.
    session_name = csv_path.parent.name if csv_path.stem in ("eeg", "imagined_eeg") else csv_path.stem

    channels = [c for c in CANDIDATE_CHANNELS if c in df.columns]
    if not channels:
        raise ValueError(f"No recognized EEG channel columns in {csv_path} "
                          f"(looked for {CANDIDATE_CHANNELS}, found {list(df.columns)})")

    time_col = next((c for c in CANDIDATE_TIME_COLS if c in df.columns), None)
    if time_col is None:
        raise ValueError(f"No recognized time column in {csv_path} "
                          f"(looked for {CANDIDATE_TIME_COLS})")

    t = df[time_col].to_numpy(dtype=float)
    dt = np.median(np.diff(t))
    if dt <= 0:
        raise ValueError(f"Non-increasing timestamps in {csv_path}; cannot infer sample rate")
    fs = 1.0 / dt

    return df, channels, fs, session_name


# ── Signal processing ───────────────────────────────────────────────────

def welch_psd(x: np.ndarray, fs: float):
    nperseg = min(len(x), int(fs * 4))
    return signal.welch(x, fs=fs, nperseg=nperseg)


def band_power(freqs: np.ndarray, psd: np.ndarray, band: tuple[float, float]) -> float:
    lo, hi = band
    mask = (freqs >= lo) & (freqs <= hi)
    if not np.any(mask):
        return 0.0
    return float(np.trapezoid(psd[mask], freqs[mask]))


def rolling_band_powers(x: np.ndarray, fs: float, window_s: float = 2.0, step_s: float = 1.0):
    win = max(int(window_s * fs), 8)
    step = max(int(step_s * fs), 1)
    times, powers = [], {b: [] for b in BANDS}
    for start in range(0, len(x) - win, step):
        seg = x[start:start + win]
        freqs, psd = signal.welch(seg, fs=fs, nperseg=win)
        for name, band in BANDS.items():
            powers[name].append(band_power(freqs, psd, band))
        times.append(start / fs)
    return np.array(times), {k: np.array(v) for k, v in powers.items()}


def rolling_rms(x: np.ndarray, fs: float, window_s: float = 1.0, step_s: float = 0.5):
    win = max(int(window_s * fs), 4)
    step = max(int(step_s * fs), 1)
    times, rms = [], []
    for start in range(0, len(x) - win, step):
        seg = x[start:start + win]
        rms.append(float(np.sqrt(np.mean(seg ** 2))))
        times.append(start / fs)
    return np.array(times), np.array(rms)


def bandpass(x: np.ndarray, fs: float, lo: float, hi: float, order: int = 4) -> np.ndarray:
    nyq = fs / 2.0
    hi = min(hi, nyq * 0.98)
    b, a = signal.butter(order, [lo / nyq, hi / nyq], btype="band")
    return signal.filtfilt(b, a, x)


def runs_from_bool(mask: np.ndarray, times: np.ndarray, min_dur_s: float) -> list[tuple[float, float]]:
    runs = []
    in_run = False
    start_idx = 0
    for i, v in enumerate(mask):
        if v and not in_run:
            in_run, start_idx = True, i
        elif not v and in_run:
            in_run = False
            if times[i - 1] - times[start_idx] >= min_dur_s:
                runs.append((float(times[start_idx]), float(times[i - 1])))
    if in_run and times[-1] - times[start_idx] >= min_dur_s:
        runs.append((float(times[start_idx]), float(times[-1])))
    return runs


# ── Artifact / segment detection ────────────────────────────────────────

def detect_clipping(df: pd.DataFrame, channels: list[str], t: np.ndarray) -> dict:
    per_channel = {}
    any_clipped = np.zeros(len(t), dtype=bool)
    for ch in channels:
        x = df[ch].to_numpy()
        clipped = np.abs(x) >= CLIP_THRESHOLD_UV
        per_channel[ch] = float(np.mean(clipped) * 100.0)
        any_clipped |= clipped
    events = runs_from_bool(any_clipped, t, min_dur_s=0.02)
    return {"pct_by_channel": per_channel, "events": events}


def detect_blinks(df: pd.DataFrame, channels: list[str], fs: float, t: np.ndarray,
                   clip_pct_by_channel: dict) -> list[dict]:
    frontal = [c for c in ("AF7", "AF8") if c in channels]
    if not frontal:
        return []
    # A heavily-clipped channel drowns real blinks in saturation noise and
    # over-triggers massively — prefer whichever frontal channel is cleaner.
    ch = min(frontal, key=lambda c: clip_pct_by_channel.get(c, 0.0))
    x = df[ch].to_numpy()
    filt = bandpass(x, fs, 1.0, 15.0)
    # A fixed absolute threshold (e.g. the ~150uV textbook figure) doesn't
    # generalize across electrode contact quality — a well-seated channel's
    # real blinks can peak well under that, while a noisy channel blows past
    # it on baseline noise alone. Use a robust (median/MAD) z-score against
    # the channel's own noise floor instead, with a small absolute floor so
    # a dead-flat channel doesn't get flagged on quantization noise.
    med = np.median(filt)
    mad = np.median(np.abs(filt - med)) + 1e-9
    robust_z = np.abs(filt - med) / (1.4826 * mad)
    above = (robust_z > 6.0) & (np.abs(filt) > 40.0)
    runs = runs_from_bool(above, t, min_dur_s=0.05)
    return [{"start_s": s, "end_s": e, "channel": ch} for s, e in runs]


def detect_emg_bursts(df: pd.DataFrame, channels: list[str], fs: float) -> list[dict]:
    events = []
    for ch in channels:
        x = df[ch].to_numpy()
        hf = bandpass(x, fs, 20.0, min(60.0, fs / 2.0 - 1.0))
        t_r, rms_hf = rolling_rms(hf, fs, window_s=0.5, step_s=0.25)
        if len(rms_hf) < 4:
            continue
        z = (rms_hf - np.median(rms_hf)) / (np.std(rms_hf) + 1e-9)
        above = z > 4.0
        runs = runs_from_bool(above, t_r, min_dur_s=0.2)
        events.extend({"start_s": s, "end_s": e, "channel": ch} for s, e in runs)
    return events


def detect_rest_periods(rms_times: np.ndarray, rms_mean: np.ndarray, min_dur_s: float = 5.0) -> list[dict]:
    if len(rms_mean) == 0:
        return []
    quiet_threshold = np.percentile(rms_mean, 30)
    below = rms_mean <= quiet_threshold
    runs = runs_from_bool(below, rms_times, min_dur_s=min_dur_s)
    return [{"start_s": s, "end_s": e} for s, e in runs]


# ── Quality assessment ───────────────────────────────────────────────────

def assess_channel_quality(clip_pct: float, rms: float) -> dict:
    """Per-channel contact/quality rating. Collapsing everything into one
    overall verdict hides *which* sensor needs attention — a single bad
    channel (e.g. saturated AF7) shouldn't read the same as four marginal
    ones."""
    plausible = 1.0 <= rms <= 200.0
    if clip_pct < 1.0 and plausible:
        contact, overall = "Excellent", "Good"
    elif clip_pct < 5.0 and plausible:
        contact, overall = "Good", "Good"
    elif clip_pct < 20.0:
        contact, overall = "Marginal", "Marginal"
    else:
        contact, overall = "Poor", "Poor"
    if not plausible and overall == "Good":
        overall = "Marginal"
    return {"contact": contact, "clip_pct": clip_pct, "rms_uv": rms, "overall": overall}


def assess_quality(channels: list[str], clip_pct_by_channel: dict, blink_events: list,
                    emg_events: list, overall_rms: dict) -> dict:
    per_channel = {
        ch: assess_channel_quality(clip_pct_by_channel.get(ch, 0.0), overall_rms.get(ch, 0.0))
        for ch in channels
    }

    notes = []
    ratings = [c["overall"] for c in per_channel.values()]
    if "Poor" in ratings:
        verdict = "poor"
    elif "Marginal" in ratings:
        verdict = "marginal"
    else:
        verdict = "healthy"

    bad = [ch for ch, c in per_channel.items() if c["overall"] == "Poor"]
    if bad:
        notes.append(f"Poor contact on {', '.join(bad)} — see per-channel table below. "
                      f"A single bad channel with the others clean points at electrode "
                      f"contact, not a pipeline-wide problem.")

    if not blink_events:
        notes.append("The current heuristic did not detect convincing blink events on the "
                      "usable frontal channel(s). This does not mean no blinks occurred — "
                      "blink detection is sensitive to electrode contact and preprocessing "
                      "choices, so treat this as inconclusive rather than a negative result.")
    else:
        notes.append(f"{len(blink_events)} blink-like transient(s) detected on the frontal "
                      f"channel used for detection.")

    if not emg_events:
        notes.append("No high-frequency EMG-like bursts detected — "
                      "recording may not include a jaw-clench segment, or contact is poor.")
    else:
        notes.append(f"{len(emg_events)} EMG-like burst(s) detected.")

    return {"verdict": verdict, "notes": notes, "per_channel": per_channel}


# ── Plotting ─────────────────────────────────────────────────────────────

def make_plots(df, channels, fs, t, out_dir: Path) -> dict:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    paths = {}

    # Raw traces
    fig, axes = plt.subplots(len(channels), 1, figsize=(12, 2.2 * len(channels)), sharex=True)
    if len(channels) == 1:
        axes = [axes]
    for ax, ch in zip(axes, channels):
        ax.plot(t, df[ch].to_numpy(), linewidth=0.4, color="#3a8fd6")
        ax.set_ylabel(f"{ch}\n(uV)")
        ax.set_ylim(-1050, 1050)
    axes[-1].set_xlabel("Time (s)")
    fig.suptitle("Raw EEG traces")
    fig.tight_layout()
    p = out_dir / "raw_traces.png"
    fig.savefig(p, dpi=110)
    plt.close(fig)
    paths["raw_traces"] = p.name

    # PSD
    fig, ax = plt.subplots(figsize=(10, 5))
    for ch in channels:
        freqs, psd = welch_psd(df[ch].to_numpy(), fs)
        mask = freqs <= 60
        ax.semilogy(freqs[mask], psd[mask], label=ch)
    for name, (lo, hi) in BANDS.items():
        ax.axvspan(lo, hi, alpha=0.06)
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("PSD (uV^2/Hz)")
    ax.set_title("Welch PSD per channel")
    ax.legend()
    fig.tight_layout()
    p = out_dir / "psd.png"
    fig.savefig(p, dpi=110)
    plt.close(fig)
    paths["psd"] = p.name

    # Rolling band power (one subplot per channel, all 4 bands overlaid)
    fig, axes = plt.subplots(len(channels), 1, figsize=(12, 2.6 * len(channels)), sharex=True)
    if len(channels) == 1:
        axes = [axes]
    for ax, ch in zip(axes, channels):
        rt, powers = rolling_band_powers(df[ch].to_numpy(), fs)
        for name, vals in powers.items():
            ax.plot(rt, vals, label=name, linewidth=1.2)
        ax.set_ylabel(f"{ch}\npower")
        ax.legend(fontsize=7, ncol=4, loc="upper right")
    axes[-1].set_xlabel("Time (s)")
    fig.suptitle("Rolling band power (delta/theta/alpha/beta)")
    fig.tight_layout()
    p = out_dir / "band_power.png"
    fig.savefig(p, dpi=110)
    plt.close(fig)
    paths["band_power"] = p.name

    # RMS timeline
    fig, ax = plt.subplots(figsize=(12, 4))
    for ch in channels:
        rt, rms = rolling_rms(df[ch].to_numpy(), fs)
        ax.plot(rt, rms, label=ch, linewidth=1.0)
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("RMS (uV)")
    ax.set_title("Rolling per-channel RMS")
    ax.legend()
    fig.tight_layout()
    p = out_dir / "rms_timeline.png"
    fig.savefig(p, dpi=110)
    plt.close(fig)
    paths["rms_timeline"] = p.name

    # Spectrogram for up to 2 frontal-preferred channels
    spec_channels = [c for c in ("AF7", "AF8") if c in channels] or channels[:2]
    fig, axes = plt.subplots(len(spec_channels), 1, figsize=(12, 3.5 * len(spec_channels)), sharex=True)
    if len(spec_channels) == 1:
        axes = [axes]
    for ax, ch in zip(axes, spec_channels):
        f, tt, Sxx = signal.spectrogram(df[ch].to_numpy(), fs=fs, nperseg=int(fs * 2))
        mask = f <= 60
        im = ax.pcolormesh(tt, f[mask], 10 * np.log10(Sxx[mask] + 1e-12), shading="auto", cmap="magma")
        ax.set_ylabel(f"{ch}\nHz")
        fig.colorbar(im, ax=ax, label="dB")
    axes[-1].set_xlabel("Time (s)")
    fig.suptitle("Spectrogram")
    fig.tight_layout()
    p = out_dir / "spectrogram.png"
    fig.savefig(p, dpi=110)
    plt.close(fig)
    paths["spectrogram"] = p.name

    return paths


# ── Report ───────────────────────────────────────────────────────────────

def build_html_report(session_name: str, summary: dict, plot_paths: dict, out_path: Path):
    def fmt_events(events, key_names=("start_s", "end_s")):
        if not events:
            return "<p><em>none detected</em></p>"
        rows = "".join(
            f"<tr><td>{e.get(key_names[0]):.1f}s</td><td>{e.get(key_names[1]):.1f}s</td>"
            f"<td>{e.get('channel', '')}</td></tr>"
            for e in events[:50]
        )
        more = f"<p><em>...and {len(events) - 50} more</em></p>" if len(events) > 50 else ""
        return f"<table><tr><th>Start</th><th>End</th><th>Channel</th></tr>{rows}</table>{more}"

    band_rows = "".join(
        f"<tr><td>{ch}</td>" + "".join(f"<td>{summary['band_power_overall'][ch][b]:.2f}</td>" for b in BANDS) + "</tr>"
        for ch in summary["channels"]
    )
    clip_rows = "".join(
        f"<tr><td>{ch}</td><td>{pct:.2f}%</td></tr>"
        for ch, pct in summary["clipping"]["pct_by_channel"].items()
    )
    per_channel_rows = "".join(
        f"<tr><td>{ch}</td><td>{q['contact']}</td><td>{q['clip_pct']:.2f}%</td>"
        f"<td>{q['rms_uv']:.1f} uV</td>"
        f"<td class=\"rating-{q['overall'].lower()}\">{q['overall']}</td></tr>"
        for ch, q in summary["quality"]["per_channel"].items()
    )

    html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>EEG session report — {session_name}</title>
<style>
body {{ font-family: -apple-system, sans-serif; max-width: 980px; margin: 2rem auto; color: #222; }}
h1, h2 {{ border-bottom: 1px solid #ddd; padding-bottom: 4px; }}
table {{ border-collapse: collapse; margin: 0.5rem 0 1.5rem; }}
td, th {{ border: 1px solid #ccc; padding: 4px 10px; text-align: right; }}
th {{ background: #f0f0f0; }}
img {{ max-width: 100%; margin: 0.5rem 0 1.5rem; border: 1px solid #ddd; }}
.verdict {{ font-size: 1.3rem; font-weight: bold; padding: 8px 14px; border-radius: 6px; display: inline-block; }}
.healthy {{ background: #d4f4dd; color: #1a7a3a; }}
.marginal {{ background: #fdf0c8; color: #8a6300; }}
.poor {{ background: #fbdada; color: #a3231b; }}
.rating-good {{ background: #d4f4dd; color: #1a7a3a; font-weight: bold; }}
.rating-marginal {{ background: #fdf0c8; color: #8a6300; font-weight: bold; }}
.rating-poor {{ background: #fbdada; color: #a3231b; font-weight: bold; }}
</style></head><body>
<h1>EEG session report — {session_name}</h1>
<p class="verdict {summary['quality']['verdict']}">{summary['quality']['verdict'].upper()}</p>
<ul>{"".join(f"<li>{n}</li>" for n in summary['quality']['notes'])}</ul>

<h2>Per-channel quality</h2>
<table><tr><th>Channel</th><th>Contact</th><th>Clipping</th><th>RMS</th><th>Overall</th></tr>
{per_channel_rows}</table>

<h2>Recording summary</h2>
<table>
<tr><th>Duration</th><td>{summary['duration_s']:.1f} s</td></tr>
<tr><th>Sample rate</th><td>{summary['fs_hz']:.2f} Hz</td></tr>
<tr><th>Samples</th><td>{summary['n_samples']}</td></tr>
<tr><th>Channels</th><td>{', '.join(summary['channels'])}</td></tr>
</table>

<h2>Raw traces</h2>
<img src="{plot_paths['raw_traces']}">

<h2>Power spectral density</h2>
<img src="{plot_paths['psd']}">
<h3>Overall band power by channel</h3>
<table><tr><th>Channel</th>{"".join(f"<th>{b}</th>" for b in BANDS)}</tr>{band_rows}</table>

<h2>Rolling band power</h2>
<img src="{plot_paths['band_power']}">

<h2>RMS timeline</h2>
<img src="{plot_paths['rms_timeline']}">
<table><tr><th>Channel</th><th>Mean RMS</th></tr>
{"".join(f"<tr><td>{ch}</td><td>{v:.2f} uV</td></tr>" for ch, v in summary['rms_overall'].items())}
</table>

<h2>Spectrogram</h2>
<img src="{plot_paths['spectrogram']}">

<h2>Clipping</h2>
<table><tr><th>Channel</th><th>% samples clipped</th></tr>{clip_rows}</table>

<h2>Estimated blink events (frontal channel, heuristic)</h2>
{fmt_events(summary['blink_events'])}

<h2>Estimated EMG / jaw-clench bursts (heuristic)</h2>
{fmt_events(summary['emg_events'])}

<h2>Estimated low-amplitude rest periods (heuristic)</h2>
{fmt_events(summary['rest_periods'], key_names=("start_s", "end_s"))}

</body></html>
"""
    out_path.write_text(html)


# ── Main ─────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", type=Path, help="Calibration folder or EEG CSV path")
    parser.add_argument("--out", type=Path, default=None,
                         help="Output directory (default: Recordings/analysis/<session_name>/)")
    args = parser.parse_args()

    if not args.input.exists():
        print(f"Error: {args.input} does not exist", file=sys.stderr)
        sys.exit(1)

    df, channels, fs, session_name = load_session(args.input)
    t = None
    time_col = next(c for c in CANDIDATE_TIME_COLS if c in df.columns)
    t_raw = df[time_col].to_numpy(dtype=float)
    t = t_raw - t_raw[0]

    out_dir = args.out or (Path(__file__).resolve().parent.parent / "Recordings" / "analysis" / session_name)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Session: {session_name}")
    print(f"Channels: {channels}")
    print(f"Duration: {t[-1]:.1f}s, fs={fs:.2f}Hz, n={len(t)}")

    clipping = detect_clipping(df, channels, t)
    blink_events = detect_blinks(df, channels, fs, t, clipping["pct_by_channel"])
    emg_events = detect_emg_bursts(df, channels, fs)

    # Use TP9/TP10 (or first channel) as the RMS reference for rest detection.
    ref_ch = channels[0]
    rms_t, rms_ref = rolling_rms(df[ref_ch].to_numpy(), fs)
    rest_periods = detect_rest_periods(rms_t, rms_ref)

    band_power_overall = {}
    rms_overall = {}
    for ch in channels:
        freqs, psd = welch_psd(df[ch].to_numpy(), fs)
        band_power_overall[ch] = {name: band_power(freqs, psd, band) for name, band in BANDS.items()}
        rms_overall[ch] = float(np.sqrt(np.mean(df[ch].to_numpy() ** 2)))

    quality = assess_quality(channels, clipping["pct_by_channel"], blink_events, emg_events, rms_overall)

    summary = {
        "session_name": session_name,
        "duration_s": float(t[-1]),
        "fs_hz": float(fs),
        "n_samples": int(len(t)),
        "channels": channels,
        "band_power_overall": band_power_overall,
        "rms_overall": rms_overall,
        "clipping": clipping,
        "blink_events": blink_events,
        "emg_events": emg_events,
        "rest_periods": rest_periods,
        "quality": quality,
    }

    print("Rendering plots...")
    plot_paths = make_plots(df, channels, fs, t, out_dir)

    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    build_html_report(session_name, summary, plot_paths, out_dir / "report.html")

    print(f"\nQuality verdict: {quality['verdict'].upper()}")
    for note in quality["notes"]:
        print(f"  - {note}")
    print(f"\nReport written to: {out_dir / 'report.html'}")
    print(f"Summary JSON:       {out_dir / 'summary.json'}")


if __name__ == "__main__":
    main()
