#!/usr/bin/env python3
"""Online/target encoder frame mismatch — does the planner's cost measure the
goal, or the disagreement between two encoders?

WHY THIS EXISTS

`forward_eval.py::_mpc_success` plans across two different maps:

    z0 = _encode_states(..., use_target=False)   # ONLINE encoder   (:316)
    zg = _encode_states(..., use_target=True)    # TARGET encoder   (:318)
    costs = ((z - zg_lat) ** 2).sum(dim=1)       # _cem_plan        (:291)

and the goal state is the start state with only `pos` changed (:315):

    goals = [{**starts[i], "pos": goal_pos[i]} for i in range(n_episodes)]

So `z0` and `zg` encode near-identical inputs -- differing by a position shift of
at most `goal_offset` (0.4) -- through two encoders that are only tied together
by an EMA with tau=0.99. If those two encoders disagree by more than a 0.4
position shift moves the latent, the planner's cost is dominated by a constant
frame offset it can never reduce by acting, and control cannot improve no matter
how good the predictor gets.

That is a candidate mechanism for node 7's null: prediction error fell 4.6x and
the rollout norm ratio went 1.20 -> 0.98, while control stayed at 0/35.

THE ISOTROPY CONNECTION

For orthogonal R, z ~ N(0, I) implies Rz ~ N(0, I). An isotropic objective
(SIGReg, VISReg) therefore places NO penalty on the encoder rotating: the
rotational gauge is left maximally free. Under EMA the target is a lagged copy
of the online encoder, so the two frames differ by however much the encoder
rotated during the EMA window. Pinning the distribution can make the gauge
*freer*, not tighter -- so a better-isotropy objective could plausibly increase
frame mismatch while improving prediction.

`procrustes_residual_ratio` is what separates the two cases. If most of the
mismatch is absorbed by an optimal rotation, the disagreement is gauge, which is
exactly what isotropy fails to constrain. If little is absorbed, the encoders
disagree in a way rotation cannot explain and the gauge argument is not the story.

WHAT THIS MODULE DOES NOT DO

It does not fix anything and it makes no control claim. It reports a ratio.
Read it against thresholds registered BEFORE the numbers exist.

NOTE ON CHECKPOINTS: this cannot be run from a saved checkpoint.
`eeg_jepa.py`'s torch.save (:593-610) persists `encoder_state_dict` and
`predictor_state_dict` only -- `target_encoder_state_dict` is never written
anywhere in this repo -- and `EEGJEPAModule.__init__` rebuilds the target as
`copy.deepcopy(self.encoder)`. A checkpoint-loaded model therefore has
target_encoder == encoder EXACTLY, and would report zero mismatch: a false
negative that reads like a clean result. It must run against a live in-memory
model, i.e. inside the same process that trained it.
"""

from __future__ import annotations

from typing import Any, Callable

import torch


def _procrustes(a: torch.Tensor, b: torch.Tensor) -> tuple[float, float, list[float]]:
    """Best orthogonal alignment of `a` onto `b`, both (n, d), already centered.

    Returns (residual_before, residual_after, principal_angle_cosines).

    Both residuals are Frobenius norms in the same units, so their ratio is the
    fraction of disagreement a pure rotation CANNOT explain. The singular values
    of a^T b are the cosines of the principal angles between the two frames;
    all-ones means the frames span the same subspace with no relative rotation.
    """
    before = float(torch.linalg.norm(a - b))
    # a^T b -> U S V^T; the optimal orthogonal map is R = U V^T.
    u, s, vh = torch.linalg.svd(a.T @ b, full_matrices=False)
    rotation = u @ vh
    after = float(torch.linalg.norm(a @ rotation - b))
    # Cosines are the singular values of the correlation between unit-scaled
    # frames; normalize so scale differences do not masquerade as angles.
    denom = float(torch.linalg.norm(a)) * float(torch.linalg.norm(b))
    cosines = (s / denom * float(len(s))).tolist() if denom > 0 else []
    return before, after, cosines


@torch.no_grad()
def frame_diagnostic(
    encode: Callable[..., torch.Tensor],
    starts: list[dict],
    goals: list[dict],
) -> dict[str, Any]:
    """Measure how much of the planner's cost is encoder disagreement.

    `encode(states, use_target: bool) -> (n, d)` must be the SAME callable path
    the planner uses, so normalization matches training exactly. In
    `forward_eval.py` that is `_encode_states` with its train_mean/train_std and
    log/symlog flags already bound.

    `starts` and `goals` must be the same lists `_mpc_success` builds, in order,
    so that goals[i] differs from starts[i] in `pos` ONLY. That matching is what
    makes A and B comparable; do not pass independently sampled states.
    """
    online_start = encode(starts, use_target=False)
    target_start = encode(starts, use_target=True)
    online_goal = encode(goals, use_target=False)
    target_goal = encode(goals, use_target=True)  # == the planner's `zg`

    # A: pure frame mismatch. Same input, two encoders. Nothing about the goal.
    a = (online_start - target_start).norm(dim=1)
    # B: the real goal displacement, measured inside ONE frame.
    b = (online_start - online_goal).norm(dim=1)
    # C: what the planner actually reads at step 0 -- online start vs target goal.
    c = (online_start - target_goal).norm(dim=1)

    # Per-episode ratio, then median. Median not mean: one degenerate episode
    # should not set the verdict, and B can be near zero when the sampled goal
    # offset is small.
    finite = b > 1e-8
    ratios = (a[finite] / b[finite]) if bool(finite.any()) else torch.zeros(0)

    centered_online = online_start - online_start.mean(dim=0, keepdim=True)
    centered_target = target_start - target_start.mean(dim=0, keepdim=True)
    before, after, cosines = _procrustes(centered_online, centered_target)

    return {
        "frame_mismatch_median": float(a.median()),
        "goal_displacement_median": float(b.median()),
        "planner_reads_median": float(c.median()),
        # THE headline number. >> 1 means the planner's cost is mostly a
        # constant offset between two encoders rather than distance to the goal.
        "mismatch_to_displacement_ratio": float(ratios.median()) if len(ratios) else float("nan"),
        "n_episodes": len(starts),
        # Rotation decomposition: fraction of disagreement a rotation cannot
        # explain. Near 0 => the frames differ by (mostly) a rotation, i.e. the
        # gauge that an isotropic objective leaves free. Near 1 => not rotation.
        "procrustes_residual_ratio": (after / before) if before > 0 else float("nan"),
        "procrustes_residual_before": before,
        "procrustes_residual_after": after,
        "principal_angle_cosine_min": min(cosines) if cosines else float("nan"),
    }


def _self_test() -> None:
    """Both-polarity check that the diagnostic is not vacuous.

    A diagnostic that reports "no mismatch" must be shown to report mismatch
    when mismatch is present, or a clean result proves nothing. Runs in ~1s on
    CPU and needs no trained model.
    """
    torch.manual_seed(0)
    n, d = 64, 32
    base = torch.randn(n, d)
    shift = torch.randn(n, d) * 0.05  # small "goal displacement"

    def make_encode(target_transform):
        def encode(states, use_target: bool = False):
            z = states[0]  # states carries the tensor directly in this fixture
            return target_transform(z) if use_target else z
        return encode

    # --- polarity 1: identical encoders. Mismatch must vanish. ---
    ident = make_encode(lambda z: z)
    out = frame_diagnostic(ident, [base], [base + shift])
    assert out["frame_mismatch_median"] < 1e-6, out
    assert out["mismatch_to_displacement_ratio"] < 1e-4, out
    assert out["procrustes_residual_ratio"] < 1e-5 or out["procrustes_residual_before"] == 0.0, out
    print(f"  identical encoders   ratio={out['mismatch_to_displacement_ratio']:.2e}  (want ~0) OK")

    # --- polarity 2: target is a ROTATION of online. Mismatch must be large,
    # and Procrustes must absorb nearly all of it -- that is what "gauge" means.
    q, _ = torch.linalg.qr(torch.randn(d, d))
    rot = make_encode(lambda z: z @ q)
    out = frame_diagnostic(rot, [base], [base + shift])
    assert out["mismatch_to_displacement_ratio"] > 5.0, out
    assert out["procrustes_residual_ratio"] < 0.05, out
    print(f"  rotated target       ratio={out['mismatch_to_displacement_ratio']:.1f}  "
          f"procrustes_left={out['procrustes_residual_ratio']:.2e}  (want big, ~0) OK")

    # --- polarity 3: target differs NON-rotationally (per-dim scaling).
    # Mismatch large, but Procrustes must NOT absorb it -- distinguishes gauge
    # from genuine disagreement, which is the whole point of reporting both.
    scale = torch.linspace(0.5, 2.0, d)
    scl = make_encode(lambda z: z * scale)
    out = frame_diagnostic(scl, [base], [base + shift])
    assert out["mismatch_to_displacement_ratio"] > 5.0, out
    assert out["procrustes_residual_ratio"] > 0.15, out
    print(f"  scaled target        ratio={out['mismatch_to_displacement_ratio']:.1f}  "
          f"procrustes_left={out['procrustes_residual_ratio']:.2f}  (want big, NOT ~0) OK")

    print("frame_diagnostic self-test: all three polarities pass")


if __name__ == "__main__":
    _self_test()
