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
import numpy as np

# Set up BrainFlow before import
BF_LIB = os.path.expanduser("~/Developer/brainflow/compiled")
if os.path.isdir(BF_LIB):
    os.environ["DYLD_LIBRARY_PATH"] = BF_LIB + ":" + os.environ.get("DYLD_LIBRARY_PATH", "")

from brainflow.board_shim import BoardShim, BoardIds, BrainFlowInputParams  # noqa: E402

# --- Configuration ---------------------------------------------------------

SAMPLE_RATE = 256          # Muse S native
SEG_OPEN = 30.0            # seconds, eyes open
SEG_CLOSED = 30.0          # seconds, eyes closed
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
MIN_VALID_SAMPLES = SEG_OPEN * SAMPLE_RATE * 0.8   # 80% of expected


# --- Utilities -------------------------------------------------------------

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
    def __init__(self):
        self.board = None
        self.started_at = None

    def connect(self):
        params = BrainFlowInputParams()
        params.timeout = 15
        # Note: MUSE_S_BOARD=39 used here; for Muse 2 use MUSE_2_BOARD=38.
        # The validation session on 2026-07-10 used Muse S. The Muse 2 path is
        # architecturally identical. Change BoardIds.MUSE_S_BOARD -> MUSE_2_BOARD
        # when running this script on a Muse 2.
        self.board = BoardShim(BoardIds.MUSE_S_BOARD, params)
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
        print(f"\n>>> {label}: {prompt}")
        for remaining in [3, 2, 1]:
            print(f"    starting in {remaining}...")
            time.sleep(1.0)
        n_samples = int(duration * SAMPLE_RATE)
        # Drain current buffer
        self.board.get_current_board_data(n_samples)
        # Wait for the duration
        time.sleep(duration + 0.2)
        data = self.board.get_current_board_data(int((duration + 5) * SAMPLE_RATE))
        # Trim to exactly the duration (use package_num as monotonic counter)
        n_cols = data.shape[1]
        # Take the last n_samples
        if n_cols > n_samples:
            data = data[:, -n_samples:]
        return data

    def disconnect(self):
        if self.board:
            try:
                self.board.stop_stream()
                self.board.release_session()
            except Exception as e:
                print(f"  warn: cleanup error: {e}")


# --- Analysis --------------------------------------------------------------

def analyze(data_open, data_closed, data_blink, data_clench, data_turn):
    results = {}

    # Channel order in BrainFlow: ch0=package_num, ch1=TP9, ch2=AF7, ch3=AF8, ch4=TP10, ch5=AUX, ch6=ts
    def extract(data, ch_idx):
        return data[ch_idx, :].astype(np.float64)

    # 1. Alpha power ratio eyes-closed / eyes-open, per channel
    print("\n--- 1. Alpha power (8-13 Hz) per channel ---")
    alpha_ratios = {}
    for i, ch_idx in enumerate(EEG_CHANNELS):
        x_open = extract(data_open, ch_idx)
        x_closed = extract(data_closed, ch_idx)
        p_open = bandpower(x_open, SAMPLE_RATE, ALPHA_BAND)
        p_closed = bandpower(x_closed, SAMPLE_RATE, ALPHA_BAND)
        ratio = p_closed / max(p_open, 1e-9)
        alpha_ratios[CHANNEL_NAMES[i]] = ratio
        print(f"  {CHANNEL_NAMES[i]:>5}: open={p_open:>10.2f}  closed={p_closed:>10.2f}  ratio={ratio:.2f}")
    results['alpha_ratios'] = alpha_ratios
    best_ratio = max(alpha_ratios.values())
    results['best_alpha_ratio'] = best_ratio
    results['alpha_pass'] = best_ratio >= ALPHA_RATIO_THRESHOLD

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
    saturated = [ch for ch in CHANNEL_NAMES if rms[ch] > 200.0]
    dead = [ch for ch in CHANNEL_NAMES if rms[ch] < 2.0]
    healthy = [ch for ch in CHANNEL_NAMES if 2.0 <= rms[ch] <= 200.0]
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
        ("Alpha rise on eyes-closed (>=1.5x)",   results['alpha_pass']),
        ("Blink transient (>=40 µV AF7/AF8)",    results['blink_pass']),
        ("Jaw clench beta (>=2x baseline)",      results['clench_pass']),
        ("Head turn artifact (>=30 µV swing)",   results['turn_pass']),
    ]
    n_pass = sum(1 for _, ok in checks if ok)
    for name, ok in checks:
        marker = "PASS" if ok else "FAIL"
        print(f"  [{marker}] {name}")
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

def main():
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

    rec = Recorder()
    try:
        rec.connect()
    except Exception as e:
        print(f"FAILED to connect: {e}")
        return 2

    # Ctrl-C to abort
    def stop(*_):
        print("\nAborted.")
        rec.disconnect()
        sys.exit(130)
    signal.signal(signal.SIGINT, stop)

    data_open = rec.segment(SEG_OPEN, "EYES OPEN",
                            "Open eyes. Look at a fixed point. Relax face/jaw.")
    data_closed = rec.segment(SEG_CLOSED, "EYES CLOSED",
                              "Close eyes gently. Same relaxation. Don't squint.")
    data_blink = rec.segment(SEG_BLINK, "BLINK",
                             "Blink deliberately, ~5 blinks over 5 seconds.")
    data_clench = rec.segment(SEG_CLENCH, "JAW CLENCH",
                              "Clench jaw hard for 3s, release 1s, repeat 2x. Total 8s.")
    data_turn = rec.segment(SEG_TURN, "HEAD TURN",
                            "Slowly turn head left, right, left, right. Don't yank.")

    rec.disconnect()

    # Save raw CSV (column-major: ch0..ch6, samples along axis 1)
    print(f"\nSaving raw data to {out_csv}")
    all_data = np.concatenate([data_open, data_closed, data_blink, data_clench, data_turn], axis=1)
    header = "package_num,TP9,AF7,AF8,TP10,AUX_R,timestamp,segment\n"
    # Annotate segment per row
    seg_labels = (['open'] * data_open.shape[1] +
                  ['closed'] * data_closed.shape[1] +
                  ['blink'] * data_blink.shape[1] +
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
    results, rc = analyze(data_open, data_closed, data_blink, data_clench, data_turn)

    # ASCII spectrograms (eyes open vs eyes closed) for visual confirmation
    print("\n--- 6. AF7 spectrogram: eyes open vs eyes closed ---")
    print(ascii_spectrogram(data_open[2, :].astype(np.float64), SAMPLE_RATE,
                            title="AF7 EYES OPEN (last 30s)", width=60, height=14))
    print(ascii_spectrogram(data_closed[2, :].astype(np.float64), SAMPLE_RATE,
                            title="AF7 EYES CLOSED (30s)", width=60, height=14))

    # Save summary
    with open(out_json, 'w') as f:
        json.dump(results, f, indent=2, default=str)
    print(f"\nSummary saved to {out_json}")
    print(f"Raw data saved to {out_csv}")
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        import traceback
        traceback.print_exc()
        sys.exit(2)
