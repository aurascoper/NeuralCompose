# Pretrained Encoder Adapter Contract

EEGPT and BENDR never receive an implicit four-to-many electrode expansion.
Every external embedding artifact must name one of these conditions:

| ID | Condition | Interpretation |
| --- | --- | --- |
| A0 | Four Muse channels, trained from scratch | Architecture baseline |
| A1 | Four channels projected through a learned adapter | Candidate transfer path |
| A2 | Approximate electrode identities plus explicit missing-channel mask | Candidate transfer sensitivity |
| A3 | Four observed channels plus explicit missing mask | Required for frozen representation claims |
| A4 | Zero-filled pretrained montage with no mask | Negative control only |

## Pinned EEGPT montage

[`configs/eegpt-58ch-montage-v0.json`](configs/eegpt-58ch-montage-v0.json)
pins the official EEGPT repository revision and its 58-channel, 256 Hz,
four-second geometry. That pretraining montage does **not** contain Muse's
`AF7`, `AF8`, `TP9`, or `TP10`. The fixed A2 approximation is therefore
explicit, not an electrode-identity claim:

| Muse source | EEGPT target | Status |
| --- | --- | --- |
| `TP9` | `TP7` | nearest listed temporal-parietal target |
| `AF7` | `AF3` | nearest listed frontal target |
| `AF8` | `AF4` | nearest listed frontal target |
| `TP10` | `TP8` | nearest listed temporal-parietal target |

`eegpt_adapter.py` implements this map. `LearnedMuseToEEGPTAdapter` also
receives the observed-channel mask and adds a trainable missing-target
embedding, so unobserved electrodes do not silently look like zero-valued
measurements. It is A1/A3 and must be fit within every training fold.
`ZeroFillNoMaskControl` intentionally omits that information and is A4 only.
The shuffled order is a mandatory mapping control, not an alternate adapter.

## Pinned BENDR encoder

[`configs/bendr-20ch-v0.json`](configs/bendr-20ch-v0.json) pins BENDR
`v0.1-alpha`, its DN3 source revision, and the official `encoder.pt` SHA-256.
M4 is limited to that frozen convolutional feature encoder. The repository
does not treat the separate contextualizer checkpoint as present, and does not
make the legacy DN3 package a product or workspace dependency.

The original encoder expects the 19-channel 10-20 division plus a `SCALE`
channel. Muse does not observe most of that geometry or the original global
scale field, so the mapping is an explicit sensitivity assumption:

| Muse source | BENDR target | Status |
| --- | --- | --- |
| `TP9` | `T5` | posterior-temporal approximation |
| `AF7` | `F7` | frontal approximation |
| `AF8` | `F8` | frontal approximation |
| `TP10` | `T6` | posterior-temporal approximation |
| `SCALE` | none | represented as an explicit missing target |

`LearnedMuseToBENDRAdapter` is fit only on each fold's training windows. It
receives the Muse observation mask and adds a trainable missing-target
embedding for every unobserved BENDR position, including `SCALE`; the frozen
encoder never mistakes these positions for observed zero traces. Its M4 random
initialization condition is the required matched control for any BENDR claim.
The canonical causal calibration-zscore input is retained; this workspace does
not claim to reconstruct BENDR's original Deep1010 min-max normalization.
Therefore M4 is a transfer-sensitivity comparator, not evidence of a literal
Muse-to-BENDR montage equivalence.

The JSON provenance emitted beside a *fixed* embedding matrix must include:

```json
{
  "schema_version": "nc-eeg-external-embeddings-v0",
  "dataset_sha256": "canonical dataset hash",
  "model_id": "eegpt",
  "initialization": "pretrained",
  "model_revision": "upstream revision",
  "checkpoint_sha256": "64-character weight hash",
  "extractor_version": "adapter source revision",
  "extractor_sha256": "64-character extractor hash",
  "input_archive_sha256": "64-character canonical archive hash",
  "channel_adapter": "approximate_electrode_mapping_with_mask",
  "missing_channel_mask": "explicit",
  "adapter_training_scope": "fixed_preprocessor",
  "worker_run_manifest": {
    "platform": "kaggle|colab|macos",
    "accelerator": "actual accelerator or cpu",
    "accelerator_memory": "actual capacity or unavailable",
    "python_version": "exact Python version",
    "torch_version": "exact PyTorch version",
    "cuda_or_mps_version": "actual runtime version or unavailable",
    "available_quota": "observed quota or unavailable",
    "git_commit": "adapter source revision",
    "seed": 42
  }
}
```

The worker manifest is mandatory even for a CPU run. `unavailable` is an
explicit observation, not a missing field. It allows Kaggle, Colab, and local
workers to remain interchangeable executors while retaining their actual
runtime conditions in the returned artifact.

Every learned-adapter worker additionally records the content hash of
`configs/experiment-v0.json`, its configuration section (`m2_m3` or `m4`),
and the exact epoch, batch-size, learning-rate, and seed values. The local
fold evaluator rejects a prediction artifact with a different fixed budget.
Its runtime evidence records process peak memory, training time, per-window
inference latency, and estimated parameter size. Core ML conversion and
CPU/GPU/Neural Engine placement are explicit `not_attempted` / `not_measured`
until a candidate has earned deployment review.

`adapter_training_scope` has only two meanings:

- `fixed_preprocessor`: a non-learned mapping such as A2, A4, or the shuffled
  mapping control. Its embeddings may be handed to `evaluate_external_probe`,
  which fits only the fold-local linear probe.
- `fold_train_only`: A1's learned input adapter. It cannot be represented by
  one embedding table because fitting it over the full corpus would leak held-
  out sessions into the frozen backbone input. It must use
  `evaluate_external_fold_predictions` instead.

The fold-scoped worker returns probabilities keyed by every canonical raw
window hash and one provenance record per held-out group. Each record binds the
adapter checkpoint to the train-window hash set and test-window hash set,
declares `backbone_frozen: true`, and permits exactly
`four_channel_adapter` plus `linear_head` as trainable modules. The local
verifier rejects any mismatch before metrics are computed.

Its metadata uses `nc-eeg-external-fold-evaluation-input-v0` and nests the
same representation fields under `representation`, changing only
`channel_adapter` to `four_channel_learned_adapter` and
`adapter_training_scope` to `fold_train_only`. The `fold_provenance` array has
one record per grouped holdout with these fields:

```json
{
  "held_out_group_id": "session-id-or-group-id",
  "train_raw_window_hashes_sha256": "64-character hash",
  "test_raw_window_hashes_sha256": "64-character hash",
  "backbone_frozen": true,
  "trainable_modules": ["four_channel_adapter", "linear_head"],
  "adapter_checkpoint_sha256": "64-character hash"
}
```

`compare_encoder_conditions` then rejects reports that did not use the same
canonical dataset and split manifest. It records whether each EEGPT or BENDR
pretrained condition has a same-adapter random-initialization control and
whether shuffled-map and zero-fill controls are present. It cannot promote a
pilot result: a pretraining claim still requires the matched random-init
control, EEGNet, deterministic baseline, shuffled mapping, and zero-fill
negative control on the same dataset/splits.
