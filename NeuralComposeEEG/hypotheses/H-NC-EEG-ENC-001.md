# H-NC-EEG-ENC-001

**Claim.** Frozen pretrained EEG representations, used with an explicit
four-channel adapter and missing-channel mask, improve at least one
preregistered held-out-session outcome over deterministic features, EEGNet,
and their matched random-initialization or mapping controls.

**Primary outcomes.** Macro F1 or balanced accuracy, AUROC where defined,
Brier score, expected calibration error, artifact sensitivity/specificity, and
cross-session performance degradation.

**Falsifiers.** The pretrained condition does not improve held-out sessions;
loses to its random-initialization or shuffled-mapping control; depends on
zero-filled unmasked channels; reduces artifact detection; or worsens
calibration. A within-session-only benefit is not transfer evidence.

**Status.** Proposed. The current pilot evaluates dataset integrity and
execution, not generalized EEG understanding.
