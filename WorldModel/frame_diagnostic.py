#!/usr/bin/env python3
"""Online/target encoder frame mismatch — does the planner's cost measure the
goal, or the disagreement between two encoders?

WHY THIS EXISTS

`forward_eval.py::_mpc_success` plans across two different maps:

    goals = [{**starts[i], "pos": goal_pos[i]} ...]   # :316  pos differs ALONE
    z0 = _encode_states(..., use_target=False)        # :317  ONLINE encoder
    zg = _encode_states(..., use_target=True)         # :319  TARGET encoder
    costs = ((z - zg_lat) ** 2).sum(dim=1)            # :292  cost reads across both

The goal state is the start state with `pos` changed alone, by at most
`goal_offset` (0.4). So `z0` and `zg` encode near-identical inputs through two
encoders tied together only by an EMA at tau=0.99. If those encoders disagree by
more than a 0.4 position shift moves the latent, the planner's cost is dominated
by a frame offset it cannot reduce by acting, and control cannot improve however
good the predictor gets.

THE ISOTROPY CONNECTION

For orthogonal R, z ~ N(0, I) implies Rz ~ N(0, I). An isotropic objective
(SIGReg, VISReg) therefore places NO penalty on the encoder rotating: the
rotational gauge is left maximally free. Under EMA the target is a lagged copy
of the online encoder, so the two frames differ by however much the encoder
rotated during the EMA window. Pinning the distribution can make the gauge
*freer*, not tighter.

This also sharpens the Theorem 5.4 problem. An L2 cost is O(n)-invariant, so a
*shared* rotation is harmless and the theorem is untroubled by it. The issue is
two encoders in two frames: the theorem's guarantee covers one representation,
and nothing in it makes an online/target pair converge to the same rotation.

`procrustes_residual_ratio` separates the two cases. If an optimal rotation
absorbs most of the mismatch, the disagreement is gauge — exactly what isotropy
fails to constrain. If little is absorbed, rotation is not the story.

READ THE PRIMARY FIELDS, NOT THE RATIO
`frame_mismatch_median` (A) and `goal_displacement_median` (B) are primary.
`mismatch_to_displacement_ratio` is A/B and is therefore sensitive to the goal
sampling distribution: holding encoder disagreement fixed and varying only the
goal displacement scale moves the ratio across 1.0 in both directions. Since
`goal_pos` is sampled uniformly within `goal_offset`, the ratio partly reports
your sampling choice. Use it as a derived summary; read A and B directly.

WHAT THIS MODULE DOES NOT DO
It does not fix anything and makes no control claim. It reports numbers.

REGISTERED READ -- fixed before any real number exists

    mismatch_to_displacement_ratio (A/B)
        > 1.0   frame offset exceeds the entire goal signal; the planner is
                chasing a constant it cannot reduce by acting
        < 0.3   frame hypothesis rejected

    procrustes_residual_ratio
        < 0.2   mostly rotational -- the gauge an isotropic objective leaves free
        > 0.5   not rotational; the gauge argument is not the mechanism

    The 0.2/0.5 band is deliberately narrower than a naive 0.3/0.7. Simulating
    EMA lag as a generic perturbation (target = online + online @ N(0, eps))
    parks the residual at ~0.67-0.70 across two orders of magnitude of eps --
    i.e. the most likely realistic outcome would have landed inside a 0.3-0.7
    "inconclusive" gap and decided nothing.

    Read `rotation_from_identity` WITH the residual: absorbed-by-rotation plus
    far-from-identity is gauge; not-absorbed plus near-identity is genuine
    disagreement. Either alone is ambiguous.

CROSS-ARM PREDICTION (registered): if the gauge story holds, SIGReg arms show a
ratio at or above VICReg arms, because better isotropy means a freer rotation.
A LOWER SIGReg ratio falsifies the mechanism.

NOTE ON CHECKPOINTS: this cannot be run from a saved checkpoint.
`eeg_jepa.py`'s torch.save (:593) persists `encoder_state_dict` and
`predictor_state_dict` only -- `target_encoder_state_dict` is written nowhere in
this repo -- and `EEGJEPAModule.__init__` rebuilds the target as
`copy.deepcopy(self.encoder)` (:327). A checkpoint-loaded model therefore has
target_encoder == encoder EXACTLY and would report zero mismatch: a false
negative that reads like a clean result. It must run against a live in-memory
model, i.e. inside the process that trained it.

PROVENANCE NOTE: an earlier commit of this file attributed the motivating null
("prediction error 4.6x lower, rollout norm ratio 1.20 -> 0.98, control 0/35")
to ledger node 7 at commit 208cbcd. That citation does not resolve: node 7 in
every pushed ledger is "Transform A/B, arm 2 audit", 208cbcd is not on the
remote, and those figures appear in no pushed ledger on any branch. They were
reported in-session from an unpushed run. Treat them as unverified here until
the run is pushed and the node is cited by number.
"""

from __future__ import annotations

import math
from typing import Any, Callable

try:
    import torch
except ModuleNotFoundError:  # pragma: no cover - exercised where torch is absent
    # Falls back to a pure-Python stand-in so _self_test() runs anywhere,
    # including CI. It verifies the algorithm, NOT torch-specific behaviour
    # (SVD sign conventions, float32 accumulation), so a green run here does not
    # discharge the need to run against real torch before trusting a production
    # number. Real torch always wins when it is importable.
    import sys as _sys
    from pathlib import Path as _Path

    _sys.path.insert(0, str(_Path(__file__).resolve().parent))
    import _tensor_shim as torch  # type: ignore[no-redef]

# Relative floor for calling a Frobenius norm "zero". Guarding on `> 0` alone
# lets 1e-14 through and turns the residual ratio into 0/0, which then prints a
# plausible-looking number instead of announcing itself.
_REL_EPS = 1e-8


def _procrustes(a: torch.Tensor, b: torch.Tensor) -> tuple[float, float, float]:
    """Best orthogonal alignment of `a` onto `b`, both (n, d), already centered.

    Returns (residual_before, residual_after, rotation_from_identity).

    The residuals are Frobenius norms in the same units. Because R = I is always
    feasible, the optimum can never be worse than no rotation: after <= before,
    hence ratio <= 1. A ratio above 1 is mathematically impossible and means the
    inputs were degenerate.

    `rotation_from_identity` is ||R - I||_F / (2*sqrt(d)), which is 0 when the
    two frames already share a gauge and rises to 1 at R = -I. For a rotation by
    a common angle theta it equals sin(theta/2), so it reads as a magnitude.

    (An earlier version reported principal-angle cosines here. Those were bounded
    correctly after orthonormalization but are VACUOUS for this comparison: both
    rotation and per-dimension scaling preserve the column span, so two full-rank
    frames always have all principal angles zero. The span is identical by
    construction; what differs is the map, which is what this measures instead.)
    """
    before = float(torch.linalg.norm(a - b))
    u, _, vh = torch.linalg.svd(a.T @ b, full_matrices=False)
    rotation = u @ vh
    after = float(torch.linalg.norm(a @ rotation - b))

    d = rotation.shape[0]
    gap = float(torch.linalg.norm(rotation - torch.eye(d)))
    return before, after, gap / (2.0 * math.sqrt(d))


@torch.no_grad()
def frame_diagnostic(
    encode: Callable[..., torch.Tensor],
    starts: list[dict],
    goals: list[dict],
) -> dict[str, Any]:
    """Measure how much of the planner's cost is encoder disagreement.

    `encode(states, use_target: bool) -> (n, d)` must be the SAME callable path
    the planner uses, so normalization matches training exactly. In
    `forward_eval.py` that is `_encode_states` (:247) with its train stats and
    log/symlog flags already bound.

    `starts` and `goals` must be the lists `_mpc_success` builds, in order, so
    goals[i] differs from starts[i] in `pos` ONLY. That matching is what makes
    A and B comparable; do not pass independently sampled states.
    """
    online_start = encode(starts, use_target=False)
    target_start = encode(starts, use_target=True)
    online_goal = encode(goals, use_target=False)
    target_goal = encode(goals, use_target=True)  # == the planner's `zg`

    # A: pure frame mismatch. Same input, two encoders. Nothing about the goal.
    #    Uncentered, so it DOES capture a constant translation between frames.
    a = (online_start - target_start).norm(dim=1)
    # B: the real goal displacement, measured inside ONE frame.
    b = (online_start - online_goal).norm(dim=1)
    # C: what the planner actually reads at step 0 -- online start vs target goal.
    c = (online_start - target_goal).norm(dim=1)

    # Per-episode ratio then median. Median not mean: one degenerate episode
    # should not set the verdict, and B is near zero when the sampled offset is.
    finite = b > 1e-8
    ratios = (a[finite] / b[finite]) if bool(finite.any()) else torch.zeros(0)

    # The Procrustes step centers both frames, which REMOVES a pure translation
    # before the decomposition can see it -- and a constant offset is exactly
    # the mechanism this module is about. So report the centroid gap separately;
    # it is the translational part that centering discards.
    online_mean = online_start.mean(dim=0, keepdim=True)
    target_mean = target_start.mean(dim=0, keepdim=True)
    centroid_gap = float(torch.linalg.norm(online_mean - target_mean))

    centered_online = online_start - online_mean
    centered_target = target_start - target_mean
    before, after, gap = _procrustes(centered_online, centered_target)

    scale = float(torch.linalg.norm(centered_online)) + float(torch.linalg.norm(centered_target))
    degenerate = before <= _REL_EPS * max(scale, 1e-30)
    residual_ratio = float("nan") if degenerate else (after / before)
    rotation_gap = float("nan") if degenerate else gap

    return {
        # --- primary: read these directly ---
        "frame_mismatch_median": float(a.median()),
        "goal_displacement_median": float(b.median()),
        "planner_reads_median": float(c.median()),
        "centroid_gap": centroid_gap,
        # --- derived: sensitive to the goal sampling distribution ---
        "mismatch_to_displacement_ratio": float(ratios.median()) if len(ratios) else float("nan"),
        # --- rotation decomposition; nan when the centered frames coincide ---
        "procrustes_residual_ratio": residual_ratio,
        "procrustes_residual_before": before,
        "procrustes_residual_after": after,
        # ||R - I||_F / (2 sqrt(d)) — 0 when the frames share a gauge, sin(th/2)
        # for a common rotation angle th. Magnitude of the gauge disagreement.
        "rotation_from_identity": rotation_gap,
        "n_episodes": len(starts),
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
            z = states[0]  # this fixture carries the tensor directly
            return target_transform(z) if use_target else z
        return encode

    def check_invariant(out, label):
        # R = I is always feasible, so the optimum can never beat no rotation.
        # A ratio above 1 is impossible and means degeneracy leaked through.
        r = out["procrustes_residual_ratio"]
        assert r != r or r <= 1.0 + 1e-6, f"{label}: residual ratio {r} > 1 is impossible"

    # --- polarity 1: identical encoders. Mismatch must vanish. ---
    out = frame_diagnostic(make_encode(lambda z: z), [base], [base + shift])
    check_invariant(out, "identical")
    assert out["frame_mismatch_median"] < 1e-6, out
    assert out["mismatch_to_displacement_ratio"] < 1e-4, out
    assert out["procrustes_residual_ratio"] != out["procrustes_residual_ratio"], \
        f"identical frames must report nan, not a ratio: {out['procrustes_residual_ratio']}"
    print(f"  identical encoders   ratio={out['mismatch_to_displacement_ratio']:.2e}  "
          f"procrustes=nan  (want ~0, nan) OK")

    # --- polarity 2: target is a ROTATION of online. Mismatch large, and
    # Procrustes must absorb nearly all of it -- that is what "gauge" means. ---
    q, _ = torch.linalg.qr(torch.randn(d, d))
    out = frame_diagnostic(make_encode(lambda z: z @ q), [base], [base + shift])
    check_invariant(out, "rotated")
    assert out["mismatch_to_displacement_ratio"] > 5.0, out
    assert out["procrustes_residual_ratio"] < 0.05, out
    # A genuine rotation must register as one: absorbed by Procrustes AND far
    # from identity. Without the second assert, a no-op R would pass the first.
    assert out["rotation_from_identity"] > 0.1, out
    print(f"  rotated target       ratio={out['mismatch_to_displacement_ratio']:.1f}  "
          f"procrustes={out['procrustes_residual_ratio']:.2e}  "
          f"rot={out['rotation_from_identity']:.2f}  (want big, ~0, >0) OK")

    # --- polarity 3: target differs NON-rotationally (per-dim scaling).
    # Mismatch large, Procrustes must NOT absorb it. Distinguishes gauge from
    # genuine disagreement, which is the point of reporting both. ---
    out = frame_diagnostic(make_encode(lambda z: z * torch.linspace(0.5, 2.0, d)),
                           [base], [base + shift])
    check_invariant(out, "scaled")
    assert out["mismatch_to_displacement_ratio"] > 5.0, out
    assert out["procrustes_residual_ratio"] > 0.15, out
    # Per-dimension scaling is diagonal-positive, so the optimal R is near I:
    # large residual WITH a small rotation is the signature of non-gauge
    # disagreement, and is what separates this case from polarity 2.
    assert out["rotation_from_identity"] < 0.1, out
    print(f"  scaled target        ratio={out['mismatch_to_displacement_ratio']:.1f}  "
          f"procrustes={out['procrustes_residual_ratio']:.2f}  "
          f"rot={out['rotation_from_identity']:.2f}  (want big, NOT ~0, ~0) OK")

    # --- polarity 4: pure TRANSLATION. Centering removes it, so the residual
    # ratio must report nan rather than dividing noise by noise -- and the
    # centroid gap must carry the signal instead. This is the case that
    # previously printed a stable ~1.5-2.2 in the "not rotational" bin. ---
    offset = torch.randn(1, d) * 3.0
    out = frame_diagnostic(make_encode(lambda z: z + offset), [base], [base + shift])
    check_invariant(out, "translated")
    assert out["procrustes_residual_ratio"] != out["procrustes_residual_ratio"], \
        f"pure translation must report nan, got {out['procrustes_residual_ratio']}"
    assert out["centroid_gap"] > 1.0, out
    assert out["frame_mismatch_median"] > 1.0, out
    print(f"  translated target    centroid_gap={out['centroid_gap']:.2f}  "
          f"procrustes=nan  (want gap>0, nan) OK")

    # --- invariant sweep: ratio <= 1 must hold across mixed perturbations. ---
    for i in range(50):
        g = torch.Generator().manual_seed(1000 + i)
        pert = torch.randn(d, d, generator=g) * (0.01 * (1 + i % 20))
        out = frame_diagnostic(make_encode(lambda z, p=pert: z + z @ p), [base], [base + shift])
        check_invariant(out, f"sweep[{i}]")
    print("  invariant sweep      50 mixed perturbations, all ratio <= 1 OK")

    print("frame_diagnostic self-test: all four polarities + invariant pass")


if __name__ == "__main__":
    _self_test()
