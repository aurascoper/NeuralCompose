#!/usr/bin/env python3
"""
train_joint_embedding.py — Phase 3.6: EEG → text-aligned spectral embedding.

Trains a lightweight MLX encoder that projects a rolling 2-second, 4-channel EEG
window into a 384-d latent vector aligned with a *text* embedding space
(BGE-small-en-v1.5). Each window's text target is a natural-language "spectral
state descriptor" derived self-supervised from that window's own PSD
(see eeg_spectral.py). Alignment is a contrastive classification of each window
against the fixed BGE embeddings of the descriptor vocabulary (cross-entropy over
text anchors) — this is the well-posed realization of "align signal embeddings to
a text space": exactly one correct anchor per window, so no false-negative
degeneracy, and retrieval@1 falls out as argmax(Z · Aᵀ).

NOT to be confused with the deferred RQ5 "joint embeddings" work
(docs/evaluation/STAGE_3_4_3_5_DESIGN.md), which fuses multiple *text↔text*
model spaces. This is *cross-modal* EEG↔text.

Output: Models/EEGEncoder/{encoder.safetensors, config.json, metadata.json},
a weight directory mirroring the MLX LLM drop-in convention. The live Swift-side
loader is Phase 4.0 (out of scope here).

Usage:
  ./Scripts/train_joint_embedding.py                     # all sessions under ~/Documents/NeuralCompose/Recordings
  ./Scripts/train_joint_embedding.py path/to/session ... # explicit sessions
  ./Scripts/train_joint_embedding.py --synthetic 400 --epochs 5   # hardware-free smoke run
  ./Scripts/train_joint_embedding.py --output Models/EEGEncoder --bge-model Models/bge-small-en-v1.5-hf
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pandas as pd

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
from mlx.utils import tree_flatten

# Sibling Scripts/ modules (robust regardless of CWD).
sys.path.insert(0, str(Path(__file__).resolve().parent))
from eeg_channel_quality import substitute_bad_channels, summarize_substitutions
from eeg_spectral import (
    welch_band_powers,
    spectral_ratios,
    descriptor_for_ratios,
    STATE_DESCRIPTORS,
    BANDS,
)

# Mirror train-intent-classifier.py's contract (eeg.csv header order, Muse S rate).
CHANNEL_LABELS = ["TP9", "AF7", "AF8", "TP10"]
EXPECTED_CHANNELS = 4
EXPECTED_SAMPLES = 512          # 2 s @ 256 Hz
EXPECTED_RATE = 256.0
OUT_DIM = 384                   # BGE-small-en-v1.5 dimensionality
TEMPERATURE = 0.07
DEFAULT_BGE = "Models/bge-small-en-v1.5-hf"


# ── Encoder ──────────────────────────────────────────────────────────────

class SpectralEncoder(nn.Module):
    """Tiny 1-D CNN over a [B, samples, channels] window → L2-normalized [B, out_dim].

    NOTE: MLX nn.Conv1d is channels-LAST ([N, L, C_in]), unlike PyTorch's
    channels-first. Windows are stored [channels, samples] on disk and must be
    transposed to [samples, channels] before entering this module.
    """

    def __init__(self, in_channels: int = EXPECTED_CHANNELS, out_dim: int = OUT_DIM, hidden: int = 64):
        super().__init__()
        self.conv1 = nn.Conv1d(in_channels, 32, kernel_size=7, stride=2, padding=3)
        self.conv2 = nn.Conv1d(32, hidden, kernel_size=5, stride=2, padding=2)
        self.conv3 = nn.Conv1d(hidden, hidden, kernel_size=3, stride=2, padding=1)
        self.proj = nn.Linear(hidden, out_dim)

    def __call__(self, x: mx.array) -> mx.array:
        x = nn.relu(self.conv1(x))
        x = nn.relu(self.conv2(x))
        x = nn.relu(self.conv3(x))
        x = mx.mean(x, axis=1)                                     # temporal global average → [B, hidden]
        x = self.proj(x)                                          # [B, out_dim]
        return x / (mx.sqrt(mx.sum(x * x, axis=-1, keepdims=True)) + 1e-8)


# ── Data ─────────────────────────────────────────────────────────────────

def _window_signal(eeg_x: np.ndarray, sr: float, window_seconds: float, stride_seconds: float) -> list[np.ndarray]:
    """Slide [N, channels] → list of [channels, EXPECTED_SAMPLES] windows.

    Mirrors train-intent-classifier.py's windowing (np.interp resample to a fixed
    512-sample grid) but is self-supervised — no events, so no per-window labels.
    """
    win_n = int(round(window_seconds * sr))
    stride_n = int(round(stride_seconds * sr))
    windows = []
    for i0 in range(0, eeg_x.shape[0] - win_n + 1, stride_n):
        block = eeg_x[i0:i0 + win_n]
        if block.shape[0] != EXPECTED_SAMPLES:
            old = np.linspace(0, block.shape[0] - 1, block.shape[0])
            new = np.linspace(0, block.shape[0] - 1, EXPECTED_SAMPLES)
            block = np.stack(
                [np.interp(new, old, block[:, c]) for c in range(EXPECTED_CHANNELS)], axis=1
            ).astype(np.float32)
        windows.append(block.T.astype(np.float32))               # [channels, samples]
    return windows


def load_session_windows(session_dir: Path) -> list[np.ndarray]:
    """Read a session's eeg.csv (+ metadata), substitute bad channels, window it.

    Supports both the live recorder's flat `eeg.csv`/`metadata.json` and the
    repo's dotted `*.eeg.csv`/`*.metadata.json` golden layout.
    """
    eeg_path = session_dir / "eeg.csv"
    if not eeg_path.exists():
        cand = sorted(session_dir.glob("*eeg.csv"))
        eeg_path = cand[0] if cand else eeg_path
    meta_path = session_dir / "metadata.json"
    if not meta_path.exists():
        cand = sorted(session_dir.glob("*metadata.json"))
        meta_path = cand[0] if cand else meta_path

    if not eeg_path.exists():
        print(f"  skip {session_dir.name}: no eeg.csv", file=sys.stderr)
        return []

    sample_rate, window_seconds, stride_seconds = EXPECTED_RATE, 2.0, 1.0
    if meta_path.exists():
        meta = json.loads(Path(meta_path).read_text())
        sample_rate = float(meta.get("sample_rate", EXPECTED_RATE))
        window_seconds = float(meta.get("window_seconds", 2.0))
        stride_seconds = float(meta.get("stride_seconds", 1.0))

    eeg = np.loadtxt(eeg_path, delimiter=",", skiprows=1, dtype=np.float64)
    if eeg.ndim == 1 or eeg.shape[0] < EXPECTED_SAMPLES:
        print(f"  skip {session_dir.name}: too few samples", file=sys.stderr)
        return []
    eeg_x = eeg[:, 1:1 + EXPECTED_CHANNELS].astype(np.float32)

    ch = CHANNEL_LABELS[:EXPECTED_CHANNELS]
    df_sub, sub_events = substitute_bad_channels(pd.DataFrame(eeg_x, columns=ch), ch, sample_rate)
    if sub_events:
        for c, info in summarize_substitutions(sub_events).items():
            print(f"  {session_dir.name}: {c} substituted from {info['substituted_from']} "
                  f"for {info['window_count']} window(s)", file=sys.stderr)
    eeg_x = df_sub.to_numpy(dtype=np.float32)

    windows = _window_signal(eeg_x, sample_rate, window_seconds, stride_seconds)
    print(f"  {session_dir.name}: {len(windows)} windows (rate={sample_rate} Hz, win={window_seconds}s)")
    return windows


def synthetic_windows(n: int, sr: float = EXPECTED_RATE, seed: int = 0) -> list[np.ndarray]:
    """Generate n windows with cycling band structure so descriptors distribute
    across the vocabulary — for hardware-free smoke tests. Returns [channels, samples]."""
    rng = np.random.default_rng(seed)
    t = np.arange(EXPECTED_SAMPLES) / sr
    profiles = [("alpha", 10.0), ("beta", 20.0), ("theta", 6.0), ("mixed", None)]
    windows = []
    for i in range(n):
        kind, freq = profiles[i % len(profiles)]
        sig = np.zeros((EXPECTED_CHANNELS, EXPECTED_SAMPLES), dtype=np.float32)
        for c in range(EXPECTED_CHANNELS):
            noise = rng.normal(0, 5.0, EXPECTED_SAMPLES)
            if kind == "mixed":
                comp = 20 * np.sin(2 * np.pi * 10 * t) + 20 * np.sin(2 * np.pi * 20 * t)
            else:
                comp = 40 * np.sin(2 * np.pi * freq * t + rng.uniform(0, 2 * np.pi))
            sig[c] = (comp + noise).astype(np.float32)
        windows.append(sig)
    return windows


def build_anchors(bge_model: str, allow_fake: bool, seed: int = 0) -> tuple[np.ndarray, str]:
    """Encode STATE_DESCRIPTORS with BGE → [n_desc, OUT_DIM] unit-norm float32.

    Refuses to silently fabricate the text space (repo convention: use the real
    BGE space or omit the number). --allow-fake-anchors is an explicit,
    loudly-logged escape hatch for offline plumbing tests only.
    """
    try:
        from sentence_transformers import SentenceTransformer
        st = SentenceTransformer(bge_model)
        embs = np.asarray(st.encode(STATE_DESCRIPTORS, normalize_embeddings=True), dtype=np.float32)
        if embs.shape[1] != OUT_DIM:
            raise ValueError(f"expected {OUT_DIM}-d BGE embeddings, got {embs.shape[1]}")
        return embs, f"bge:{bge_model}"
    except Exception as e:  # noqa: BLE001 — surface any load/encode failure the same way
        if not allow_fake:
            raise SystemExit(
                f"failed to load BGE text encoder from '{bge_model}': {e}\n"
                f"Refusing to fabricate the text target space. Pass --allow-fake-anchors "
                f"only for offline plumbing tests (results are NOT semantically meaningful).")
        print(f"WARNING: BGE unavailable ({e}); using RANDOM fake anchors — plumbing only, "
              f"NOT semantic.", file=sys.stderr)
        rng = np.random.default_rng(seed)
        a = rng.normal(size=(len(STATE_DESCRIPTORS), OUT_DIM)).astype(np.float32)
        return a / np.linalg.norm(a, axis=1, keepdims=True), "random-fallback (NOT bge)"


# ── Loss / training ──────────────────────────────────────────────────────

def _make_loss(anchors: mx.array, temperature: float):
    """Cross-entropy of each window over the fixed text anchors (unit-norm)."""
    n_desc = anchors.shape[0]

    def loss_fn(model, x, labels):
        z = model(x)                                             # [B, D] unit-norm
        logits = (z @ anchors.T) / temperature                  # [B, n_desc]
        logp = logits - mx.logsumexp(logits, axis=1, keepdims=True)
        onehot = (mx.arange(n_desc)[None, :] == labels[:, None]).astype(mx.float32)
        return -mx.mean(mx.sum(onehot * logp, axis=1))

    return loss_fn


def train_encoder(x_cl: np.ndarray, labels_np: np.ndarray, anchors_np: np.ndarray, *,
                  epochs: int, batch_size: int, lr: float, temperature: float,
                  val_frac: float, seed: int) -> tuple[SpectralEncoder, list[float]]:
    """x_cl: [N, samples, channels] channels-last float32; labels_np: [N] int."""
    mx.random.seed(seed)
    anchors = mx.array(anchors_np.astype(np.float32))
    model = SpectralEncoder(in_channels=EXPECTED_CHANNELS, out_dim=anchors_np.shape[1])
    mx.eval(model.parameters())
    opt = optim.AdamW(learning_rate=lr)
    loss_and_grad = nn.value_and_grad(model, _make_loss(anchors, temperature))

    n = x_cl.shape[0]
    rng = np.random.default_rng(seed)
    idx = rng.permutation(n)
    n_val = max(1, int(n * val_frac))
    val_idx, train_idx = idx[:n_val], idx[n_val:]
    if train_idx.size == 0:                                       # tiny datasets: train on all
        train_idx = idx

    def evaluate(sel: np.ndarray) -> tuple[float, float]:
        z = model(mx.array(x_cl[sel]))
        pred = mx.argmax(z @ anchors.T, axis=1)
        yb = mx.array(labels_np[sel].astype(np.int32))
        acc = float(mx.mean((pred == yb).astype(mx.float32)))
        anch = mx.array(anchors_np[labels_np[sel]].astype(np.float32))
        cos = float(mx.mean(mx.sum(z * anch, axis=1)))
        return acc, cos

    history = []
    for epoch in range(epochs):
        perm = rng.permutation(train_idx)
        total, nb = 0.0, 0
        for s in range(0, perm.size, batch_size):
            bidx = perm[s:s + batch_size]
            xb = mx.array(x_cl[bidx])
            yb = mx.array(labels_np[bidx].astype(np.int32))
            loss, grads = loss_and_grad(model, xb, yb)
            opt.update(model, grads)
            mx.eval(model.parameters(), opt.state)
            total += float(loss)
            nb += 1
        vacc, vcos = evaluate(val_idx)
        avg = total / max(nb, 1)
        history.append(avg)
        print(f"epoch {epoch + 1:>3}/{epochs}: loss={avg:.4f} val_retrieval@1={vacc:.3f} val_cos={vcos:.3f}")
    return model, history


def self_verify(model: SpectralEncoder, x_cl: np.ndarray, labels_np: np.ndarray,
                anchors_np: np.ndarray) -> dict:
    """Post-train sanity: output shape, unit-norm, alignment, retrieval@1."""
    anchors = mx.array(anchors_np.astype(np.float32))
    z = model(mx.array(x_cl))
    norms = mx.sqrt(mx.sum(z * z, axis=1))
    pred = mx.argmax(z @ anchors.T, axis=1)
    yb = mx.array(labels_np.astype(np.int32))
    anch = mx.array(anchors_np[labels_np].astype(np.float32))
    return {
        "shape_ok": bool(z.shape[0] == x_cl.shape[0] and z.shape[1] == anchors_np.shape[1]),
        "unit_norm_max_dev": float(mx.max(mx.abs(norms - 1.0))),
        "mean_cos_to_target": float(mx.mean(mx.sum(z * anch, axis=1))),
        "retrieval_at_1": float(mx.mean((pred == yb).astype(mx.float32))),
        "n_windows": int(x_cl.shape[0]),
    }


# ── Export ───────────────────────────────────────────────────────────────

def _mlx_version() -> str:
    return getattr(mx, "__version__", "unknown")


def _git_sha() -> str:
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True,
                             cwd=Path(__file__).resolve().parent)
        return out.stdout.strip() or "unknown"
    except Exception:  # noqa: BLE001
        return "unknown"


def export_encoder(model: SpectralEncoder, out_dir: str, config: dict, metadata: dict) -> None:
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    weights = dict(tree_flatten(model.parameters()))
    mx.save_safetensors(str(out / "encoder.safetensors"), weights)
    (out / "config.json").write_text(json.dumps(config, indent=2))
    (out / "metadata.json").write_text(json.dumps(metadata, indent=2))
    print(f"wrote {out}/encoder.safetensors + config.json + metadata.json")


# ── Pipeline ─────────────────────────────────────────────────────────────

def run_pipeline(*, sessions: list[str] | None = None, synthetic: int = 0,
                 output_dir: str = "Models/EEGEncoder", epochs: int = 20,
                 batch_size: int = 64, lr: float = 1e-3, temperature: float = TEMPERATURE,
                 bge_model: str = DEFAULT_BGE, allow_fake_anchors: bool = False,
                 val_frac: float = 0.2, seed: int = 0) -> dict:
    # 1. Gather windows.
    fs = EXPECTED_RATE
    if synthetic and synthetic > 0:
        print(f"generating {synthetic} synthetic windows")
        windows = synthetic_windows(synthetic, seed=seed)
    else:
        windows = []
        for sdir in (sessions or []):
            windows.extend(load_session_windows(Path(sdir)))
    if not windows:
        raise SystemExit("no windows to train on")
    windows_np = np.stack(windows).astype(np.float32)             # [N, channels, samples]

    # 2. Derive per-window spectral descriptors (self-supervised).
    labels = []
    for w in windows_np:
        ratios = spectral_ratios(welch_band_powers(w, fs))
        labels.append(STATE_DESCRIPTORS.index(descriptor_for_ratios(ratios)))
    labels_np = np.asarray(labels, dtype=np.int32)
    dist = {STATE_DESCRIPTORS[i]: int((labels_np == i).sum()) for i in range(len(STATE_DESCRIPTORS))}
    print("descriptor distribution:", {k: v for k, v in dist.items() if v})

    # 3. Text anchors (the alignment target space).
    anchors_np, target_space = build_anchors(bge_model, allow_fake_anchors, seed=seed)

    # 4. Channels-last for MLX, then train.
    x_cl = np.transpose(windows_np, (0, 2, 1)).astype(np.float32)  # [N, samples, channels]
    model, history = train_encoder(
        x_cl, labels_np, anchors_np, epochs=epochs, batch_size=batch_size, lr=lr,
        temperature=temperature, val_frac=val_frac, seed=seed)

    # 5. Self-verify + export.
    sv = self_verify(model, x_cl, labels_np, anchors_np)
    print("self-verify:", sv)
    config = {
        "model": "eeg-spectral-encoder",
        "in_channels": EXPECTED_CHANNELS,
        "window_samples": EXPECTED_SAMPLES,
        "sample_rate": fs,
        "window_seconds": EXPECTED_SAMPLES / fs,
        "out_dim": int(anchors_np.shape[1]),
        "hidden": 64,
        "input_layout": "channels_last [batch, samples, channels]",
        "bands": BANDS,
    }
    metadata = {
        "model": "eeg-spectral-encoder",
        "dimension": int(anchors_np.shape[1]),
        "target_space": target_space,
        "pooling": "temporal-mean",
        "descriptors": STATE_DESCRIPTORS,
        "descriptor_distribution": dist,
        "temperature": temperature,
        "epochs": epochs,
        "self_verify": sv,
        "converted_with": {
            "script": "train_joint_embedding.py",
            "mlx": _mlx_version(),
            "final_train_loss": history[-1] if history else None,
        },
        "git_sha": _git_sha(),
        "note": "Descriptors are PSD-derived (self-supervised); this validates the "
                "EEG->text bridge and a text-aligned latent, not a novel decoding capability.",
    }
    export_encoder(model, output_dir, config, metadata)
    return metadata


def main() -> None:
    ap = argparse.ArgumentParser(description="Phase 3.6 EEG→text-aligned spectral embedding trainer")
    ap.add_argument("sessions", nargs="*",
                    help="session directories (default: all under ~/Documents/NeuralCompose/Recordings)")
    ap.add_argument("--output", default="Models/EEGEncoder")
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--temperature", type=float, default=TEMPERATURE)
    ap.add_argument("--bge-model", default=DEFAULT_BGE)
    ap.add_argument("--synthetic", type=int, default=0,
                    help="train on N synthetic windows (hardware-free smoke test)")
    ap.add_argument("--allow-fake-anchors", action="store_true",
                    help="use random text anchors if BGE is unavailable (plumbing only, NOT semantic)")
    args = ap.parse_args()

    sessions = args.sessions
    if not sessions and not args.synthetic:
        root = Path.home() / "Documents" / "NeuralCompose" / "Recordings"
        sessions = [str(p) for p in sorted(root.iterdir()) if p.is_dir()] if root.exists() else []
        if not sessions:
            raise SystemExit("no sessions found; pass session paths or --synthetic N")

    run_pipeline(sessions=sessions, synthetic=args.synthetic, output_dir=args.output,
                 epochs=args.epochs, batch_size=args.batch_size, lr=args.lr,
                 temperature=args.temperature, bge_model=args.bge_model,
                 allow_fake_anchors=args.allow_fake_anchors)


if __name__ == "__main__":
    main()
