# Phase 3.6 — Multi-Modal Embedding Bridge (EEG → text-aligned latent)

## Objective

Begin the shift from **discrete** EEG intent classification (the CoreML CNN → 5
classes) to a **continuous latent** representation: a lightweight MLX encoder that
projects a rolling 2-second, 4-channel EEG window into a 384-d vector *aligned with
a text embedding space* (BGE-small-en-v1.5). This latent is the substrate later
phases build on — Phase 4.0 (translate live signal state into LLM prompt
modulation), 4.5 (log signal↔response tuples), 5.0 (sequential state tracking).

Not to be confused with the deferred **RQ5 "joint embeddings"** work
(`STAGE_3_4_3_5_DESIGN.md`), which fuses multiple *text↔text* model spaces. This is
*cross-modal* EEG↔text.

## What the target text is (and why)

Each window's text target is a **spectral state descriptor** derived
self-supervised from that window's own Power Spectral Density:

```
window[4,512] → welch_band_powers → spectral_ratios → descriptor_for_ratios → one of STATE_DESCRIPTORS
```

The descriptor vocabulary (`Scripts/eeg_spectral.py::STATE_DESCRIPTORS`) is a small
closed set, e.g. *"relaxed wakefulness, alpha-dominant brain activity"*,
*"engaged and focused, beta-dominant brain activity"*, *"drowsy and fatigued,
theta-dominant low-frequency brain activity"*. Each phrase is encoded once by BGE
into a 384-d unit vector — the **text anchor** for that state.

Chosen over two alternatives:
- **Intent-label text** — defensible signal on this montage (EMG/EOG are large), but
  only ~5 unique targets and it recasts existing discrete classification.
- **Imagined-word semantics (Track B)** — the path project memory flags as
  scientifically thin on the 4-ch Muse montage (misses Broca's area / T7); requires a
  pre-registration gate. Deferred.

Spectral descriptors are **self-supervised** (labels come from the PSD, not manual
annotation), so training scales to arbitrary recordings — including long passive
sessions — and the target space is the *same* BGE space the live app already uses,
so the latent bridges directly into Phase 4.0's prompt prefixes.

## Honesty framing (load-bearing)

- The descriptor is a **deterministic function of the window's own PSD**. This
  milestone therefore validates the **cross-modal bridge/plumbing and a text-aligned
  continuous latent** — *not* a novel decoding capability. The encoder is essentially
  learning to re-express its own band structure in a text-aligned space.
- Descriptors are **primarily spectral** ("alpha-dominant"). The cognitive adjectives
  ("high cognitive load", "fatigue") are a clearly-labeled **heuristic gloss** so the
  BGE embeddings read naturally as prompt prefixes — they are **not** a validated
  cognitive-state classifier. Band powers on a 4-electrode montage are physically
  real; the state-word mapping is an interpretive convenience the montage owner tunes
  in `descriptor_for_ratios`.
- We never fabricate the text space: `build_anchors` refuses to run without real BGE
  unless `--allow-fake-anchors` is passed, and that path is loudly logged and stamped
  `target_space: "random-fallback (NOT bge)"` in metadata. Mirrors the
  `GenerationEval`/`SemanticEval` "use the real BGE space or omit the number" rule.

## Alignment objective

Contrastive **classification against the fixed text anchors**: for each window,
`logits = (Z · Aᵀ) / τ` over the `STATE_DESCRIPTORS` anchors `A`, cross-entropy to
the window's descriptor index. Exactly one correct anchor per window ⇒ no
false-negative degeneracy (the failure mode a naive in-batch InfoNCE hits when many
windows share a descriptor), and **retrieval@1 = argmax(Z · Aᵀ)** falls out for free.
`Z` (encoder output) and `A` (BGE anchors) are both L2-normalized, so the dot product
is cosine similarity — the same geometry as `Embedding.cosineSimilarity` in Swift.

## Encoder

`Scripts/train_joint_embedding.py::SpectralEncoder` — MLX 1-D CNN.
**Input layout is channels-last `[batch, samples, channels]`** (MLX `nn.Conv1d`
convention; windows are stored `[channels, samples]` and transposed before entry —
the #1 shape trap, explicitly tested). Conv1d(4→32,k7,s2) → Conv1d(32→64,k5,s2) →
Conv1d(64→64,k3,s2), each ReLU → temporal mean-pool → Linear(64→384) → L2-normalize.

## Export contract → `Models/EEGEncoder/` (spec for the Phase 4.0 Swift loader)

A weight directory, mirroring the MLX LLM drop-in convention (not committed — models
live outside the repo per `CLAUDE.md`):

| File | Contents |
|------|----------|
| `encoder.safetensors` | `tree_flatten(model.parameters())` — keys `conv1.weight`, `conv1.bias`, … `proj.weight`, `proj.bias`. |
| `config.json` | Architecture: `in_channels`, `window_samples`, `sample_rate`, `out_dim`, `hidden`, `input_layout`, `bands`. Enough to reconstruct `SpectralEncoder` in Swift MLX. |
| `metadata.json` | `dimension` (384), `target_space` (`bge:…` or `random-fallback…`), `pooling` (`temporal-mean`), `descriptors` (the anchor vocabulary — Phase 4.0 re-encodes these with the live BGE), `descriptor_distribution`, `self_verify` (`shape_ok`, `unit_norm_max_dev`, `mean_cos_to_target`, `retrieval_at_1`), `git_sha`. |

Phase 4.0 note: the Swift `SpectralEncoder` must feed **channels-last** `[1, 512, 4]`
and re-encode `metadata.json.descriptors` through the app's live BGE
(`CoreMLSentenceEmbedder`) to rebuild the anchor table — the exported vectors are a
provenance record, not a runtime dependency.

## Run / verify

```sh
# unit tests (pytest-style + __main__ runner; pytest is not installed in venv)
venv/bin/python3 Tests/eval/test_joint_embedding.py

# hardware-free smoke run (real BGE from the local snapshot)
venv/bin/python3 Scripts/train_joint_embedding.py --synthetic 400 --epochs 5 \
    --bge-model Models/bge-small-en-v1.5-hf --output Models/EEGEncoder

# real training on recorded sessions (self-supervised — no labels needed)
venv/bin/python3 Scripts/train_joint_embedding.py ~/Documents/NeuralCompose/Recordings/<session>
```

## Out of scope (later phases)
Swift `SpectralEncoder`/`DynamicRouter`, prompt-prefix injection, Stage 3.5 routing
wiring (4.0/4.5); recurrent/SSM state model over logged sequences (5.0); any live or
hardware path. Phase 3.6 ships the offline trainer + exported weight directory only.
