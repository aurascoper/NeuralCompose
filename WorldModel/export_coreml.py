#!/usr/bin/env python3
"""export_coreml.py — CoreML export of the synthetic-task JEPA.

Scope, deliberately narrow: this exports ONLY `models.py`'s `Encoder` /
`LatentPredictor` / `target_encoder` (the synthetic 2D-particle-navigation
JEPA, checkpoint `WorldModel/checkpoints/jepa.pt`). It does NOT export
`eeg_jepa.py`'s real-EEG classes — no validated corpus exists yet for that
path (`ADR-006-jepa-transition-capture.md`), so exporting it would commit
to an integration step nobody has scoped. If you're looking to point this
at real EEG data, that's a separate, future decision — see
`WorldModel/EEG_INTEGRATION_DESIGN.md`.

Three `.mlpackage` models are produced:
- `Encoder.mlpackage` — the ONLINE encoder (`model.encoder`), batch size 1
  (the Swift side only ever encodes one live/current state at a time).
- `GoalEncoder.mlpackage` — the TARGET encoder (`model.target_encoder`),
  exported SEPARATELY, not reused from `Encoder.mlpackage`. `encoder` and
  `target_encoder` are architecturally identical but have diverged learned
  weights after EMA training (`ema_tau`, ~75 epochs) — `mpc.py`'s own
  module docstring names mixing these two up as a real, easy-to-make
  mistake ("which encoder produces which latent is easy to get
  backwards"). Conflating them here would reintroduce that risk at the
  Swift layer. `GoalEncoder` is an export-time name only — there is no
  `GoalEncoder` class in `models.py`, and none is added by this script.
- `LatentPredictor.mlpackage` — `model.predictor`, exported with batch size
  512 (matching `MPCConfig.num_candidates`'s default), NOT batch size 1.
  This lets the Swift MPPI planner score all candidates in one CoreML call
  per horizon step (mirroring what `mpc.py::score_candidates` already does
  — one batched forward pass per step, not one call per candidate). If
  `MPCConfig.num_candidates` is ever changed, this export must be
  regenerated to match — a fixed, not flexible, batch dimension, which is
  a fine trade-off for a research demo but a real coupling to be aware of.

Dependency note: no new requirements file. The shared root `venv/` already
has `coremltools==8.0` / `numpy==1.26.4` / `torch==2.13.0` installed and
importable — the same `numpy<2` constraint `requirements-calibration.txt`
documents for its own (unrelated) coremltools usage is already satisfied
here; nothing new to pin.

Usage:
  ./WorldModel/export_coreml.py
  ./WorldModel/export_coreml.py --checkpoint WorldModel/checkpoints/jepa.pt \
      --output-dir Models/WorldModelDemo
  ./WorldModel/export_coreml.py --skip-verify
"""
from __future__ import annotations

import argparse
import json
import platform
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

from env import ACTION_DIM, STATE_DIM
from models import JEPAConfig, JEPAModule
from train import DEFAULT_CHECKPOINT

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = REPO_ROOT / "Models" / "WorldModelDemo"
PREDICTOR_BATCH = 512  # must match MPCConfig.num_candidates's default — see module docstring


def verify_conversion(
    name: str,
    traced_model: torch.jit.ScriptModule,
    mlmodel: ct.models.MLModel,
    example_inputs: list[torch.Tensor],
    input_names: list[str],
    output_name: str,
    n_samples: int,
    tolerance: float,
) -> float:
    """Numerical-parity smoke test: compare the traced PyTorch model against
    the converted CoreML model on N fresh random inputs (same shapes as the
    tracing example). Raises on failure -- this is a correctness gate, not a
    research finding, so it doesn't get the softer "print a WARNING" style
    used elsewhere in this directory for things like representation-collapse
    diagnostics."""
    max_diff = 0.0
    for _ in range(n_samples):
        inputs = [torch.randn_like(ex) for ex in example_inputs]
        with torch.no_grad():
            torch_out = traced_model(*inputs).numpy()
        coreml_inputs = {n: t.numpy() for n, t in zip(input_names, inputs)}
        coreml_out = mlmodel.predict(coreml_inputs)[output_name]
        max_diff = max(max_diff, float(np.abs(torch_out - coreml_out).max()))
    print(f"  {name}: max_abs_diff={max_diff:.6g} over {n_samples} samples (tolerance={tolerance})")
    if max_diff >= tolerance:
        raise RuntimeError(f"{name}: CoreML conversion parity check failed ({max_diff:.6g} >= {tolerance})")
    return max_diff


def export_model(
    torch_model: torch.nn.Module,
    example_inputs: tuple[torch.Tensor, ...],
    input_specs: list[ct.TensorType],
    output_name: str,
    output_path: Path,
) -> tuple[torch.jit.ScriptModule, ct.models.MLModel]:
    traced = torch.jit.trace(torch_model, example_inputs if len(example_inputs) > 1 else example_inputs[0])
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        inputs=input_specs,
        outputs=[ct.TensorType(name=output_name)],
    )
    mlmodel.save(str(output_path))
    return traced, mlmodel


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    ap.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    ap.add_argument("--verify", action=argparse.BooleanOptionalAction, default=True)
    ap.add_argument("--verify-samples", type=int, default=50)
    ap.add_argument("--tolerance", type=float, default=1e-3)
    args = ap.parse_args()

    if not args.checkpoint.exists():
        raise SystemExit(f"{args.checkpoint} not found — run ./WorldModel/train.py first")

    device = torch.device("cpu")  # tracing/conversion has no reason to touch mps
    ckpt = torch.load(args.checkpoint, map_location=device)
    jepa_config = JEPAConfig(**ckpt["jepa_config"])
    model = JEPAModule(jepa_config).to(device)
    model.load_state_dict(ckpt["model_state_dict"])
    model.eval()
    for p in model.parameters():
        p.requires_grad_(False)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    print(f"export_coreml.py: checkpoint={args.checkpoint} jepa_config={jepa_config}")
    print(f"  output_dir={args.output_dir}")

    verify_results: dict[str, float] = {}

    # --- Encoder (online) ---
    example_state = torch.randn(1, STATE_DIM)
    traced_encoder, mlmodel_encoder = export_model(
        model.encoder,
        (example_state,),
        [ct.TensorType(name="state_in", shape=(1, STATE_DIM))],
        "latent_out",
        args.output_dir / "Encoder.mlpackage",
    )
    print(f"  wrote {args.output_dir / 'Encoder.mlpackage'}")
    if args.verify:
        verify_results["Encoder"] = verify_conversion(
            "Encoder", traced_encoder, mlmodel_encoder, [example_state],
            ["state_in"], "latent_out", args.verify_samples, args.tolerance,
        )

    # --- GoalEncoder (target_encoder — separate export, see module docstring) ---
    example_goal_state = torch.randn(1, STATE_DIM)
    traced_goal_encoder, mlmodel_goal_encoder = export_model(
        model.target_encoder,
        (example_goal_state,),
        [ct.TensorType(name="goal_state_in", shape=(1, STATE_DIM))],
        "goal_latent_out",
        args.output_dir / "GoalEncoder.mlpackage",
    )
    print(f"  wrote {args.output_dir / 'GoalEncoder.mlpackage'}")
    if args.verify:
        verify_results["GoalEncoder"] = verify_conversion(
            "GoalEncoder", traced_goal_encoder, mlmodel_goal_encoder, [example_goal_state],
            ["goal_state_in"], "goal_latent_out", args.verify_samples, args.tolerance,
        )

    # --- LatentPredictor (batch 512, see module docstring) ---
    example_latent = torch.randn(PREDICTOR_BATCH, jepa_config.latent_dim)
    example_action = torch.randn(PREDICTOR_BATCH, ACTION_DIM)
    traced_predictor, mlmodel_predictor = export_model(
        model.predictor,
        (example_latent, example_action),
        [
            ct.TensorType(name="current_latent", shape=(PREDICTOR_BATCH, jepa_config.latent_dim)),
            ct.TensorType(name="action_vector", shape=(PREDICTOR_BATCH, ACTION_DIM)),
        ],
        "predicted_latent",
        args.output_dir / "LatentPredictor.mlpackage",
    )
    print(f"  wrote {args.output_dir / 'LatentPredictor.mlpackage'}")
    if args.verify:
        verify_results["LatentPredictor"] = verify_conversion(
            "LatentPredictor", traced_predictor, mlmodel_predictor,
            [example_latent, example_action], ["current_latent", "action_vector"],
            "predicted_latent", args.verify_samples, args.tolerance,
        )

    metadata = {
        "checkpoint": str(args.checkpoint),
        "jepa_config": {
            "latent_dim": jepa_config.latent_dim,
            "hidden_dim": jepa_config.hidden_dim,
            "ema_tau": jepa_config.ema_tau,
        },
        "state_dim": STATE_DIM,
        "action_dim": ACTION_DIM,
        "predictor_batch": PREDICTOR_BATCH,
        "verify": {"tolerance": args.tolerance, "max_abs_diff": verify_results} if args.verify else None,
        "coremltools_version": ct.__version__,
        "torch_version": torch.__version__,
        "numpy_version": np.__version__,
        "python_version": platform.python_version(),
    }
    (args.output_dir / "metadata.json").write_text(json.dumps(metadata, indent=2))
    print(f"  wrote {args.output_dir / 'metadata.json'}")
    print("export_coreml.py: done" + (" (verified)" if args.verify else " (verify skipped)"))


if __name__ == "__main__":
    main()
