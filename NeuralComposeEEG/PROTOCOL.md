# Muse Observable-State Acquisition Protocol

`EXP-NC-EEG-ENC-001` uses only observable calibration labels. It does not
label intention, agreement, imagined words, emotion, philosophical state, or
semantic meaning from EEG.

## One Session

Record one complete session at 256 Hz with `TP9`, `AF7`, `AF8`, and `TP10`.
Use Unix-wall-clock protocol cues for the frozen `encoder-pilot-v1` blocks:

| Block | Duration | Role |
| --- | ---: | --- |
| quiet eyes open | 60 s | calibration |
| quiet eyes closed | 45 s | task |
| intentional blink artifact | 30 s | task |
| intentional jaw/facial-muscle artifact | 30 s | task |
| slow head-motion artifact | 30 s | task |
| listening | 60 s | task |
| speaking | 60 s | task |
| recovery / quiet baseline | 60 s | task |

Every block is followed by an eight-second unlabeled transition gap. The
protocol log is authoritative for every cue, start, end, duration, and gap;
never infer alignment from filenames, file modification times, or recollection.

### Operator sequence

1. Start NeuralCompose with a live local Muse profile and confirm the app is
   running before opening its calibration recorder. Do not collect this
   experiment through synthetic, playback, OSC, or a fallback-degraded stream.
2. Start calibration recording in the app and wait for live samples to arrive.
   The recorder writes a new `calibration_*_muses` directory under
   `~/Documents/NeuralCompose/Recordings/`.
3. In a separate protocol-cue terminal, run the exact helper command below.
   Begin the first activity only after the helper's first blink-tag cue; the
   helper's explicit block start is deliberately after that cue window. The
   cue process must not edit or process EEG data.
4. Let every block complete, then stop calibration recording in the app. Do
   not reuse a protocol log for a later recording or manually edit its times.
5. Add the resulting recording directory and protocol-log path to a local
   capture index, then run `capture_manifest --integrity-output` for the
   individual capture. A rejected session is evidence about collection
   integrity, not a reason to repair its timestamps by hand.

The first capture is an engineering capture, but it must execute the complete
protocol without relaxing any gate. Afterward run only the per-capture
integrity report, window builder, and deterministic replay check. Do not train
EEGNet from one session. A second clean capture on a distinct UTC recording
date permits source-manifest compilation and M0/M1 only as pipeline evidence;
collect three or more days before interpreting held-out performance.

Capture integrity and experiment eligibility are intentionally separate.
`--integrity-output` establishes that one non-excluded capture is complete,
clock-aligned, and trustworthy. The canonical `--output` source manifest
additionally requires two or more clean sessions on two or more UTC recording
dates with pinned stimulus identity; one valid session never becomes eligible
for model evaluation by override.

Run the exact `encoder-pilot` preset. It writes an
`nc-eeg-observable-protocol-v1` log that records the activity instruction,
explicit start and end timestamps, and a completion state for every block. A
block stopped early, a dry run, a custom label sequence, or a log missing an
explicit end is ineligible for this experiment; its samples must not be
reinterpreted from the following cue time.

The listening asset is pinned before the first capture. The helper records its
identifier and SHA-256, and a later session with another identity is rejected.
Speaking always follows the versioned
[`speaking-count-1-to-20-v1.txt`](stimuli/speaking-count-1-to-20-v1.txt)
script. Changing either stimulus requires a new protocol revision.

The operator follows these fixed activities:

- eyes open: still, face forward, silent;
- eyes closed: still and silent;
- blink artifact: deliberate separated blinks;
- jaw artifact: repeated gentle jaw or facial-muscle movements with head still;
- head-motion artifact: slow deliberate side-to-side head motion, silent;
- listening: still and silent while listening to the preselected neutral audio;
- speaking: still while repeating a prepared neutral count aloud;
- recovery: still, silent, eyes-open baseline.

The calibration block must precede every task block. Its samples determine
only the held-out session's own affine normalization, as would a real
pre-task calibration. No task labels or held-out task windows may fit a global
normalizer, classifier, class weights, or selection rule.

## Multiple Sessions

Collect complete sessions on multiple days before treating the result as more
than plumbing. Store the participant ID, recording date, task block times,
signal quality, missing channels, and label provenance in the local source
manifest. Keep every window from a recording session in the same split;
one-second stride windows never cross a train/test boundary.

## Data Handling

Raw waveform CSVs remain local and ignored by Git. The builder records source
file checksums, raw-window hashes, calibration provenance, preprocessing hash,
and derived numeric arrays. It does not copy the raw source CSV path or raw
samples into a committed artifact.

The manifest compiler uses the recorded end of each completed block, leaving
blink-tag and transition intervals unlabeled. It requires an explicit EEG
timestamp clock, first-sample timestamp, first-sample Unix wall-clock anchor,
a monotonic cue mapping, and recording coverage of every completed block. It
rejects overlap, incomplete blocks, synthetic/playback/OSC sources, any
stall/reconnect/fallback event, incorrect montage/rate, missing channels,
unknown EEG clock origin, and blocks shorter than four seconds.

## Capture Index

Use [`configs/capture-index.example.json`](configs/capture-index.example.json)
for the local v1 capture index. Each source entry contains the participant,
session, recorder date and directory, protocol log, pinned Muse profile,
headset-fit identifier, protocol preset, operator notes, and
`eligible_override`. Empty `operator_notes` is valid. `eligible_override:
true` is exclusion only: it can force a session out or document a reason, but
cannot make any failed session eligible.

Keep the roles separate during collection:

1. frozen NeuralCompose operator build: live Muse acquisition only;
2. protocol-cue terminal: cues and immutable protocol log only;
3. post-capture compiler: validation and manifest creation only, with no
   timestamp repair capability.

## Decision Boundary

The pilot answers whether collection, window construction, grouping, target
variability, M0, and M1 are reproducible. It is always shadow-only. A
pretrained model earns a later confirmation attempt only after it is evaluated
against M0, EEGNet, its random-init control, channel-mapping controls, and the
unmasked-zero-fill negative control on held-out sessions.
