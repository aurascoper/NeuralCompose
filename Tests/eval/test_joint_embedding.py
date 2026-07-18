"""Tests for Phase 3.6 EEG→text-aligned spectral embedding.

Covers the shared spectral module (eeg_spectral) and the MLX trainer
(train_joint_embedding): the channels-last transpose trap, encoder output
shape/unit-norm, the contrastive-against-text-anchors loss, and end-to-end
export. Pytest-style bare functions + a __main__ runner, since pytest is not
installed in the calibration venv (run: `python3 Tests/eval/test_joint_embedding.py`).
"""
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Scripts"))

import numpy as np
import mlx.core as mx

import eeg_spectral as spec
import train_joint_embedding as tje


def test_encoder_forward_shape_and_norm():
    enc = tje.SpectralEncoder(in_channels=4, out_dim=384)
    mx.eval(enc.parameters())
    x = mx.array(np.random.default_rng(0).normal(size=(8, 512, 4)).astype(np.float32))
    z = enc(x)
    assert z.shape == (8, 384), f"expected (8, 384), got {z.shape}"
    norms = np.asarray(mx.sqrt(mx.sum(z * z, axis=1)))
    assert np.allclose(norms, 1.0, atol=1e-4), f"rows not unit-norm: {norms[:3]}"


def test_channels_last_required():
    # MLX Conv1d is channels-last: input must be [B, samples, channels] = [B, 512, 4].
    # Feeding PyTorch-style [B, 4, 512] puts 512 in the channel axis and must fail
    # against conv1's 4 input channels — this guards the #1 shape trap of this milestone.
    enc = tje.SpectralEncoder(in_channels=4, out_dim=384)
    mx.eval(enc.parameters())
    bad = mx.array(np.zeros((2, 4, 512), dtype=np.float32))
    raised = False
    try:
        mx.eval(enc(bad))
    except Exception:
        raised = True
    assert raised, "encoder must reject channels-first [B, 4, 512]; layout is [B, 512, 4]"


def test_supcon_loss_properties():
    n_desc, dim = 3, 16
    rng = np.random.default_rng(1)
    anchors_np = rng.normal(size=(n_desc, dim)).astype(np.float32)
    anchors_np /= np.linalg.norm(anchors_np, axis=1, keepdims=True)
    loss_fn = tje._make_loss(mx.array(anchors_np), temperature=0.07)

    class _Fixed:  # stand-in "model" that returns preset embeddings, ignoring input
        def __init__(self, z):
            self._z = z

        def __call__(self, _x):
            return self._z

    labels = mx.array(np.array([0, 1, 2, 0], dtype=np.int32))
    aligned = float(loss_fn(_Fixed(mx.array(anchors_np[[0, 1, 2, 0]])), None, labels))
    misaligned = float(loss_fn(_Fixed(mx.array(anchors_np[[1, 2, 0, 1]])), None, labels))
    assert aligned >= 0 and misaligned >= 0
    assert aligned < misaligned, f"aligned loss {aligned} should be < misaligned {misaligned}"

    # A batch where every window shares one descriptor must stay finite (no
    # false-negative degeneracy — this is why we classify against fixed anchors).
    one = float(loss_fn(_Fixed(mx.array(anchors_np[[0, 0]])), None,
                        mx.array(np.array([0, 0], dtype=np.int32))))
    assert np.isfinite(one)


def test_supcon_training_decreases():
    windows = tje.synthetic_windows(48, seed=3)
    x_np = np.stack(windows).astype(np.float32)
    fs = tje.EXPECTED_RATE
    labels = np.array(
        [spec.STATE_DESCRIPTORS.index(
            spec.descriptor_for_ratios(spec.spectral_ratios(spec.welch_band_powers(w, fs))))
         for w in x_np], dtype=np.int32)
    rng = np.random.default_rng(0)
    anchors = rng.normal(size=(len(spec.STATE_DESCRIPTORS), 384)).astype(np.float32)
    anchors /= np.linalg.norm(anchors, axis=1, keepdims=True)
    x_cl = np.transpose(x_np, (0, 2, 1)).astype(np.float32)
    _, hist = tje.train_encoder(x_cl, labels, anchors, epochs=15, batch_size=16,
                                lr=2e-3, temperature=0.07, val_frac=0.2, seed=0)
    assert hist[-1] < hist[0], f"loss did not decrease: {hist[0]:.3f} → {hist[-1]:.3f}"


def test_spectral_alpha_dominant_descriptor():
    fs = 256.0
    t = np.arange(512) / fs
    window = np.stack([40 * np.sin(2 * np.pi * 10 * t) for _ in range(4)]).astype(np.float32)
    bp = spec.welch_band_powers(window, fs)
    assert max(bp, key=bp.get) == "alpha", f"expected alpha-dominant, got {bp}"
    descriptor = spec.descriptor_for_ratios(spec.spectral_ratios(bp))
    assert descriptor in spec.STATE_DESCRIPTORS
    assert "alpha" in descriptor, f"pure 10 Hz should read as alpha-dominant, got {descriptor!r}"


def test_export_writes_artifacts():
    # Stay offline & hermetic: force the fake-anchor path via a nonexistent local
    # BGE path with HF network access disabled, so no request is attempted.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    with tempfile.TemporaryDirectory() as tmp:
        meta = tje.run_pipeline(synthetic=120, output_dir=tmp, epochs=2, batch_size=32,
                                bge_model="/nonexistent/__bge__", allow_fake_anchors=True, seed=0)
        out = Path(tmp)
        assert (out / "encoder.safetensors").exists()
        assert (out / "config.json").exists()
        assert (out / "metadata.json").exists()
        md = json.loads((out / "metadata.json").read_text())
        assert md["dimension"] == 384
        assert md["self_verify"]["shape_ok"] is True
        assert md["self_verify"]["unit_norm_max_dev"] < 1e-3
        assert "random-fallback" in md["target_space"], "fake-anchor run must be labeled, not silent"


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            import traceback
            traceback.print_exc()
            print(f"FAIL {t.__name__}: {exc}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
