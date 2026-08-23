#!/usr/bin/env python3
"""
validate-muse-physiology.py — wear-the-Muse physiological validation.

Run AFTER putting the Muse S on (forehead sensor centered, hair parted
under the behind-ear sensors, ~3-5 min to settle contact impedance).

Pipeline: 5-condition protocol, automated signature checks, pass/fail report.

Protocol
========
  0. Find Muse via BrainFlow BLE scan (board id 39 = MUSE_S_BOARD).
  1. Eyes open   (30 s)  — relax, look at a fixed point
  2. Eyes closed (30 s)  — relax, eyes shut
  3. Blinks     (~5 s)   — blink deliberately, ~5 in 5 s
  4. Jaw clench (~5 s)   — clench and release, ~3 cycles
  5. Head turns (~10 s)  — turn head left/right slowly, ~3 cycles

Each segment is event-tagged. Total ~80 s. Recorded to CSV with one
row per sample (5 minutes would be ~77k rows × 9 cols; 80 s is ~21k).

Expected signatures (after contact settles)
============================================
  Eyes open   → broadband 1-30 Hz, weak alpha
  Eyes closed → alpha (8-13 Hz) power RISE on AF7/AF8, ratio
                 alpha_closed/alpha_open > 1.5 typical
  Blink       → large low-frequency transient (200-1000 µV, ~200 ms),
                 strongest at AF7/AF8 (frontal)
  Jaw clench  → broadband HIGH-frequency (20-100 Hz+) burst,
                 high std across all channels
  Head turn   → slow baseline shift, large low-freq transients

Pass criteria
=============
  Signal-to-noise ratio (eyes-closed alpha power / eyes-open alpha power)
  in AF7 or AF8 >= 1.5
  OR (more lenient) blink signature detected (max abs > 150 µV in
  frontal channel during blink window)

Output
======
  - raw CSV at $OUT_DIR/muse_validation_<ts>.csv
  - ASCII spectrogram of AF7 eyes-open vs eyes-closed to terminal
  - JSON summary printed at end
  - exit code 0 if passed, 1 if inconclusive, 2 if clearly broken

Run: DYLD_LIBRARY_PATH=~/Developer/brainflow/compiled python3 validate-muse-physiology.py
"""
import os
import sys
import time
import json
import signal
import datetime
import argparse
import numpy as np

# Set up BrainFlow before import
BF_LIB = os.path.expanduser("~/Developer/brainflow/compiled")
if os.path.isdir(BF_LIB):
    os.environ["DYLD_LIBRARY_PATH"] = BF_LIB + ":" + os.environ.get("DYLD_LIBRARY_PATH", "")

try:
    from brainflow.board_shim import BoardShim, BoardIds, BrainFlowInputParams  # noqa: E402
except ImportError:  # --self-check analyses synthetic arrays and needs no hardware lib
    BoardShim = BoardIds = BrainFlowInputParams = None

# --- Configuration ---------------------------------------------------------

SAMPLE_RATE = 256          # Muse S native

# Alpha contrast: four counterbalanced blocks, not one open then one closed.
#
# Number the blocks by position 1-4. Under ABBA the open blocks sit at 1 and 4
# (mean position 2.5) and the closed at 2 and 3 (also 2.5), so both conditions
# occupy the same average point in the session and a LINEAR drift — impedance
# settling, gel warming, drowsiness onset — subtracts out of the ratio. Under the
# old `open, closed` every bit of drift landed on `closed` and was indistinguishable
# from alpha. Under ABAB the closed mean is still one position later, leaving a
# residual that always points the same way.
#
# ABBA cancels a linear trend EXACTLY, and electrode settling is usually curved —
# fast, then flattening. Under a convex or concave trend, equal mean position is not
# sufficient: a residual survives whose sign depends on which way the curve bends
# (decaying settling biases the ratio conservatively, saturating warming biases it
# the wrong way). Measuring that leftover is what the time-index baseline in
# analyze() is for. The two are not redundant — this constant removes the bulk,
# that gate measures what curvature left behind.
BLOCK_SECONDS = 15.0                                  # 4 x 15 s = same 60 s of alpha data
BLOCK_ORDERS = {
    'ABBA': ['open', 'closed', 'closed', 'open'],
    'BAAB': ['closed', 'open', 'open', 'closed'],
}
# Synthetic controls remain pinned to ABBA. Live acquisition passes its selected
# order explicitly so alternating sessions never changes the fixtures.
ALPHA_BLOCK_ORDER = BLOCK_ORDERS['ABBA']

# Occipital alpha takes ~1-2 s to rise after eye closure. Including the build-up
# biases closed blocks downward and makes the ratio sensitive to block length.
# Trimmed from the START OF EVERY BLOCK, open and closed alike — trimming both
# conditions symmetrically is what keeps the discard from being its own thumb on
# the scale.
BLOCK_EDGE_DISCARD_S = 2.0

SEG_BLINK = 5.0            # seconds, blink deliberately
SEG_CLENCH = 8.0           # seconds, jaw clench (3s clench, 1s release, 2 cycles = 8s)
SEG_TURN = 10.0            # seconds, head turn

EEG_CHANNELS = [1, 2, 3, 4]   # TP9, AF7, AF8, TP10 (BrainFlow ordering)
CHANNEL_NAMES = ['TP9', 'AF7', 'AF8', 'TP10']
TIMESTAMP_CH = 6
PACKAGE_NUM_CH = 0

ALPHA_BAND = (8.0, 13.0)
BETA_BAND = (13.0, 30.0)

# Pass thresholds
ALPHA_RATIO_THRESHOLD = 1.5
BLINK_DETECTION_UV = 40.0        # normal gentle blinks are 50-100 µV; aggressive is 150+
HEAD_TURN_UV = 30.0              # slow turns are 30-80 µV; jerky is 100+
CLENCH_BETA_RATIO = 2.0          # true EMG bursts are broadband >50 Hz, but 13-30 should rise
CLENCH_BROADBAND_RATIO = 1.5      # 30-100 Hz broadband rise; EMG is broadband, single-band tests miss it
CONTACT_RMS_MIN_UV = 2.0
CONTACT_RMS_MAX_UV = 200.0

# The condition ratio must also beat the drift the time-index baseline measures.
# A multiplier, not a bare `>`, because the residual ABBA leaves behind is
# empirical — it depends on how this unit's electrodes settle — and only real
# sessions can say how noisy the estimate is. This is the calibration knob.
TIME_BASELINE_MARGIN = 1.0

# Temporal permutation baseline. Ten seeds matches the paper's protocol. The
# 3x collapse bound is conservative: theory gives B/4, roughly 11-32x for the
# analysis bandwidths used here.
SHUFFLE_SEEDS = 10
SHUFFLE_COLLAPSE_FACTOR = 3.0

# Require 80% of each segment's expected samples. The duration must remain
# segment-specific: alpha, blink, clench, and turn intentionally differ.
MIN_VALID_FRACTION = 0.8


# --- Utilities -------------------------------------------------------------

def is_short_segment(n_samples, duration):
    return n_samples < duration * SAMPLE_RATE * MIN_VALID_FRACTION


def classify_contact(rms):
    saturated = [ch for ch in CHANNEL_NAMES
                 if np.isfinite(rms[ch]) and rms[ch] > CONTACT_RMS_MAX_UV]
    dead = [ch for ch in CHANNEL_NAMES
            if not np.isfinite(rms[ch]) or rms[ch] < CONTACT_RMS_MIN_UV]
    healthy = [ch for ch in CHANNEL_NAMES
               if CONTACT_RMS_MIN_UV <= rms[ch] <= CONTACT_RMS_MAX_UV]
    return healthy, saturated, dead


def contact_check_record(rms):
    healthy, saturated, dead = classify_contact(rms)
    return {
        'rms_uv': {
            name: float(rms[name]) if np.isfinite(rms[name]) else None
            for name in CHANNEL_NAMES
        },
        'healthy': healthy,
        'saturated': saturated,
        'dead': dead,
        'passed': not saturated and not dead,
    }


def alpha_block_contact_records(alpha_blocks, block_order):
    records = []
    for block_index, (block, label) in enumerate(
            zip(alpha_blocks, block_order), start=1):
        rms = {
            name: float(np.sqrt(np.mean(block[ch_idx, :].astype(np.float64) ** 2)))
            for name, ch_idx in zip(CHANNEL_NAMES, EEG_CHANNELS)
        }
        record = contact_check_record(rms)
        record.update(block_index=block_index, label=label)
        records.append(record)
    return records


def new_contact_preflight():
    return {
        'status': 'not_run_noninteractive',
        'override_used': False,
        'classification_thresholds_uv': {
            'minimum_inclusive': CONTACT_RMS_MIN_UV,
            'maximum_inclusive': CONTACT_RMS_MAX_UV,
        },
        'checks': [],
        'final_check': None,
    }


def bandpower(signal_1d, fs, band):
    """Welch-like simple periodogram power in band (Hz^2 * count)."""
    if len(signal_1d) < int(fs):
        return 0.0
    # Detrend
    x = signal_1d - signal_1d.mean()
    # FFT
    n = len(x)
    f = np.fft.rfftfreq(n, d=1.0/fs)
    X = np.abs(np.fft.rfft(x * np.hanning(n))) ** 2
    # Integrate over band
    mask = (f >= band[0]) & (f <= band[1])
    if not mask.any():
        return 0.0
    return float(X[mask].sum() / (n * n))


def ascii_spectrogram(signal_1d, fs, title="", width=60, height=14, fmax=40):
    """Tiny ASCII spectrogram: time on x, freq on y, intensity as chars."""
    n = len(signal_1d)
    if n < int(fs):
        return f"  [{title}] (too few samples: {n})\n"
    x = signal_1d - signal_1d.mean()
    # Break into windows
    win = int(fs)  # 1-second windows
    nwin = n // win
    if nwin < 2:
        return f"  [{title}] (need at least 2s)\n"
    # Build spectrogram
    spec = np.zeros((nwin, height))
    for i in range(nwin):
        seg = x[i*win:(i+1)*win]
        seg = seg * np.hanning(len(seg))
        X = np.abs(np.fft.rfft(seg))[:height]
        # Resample to height frequency bins
        freqs = np.fft.rfftfreq(len(seg), d=1.0/fs)
        for j in range(height):
            target_f = (j + 0.5) * fmax / height
            idx = np.argmin(np.abs(freqs - target_f))
            idx = min(idx, len(X) - 1)  # clip to valid range
            spec[i, j] = X[idx]
    # Normalize per row
    spec_max = spec.max()
    if spec_max > 0:
        spec = spec / spec_max
    chars = ' .:-=+*#%@'
    lines = [f"  [{title}] (time→, freq↑, 0-{fmax}Hz, {nwin}s)"]
    for j in range(height - 1, -1, -1):
        f_low = j * fmax / height
        f_high = (j + 1) * fmax / height
        row = ''.join(chars[min(int(spec[i, j] * (len(chars) - 1)), len(chars) - 1)] for i in range(nwin))
        lines.append(f"  {f_high:5.1f} |{row}|")
    return '\n'.join(lines) + '\n'


# --- Recording ------------------------------------------------------------

class Recorder:
    def __init__(self, require_segment_ack=False):
        self.board = None
        self.started_at = None
        self.require_segment_ack = require_segment_ack
        # Cue onset is logged separately from block start. Without both, the 2 s
        # edge discard is a magic constant no later reader can audit: "user was
        # told to close their eyes" and "samples began" are 3+ seconds apart.
        self.marks = []

    def connect(self):
        params = BrainFlowInputParams()
        params.timeout = 15
        # Note: MUSE_S_BOARD=39 used here; for Muse 2 use MUSE_2_BOARD=38.
        # The validation session on 2026-07-10 used Muse S. The Muse 2 path is
        # architecturally identical. Change BoardIds.MUSE_S_BOARD -> MUSE_2_BOARD
        # when running this script on a Muse 2.
        self.board = BoardShim(BoardIds.MUSE_S_BOARD, params)
        if os.environ.get("NC_BRAINFLOW_DEV_LOG", "1") == "0":
            BoardShim.disable_board_logger()
        else:
            BoardShim.enable_dev_board_logger()
        print("Scanning for Muse S (board 39)...")
        self.board.prepare_session()
        print(f"Connected. ID: {self.board.get_board_id()}")
        self.board.start_stream()
        # Drain initial settle
        time.sleep(2.0)
        self.board.get_current_board_data(SAMPLE_RATE * 2)
        self.started_at = time.time()

    def segment(self, duration, label, prompt):
        """Record one segment with a real-time prompt to the user."""
        cue_unix = time.time()
        print("\a\n" + "=" * 60)
        print(f">>> {label}: {prompt}")
        print("=" * 60, flush=True)
        if self.require_segment_ack:
            try:
                input("Adopt that state now, then press ENTER to start the countdown...")
            except EOFError as exc:
                raise RuntimeError(
                    "Interactive segment confirmation requires a TTY; "
                    "use NC_VALIDATE_NONINTERACTIVE=1 only for attended automation"
                ) from exc
        for remaining in [3, 2, 1]:
            print(f"    starting in {remaining}...", flush=True)
            time.sleep(1.0)
        n_samples = int(duration * SAMPLE_RATE)
        # Drain current buffer
        self.board.get_current_board_data(n_samples)
        block_start_unix = time.time()
        # Wait for the duration
        time.sleep(duration + 0.2)
        data = self.board.get_current_board_data(int((duration + 5) * SAMPLE_RATE))
        # Trim to exactly the duration (use package_num as monotonic counter)
        n_cols = data.shape[1]
        # Take the last n_samples
        if n_cols > n_samples:
            data = data[:, -n_samples:]
        self.marks.append({
            "label": label, "block_index": len(self.marks) + 1,
            "cue_unix": cue_unix, "block_start_unix": block_start_unix,
            "cue_to_start_s": block_start_unix - cue_unix,
            "duration_s": duration, "n_samples": int(data.shape[1]),
            "short_block": is_short_segment(data.shape[1], duration),
        })
        return data

    def contact_snapshot(self, duration=2.0):
        """Measure live channel RMS before committing to the timed protocol."""
        n_samples = int(duration * SAMPLE_RATE)
        self.board.get_current_board_data(n_samples)
        time.sleep(duration + 0.2)
        data = self.board.get_current_board_data(n_samples)
        if data.shape[1] == 0:
            return {name: float('nan') for name in CHANNEL_NAMES}
        return {
            name: float(np.sqrt(np.mean(data[ch_idx, :].astype(np.float64) ** 2)))
            for name, ch_idx in zip(CHANNEL_NAMES, EEG_CHANNELS)
        }

    def disconnect(self):
        if self.board:
            try:
                self.board.stop_stream()
                self.board.release_session()
            except Exception as e:
                print(f"  warn: cleanup error: {e}")


# --- Analysis --------------------------------------------------------------

def trim_block_edge(block):
    """Drop BLOCK_EDGE_DISCARD_S from the front of one block (alpha build-up)."""
    n = int(BLOCK_EDGE_DISCARD_S * SAMPLE_RATE)
    return block[:, n:] if block.shape[1] > n else block


def alpha_ratio(blocks_hi, blocks_lo, ch_idx):
    """Alpha power in one group of blocks over another, for a single channel."""
    x_hi = np.concatenate([b[ch_idx, :] for b in blocks_hi]).astype(np.float64)
    x_lo = np.concatenate([b[ch_idx, :] for b in blocks_lo]).astype(np.float64)
    p_hi = bandpower(x_hi, SAMPLE_RATE, ALPHA_BAND)
    p_lo = bandpower(x_lo, SAMPLE_RATE, ALPHA_BAND)
    return p_hi / max(p_lo, 1e-9)


def shuffle_blocks(blocks, seed):
    """Permute retained samples independently within each block and channel."""
    rng = np.random.default_rng(seed)
    shuffled = []
    for block in blocks:
        out = block.copy()
        for ch_idx in EEG_CHANNELS:
            out[ch_idx, :] = rng.permutation(block[ch_idx, :])
        # If a cross-channel measure is added, share one permutation within
        # each block instead so the shuffle preserves inter-channel structure.
        shuffled.append(out)
    return shuffled


def shuffle_ratio_diagnostics(trimmed, block_order):
    """Return report-only shuffled condition and time-index ratios by channel."""
    condition = {name: [] for name in CHANNEL_NAMES}
    time_index = {name: [] for name in CHANNEL_NAMES}
    for seed in range(SHUFFLE_SEEDS):
        shuffled = shuffle_blocks(trimmed, seed)
        shuffled_open = [b for b, lab in zip(shuffled, block_order) if lab == 'open']
        shuffled_closed = [b for b, lab in zip(shuffled, block_order) if lab == 'closed']
        first_half, second_half = shuffled[:2], shuffled[2:]
        for name, ch_idx in zip(CHANNEL_NAMES, EEG_CHANNELS):
            condition[name].append(alpha_ratio(shuffled_closed, shuffled_open, ch_idx))
            time_index[name].append(alpha_ratio(second_half, first_half, ch_idx))
    return condition, time_index


def analyze(alpha_blocks, data_blink, data_clench, data_turn,
            contact_preflight=None, block_order=ALPHA_BLOCK_ORDER):
    """Analyze four counterbalanced alpha blocks in acquisition order."""
    results = {}
    if contact_preflight is not None:
        results['contact_preflight'] = contact_preflight
    block_contact = alpha_block_contact_records(alpha_blocks, block_order)
    results['alpha_block_contact'] = {
        'classification_thresholds_uv': {
            'minimum_inclusive': CONTACT_RMS_MIN_UV,
            'maximum_inclusive': CONTACT_RMS_MAX_UV,
        },
        'blocks': block_contact,
    }

    # Channel order in BrainFlow: ch0=package_num, ch1=TP9, ch2=AF7, ch3=AF8, ch4=TP10, ch5=AUX, ch6=ts
    def extract(data, ch_idx):
        return data[ch_idx, :].astype(np.float64)

    trimmed = [trim_block_edge(b) for b in alpha_blocks]
    open_blocks = [b for b, lab in zip(trimmed, block_order) if lab == 'open']
    closed_blocks = [b for b, lab in zip(trimmed, block_order) if lab == 'closed']
    # Relabelled by POSITION alone, ignoring condition. Under ABBA this split is
    # orthogonal to the real labels, so it measures pure drift and nothing else.
    first_half, second_half = trimmed[:2], trimmed[2:]

    # Sections 3 and 5 below want contiguous open/closed arrays; the untrimmed
    # concatenation is right there since they are baselines, not the contrast.
    data_open = np.concatenate(
        [b for b, lab in zip(alpha_blocks, block_order) if lab == 'open'], axis=1)
    data_closed = np.concatenate(
        [b for b, lab in zip(alpha_blocks, block_order) if lab == 'closed'], axis=1)

    # 1. Alpha power ratio eyes-closed / eyes-open, per channel, against drift
    print("\n--- 1. Alpha power (8-13 Hz) per channel ---")
    print(f"  blocks: {' '.join(block_order)} @ {BLOCK_SECONDS:.0f}s, "
          f"first {BLOCK_EDGE_DISCARD_S:.0f}s of each discarded")
    alpha_ratios = {}
    time_ratios = {}
    alpha_pass_by_ch = {}
    for i, ch_idx in enumerate(EEG_CHANNELS):
        r_cond = alpha_ratio(closed_blocks, open_blocks, ch_idx)
        r_time = alpha_ratio(second_half, first_half, ch_idx)
        alpha_ratios[CHANNEL_NAMES[i]] = r_cond
        time_ratios[CHANNEL_NAMES[i]] = r_time
        # Both gates: big enough, AND bigger than the drift on the same data.
        alpha_pass_by_ch[CHANNEL_NAMES[i]] = (
            r_cond >= ALPHA_RATIO_THRESHOLD and r_cond > r_time * TIME_BASELINE_MARGIN)
        verdict = 'PASS' if alpha_pass_by_ch[CHANNEL_NAMES[i]] else (
            'drift' if r_cond >= ALPHA_RATIO_THRESHOLD else 'fail')
        print(f"  {CHANNEL_NAMES[i]:>5}: condition={r_cond:>6.2f}  "
              f"time-index={r_time:>6.2f}  {verdict}")
    results['alpha_ratios'] = alpha_ratios
    results['alpha_time_index_ratios'] = time_ratios
    results['alpha_pass_by_channel'] = alpha_pass_by_ch
    results['best_alpha_ratio'] = max(alpha_ratios.values())
    results['worst_time_index_ratio'] = max(time_ratios.values())
    results['alpha_pass'] = any(alpha_pass_by_ch.values())
    if not results['alpha_pass'] and results['best_alpha_ratio'] >= ALPHA_RATIO_THRESHOLD:
        print("  ** alpha ratio cleared 1.5x but did NOT beat the time-index baseline.")
        print("     A drift across the session explains it as well as eye closure does.")

    shuffled_condition, shuffled_time = shuffle_ratio_diagnostics(trimmed, block_order)
    results['alpha_shuffle_seeds'] = SHUFFLE_SEEDS
    results['alpha_shuffle_collapse_factor'] = SHUFFLE_COLLAPSE_FACTOR
    results['alpha_shuffle_condition_ratios'] = shuffled_condition
    results['alpha_shuffle_time_index_ratios'] = shuffled_time
    results['alpha_shuffle_gate'] = 'report_only'

    # 2. Blink detection: max abs value in AF7/AF8 during blink window
    print("\n--- 2. Blink transient detection (frontal channels) ---")
    blink_max_af7 = float(np.max(np.abs(extract(data_blink, 2))))
    blink_max_af8 = float(np.max(np.abs(extract(data_blink, 3))))
    print(f"  AF7 max |µV|: {blink_max_af7:.1f}")
    print(f"  AF8 max |µV|: {blink_max_af8:.1f}")
    results['blink_max_af7'] = blink_max_af7
    results['blink_max_af8'] = blink_max_af8
    results['blink_pass'] = max(blink_max_af7, blink_max_af8) >= BLINK_DETECTION_UV

    # 3. Jaw clench: broadband high-frequency energy
    #    Test two bands: 13-30 Hz (beta) and 30-100 Hz (broadband EMG).
    #    EMG contamination from a real clench is broadband and often peaks
    #    well above 30 Hz; beta alone can miss a clench that the user
    #    held sub-clinically. Either band rising is a pass.
    print("\n--- 3. Jaw clench (broadband HF energy) ---")
    clench_beta = {}
    clench_broadband = {}
    for i, ch_idx in enumerate(EEG_CHANNELS):
        x = extract(data_clench, ch_idx)
        clench_beta[CHANNEL_NAMES[i]] = bandpower(x, SAMPLE_RATE, BETA_BAND)
        clench_broadband[CHANNEL_NAMES[i]] = bandpower(x, SAMPLE_RATE, (30.0, 100.0))
        print(f"  {CHANNEL_NAMES[i]:>5}: beta-band power = {clench_beta[CHANNEL_NAMES[i]]:.2f}, "
              f"30-100Hz = {clench_broadband[CHANNEL_NAMES[i]]:.2f}")
    # Compare to eyes-open baseline (no clench, no movement)
    baseline_beta = {}
    baseline_broadband = {}
    for i, ch_idx in enumerate(EEG_CHANNELS):
        x = extract(data_open, ch_idx)
        baseline_beta[CHANNEL_NAMES[i]] = bandpower(x, SAMPLE_RATE, BETA_BAND)
        baseline_broadband[CHANNEL_NAMES[i]] = bandpower(x, SAMPLE_RATE, (30.0, 100.0))
    results['clench_beta'] = clench_beta
    results['clench_broadband'] = clench_broadband
    results['baseline_beta'] = baseline_beta
    results['baseline_broadband'] = baseline_broadband
    # Pass if EITHER band shows >=threshold on any channel.
    beta_ratios = {ch: clench_beta[ch] / max(baseline_beta[ch], 1e-9) for ch in CHANNEL_NAMES}
    broadband_ratios = {ch: clench_broadband[ch] / max(baseline_broadband[ch], 1e-9) for ch in CHANNEL_NAMES}
    results['clench_ratios'] = beta_ratios
    results['clench_broadband_ratios'] = broadband_ratios
    beta_pass = max(beta_ratios.values()) >= CLENCH_BETA_RATIO
    broadband_pass = max(broadband_ratios.values()) >= CLENCH_BROADBAND_RATIO
    results['clench_pass'] = beta_pass or broadband_pass
    print(f"  beta ratio max:    {max(beta_ratios.values()):.2f}  {'PASS' if beta_pass else 'fail'}")
    print(f"  broadband ratio max: {max(broadband_ratios.values()):.2f}  {'PASS' if broadband_pass else 'fail'}")

    # 4. Head turn: motion artifacts (large low-freq swings)
    print("\n--- 4. Head turn motion artifact ---")
    turn_max = {}
    for i, ch_idx in enumerate(EEG_CHANNELS):
        x = extract(data_turn, ch_idx)
        # Look at slow drift (low-pass via moving average, ~1s window)
        win = SAMPLE_RATE  # 1 second
        if len(x) >= win:
            kernel = np.ones(win) / win
            x_lp = np.convolve(x, kernel, mode='same')
            turn_max[CHANNEL_NAMES[i]] = float(np.max(np.abs(x_lp - x_lp.mean())))
        else:
            turn_max[CHANNEL_NAMES[i]] = float(np.max(np.abs(x - x.mean())))
        print(f"  {CHANNEL_NAMES[i]:>5}: low-freq max swing = {turn_max[CHANNEL_NAMES[i]]:.1f} µV")
    results['turn_max'] = turn_max
    results['turn_pass'] = max(turn_max.values()) >= HEAD_TURN_UV

    # 5. Overall contact-quality check: RMS should be in physiological range
    print("\n--- 5. Contact quality (RMS amplitude per channel) ---")
    rms = {}
    for i, ch_idx in enumerate(EEG_CHANNELS):
        x = extract(data_open, ch_idx)
        rms[CHANNEL_NAMES[i]] = float(np.sqrt(np.mean(x ** 2)))
        print(f"  {CHANNEL_NAMES[i]:>5}: RMS = {rms[CHANNEL_NAMES[i]]:.1f} µV")
    results['rms'] = rms
    # Healthy resting EEG RMS is 5-50 µV. >200 µV suggests poor contact
    # (floating) or saturated front-end. <2 µV suggests dead/shorted electrode.
    # For saturated channels we expect RMS ~ 577 µV (uniformly distributed
    # in [-1000, 1000]); report them as a separate diagnostic flag so a
    # future session can re-fit the headband.
    healthy, saturated, dead = classify_contact(rms)
    rms_ok = (len(saturated) == 0 and len(dead) == 0)
    results['contact_pass'] = rms_ok
    results['contact_saturated'] = saturated
    results['contact_dead'] = dead
    results['contact_healthy'] = healthy
    if saturated:
        print(f"  ** SATURATED CHANNELS: {saturated}")
        print(f"     These electrodes are likely making poor contact with skin.")
        print(f"     Reposition the headband before next session.")
    if dead:
        print(f"  ** DEAD CHANNELS: {dead}")
        print(f"     These electrodes are shorted or not connected.")

    # Summary
    print("\n" + "=" * 60)
    print("PHYSIOLOGICAL VALIDATION SUMMARY")
    print("=" * 60)
    checks = [
        ("Contact quality (RMS 2-200 µV)",      results['contact_pass']),
        ("Alpha rise on eyes-closed (>=1.5x, beats time-index)", results['alpha_pass']),
        ("Blink transient (>=40 µV AF7/AF8)",    results['blink_pass']),
        ("Jaw clench beta (>=2x baseline)",      results['clench_pass']),
        ("Head turn artifact (>=30 µV swing)",   results['turn_pass']),
    ]
    n_pass = sum(1 for _, ok in checks if ok)
    for name, ok in checks:
        marker = "PASS" if ok else "FAIL"
        print(f"  [{marker}] {name}")
    if contact_preflight is None:
        print("\n  Contact preflight: NOT RECORDED (legacy or analysis-only input)")
    else:
        thresholds = contact_preflight['classification_thresholds_uv']
        print(f"\n  Contact preflight: {contact_preflight['status']} "
              f"(override={contact_preflight['override_used']}, "
              f"checks={len(contact_preflight['checks'])}, "
              f"healthy={thresholds['minimum_inclusive']:.1f}-"
              f"{thresholds['maximum_inclusive']:.1f} uV inclusive)")
        final_check = contact_preflight['final_check']
        if final_check is not None:
            for name in CHANNEL_NAMES:
                state = ("healthy" if name in final_check['healthy'] else
                         "SATURATED" if name in final_check['saturated'] else "DEAD")
                value = final_check['rms_uv'][name]
                value_text = "missing" if value is None else f"{value:.1f} uV"
                print(f"    {name:>5}: {value_text:>10}  {state}")
    print("\n  Per-block alpha contact:")
    for block in block_contact:
        states = []
        for name in CHANNEL_NAMES:
            state = ("healthy" if name in block['healthy'] else
                     "SATURATED" if name in block['saturated'] else "DEAD")
            value = block['rms_uv'][name]
            value_text = "missing" if value is None else f"{value:.1f}uV"
            states.append(f"{name}={value_text}/{state}")
        print(f"    block {block['block_index']} {block['label']}: " + ", ".join(states))
    print("\n  Temporal-shuffle diagnostics (report only; one ratio per seed):")
    for name in CHANNEL_NAMES:
        cond = ', '.join(f"{value:.2f}" for value in shuffled_condition[name])
        time_values = ', '.join(f"{value:.2f}" for value in shuffled_time[name])
        print(f"  {name:>5} condition:  [{cond}]")
        print(f"        time-index: [{time_values}]")
    print()
    if n_pass == 5:
        verdict = "DEFINITIVE — Muse is on your head and producing physiological EEG."
        rc = 0
    elif n_pass >= 3:
        verdict = "LIKELY — most signatures present, but check electrode contact or relax."
        rc = 1
    elif n_pass >= 1:
        verdict = "INCONCLUSIVE — Muse is connected but signal may be artifact. Check contact."
        rc = 1
    else:
        verdict = "BROKEN — Muse connected but no physiological signal. Check electrode contact."
        rc = 2
    print(f"VERDICT ({n_pass}/5): {verdict}")
    results['verdict'] = verdict
    results['n_pass'] = n_pass
    return results, rc


# --- Main ------------------------------------------------------------------

def main(block_order):
    out_dir = os.path.expanduser("~/Developer/NeuralCompose/Recordings")
    os.makedirs(out_dir, exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_csv = os.path.join(out_dir, f"muse_validation_{timestamp}.csv")
    out_json = os.path.join(out_dir, f"muse_validation_{timestamp}.json")

    print("=" * 60)
    print("Muse S physiological validation")
    print(f"Output: {out_csv}")
    print("=" * 60)
    print()
    print("PROTOCOL")
    print(f"  Alpha block order: {' '.join(block_order)}")
    print("  Total time: ~80 s. Keep the Muse on your head the whole time.")
    print("  Prompted on screen for each segment.")
    print()
    print("Pre-flight checklist:")
    print("  [ ] Muse S centered on forehead (FP1/FP2 area, not above the brows)")
    print("  [ ] Behind-ear sensors (TP9, TP10) with hair parted under each pad")
    print("  [ ] Reference sensors (AF7, AF8) on the forehead just above the brows")
    print("  [ ] All four pads making skin contact (firm pressure, no hair between)")
    print("  [ ] Headband snug but comfortable")
    print()
    if os.environ.get("NC_VALIDATE_NONINTERACTIVE") == "1":
        print("NC_VALIDATE_NONINTERACTIVE=1, skipping prompt. Starting in 3s...")
        time.sleep(3.0)
    else:
        try:
            input("Press ENTER when Muse is on and you're ready to begin...")
        except EOFError:
            print("No stdin available. Set NC_VALIDATE_NONINTERACTIVE=1 to skip prompt.")
            return 2
    print()

    rec = Recorder(require_segment_ack=(
        os.environ.get("NC_VALIDATE_NONINTERACTIVE") != "1"))
    try:
        rec.connect()
    except Exception as e:
        print(f"FAILED to connect: {e}")
        return 2

    # Install cleanup before any interactive contact checks.
    def stop(*_):
        print("\nAborted.")
        rec.disconnect()
        sys.exit(130)
    signal.signal(signal.SIGINT, stop)

    contact_preflight = new_contact_preflight()
    if rec.require_segment_ack:
        while True:
            rms = rec.contact_snapshot()
            check = contact_check_record(rms)
            contact_preflight['checks'].append(check)
            contact_preflight['final_check'] = check
            print("\nLive contact snapshot:")
            for name in CHANNEL_NAMES:
                state = ("healthy" if name in check['healthy'] else
                         "SATURATED" if name in check['saturated'] else "DEAD")
                print(f"  {name:>5}: {rms[name]:7.1f} uV  {state}")
            if check['passed']:
                input("All channels are in range. Press ENTER to begin the protocol...")
                contact_preflight['status'] = 'passed'
                break
            response = input(
                "Reseat the flagged contacts, then press ENTER to recheck; "
                "type RUN to continue anyway: ")
            if response.strip().lower() == "run":
                print("Proceeding with an explicit contact-quality override.")
                contact_preflight['status'] = 'overridden'
                contact_preflight['override_used'] = True
                break

    prompts = {
        'open': "Open eyes. Look at a fixed point. Relax face/jaw.",
        'closed': "Close eyes gently. Same relaxation. Don't squint.",
    }
    alpha_blocks = []
    for n, lab in enumerate(block_order, start=1):
        alpha_blocks.append(rec.segment(
            BLOCK_SECONDS, f"BLOCK {n}/{len(block_order)} — EYES {lab.upper()}",
            prompts[lab]))

    data_blink = rec.segment(SEG_BLINK, "BLINK",
                             "Blink deliberately, ~5 blinks over 5 seconds.")
    data_clench = rec.segment(SEG_CLENCH, "JAW CLENCH",
                              "Clench jaw hard for 3s, release 1s, repeat 2x. Total 8s.")
    data_turn = rec.segment(SEG_TURN, "HEAD TURN",
                            "Slowly turn head left, right, left, right. Don't yank.")

    rec.disconnect()

    # Save raw CSV (column-major: ch0..ch6, samples along axis 1)
    print(f"\nSaving raw data to {out_csv}")
    all_data = np.concatenate(alpha_blocks + [data_blink, data_clench, data_turn], axis=1)
    header = "package_num,TP9,AF7,AF8,TP10,AUX_R,timestamp,segment\n"
    # Annotate segment per row. Blocks are numbered (open1, closed1, closed2,
    # open2) so the ABBA position survives into the CSV — a bare open/closed
    # would throw away exactly what the counterbalancing bought. The downstream
    # consumer (convert_muse_validation_recordings.py:58) passes this column
    # through verbatim, so the new labels are additive, not breaking.
    seen = {}
    seg_labels = []
    for blk, lab in zip(alpha_blocks, block_order):
        seen[lab] = seen.get(lab, 0) + 1
        seg_labels += [f"{lab}{seen[lab]}"] * blk.shape[1]
    seg_labels += (['blink'] * data_blink.shape[1] +
                  ['clench'] * data_clench.shape[1] +
                  ['turn'] * data_turn.shape[1])
    rows = []
    for i in range(all_data.shape[1]):
        rows.append(f"{all_data[0,i]:.0f},{all_data[1,i]:.3f},{all_data[2,i]:.3f},"
                    f"{all_data[3,i]:.3f},{all_data[4,i]:.3f},{all_data[5,i]:.3f},"
                    f"{all_data[6,i]:.6f},{seg_labels[i]}")
    with open(out_csv, 'w') as f:
        f.write(header)
        f.write('\n'.join(rows) + '\n')

    # Analyze
    results, rc = analyze(
        alpha_blocks, data_blink, data_clench, data_turn,
        contact_preflight=contact_preflight, block_order=block_order)
    results['block_marks'] = rec.marks
    results['block_order'] = block_order

    # ASCII spectrograms (eyes open vs eyes closed) for visual confirmation
    af7_open = np.concatenate(
        [b[2, :] for b, lab in zip(alpha_blocks, block_order) if lab == 'open'])
    af7_closed = np.concatenate(
        [b[2, :] for b, lab in zip(alpha_blocks, block_order) if lab == 'closed'])
    print("\n--- 6. AF7 spectrogram: eyes open vs eyes closed ---")
    print(ascii_spectrogram(af7_open.astype(np.float64), SAMPLE_RATE,
                            title="AF7 EYES OPEN (both blocks)", width=60, height=14))
    print(ascii_spectrogram(af7_closed.astype(np.float64), SAMPLE_RATE,
                            title="AF7 EYES CLOSED (both blocks)", width=60, height=14))

    # Save summary
    with open(out_json, 'w') as f:
        json.dump(results, f, indent=2, default=str)
    print(f"\nSummary saved to {out_json}")
    print(f"Raw data saved to {out_csv}")
    return rc


def _synth_blocks(alpha_gain=1.0, drift_per_block=1.0, seed=0):
    """Four synthetic ABBA blocks. alpha_gain multiplies 10 Hz amplitude on the
    CLOSED blocks; drift_per_block multiplies broadband amplitude by position,
    ignoring condition entirely."""
    rng = np.random.default_rng(seed)
    n = int(BLOCK_SECONDS * SAMPLE_RATE)
    t = np.arange(n) / SAMPLE_RATE
    blocks = []
    for pos, lab in enumerate(ALPHA_BLOCK_ORDER):
        sig = rng.normal(0.0, 10.0, n)
        if lab == 'closed':
            sig = sig + alpha_gain * 10.0 * np.sin(2 * np.pi * 10.0 * t)
        sig = sig * (drift_per_block ** pos)
        block = np.zeros((7, n))
        for ch in EEG_CHANNELS:
            block[ch, :] = sig + rng.normal(0.0, 1.0, n)
        blocks.append(block)
    return blocks


def _old_protocol_ratio(blocks, ch_idx):
    """The statistic the OLD script computed: blocks 1-2 as 'open', 3-4 as
    'closed' — i.e. the sequential order it recorded in, with no edge trim."""
    return alpha_ratio(blocks[2:], blocks[:2], ch_idx)


def demo():
    """Self-check. Runs without brainflow or hardware: python3 <this> --self-check"""
    ch = EEG_CHANNELS[0]

    # Segment completeness follows each segment's own duration, not the longer
    # alpha-block duration.
    assert not is_short_segment(int(SEG_BLINK * SAMPLE_RATE), SEG_BLINK)
    assert not is_short_segment(int(SEG_CLENCH * SAMPLE_RATE), SEG_CLENCH)
    assert not is_short_segment(int(SEG_TURN * SAMPLE_RATE), SEG_TURN)
    assert is_short_segment(int(SEG_BLINK * SAMPLE_RATE * 0.79), SEG_BLINK)
    contact_record = contact_check_record({
        'TP9': 20.0, 'AF7': 201.0, 'AF8': 2.0, 'TP10': 1.9})
    assert contact_record == {
        'rms_uv': {'TP9': 20.0, 'AF7': 201.0, 'AF8': 2.0, 'TP10': 1.9},
        'healthy': ['TP9', 'AF8'],
        'saturated': ['AF7'],
        'dead': ['TP10'],
        'passed': False,
    }
    missing_record = contact_check_record({
        'TP9': float('nan'), 'AF7': 20.0, 'AF8': 20.0, 'TP10': 20.0})
    assert missing_record['rms_uv']['TP9'] is None
    assert missing_record['dead'] == ['TP9']
    json.dumps(missing_record, allow_nan=False)
    preflight = new_contact_preflight()
    assert preflight['status'] == 'not_run_noninteractive'
    assert preflight['override_used'] is False
    assert preflight['classification_thresholds_uv'] == {
        'minimum_inclusive': 2.0,
        'maximum_inclusive': 200.0,
    }
    assert BLOCK_ORDERS[parse_args(['--order', 'BAAB']).order] == \
        ['closed', 'open', 'open', 'closed']
    contact_blocks = [np.zeros((7, 8)) for _ in range(4)]
    for block in contact_blocks:
        block[1, :] = 20.0
        block[2, :] = 250.0
        block[3, :] = 1.0
        block[4, :] = 100.0
    block_records = alpha_block_contact_records(contact_blocks, BLOCK_ORDERS['BAAB'])
    assert [record['label'] for record in block_records] == \
        ['closed', 'open', 'open', 'closed']
    assert block_records[0]['healthy'] == ['TP9', 'TP10']
    assert block_records[0]['saturated'] == ['AF7']
    assert block_records[0]['dead'] == ['AF8']

    # (a) Real alpha, no drift -> condition ratio high, time ratio ~1, PASSES.
    # The modest gain isolates spectral structure without smuggling a near-gate
    # broadband amplitude contrast into the fixture. Its d1 tightness is a
    # consequence of that mechanism-focused fixture, not a tuned target.
    b = [trim_block_edge(x) for x in _synth_blocks(alpha_gain=0.3, drift_per_block=1.0)]
    r_cond = alpha_ratio(b[1:3], [b[0], b[3]], ch)
    r_time = alpha_ratio(b[2:], b[:2], ch)
    assert r_cond >= ALPHA_RATIO_THRESHOLD, f"(a) alpha not detected: {r_cond:.2f}"
    assert r_cond > r_time * TIME_BASELINE_MARGIN, f"(a) {r_cond:.2f} !> {r_time:.2f}"

    # (b) Pure drift, no alpha. The new gate must fail -- AND the old design,
    #     on this identical array, must PASS. Without the second assertion this
    #     only proves the new gate works, not that it catches anything the old
    #     one missed, which is the entire claim the redesign rests on.
    raw = _synth_blocks(alpha_gain=0.0, drift_per_block=1.6)
    d = [trim_block_edge(x) for x in raw]
    r_cond = alpha_ratio(d[1:3], [d[0], d[3]], ch)
    r_time = alpha_ratio(d[2:], d[:2], ch)
    assert not (r_cond >= ALPHA_RATIO_THRESHOLD and r_cond > r_time * TIME_BASELINE_MARGIN), \
        f"(b) new gate passed pure drift: cond={r_cond:.2f} time={r_time:.2f}"
    r_old = _old_protocol_ratio(raw, ch)
    assert r_old >= ALPHA_RATIO_THRESHOLD, \
        f"(b) old protocol did not report a pass on pure drift ({r_old:.2f}); " \
        "the regression this change exists to fix is not being exercised"

    # (c) Alpha AND drift -> condition must still beat time-index.
    m = [trim_block_edge(x) for x in _synth_blocks(alpha_gain=2.0, drift_per_block=1.2)]
    r_cond = alpha_ratio(m[1:3], [m[0], m[3]], ch)
    r_time = alpha_ratio(m[2:], m[:2], ch)
    assert r_cond >= ALPHA_RATIO_THRESHOLD and r_cond > r_time * TIME_BASELINE_MARGIN, \
        f"(c) real alpha lost to drift: cond={r_cond:.2f} time={r_time:.2f}"

    # (d) Shuffle the exact post-trim arrays passed to bandpower(). It must
    #     destroy within-block spectral structure without erasing a between-
    #     block amplitude effect.
    alpha_blocks = b
    drift_blocks = [trim_block_edge(x) for x in _synth_blocks(
        alpha_gain=0.0, drift_per_block=1.6)]
    for seed in range(SHUFFLE_SEEDS):
        shuffled_alpha = shuffle_blocks(alpha_blocks, seed)
        shuffled_drift = shuffle_blocks(drift_blocks, seed)

        # (d3) Sampling is without replacement, independently per block/channel.
        for original, shuffled in zip(alpha_blocks, shuffled_alpha):
            for ch_idx in EEG_CHANNELS:
                assert np.array_equal(np.sort(shuffled[ch_idx]), np.sort(original[ch_idx])), \
                    f"(d3) seed {seed} channel {ch_idx} is not a permutation"
        for original, shuffled in zip(drift_blocks, shuffled_drift):
            for ch_idx in EEG_CHANNELS:
                assert np.array_equal(np.sort(shuffled[ch_idx]), np.sort(original[ch_idx])), \
                    f"(d3) drift seed {seed} channel {ch_idx} is not a permutation"

        for name, ch_idx in zip(CHANNEL_NAMES, EEG_CHANNELS):
            true_condition = alpha_ratio(
                [alpha_blocks[1], alpha_blocks[2]],
                [alpha_blocks[0], alpha_blocks[3]], ch_idx)
            shuffled_condition = alpha_ratio(
                [shuffled_alpha[1], shuffled_alpha[2]],
                [shuffled_alpha[0], shuffled_alpha[3]], ch_idx)
            assert shuffled_condition - 1 < \
                (true_condition - 1) / SHUFFLE_COLLAPSE_FACTOR, \
                f"(d1) seed {seed} {name} spectral excess survived: " \
                f"true={true_condition:.2f} shuffled={shuffled_condition:.2f}"
            assert shuffled_condition < ALPHA_RATIO_THRESHOLD, \
                f"(d1) seed {seed} {name} shuffled condition passed gate: " \
                f"{shuffled_condition:.2f}"

            true_time = alpha_ratio(drift_blocks[2:], drift_blocks[:2], ch_idx)
            shuffled_time = alpha_ratio(shuffled_drift[2:], shuffled_drift[:2], ch_idx)
            assert shuffled_time - 1 > \
                (true_time - 1) / SHUFFLE_COLLAPSE_FACTOR, \
                f"(d2) seed {seed} {name} amplitude excess collapsed: " \
                f"true={true_time:.2f} shuffled={shuffled_time:.2f}"

    # (d4) A seed identifies one exact permutation and therefore one result.
    repeat_a = shuffle_blocks(alpha_blocks, 0)
    repeat_b = shuffle_blocks(alpha_blocks, 0)
    assert all(np.array_equal(a, b) for a, b in zip(repeat_a, repeat_b)), \
        "(d4) identical seeds produced different permutations"

    print(f"self-check ok — pure drift: old protocol reports {r_old:.2f}x (PASS), "
          f"new gate rejects it; {SHUFFLE_SEEDS} shuffle seeds pass d1-d4")
    return 0


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-check', action='store_true')
    parser.add_argument('--order', choices=sorted(BLOCK_ORDERS), default='ABBA')
    return parser.parse_args(argv)


if __name__ == "__main__":
    try:
        args = parse_args(sys.argv[1:])
        sys.exit(demo() if args.self_check else main(BLOCK_ORDERS[args.order]))
    except Exception as e:
        import traceback
        traceback.print_exc()
        sys.exit(2)
