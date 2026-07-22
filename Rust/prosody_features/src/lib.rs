//! Deterministic Phase 0 prosody feature extraction.
//!
//! This crate measures audio. It does not infer mental state, choose a voice,
//! run a TTS backend, or implement a behavioral model. Swift can acquire and
//! record signals; this crate can produce stable numeric features; Julia can
//! later test hypotheses over those telemetry artifacts.

/// Configuration for mono prosody analysis.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProsodyAnalysisConfig {
    /// Non-overlapping analysis frame size. Used for pause density, voiced
    /// duration, and energy entropy.
    pub frame_duration_ms: f64,
    /// A frame whose RMS is less than or equal to this threshold is silent.
    pub silence_rms_threshold: f64,
    /// Minimum pitch lag considered by the autocorrelation confidence proxy.
    pub min_pitch_hz: f64,
    /// Maximum pitch lag considered by the autocorrelation confidence proxy.
    pub max_pitch_hz: f64,
}

impl Default for ProsodyAnalysisConfig {
    fn default() -> Self {
        Self {
            frame_duration_ms: 20.0,
            silence_rms_threshold: 0.01,
            min_pitch_hz: 60.0,
            max_pitch_hz: 400.0,
        }
    }
}

/// Optional metadata that turns acoustic timing into speech-rate features.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ProsodyAnalysisMetadata {
    /// Syllable count for the utterance, if supplied by a transcript/text
    /// pipeline. Raw audio alone cannot determine this robustly.
    pub syllable_count: Option<u32>,
}

/// Deterministic feature vector emitted by the Phase 0 kernel.
#[derive(Debug, Clone, PartialEq)]
pub struct ProsodyFeatures {
    pub sample_count: usize,
    pub sample_rate_hz: u32,
    pub duration_seconds: f64,
    pub rms: f64,
    pub pause_duration_seconds: f64,
    pub pause_density: f64,
    pub voiced_duration_seconds: f64,
    pub voicing_probability: f64,
    pub zero_crossing_rate_hz: f64,
    pub spectral_centroid_hz: Option<f64>,
    pub pitch_confidence: f64,
    pub energy_entropy: f64,
    pub speech_rate_syllables_per_second: Option<f64>,
    pub articulation_rate_syllables_per_second: Option<f64>,
}

/// Analyze mono audio without transcript-derived metadata.
pub fn analyze_mono(
    samples: &[f32],
    sample_rate_hz: u32,
    config: ProsodyAnalysisConfig,
) -> ProsodyFeatures {
    analyze_mono_with_metadata(
        samples,
        sample_rate_hz,
        config,
        ProsodyAnalysisMetadata::default(),
    )
}

/// Analyze mono audio and optional transcript-derived metadata.
pub fn analyze_mono_with_metadata(
    samples: &[f32],
    sample_rate_hz: u32,
    config: ProsodyAnalysisConfig,
    metadata: ProsodyAnalysisMetadata,
) -> ProsodyFeatures {
    let sr = sample_rate_hz.max(1);
    let clean = sanitized(samples);
    let sample_count = clean.len();
    let duration_seconds = sample_count as f64 / sr as f64;

    let rms = root_mean_square(&clean);
    let zero_crossing_rate_hz = if duration_seconds > 0.0 {
        zero_crossings(&clean) as f64 / duration_seconds
    } else {
        0.0
    };

    let frame_len = frame_len_samples(sr, config.frame_duration_ms);
    let frames = frame_rms_values(&clean, frame_len);
    let silent_frames = frames
        .iter()
        .filter(|frame| frame.rms <= config.silence_rms_threshold)
        .count();
    let pause_density = ratio(silent_frames, frames.len());
    let pause_duration_seconds = frames
        .iter()
        .filter(|frame| frame.rms <= config.silence_rms_threshold)
        .map(|frame| frame.sample_count as f64 / sr as f64)
        .sum::<f64>();
    let voiced_duration_seconds = (duration_seconds - pause_duration_seconds).max(0.0);
    let voicing_probability = 1.0 - pause_density;

    let speech_rate_syllables_per_second = metadata
        .syllable_count
        .and_then(|count| per_second(count, duration_seconds));
    let articulation_rate_syllables_per_second = metadata
        .syllable_count
        .and_then(|count| per_second(count, voiced_duration_seconds));

    ProsodyFeatures {
        sample_count,
        sample_rate_hz: sr,
        duration_seconds,
        rms,
        pause_duration_seconds,
        pause_density,
        voiced_duration_seconds,
        voicing_probability,
        zero_crossing_rate_hz,
        spectral_centroid_hz: spectral_centroid_hz(&clean, sr),
        pitch_confidence: pitch_confidence(&clean, sr, config.min_pitch_hz, config.max_pitch_hz),
        energy_entropy: normalized_energy_entropy(&frames),
        speech_rate_syllables_per_second,
        articulation_rate_syllables_per_second,
    }
}

#[derive(Debug, Clone, Copy)]
struct FrameRms {
    rms: f64,
    sample_count: usize,
}

fn sanitized(samples: &[f32]) -> Vec<f64> {
    samples
        .iter()
        .map(|sample| {
            let value = *sample as f64;
            if value.is_finite() {
                value
            } else {
                0.0
            }
        })
        .collect()
}

fn frame_len_samples(sample_rate_hz: u32, frame_duration_ms: f64) -> usize {
    if !frame_duration_ms.is_finite() || frame_duration_ms <= 0.0 {
        return 1;
    }
    ((sample_rate_hz as f64 * frame_duration_ms / 1000.0).round() as usize).max(1)
}

fn root_mean_square(samples: &[f64]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let energy = samples.iter().map(|sample| sample * sample).sum::<f64>();
    (energy / samples.len() as f64).sqrt()
}

fn zero_crossings(samples: &[f64]) -> usize {
    if samples.len() <= 1 {
        return 0;
    }
    samples
        .windows(2)
        .filter(|pair| (pair[0] >= 0.0) != (pair[1] >= 0.0))
        .count()
}

fn frame_rms_values(samples: &[f64], frame_len: usize) -> Vec<FrameRms> {
    if samples.is_empty() {
        return Vec::new();
    }
    samples
        .chunks(frame_len.max(1))
        .map(|chunk| FrameRms {
            rms: root_mean_square(chunk),
            sample_count: chunk.len(),
        })
        .collect()
}

fn ratio(numerator: usize, denominator: usize) -> f64 {
    if denominator == 0 {
        0.0
    } else {
        numerator as f64 / denominator as f64
    }
}

fn per_second(count: u32, duration_seconds: f64) -> Option<f64> {
    if duration_seconds > 0.0 {
        Some(count as f64 / duration_seconds)
    } else {
        None
    }
}

fn normalized_energy_entropy(frames: &[FrameRms]) -> f64 {
    if frames.len() <= 1 {
        return 0.0;
    }
    let energies: Vec<f64> = frames.iter().map(|frame| frame.rms * frame.rms).collect();
    let total = energies.iter().sum::<f64>();
    if total <= 0.0 || !total.is_finite() {
        return 0.0;
    }
    let entropy = energies
        .iter()
        .filter(|energy| **energy > 0.0)
        .map(|energy| {
            let p = energy / total;
            -p * p.log2()
        })
        .sum::<f64>();
    let max_entropy = (frames.len() as f64).log2();
    if max_entropy > 0.0 {
        (entropy / max_entropy).clamp(0.0, 1.0)
    } else {
        0.0
    }
}

fn spectral_centroid_hz(samples: &[f64], sample_rate_hz: u32) -> Option<f64> {
    let n = samples.len();
    if n < 2 || root_mean_square(samples) == 0.0 {
        return None;
    }

    let mut weighted = 0.0;
    let mut magnitude_sum = 0.0;
    let half = n / 2;
    for k in 1..=half {
        let mut real = 0.0;
        let mut imag = 0.0;
        for (i, sample) in samples.iter().enumerate() {
            let angle = -2.0 * std::f64::consts::PI * k as f64 * i as f64 / n as f64;
            real += sample * angle.cos();
            imag += sample * angle.sin();
        }
        let magnitude = (real * real + imag * imag).sqrt();
        let frequency = k as f64 * sample_rate_hz as f64 / n as f64;
        weighted += frequency * magnitude;
        magnitude_sum += magnitude;
    }

    if magnitude_sum > 0.0 {
        Some(weighted / magnitude_sum)
    } else {
        None
    }
}

fn pitch_confidence(
    samples: &[f64],
    sample_rate_hz: u32,
    min_pitch_hz: f64,
    max_pitch_hz: f64,
) -> f64 {
    if samples.len() < 3 || root_mean_square(samples) == 0.0 {
        return 0.0;
    }
    let mean = samples.iter().sum::<f64>() / samples.len() as f64;
    let centered: Vec<f64> = samples.iter().map(|sample| sample - mean).collect();

    let min_hz = min_pitch_hz.max(1.0);
    let max_hz = max_pitch_hz.max(min_hz + f64::EPSILON);
    let min_lag = ((sample_rate_hz as f64 / max_hz).floor() as usize).max(1);
    let max_lag = ((sample_rate_hz as f64 / min_hz).ceil() as usize)
        .min(centered.len().saturating_sub(1))
        .max(min_lag);

    let mut best = 0.0;
    for lag in min_lag..=max_lag {
        let mut numerator = 0.0;
        let mut left_energy = 0.0;
        let mut right_energy = 0.0;
        for i in lag..centered.len() {
            let left = centered[i - lag];
            let right = centered[i];
            numerator += left * right;
            left_energy += left * left;
            right_energy += right * right;
        }
        let denominator = (left_energy * right_energy).sqrt();
        if denominator > 0.0 {
            let correlation = (numerator / denominator).max(0.0);
            if correlation > best {
                best = correlation;
            }
        }
    }
    best.clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(hz: f64, sample_rate_hz: u32, seconds: f64, amplitude: f64) -> Vec<f32> {
        let n = (sample_rate_hz as f64 * seconds).round() as usize;
        (0..n)
            .map(|i| {
                let t = i as f64 / sample_rate_hz as f64;
                (amplitude * (2.0 * std::f64::consts::PI * hz * t).sin()) as f32
            })
            .collect()
    }

    #[test]
    fn silence_reports_pause_without_audio_energy() {
        let samples = vec![0.0_f32; 800];
        let features = analyze_mono(&samples, 8_000, ProsodyAnalysisConfig::default());

        assert_eq!(features.sample_count, 800);
        assert_eq!(features.sample_rate_hz, 8_000);
        assert!((features.duration_seconds - 0.1).abs() < 1e-12);
        assert_eq!(features.rms, 0.0);
        assert_eq!(features.pause_density, 1.0);
        assert!((features.pause_duration_seconds - 0.1).abs() < 1e-12);
        assert_eq!(features.voicing_probability, 0.0);
        assert_eq!(features.zero_crossing_rate_hz, 0.0);
        assert_eq!(features.spectral_centroid_hz, None);
        assert_eq!(features.pitch_confidence, 0.0);
    }

    #[test]
    fn sine_wave_reports_stable_acoustic_features() {
        let samples = sine(100.0, 8_000, 0.1, 1.0);
        let features = analyze_mono(&samples, 8_000, ProsodyAnalysisConfig::default());

        assert!(features.rms > 0.70 && features.rms < 0.71);
        assert!(features.pause_density < 0.001);
        assert!(features.voicing_probability > 0.999);
        assert!((features.zero_crossing_rate_hz - 200.0).abs() <= 20.0);
        let centroid = features
            .spectral_centroid_hz
            .expect("centroid for voiced tone");
        assert!((centroid - 100.0).abs() < 1e-3, "centroid={centroid}");
        assert!(features.pitch_confidence > 0.95);
    }

    #[test]
    fn syllable_metadata_produces_speech_and_articulation_rates() {
        let samples = sine(120.0, 8_000, 1.0, 0.5);
        let features = analyze_mono_with_metadata(
            &samples,
            8_000,
            ProsodyAnalysisConfig::default(),
            ProsodyAnalysisMetadata {
                syllable_count: Some(4),
            },
        );

        assert_eq!(features.speech_rate_syllables_per_second, Some(4.0));
        assert_eq!(features.articulation_rate_syllables_per_second, Some(4.0));
    }

    #[test]
    fn pause_density_tracks_silent_frames() {
        let mut samples = sine(100.0, 8_000, 0.1, 1.0);
        samples.extend(vec![0.0_f32; 800]);
        let features = analyze_mono(&samples, 8_000, ProsodyAnalysisConfig::default());

        assert!((features.duration_seconds - 0.2).abs() < 1e-12);
        assert!((features.pause_density - 0.5).abs() < 1e-12);
        assert!((features.pause_duration_seconds - 0.1).abs() < 1e-12);
        assert!((features.voiced_duration_seconds - 0.1).abs() < 1e-12);
    }

    #[test]
    fn analysis_is_deterministic_for_same_input() {
        let samples = sine(180.0, 8_000, 0.08, 0.3);
        let config = ProsodyAnalysisConfig {
            silence_rms_threshold: 0.02,
            ..ProsodyAnalysisConfig::default()
        };

        let a = analyze_mono(&samples, 8_000, config);
        let b = analyze_mono(&samples, 8_000, config);

        assert_eq!(a, b);
    }

    #[test]
    fn non_finite_samples_are_deterministically_zeroed() {
        let samples = vec![0.0_f32, f32::NAN, f32::INFINITY, -1.0, 1.0];
        let features = analyze_mono(&samples, 1_000, ProsodyAnalysisConfig::default());

        assert_eq!(features.sample_count, 5);
        assert!(features.rms.is_finite());
        assert!(features.zero_crossing_rate_hz.is_finite());
    }
}
