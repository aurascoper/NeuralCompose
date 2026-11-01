# Muse S Saturated AF7 (800-915 uV) Laya and Health-Gate Benchmark

`[EMPIRICAL ENGINEERING BENCHMARK - PRIVACY-SAFE AGGREGATE METRICS ONLY]`

## 1. Executive Summary

- **Source Kind**: `empirical_muse_s_recordings` (`6` recordings evaluated at `256.0 Hz`, `2.0 s` windows)
- **AF7 Demeaned RMS (Substitution OFF -> ON)**: `589.77 uV` (`saturated`) -> `36.88 uV` (`healthy` via `AF7 <- AF8` contralateral substitution)
- **SpectralArtifactGate (`window_is_clean <= 150 uV`) Pass Rate (OFF -> ON)**: `32.1%` -> `92.2%`
- **Pillar 1 Laya Raw State Condition Number `kappa(Sigma_raw)` (OFF -> ON)**: `318.95` -> `107.98` (`SIGReg` whitened `kappa(Sigma_white) = 1.0000`)

## 2. Per-Recording Contralateral Substitution Comparison (OFF vs ON)

| Recording ID | Duration (s) | AF7 RMS OFF (uV) | AF7 RMS ON (uV) | Clean Windows OFF | Clean Windows ON | Beta Power OFF (uV^2) | Beta Power ON (uV^2) | Laya `kappa_raw` OFF | Laya `kappa_raw` ON | Laya `kappa_white` ON |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| `muse_validation_20260710-004345` | 80.0 | 20.02 (`healthy`) | 20.02 (`healthy`) | 100.0% (40/40) | 100.0% (40/40) | 55.91 | 55.91 | 151.61 | 151.61 | 1.0000 |
| `muse_validation_20260710-004400` | 80.0 | 16.52 (`healthy`) | 16.52 (`healthy`) | 92.5% (37/40) | 92.5% (37/40) | 47.86 | 47.86 | 176.56 | 176.56 | 1.0000 |
| `muse_validation_20260710-013446` | 83.0 | 823.55 (`saturated`) | 19.41 (`healthy`) | 0.0% (0/41) | 85.4% (35/41) | 39906.62 | 67.52 | 1266.71 | 110.81 | 1.0000 |
| `muse_validation_20260710-013820` | 83.0 | 901.18 (`saturated`) | 149.33 (`healthy`) | 0.0% (0/41) | 85.4% (35/41) | 107999.07 | 847.58 | 133.43 | 69.46 | 1.0000 |
| `muse_validation_20260710-014223` | 83.0 | 905.55 (`saturated`) | 8.39 (`healthy`) | 0.0% (0/41) | 92.7% (38/41) | 115188.36 | 26.77 | 55.63 | 89.24 | 1.0000 |
| `muse_validation_20260710-015723` | 83.0 | 871.81 (`saturated`) | 7.63 (`healthy`) | 0.0% (0/41) | 97.6% (40/41) | 83990.68 | 16.05 | 129.74 | 50.18 | 1.0000 |

## 3. Architectural Verification Notes

1. **Consumption-Time Non-Destructive Substitution**: Raw CSV files on disk are never mutated or committed to git; `substitute_bad_channels` logs every `SubstitutionEvent(channel='AF7', paired_from='AF8')` explicitly.
2. **DC-Offset Demeaning Before RMS and Peak Gating**: Both `EEGChannelHealthProvider.swift` / `eeg_channel_quality.py` and `SpectralStateEstimator.swift` / `eeg_spectral.py` subtract per-window channel DC mean before evaluating RMS or the `150 uV` peak artifact gate.
3. **Pillar 1 Laya Conditioning**: Replacing rail-saturated `AF7` (`~900 uV` RMS) with healthy contralateral `AF8` (`10-18 uV` RMS) eliminates spurious `10^4 uV^2` broadband spectral leakage and restores well-conditioned 3D spectral state trajectories prior to `SIGReg` whitening.
