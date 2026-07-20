# Representation Geometry & Spectral Preprocessing for the Synthetic JEPA World Model

*Scientific grounding for the WorldModel `/loop` (Phase B forward-evaluation design). The loop **reads** this;
it does not re-derive it. This is a literature synthesis, not a result of this repo — every claim's transfer
to our synthetic setting is a **hypothesis the Phase-B benchmark tests**, not an established fact here.*

## TL;DR
- **The 1/f log-transform must be *conditional*, not default, and is better re-specified as explicit
  periodic/aperiodic decomposition (specparam/FOOOF) than as blind log-compression.** In JEPA-style latent
  prediction the **aperiodic exponent is often the *signal*, not nuisance** — it has documented physiological
  meaning (excitation/inhibition balance; Donoghue et al., *Nat. Neurosci.* 23:1655–1665, 2020) and blindly
  compressing it can delete the most informative component. Keep the transform only where a **forward
  benchmark** shows it helps.
- **Backward validation (finite/bounded/deterministic/round-trippable) is necessary but NOT sufficient.** A
  forward benchmark is mandatory: synthetic latent-factor recovery + latent-space MPC planning, reporting a
  **panel** (RankMe/LiDAR, α-ReQ, VICReg var/cov, linear-probe factor recovery) — each an imperfect proxy with
  documented failure cases.
- **For the heterogeneous embedding zoo (language, world-state, semantic graph, dialectical memory, JEPA
  latent): do NOT use one shared space or naive concatenation.** Use **coupled latent spaces** with learned
  cross-attention/alignment, optionally over a **product manifold** (Euclidean world-state × hyperbolic
  graph/memory). *(This is a future direction — OUT of the WorldModel-only loop; it spans `Sources/`.)*

## Key findings
1. **Suppressing/compressing 1/f helps only when it is nuisance; it hurts when it is signal.** Efficient-coding
   (Field 1987; Dan, Atick & Reid 1996) motivates whitening because natural-image power spectra fall ~1/f² and
   flattening decorrelates. But specparam (Donoghue 2020) shows the aperiodic exponent carries information and
   tracks E/I balance (Gao 2017; Wiest et al., *eLife* 2023). **Whether to suppress 1/f is a domain-dependent
   empirical question, not a default.**
2. **Whitening/decorrelation helps by three DISTINCT mechanisms the roadmap conflates:** (a) optimization
   conditioning (LeCun et al., "Efficient BackProp," 1998 — input covariance → identity lowers the Hessian
   condition number); (b) collapse prevention (VICReg covariance term; Barlow Twins; W-MSE — on the
   *embedding*); (c) dynamic-range compression (log/symlog for heavy tails — DreamerV3, *Nature* 2025).
3. **A log transform is generally NOT the right representation of 1/f for a JEPA encoder** — it is a monotone
   compressor, not a decomposition. The principled step is to estimate the spectral exponent first (specparam)
   and feed explicit periodic + aperiodic parameters, letting the encoder decide.
4. **No label-free metric is a trusted oracle — report a panel, anchor to a downstream task.** RankMe (Garrido
   et al., ICML 2023) predicts downstream accuracy in standard JE-SSL but *fails* elsewhere (no correlation
   with defect-detection F1/F2 — "Otero et al. 2024" [first author to verify]); α-ReQ (Agrawal et al., NeurIPS
   2022; good-generalization near α ≈ 1 [interval to verify]); LiDAR (Thilak et al., ICLR 2024) is
   JEPA-specific and preferred; linear-probe transfer degrades for few-shot/dense tasks (Ericsson et al., CVPR
   2021). RankMe & α-ReQ **break under collapse**.
5. **Major world-model projects converge on modular, staged structure** (Ha & Schmidhuber V/M/C; Dreamer v1–v3;
   TD-MPC2; V-JEPA 2 → 2-AC frozen encoder + separate action-conditioned predictor). Our research→validated→
   production isolation is consistent with practice — caveat: over-isolation can starve the representation, so
   add a **joint end-to-end gate** before any promotion.

## Preferred spectral-input ordering (most→least principled for a JEPA world model)
1. **specparam periodic + aperiodic channels** (preserves aperiodic info as explicit, interpretable features).
2. **Learned/parametric normalization** (standardize; learned affine + symlog) — scale-robustness without
   targeted 1/f suppression.
3. **Log band-power (the ported transform)** — acceptable dynamic-range compression, but conflates aperiodic +
   periodic; keep only if the benchmark beats 1–2.
4. **Aggressive 1/f flatten** — only if the benchmark shows the aperiodic component is nuisance. A hypothesis,
   never a default.

## Phase-B synthetic forward-evaluation protocol (the loop implements this)
1. **Controllable generator:** known ground-truth latent factors + a **dial-able aperiodic exponent** and
   inject/removable oscillatory peaks. Make *some* factors depend on the slope and some not — that is what
   makes "signal vs nuisance" measurable. Synthetic, never real EEG; seeded.
2. **Arms (identical encoder+predictor):** `{none · standardize · symlog · log-band-power · specparam
   periodic+aperiodic · aggressive 1/f-flatten}`.
3. **Metric panel (all, multi-seed CIs):** (i) latent multi-step rollout error; (ii) goal-conditioned MPC/CEM
   planning success; (iii) linear-probe recovery of each latent factor — **including a probe for the aperiodic
   exponent itself** (information-destruction detector); (iv) RankMe + α-ReQ + LiDAR; (v) VICReg var & cov; (vi)
   alignment/uniformity (Wang & Isola).
4. **Decision rule:** adopt a transform **only if it improves (i)+(ii) without degrading factor recovery,
   especially the aperiodic-exponent probe.** If 1/f suppression raises rollout accuracy but *lowers*
   aperiodic recovery → **reject it; record the negative result** (direct evidence it discards signal).
5. **Never promote on a label-free metric alone.** Anchor to (i)+(ii)+factor recovery. Multi-seed ± CI; a
   single run is uninformative given SSL variance.

## Future direction (OUT of this loop — document, don't build here)
Coupled latent spaces (cross-attention + alignment/uniformity) as the top level; a **hyperbolic (or small
product) factor** for the semantic-graph/dialectical-memory hierarchy; JEPA latent stays Euclidean/ℓ2;
language stays in its native LLM space. Rationale: Euclidean distorts trees (Nickel & Kiela 2017); mixed
curvature reduces distortion (Gu et al., ICLR 2019) but can overfit topology / regress OOD (McNeela et al.
2023); a single contrastive space induces a persistent modality gap (Liang 2022; Fahim 2024). **This spans
`Sources/` embeddings and is open-ended — capture as a ledger research question, do not implement in the
WorldModel loop.**

## Caveats (carry these into every result)
- **Domain transfer unverified.** The metric/geometry evidence is from vision/NLP SSL; transfer to synthetic
  EEG-derived spectral features is *plausible but unverified* — that is *why* Phase B tests it.
- **The synthetic aperiodic exponent is a MODEL of 1/f, not real physiology.** Any result is "on this synthetic
  generator," never a physiological claim.
- **Label-free metrics are imperfect** and break under collapse — never promote on one alone.
- **Verify citations before any formal write-up:** the "Otero et al. 2024" first author and the α-ReQ "α ≈ 1"
  interval are flagged as needing confirmation.
