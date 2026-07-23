# NeuralComposeEEG

`NeuralComposeEEG` is an offline, local-only benchmark for
`EXP-NC-EEG-ENC-001`. It evaluates whether representations derived from the
four Muse channels (`TP9`, `AF7`, `AF8`, `TP10`) improve *observable* state
classification across complete recording sessions. It is not an application
runtime, a thought decoder, a dialogue-policy component, or a live BCI
controller.

The benchmark is deliberately separate from `Sources/`. Raw EEG remains under
the repository's ignored `Recordings/` policy; generated waveform archives,
checkpoints, and reports are also local-only.

## Scope

The primary comparison is:

- `M0`: deterministic spectral/signal-quality features plus logistic
  regression;
- `M1`: EEGNet trained from scratch;
- `M2`: an EEGPT-shaped random-initialization control, run with the same
  fold-local four-channel adapter and linear head as M3;
- `M3`: a frozen EEGPT representation with an explicit four-channel adapter
  and missing-channel mask;
- `M4`: a frozen BENDR convolutional feature encoder with the same fold-local
  adapter and linear-head contract.

`M2`, `M3`, and `M4` have runnable, provenance-bound workers. M4 deliberately
uses BENDR's official frozen convolutional feature encoder only, not its
legacy contextualizer stack. A pretrained result is only accepted when its
artifact records the checkpoint hash, model revision, channel adapter,
missing-channel handling, and exact source dataset hash. Zero-filled, unmasked
montage expansion is a labelled negative control, never a transfer result.

A fixed preprocessing path may be evaluated as a local linear probe from a
provenance-bound embedding matrix. A learned four-channel input adapter is
different: it must be fit separately inside every grouped training partition.
Those workers return fold-scoped held-out probabilities, never an embedding
matrix trained once on the full corpus.

Every condition uses the versioned fixed budget in
[`configs/experiment-v0.json`](configs/experiment-v0.json). M0/M1 and all
external workers attest to that configuration's content hash; the local
verifier and final ledger reject a condition using another budget. Worker flags
may repeat a pinned value for legibility, but cannot override it. Every
evaluation report also carries peak process memory, training time,
per-window latency, estimated checkpoint size, and an explicit deployment
state. Core ML conversion and CPU/GPU/Neural Engine placement remain
`not_attempted` / `not_measured` until an evidence-selected compact candidate
exists.

## Canonical input

Create a local source manifest from
[`configs/source-manifest.example.json`](configs/source-manifest.example.json).
It must describe immutable files and observable task blocks. The builder
requires:

- exactly four Muse channels at 256 Hz;
- four-second windows (1,024 samples), one-second stride;
- a calibration block that ends before any task block;
- session, participant, date, block, signal-quality, and label provenance;
- timestamp continuity; windows crossing a packet-loss gap are rejected;
- a missing-channel mask for every window.

The current converted validation sessions are useful plumbing inputs, but are
not evidence until their collection metadata is reconstructed and reviewed.
Their legacy `segments.csv` files do not satisfy this manifest contract.

## Local workflow

```sh
cd NeuralComposeEEG
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt

PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.build_dataset \
  --manifest local-manifests/muse-pilot.json \
  --output data/muse-pilot-v0.npz \
  --metadata-output data/muse-pilot-v0.json

PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.evaluate \
  --dataset data/muse-pilot-v0.npz \
  --metadata data/muse-pilot-v0.json \
  --models m0,m1 \
  --output artifacts/muse-pilot-evaluation-v0.json
```

All `EXP-NC-EEG-ENC-001` output is explicitly `insufficient_evidence` during
the pilot. It is shadow-only and cannot promote a model into NeuralCompose.

## Capture To Manifest

Start the frozen app's local Muse recording first and wait for live samples,
then run its cue helper in a separate terminal. The capture must remain a live
local Muse session: synthetic, playback, OSC, and any stalled, reconnected, or
fallback-degraded recording are ineligible. The hard-blink tags and fixed
eight-second gaps happen before each logged `start_unix`, so they are not
labelled as the following state. Finish every helper block before stopping
recording in the app; the compiler refuses a reused, incomplete, or manually
repaired timing log.

```sh
cd ..
python3 Scripts/run-session-protocol.py --preset encoder-pilot \
  --listening-audio "$HOME/Documents/NeuralCompose/Stimuli/neutral-listening-v1.wav" \
  --listening-audio-id "nc-eeg-neutral-listening-v1"

cd NeuralComposeEEG
# Complete a local capture index from configs/capture-index.example.json.
# A single clean recording can pass integrity validation but cannot yet be a
# benchmark cohort.
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.capture_manifest \
  --capture-index local-manifests/capture-index.json \
  --integrity-output local-manifests/capture-integrity-first.json

# After a second clean capture on a distinct UTC recording date, compile the
# source manifest used for dataset windows and grouped evaluation.
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.capture_manifest \
  --capture-index local-manifests/capture-index.json \
  --output local-manifests/muse-pilot.json
```

The compiler accepts only completed `encoder-pilot-v1` logs with these pinned
durations: 60 s eyes-open, 45 s eyes-closed, 30 s each artifact block, then 60
s listening, speaking, and recovery. It verifies eight-second unlabeled gaps,
script/audio identifiers and checksums, explicit block ends, and recorded
activity instructions. It refuses synthetic/degraded transport, any transport
event, missing Muse montage, unknown rate, dry-run or incomplete protocols,
overlapping blocks, and segments shorter than four seconds. It stores only
local paths in the ignored manifest; generated benchmark metadata keeps hashes
instead of those paths.

It also requires the recorder's explicit `eeg_timestamp_clock` metadata. New
recordings contain either an epoch coordinate or a first-sample wall-clock
anchor for a stream-relative coordinate; old recordings without that evidence
are intentionally not protocol-aligned retrospectively.

`--integrity-output` answers whether each non-excluded local capture is
complete, aligned, and trustworthy. It may report one clean session as
`integrity_valid: true` while keeping `experiment_eligible: false` with
`insufficient_session_count`. `--output` is stricter: it requires at least two
clean, stimulus-matched sessions from at least two distinct UTC recording
dates before it emits an evaluation source manifest.

The first session is capture-pipeline evidence only: run the compiler, window
builder, integrity report, and deterministic replay check, but do not train an
encoder. Two eligible dates permit M0/M1 as `insufficient_evidence`; add more
days before interpreting held-out-session performance. Qwen, Gemma, ARC, and
all live model-driven behavior remain outside this acquisition experiment.

The pilot uses `--split-unit session`. Once the cohort supports it, the same
evaluator can use `recording_date`, `participant`, `device`, or `headset_fit`
without ever splitting one recording session across train and test.

## Frozen-representation handoff

Kaggle and Colab workers must write an `.npz` containing `raw_window_hashes`
and `embeddings`, plus a JSON file with schema
`nc-eeg-external-embeddings-v0`. The JSON is required to bind the vectors to
the canonical `dataset_sha256`, model revision/checkpoint hash, initialization,
channel adapter, and missing-channel mask. The local grouped probe is then:

For EEGPT, use the repository's pinned
[`eegpt-58ch-montage-v0.json`](configs/eegpt-58ch-montage-v0.json) and
`eegpt_adapter.py`. The adapter records the unavoidable Muse-to-pretraining
montage approximation and makes an explicit missing-target mask part of the
trainable A1/A3 input path. The zero-fill version is only the A4 control.

The learned-adapter path is M2/M3. It requires a checkout of the pinned EEGPT
revision and emits only fold-held-out probabilities. Run it once with
`--initialization random` for M2 and once with the verified checkpoint for M3;
the local verifier is still the authority for metrics:

```sh
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.run_eegpt_fold_worker \
  --dataset data/muse-pilot-v0.npz --metadata data/muse-pilot-v0.json \
  --upstream-root /path/to/EEGPT --initialization random \
  --predictions-output artifacts/eegpt-random-fold-probabilities.npz \
  --metadata-output artifacts/eegpt-random-fold-provenance.json

PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.evaluate_external_fold_predictions \
  --dataset data/muse-pilot-v0.npz --metadata data/muse-pilot-v0.json \
  --predictions artifacts/eegpt-random-fold-probabilities.npz \
  --prediction-metadata artifacts/eegpt-random-fold-provenance.json \
  --split-unit session \
  --output artifacts/eegpt-random-fold-evaluation-v0.json
```

The worker reads `configs/experiment-v0.json` by default. Use
`--experiment-config` only to name an equivalent, reviewed configuration; the
worker rejects a different `--epochs`, `--batch-size`, `--learning-rate`, or
`--seed`. The evaluator verifies the returned configuration hash before it
calculates metrics.

For M3, replace `--initialization random` with
`--initialization pretrained --checkpoint /path/to/eegpt_mcae_58chs_4s_large4E.ckpt`
and use distinct output names. The worker refuses an unpinned upstream checkout
or a mismatched checkpoint geometry.

M4 requires the pinned BENDR `encoder.pt` named in
[`bendr-20ch-v0.json`](configs/bendr-20ch-v0.json). It strictly verifies that
file's SHA-256 and architecture before evaluating its frozen convolutional
features. This is an encoder-only BENDR comparator; it does not silently
substitute the unavailable contextualizer release asset or introduce DN3 as a
workspace dependency.

```sh
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.run_bendr_fold_worker \
  --dataset data/muse-pilot-v0.npz --metadata data/muse-pilot-v0.json \
  --initialization pretrained --checkpoint /path/to/encoder.pt \
  --predictions-output artifacts/bendr-frozen-fold-probabilities.npz \
  --metadata-output artifacts/bendr-frozen-fold-provenance.json

PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.evaluate_external_fold_predictions \
  --dataset data/muse-pilot-v0.npz --metadata data/muse-pilot-v0.json \
  --predictions artifacts/bendr-frozen-fold-probabilities.npz \
  --prediction-metadata artifacts/bendr-frozen-fold-provenance.json \
  --split-unit session \
  --output artifacts/bendr-frozen-fold-evaluation-v0.json
```

Run the same command with `--initialization random` and no checkpoint for the
matched random BENDR control. Both M4 artifacts remain pilot-only.

Mapped and falsification controls use the deterministic extractor plus the
same grouped linear probe. `canonical` is A2, `shuffled` is the electrode-map
negative control, and `zero_fill` is A4. The mapped variants append the
explicit 58-target missing-electrode mask to the frozen representation before
the fold-local probe; A4 deliberately omits it.

```sh
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.extract_eegpt_fixed_embeddings \
  --dataset data/muse-pilot-v0.npz --metadata data/muse-pilot-v0.json \
  --upstream-root /path/to/EEGPT \
  --initialization pretrained --checkpoint /path/to/eegpt_mcae_58chs_4s_large4E.ckpt \
  --condition shuffled \
  --embeddings-output artifacts/eegpt-shuffled-embeddings.npz \
  --metadata-output artifacts/eegpt-shuffled-embeddings.json
```

```sh
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.evaluate_external_probe \
  --dataset data/muse-pilot-v0.npz --metadata data/muse-pilot-v0.json \
  --embeddings artifacts/eegpt-frozen-embeddings.npz \
  --embedding-metadata artifacts/eegpt-frozen-embeddings.json \
  --split-unit session \
  --output artifacts/eegpt-frozen-probe-v0.json
```

An `eegpt` or `bendr` result with `zero_filled_no_mask_negative_control` is
retained only as a negative control. The loader refuses to call it transfer.

For the actual learned-adapter conditions, an external worker must instead
emit one probability row for every canonical window plus fold provenance that
binds the adapter fit to the corresponding training hashes:

```sh
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.evaluate_external_fold_predictions \
  --dataset data/muse-pilot-v0.npz --metadata data/muse-pilot-v0.json \
  --predictions artifacts/eegpt-fold-probabilities.npz \
  --prediction-metadata artifacts/eegpt-fold-provenance.json \
  --split-unit session \
  --output artifacts/eegpt-fold-evaluation-v0.json
```

Finally, assemble the M0/M1 and external reports. The ledger rejects reports
with a different canonical dataset or grouped split manifest, records random
initialization and mapping-control coverage, and remains non-promotable:

```sh
PYTHONPATH=src .venv/bin/python -m neuralcompose_eeg.compare_encoder_conditions \
  --local-evaluation artifacts/muse-pilot-evaluation-v0.json \
  --external-evaluation artifacts/eegpt-random-fold-evaluation-v0.json \
  --external-evaluation artifacts/eegpt-frozen-fold-evaluation-v0.json \
  --external-evaluation artifacts/eegpt-shuffled-control-v0.json \
  --external-evaluation artifacts/eegpt-zero-fill-control-v0.json \
  --output artifacts/encoder-comparison-v0.json
```

## Tests

```sh
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

The tests exercise the failure modes that would otherwise make an EEG result
look better than it is: malformed source rejection, held-out-session leakage,
overlap across a split, packet-loss censoring, calibration-only normalization,
and provenance requirements for external representations.
