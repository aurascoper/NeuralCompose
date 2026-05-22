#!/usr/bin/env python3
"""
train-intent-classifier.py — Train a Core ML intent classifier from one or
more calibration sessions recorded by NeuralCompose.

Input: one or more session directories under ~/Documents/NeuralCompose/Recordings/
  Each contains eeg.csv, labels.csv, events.csv, metadata.json.

Output: Models/IntentClassifier.mlpackage — picked up by ClassifierFactory.live()
  if .mlpackage support is added (otherwise compile with `xcrun coremlcompiler`
  to .mlmodelc, which needs full Xcode).

I/O contract (must match CoreMLIntentClassifier.swift):
  input  "eeg_window":    Float32 MLMultiArray of shape [1, 4, 512]
  output "intent_logits": Float32 MLMultiArray of shape [1, 5]
  class order: rest, jawClench, singleBlink, doubleBlink, select
               (drops `artifact` and the derived `none` label during training)

Usage:
  ./Scripts/train-intent-classifier.py                       # uses all sessions in ~/Documents/NeuralCompose/Recordings
  ./Scripts/train-intent-classifier.py path/to/session       # single session
  ./Scripts/train-intent-classifier.py s1/ s2/ s3/           # union of sessions
  ./Scripts/train-intent-classifier.py --output Models/IntentClassifier.mlpackage
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader, Dataset, random_split


# Canonical class order — must match Sources/BCICore/Models/Intent.swift
CLASS_ORDER = ["rest", "jawClench", "singleBlink", "doubleBlink", "select"]
LABEL_TO_INDEX = {
    "rest": 0,
    "jaw_clench": 1,
    "blink": 2,
    "single_blink": 2,
    "double_blink": 3,
    "select": 4,
}
# Labels we drop entirely from training
DROP_LABELS = {"artifact", "none", ""}

EXPECTED_CHANNELS = 4
EXPECTED_SAMPLES = 512
EXPECTED_RATE = 256.0  # Muse S


def load_session(session_dir: Path):
    """Slice (eeg.csv, labels.csv) → list of (window[4,512], label_idx)."""
    eeg_path = session_dir / "eeg.csv"
    labels_path = session_dir / "labels.csv"
    meta_path = session_dir / "metadata.json"

    if not all(p.exists() for p in (eeg_path, labels_path, meta_path)):
        print(f"  skip {session_dir.name}: missing files", file=sys.stderr)
        return []

    with open(meta_path) as f:
        meta = json.load(f)
    sample_rate = float(meta.get("sample_rate", EXPECTED_RATE))

    # eeg.csv: t_seconds, TP9, AF7, AF8, TP10
    eeg = np.loadtxt(eeg_path, delimiter=",", skiprows=1, dtype=np.float64)
    if eeg.ndim == 1 or eeg.shape[0] < EXPECTED_SAMPLES:
        print(f"  skip {session_dir.name}: only {eeg.shape[0] if eeg.ndim else 0} samples",
              file=sys.stderr)
        return []
    eeg_t = eeg[:, 0]
    eeg_x = eeg[:, 1:1 + EXPECTED_CHANNELS].astype(np.float32)  # [N, 4]

    # labels.csv: session_id, window_seq, t_start, t_end, label, profile, sample_rate
    labels = np.genfromtxt(
        labels_path, delimiter=",", skip_header=1, dtype=None, encoding="utf-8"
    )
    if labels.ndim == 0:  # single row
        labels = labels.reshape(1)

    windows = []
    for row in labels:
        # numpy structured array indexing
        try:
            t_start = float(row[2])
            t_end = float(row[3])
            label = str(row[4]).strip().lower()
        except (IndexError, ValueError):
            continue
        if label in DROP_LABELS:
            continue
        if label not in LABEL_TO_INDEX:
            continue

        # Find samples in [t_start, t_end). Window length ~ sample_rate * 2 s.
        i0 = np.searchsorted(eeg_t, t_start, side="left")
        i1 = np.searchsorted(eeg_t, t_end, side="left")
        if i1 - i0 < EXPECTED_SAMPLES // 2:  # need at least 1 s of samples
            continue

        block = eeg_x[i0:i1]  # [n, 4]
        # Resample / pad / truncate to exactly EXPECTED_SAMPLES via simple interp.
        if block.shape[0] != EXPECTED_SAMPLES:
            old_idx = np.linspace(0, block.shape[0] - 1, block.shape[0])
            new_idx = np.linspace(0, block.shape[0] - 1, EXPECTED_SAMPLES)
            block = np.stack(
                [np.interp(new_idx, old_idx, block[:, c]) for c in range(EXPECTED_CHANNELS)],
                axis=1,
            ).astype(np.float32)

        window = block.T  # [4, 512]
        windows.append((window, LABEL_TO_INDEX[label]))

    print(f"  {session_dir.name}: {len(windows)} windows (rate={sample_rate} Hz)")
    return windows


class WindowDataset(Dataset):
    def __init__(self, items):
        self.items = items

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        w, y = self.items[i]
        return torch.from_numpy(w), torch.tensor(y, dtype=torch.long)


class IntentCNN(nn.Module):
    """Tiny 1-D CNN over EEG channels. ~25K params, ANE-friendly."""

    def __init__(self, n_classes: int = 5):
        super().__init__()
        self.net = nn.Sequential(
            nn.Conv1d(EXPECTED_CHANNELS, 32, kernel_size=7, stride=2, padding=3),
            nn.ReLU(inplace=True),
            nn.Conv1d(32, 64, kernel_size=5, stride=2, padding=2),
            nn.ReLU(inplace=True),
            nn.Conv1d(64, 64, kernel_size=3, stride=2, padding=1),
            nn.ReLU(inplace=True),
            nn.AdaptiveAvgPool1d(1),
            nn.Flatten(),
            nn.Linear(64, n_classes),
        )

    def forward(self, x):
        # x: [B, 4, 512]
        return self.net(x)


def train(items, epochs=40, batch_size=32, lr=1e-3, val_frac=0.2, device="cpu"):
    counts = Counter(y for _, y in items)
    print(f"class distribution: { {CLASS_ORDER[k]: v for k, v in counts.items()} }")

    ds = WindowDataset(items)
    n_val = max(1, int(len(ds) * val_frac))
    n_train = len(ds) - n_val
    train_ds, val_ds = random_split(ds, [n_train, n_val], generator=torch.Generator().manual_seed(0))

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=batch_size)

    # Inverse-frequency class weights
    n_classes = len(CLASS_ORDER)
    weights = torch.ones(n_classes)
    for k, v in counts.items():
        weights[k] = 1.0 / max(v, 1)
    weights = weights / weights.sum() * n_classes
    print(f"class weights: {weights.tolist()}")

    model = IntentCNN(n_classes=n_classes).to(device)
    opt = torch.optim.Adam(model.parameters(), lr=lr)
    loss_fn = nn.CrossEntropyLoss(weight=weights.to(device))

    best_val_acc = 0.0
    best_state = None
    for epoch in range(epochs):
        model.train()
        train_loss = 0.0
        train_correct = 0
        train_total = 0
        for x, y in train_loader:
            x, y = x.to(device), y.to(device)
            logits = model(x)
            loss = loss_fn(logits, y)
            opt.zero_grad()
            loss.backward()
            opt.step()
            train_loss += loss.item() * x.size(0)
            train_correct += (logits.argmax(1) == y).sum().item()
            train_total += x.size(0)

        model.eval()
        val_correct = 0
        val_total = 0
        with torch.no_grad():
            for x, y in val_loader:
                x, y = x.to(device), y.to(device)
                pred = model(x).argmax(1)
                val_correct += (pred == y).sum().item()
                val_total += x.size(0)
        val_acc = val_correct / max(val_total, 1)
        print(f"epoch {epoch + 1:>3}/{epochs}: "
              f"loss={train_loss / max(train_total, 1):.4f} "
              f"train_acc={train_correct / max(train_total, 1):.3f} "
              f"val_acc={val_acc:.3f}")
        if val_acc > best_val_acc:
            best_val_acc = val_acc
            best_state = {k: v.clone() for k, v in model.state_dict().items()}

    if best_state is not None:
        model.load_state_dict(best_state)
    print(f"best val acc: {best_val_acc:.3f}")
    return model


def export_coreml(model, output_path: Path):
    model.eval()
    example = torch.zeros(1, EXPECTED_CHANNELS, EXPECTED_SAMPLES, dtype=torch.float32)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="eeg_window", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="intent_logits", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "EEG → intent classifier (rest, jawClench, singleBlink, doubleBlink, select)"
    mlmodel.author = "NeuralCompose calibration pipeline"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))
    print(f"wrote {output_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sessions", nargs="*",
                    help="session directories (default: all under ~/Documents/NeuralCompose/Recordings)")
    ap.add_argument("--output", default="Models/IntentClassifier.mlpackage")
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch-size", type=int, default=32)
    ap.add_argument("--lr", type=float, default=1e-3)
    args = ap.parse_args()

    if not args.sessions:
        root = Path.home() / "Documents" / "NeuralCompose" / "Recordings"
        sessions = sorted(p for p in root.iterdir() if p.is_dir()) if root.exists() else []
    else:
        sessions = [Path(s) for s in args.sessions]

    if not sessions:
        print("no sessions found", file=sys.stderr)
        sys.exit(1)

    print(f"loading {len(sessions)} session(s):")
    all_items = []
    for s in sessions:
        all_items.extend(load_session(s))

    if not all_items:
        print("no usable windows after filtering", file=sys.stderr)
        sys.exit(1)
    print(f"total windows: {len(all_items)}")

    device = "cpu"  # PyTorch + MPS quirks; CPU is fine for ~25K param model
    model = train(all_items, epochs=args.epochs, batch_size=args.batch_size,
                  lr=args.lr, device=device)
    export_coreml(model, Path(args.output))


if __name__ == "__main__":
    main()
