# Q3 — Session-to-session variability as a factor in EEG self-supervised learning

**Scope of this note:** does published work tell a from-zero single-subject 4-channel/256 Hz collector to record ONE long block or MANY SHORT sessions across days with headset re-placement?

**Bottom line up front:** No paper directly answers the question in EEG. But three independent lines of published evidence converge on *many short sessions with re-placement*, and one line of evidence (Banville's pretext-task design) explains why the penalty for a single-session corpus is smaller for time-offset pretext tasks than for augmentation-invariance methods. Every claim below is tagged DIRECT EVIDENCE / INFERENCE / SINGLE SOURCE.

---

## Evidence table

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Cheng, Goh, Dogrusoz, Tuzel, Azemi — *Subject-Aware Contrastive Learning for Biosignals* (arXiv:2007.04871) | https://ar5iv.labs.arxiv.org/html/2007.04871 | "With the variability in how the sensors are setup and how the signals behave for each subject, the learned embeddings **will be dominated by subject-specific characteristics**." Also: "For **multi-session measurements, the differences in sensor setup for the same subject will also be a factor** but can be treated as a separate subject with this formulation." | primary (read in full) | high |
| 2 | Cheng et al., same paper — subject-ID probe result | https://ar5iv.labs.arxiv.org/html/2007.04871 | Both subject-specific and subject-invariant training "decreased subject features (**lower subject identification accuracies**) and improved classification accuracies." Subject-invariance mattered most in the **few-subject regime**; with ~64+ subjects base SSL caught up. | primary (read) | high |
| 3 | Banville, Chehab, Hyvärinen, Engemann, Gramfort — *Uncovering the structure of clinical EEG signals with self-supervised learning* (arXiv:2007.16104) | https://ar5iv.labs.arxiv.org/html/2007.16104 | RP/TS positives AND negatives are sampled from **time indices within a single time series S**; negative sampling is a *choice* between "same-recording" and "across-recording". CPC likewise defines "same-recording negative sampling" vs "across-recording negative sampling". | primary (read) | high |
| 4 | Banville et al., same paper — Fig. 6 / §3.2 | https://ar5iv.labs.arxiv.org/html/2007.16104 | TS-learned embeddings on TUHab form clusters that align with **number of EEG channels and measurement date** of the original recording: "the cluster-like structure reflects differences in experimental setups… the SSL tasks have partially learned the noise introduced by data collection." Mitigation suggested: aggressive preprocessing, or **sampling negatives within recordings from the same cohort**. | primary (read) | high |
| 5 | Banville et al., same paper — §3.3 negative-sampling ablation | https://ar5iv.labs.arxiv.org/html/2007.16104 | Same-recording vs across-recording negative sampling has a **"considerable effect"** on downstream performance and the effect **reverses by task**: sleep staging degrades with across-recording negatives, pathology detection improves. For CPC on sleep the effect was minor (71.6 vs 72.2%). | primary (read) | high |
| 6 | Banville et al. — earlier paper, *Self-supervised representation learning from EEG signals* (arXiv:1911.05419) | https://arxiv.org/abs/1911.05419 | Exists; abstract confirms "predicting whether time windows are sampled from the same temporal context or not," sleep scoring, two EEG datasets, beats supervised in low-data regimes. (Abstract read only — contents beyond abstract NOT read.) | primary (abstract only) | medium |
| 7 | Ma, Chen, et al. — SHU multi-day MI dataset, *Sci Data* 2022 (5 sessions × 25 subjects) | https://pmc.ncbi.nlm.nih.gov/articles/PMC9436944/ | Within-session avg accuracy 68.8% ± 0.146 (FBCNet, best of 5 methods, 125 sessions, 2-class, chance 51.4%). Cross-session (train on session 1, test on sessions 2–5, same subject): "the performance of the three deep learning algorithms was **not good**"; only **20 of 100 test sessions exceeded 60%** with EEGNet (best method). | primary (read) | high |
| 8 | Ma et al., same — cross-session adaptation | https://pmc.ncbi.nlm.nih.gov/articles/PMC9436944/ | Adding target-session data recovers and exceeds: 50% adaptive training → 70.52% (> 68.8% within-session); 100% → 78.86% (~+10 pts). | primary (read) | high |
| 9 | *A Dual-Validation Framework for Temporal Robustness…*, Technologies 13(12):595, 2025 | https://www.mdpi.com/2227-7080/13/12/595 | **Counter-evidence:** with 6 subjects, OpenBCI 16-ch, sessions 1–2 days apart, CSP+classical ML, within→cross-session drop was only **2.5% average** (AdaBoost 84.0%→81.4%; KNN 83.3%→81.2%); significant (Wilcoxon p=0.010) but small (Cohen's d=0.606). Authors explicitly flag the 1–2 day gap as a limitation. | primary (read) | medium (n=6, short gaps, MDPI) |
| 10 | *The Identity Trap in EEG Foundation Models: A Diagnostic Audit* (arXiv:2606.06647) | https://arxiv.org/html/2606.06647v1 | Subject-identity variance fraction in frozen FM embeddings is **13–89× a random-Gaussian null in 12 of 12 model×dataset pairs**, rising further under fine-tuning (+10 to +63 pp). Erasing the linear identity axis **improves** label decoding (+6 to +12 pp primary; +4 to +27 pp external). Aperiodic 1/f is one identified carrier (removing it drops the subject probe 9–19 pp on LaBraM/CBraMod). Called "a physically-grounded instance of **shortcut learning**." | primary (abstract + intro read) | high |
| 11 | Yuan et al., *SSL for HAR using 700,000 person-days of wearable data*, npj Digital Medicine 2024 | https://www.nature.com/articles/s41746-024-01062-3 | **CROSS-MODALITY, closest thing to a breadth-vs-depth ablation found.** Downstream F1 increases roughly **log-linearly with number of unlabelled subjects**. At fixed 10,000 pretraining participants, "the data ratio included **per subject** did not significantly influence downstream performance… did not degrade more than 10% in F1 even when we reduced the amount of data per subject from 100 to 25%." | primary (read) | high |
| 12 | Kostas, Aroca-Ouellette, Rudzicz — *BENDR*, Front. Hum. Neurosci. 2021 | https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2021.653659/full | Design prescription (not an ablation): "the ideal pre-training dataset for our purposes would feature many subjects, **each recorded over many sessions**. These sessions would also ideally be **distributed across large time scales** and consist of a variety of performed tasks." | primary (provider snippet; full text NOT fetched) | medium |
| 13 | Śliwowski, Martin, et al. — *Impact of dataset size and long-term ECoG-based BCI usage on deep learning decoders performance*, Front. Hum. Neurosci. 2023 | https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2023.1111645/full | 43 sessions over >200 days, one tetraplegic patient, ECoG 586 Hz. Learning curves showed features "unlikely caused by just the dataset increase"; intrinsic dimensionality and state separability of the data **changed over time**, attributed to long-term patient learning. Explicitly: "in some cases, we may add more data to the dataset and **decrease** the performance," because of non-stationarity. Also notes optimal training-data quantity "is rarely studied for BCI" and most human BCI studies use <15 sessions. | primary (intro + discussion read) | high |
| 14 | Zanini et al., *Transfer Learning: A Riemannian Geometry Framework…*, IEEE TBME 2018 | https://ieeexplore.ieee.org/document/8013808 (preprint: https://hal.science/hal-01923278/document) | Proposes affine re-centering of per-session/per-subject covariance matrices to a reference, motivated by "changes between sessions and between subjects, including physiological, environmental, as well as **instrumental** changes." | primary (abstract only — full text NOT read) | medium |
| 15 | He & Wu, *Transfer Learning for BCIs: A Euclidean Space Data Alignment Approach* (arXiv:1808.05464) | https://ar5iv.labs.arxiv.org/html/1808.05464 | Euclidean alignment of per-session/subject trial covariances; term "covariance shift" used for session-level distribution change. | primary (abstract only — full text NOT read) | medium |
| 16 | *Pretrained, Frozen, Still Leaking: Auditing Cross-Encoder Attribute Transfer in EEG Foundation Models* (arXiv:2606.09189) | https://arxiv.org/html/2606.09189v1 | Frozen released EEG-FM embeddings (BIOT, LaBraM, EEGPT) leak spectral attributes; a ridge attribute decoder learned on one frozen encoder transfers to another. (Abstract only.) | primary (abstract only) | medium |

---

## Findings by sub-question

### (a) Does ANY paper compare one long recording vs many short recordings as SSL pretraining data, or ablate #sessions at fixed total hours?

**In EEG: NO. I found no such ablation.** Status: **answered — no published answer exists** within my search protocol (protocol bounded below).

What exists instead:
- EEG SSL papers ablate **total hours** or **number of subjects**, not **number of sessions at fixed hours**. This is confirmed indirectly by [13], which states that optimal training-data quantity and learning curves "are rarely studied for BCI."
- [12] BENDR states the *prescription* — "many subjects, each recorded over many sessions… distributed across large time scales" — as a dataset-design desideratum, with **no ablation backing it** in the quoted text. This is a design opinion by credible authors, not a measured result. SINGLE SOURCE; full text not read.

**Cross-modality, the closest real ablation is [11] (wearable accelerometer HAR, UK Biobank, 700k person-days).** DIRECT EVIDENCE, cross-modality:
- Holding pretraining participants fixed at 10,000, cutting **data per subject from 100% → 25%** cost **<10% downstream F1**.
- Increasing the **number of unlabelled subjects** improved downstream F1 approximately **log-linearly**.
- Read as a breadth-vs-depth statement: **breadth of recording contexts bought more than depth within a context**, at a ~4× depth reduction.

**Transfer caveat (INFERENCE, mine):** [11] varies *subjects*, not *sessions within one subject*. For a single-subject protocol the analogue of "more subjects" is "more sessions/mountings", because [1] explicitly says a re-mounted session behaves like a separate subject for the purposes of the SSL objective ("differences in sensor setup for the same subject… can be treated as a separate subject"). That mapping is an inference, not a result anyone measured.

ECG scaling papers surfaced (e.g. https://arxiv.org/html/2605.12241, https://arxiv.org/html/2605.17276v1, https://doi.org/10.48550/arxiv.2509.10369) study cohort composition and parameter/data scaling. I did **not** read them and cannot claim any of them contains a sessions-at-fixed-hours ablation. Flagged as unresolved follow-up.

---

### (b) SESSION SHORTCUT: do augmentation-invariance methods learn recording/session identity as a shortcut?

**Yes — DIRECT EVIDENCE, multiple independent sources.**

1. **[1] Apple, Cheng et al. 2020, states the mechanism outright.** The InfoNCE loss "focuses on features that differentiate each time segment from other time segments. With the variability in how the sensors are setup and how the signals behave for each subject, **the learned embeddings will be dominated by subject-specific characteristics**." Their entire subject-invariance apparatus (adversarial subject classifier + subject-specific negative sampling) exists to *counteract* this. This is the paper's premise, so it is stated, not measured — but it is measured downstream (point 2).

2. **[2] They measure it.** They train a subject-ID classifier on the frozen embedding as a probe. Base SSL yields higher subject-ID accuracy; both subject-aware variants lower it, and lowering it **raises** downstream task accuracy. (The exact percentages are in Tables 2 and 4, which did not render in the ar5iv text I read — I am not quoting numbers I did not see.) Critically for us: the benefit of subject-invariance was **largest with few subjects and vanished at ~64 subjects**. Single-subject/single-session is the extreme of the regime where it matters most.

3. **[1] explicitly extends this to sessions.** "For multi-session measurements, **the differences in sensor setup for the same subject will also be a factor** but can be treated as a separate subject with this formulation." That is the sharpest published statement I found that *session ≡ nuisance domain* for contrastive biosignal SSL. SINGLE SOURCE for the sessions-specifically framing.

4. **[4] Banville shows the artifact empirically in EEG embeddings.** On TUHab, temporal-shuffling embeddings cluster by **channel count and measurement date** — i.e. by acquisition setup — and the authors say the model "partially learned the noise introduced by data collection." This is the recording-identity shortcut visualized. DIRECT EVIDENCE.

5. **[10] Identity Trap quantifies the shortcut in modern EEG foundation models.** Subject-identity variance in frozen embeddings is **13–89× a random null in 12/12 model×dataset pairs**, and **erasing** the linear identity direction *improves* label decoding by +6 to +12 pp (up to +27 pp externally). One physical carrier is the **aperiodic 1/f background** — removing it drops the subject probe 9–19 pp on LaBraM/CBraMod. Note the caveat: these are **masked-modeling** FMs, not SimCLR/BYOL, so this is evidence that the shortcut is general to EEG SSL, not specific to augmentation-invariance. [16] independently reports attribute leakage from frozen EEG-FM embeddings.

**Direct answer to "can you decode subject/recording identity from SSL embeddings?" — YES, reported by [2] (probe accuracy, biosignals), [4] (recording setup clusters, EEG), [10] (13–89× null, EEG FMs), [16] (attribute leakage, EEG FMs).**

**Practical consequence (INFERENCE, mine, but grounded in [1]+[10]):** if all positives come from one continuous session on one headset mounting, the electrode-impedance/placement/1-f signature is *constant across the entire corpus*. A constant feature carries zero contrastive gradient — it cannot be used to discriminate positives from negatives — so the model will not *learn to encode* it as a discriminative axis, but it also never learns *invariance* to it. The failure mode is therefore not "the model learns session ID"; it is "the model has never seen a mounting change, so nothing in its representation is invariant to one, and the first re-mount at inference time is fully out-of-distribution." I did not find a paper that states this specific single-session version of the argument. Label it INFERENCE.

---

### (c) Are within-recording pretext tasks (RP / TS / CPC) structurally more robust to a single-session corpus?

**Partly DIRECT, partly INFERENCE. Be precise about which.**

DIRECT, from reading [3]:
- **RP and TS never cross recordings.** The pair set is defined as 𝒯 = {(t,t′) ∈ ⟦M−T+1⟧² : |t−t′| ≤ τ_pos or |t−t′| > τ_neg} — both indices live in **one** multivariate time series S. So a single-recording corpus is not a degenerate case for RP/TS; it is the *native* case. Positives and negatives are both defined by time offset.
- **But Banville does implement an across-recording variant**, and it matters: the paper labels negative-sampling scope "same" vs "all" as a first-class hyperparameter, with a **"considerable effect on downstream performance"** [5]. So the honest answer to "does Banville's RP sampling ever cross recordings?" is: **the default/primary analysis is same-recording, but the paper explicitly ablates an across-all-recordings negative sampler.**
- **The direction of the effect is task-dependent** [5]: across-recording negatives *hurt* sleep staging (because within-recording discrimination *is* the sleep-stage signal) and *help* pathology detection (because the label is constant per recording). CPC on sleep was nearly insensitive (71.6 vs 72.2%).
- **Banville also implies the robustness argument.** In §3.2 they propose mitigating the acquisition-setup clustering by "sampling negative examples **within recordings** from the same cohort" [4]. That is a published statement that *restricting sampling to within-recording reduces the acquisition-artifact contamination*. It is the closest thing to an explicit claim that within-recording sampling is more robust to recording-level nuisance — but it is offered as a *suggestion for mitigation*, not as a tested result.

INFERENCE (mine, from architecture):
- RP/TS/CPC on a single long recording still have a well-posed learning problem, whereas SimCLR/BYOL on a single recording have a *degenerate* nuisance distribution (one mounting), so the augmentation set is the only source of invariance and it must be hand-specified. No paper I found says this.
- The "one long block" option is therefore *less bad* for RP/TS/CPC than for augmentation-invariance SSL. Not measured by anyone.

**Explicit warning from [5], which cuts against pure within-recording sampling for our use case:** the negative-sampling distribution "determines the kind of invariance that the network is forced to learn." With one recording you have exactly one choice available (same-recording), so you forfeit that design lever entirely. DIRECT (the quoted principle); the application to single-session is INFERENCE.

---

### (d) Quantitative EEG non-stationarity across sessions, same subject

The literature is **not consistent** on magnitude, and the disagreement tracks the inter-session gap and the pipeline. Report both.

**Large degradation — [7], SHU dataset, 25 subjects × 5 sessions, 2–3 days apart, 32 ch, 2-class MI (chance ~51%):**
- Within-session (8:1:1 split, 10-fold, 125 sessions): best method FBCNet **68.8% ± 0.146**.
- Cross-session, same subject, train on session 1 → test sessions 2–5: performance "not good"; with the best method (EEGNet), **only 20 of 100 test sessions exceeded 60%**.
- Recovery via target-session data [8]: 50% of target-session data → **70.52%**; 100% → **78.86%** (≈ +10 pts over within-session baseline). *This is the most operationally useful number in the whole note: a single subject's session-1 model does not transfer, but the same subject's data across sessions, once pooled, beats any single session.*

**Small degradation — [9], 6 subjects, sessions 1–2 days apart, 16 ch OpenBCI, CSP + classical ML:**
- Within→cross-session drop **2.5% average** across 10 classifiers (AdaBoost 84.0→81.4; KNN 83.3→81.2; LDA 73.1→74.2, i.e. *up*).
- Statistically significant (Wilcoxon p = 0.010, Cohen's d = 0.606) but small in practice.
- **Caveats I would not ignore:** n = 6; 1–2 day gaps only; authors themselves write that this "may not capture the challenges associated with long-term or real-world BCI deployment spanning weeks or months"; MDPI venue; no external benchmark. SINGLE SOURCE, and it is the outlier.

**Long-horizon, high-session-count — [13], 43 sessions over >200 days, one tetraplegic patient, ECoG (not EEG):**
- The dataset's **intrinsic dimensionality and state separability changed over time**, which the authors attribute to long-term patient learning, i.e. the *generating distribution itself drifts* over months, not just the sensor.
- "In some cases, we may add more data to the dataset… and **decrease** the performance," due to non-stationarity. DIRECT.
- Notes most human BCI longitudinal studies use **<15 sessions**, and that >20-session studies are rare (they cite Neuper 2003, Wolpaw & McFarland 2004, McFarland 2010, Wodlinger 2014, Perdikis 2018, Moly 2022 — I did **not** read any of those).
- **They do not report a session count at which a subject-specific model stabilizes.** I found no paper that reports such a number.

**Alignment methods [14][15]:** Both Riemannian (Zanini) and Euclidean (He & Wu) alignment exist precisely because per-session covariance means differ; Zanini's abstract attributes inter-session change to "physiological, environmental, as well as **instrumental** changes." I read abstracts only — **I am not reporting an accuracy-gain number from either, because I did not read their results tables.** Unresolved: the magnitude of covariance/distribution shift in a metric (e.g. Riemannian distance between session means) was **not** located.

**Unresolved in (d):** (i) no published "N sessions until a single-subject model stabilizes"; (ii) no quantitative covariance-shift magnitude read directly; (iii) the 2.5% vs "20/100 sessions above 60%" discrepancy is not adjudicated by any source I read — it is plausibly explained by the 1–2 day vs 2–3 day gaps, sample size, and CSP-vs-deep pipelines, but that explanation is my INFERENCE.

---

## Synthesis: what this implies for the 4-channel / 256 Hz / single-subject protocol

Ranked by evidential strength:

1. **Many short sessions with deliberate re-placement, not one long block.** Strongest support: [11] (fixed budget, breadth > depth, cross-modality, DIRECT), [1] (a re-mounted session functions as a separate nuisance domain, DIRECT statement), [12] (design prescription, no ablation), [4] (embeddings otherwise cluster by acquisition setup, DIRECT). No paper measured this in EEG. Confidence: medium-high, entirely on convergent indirect evidence.
2. **Deliberately vary the mounting.** [1] and [4] together say the nuisance axis is the *sensor setup*, so re-placement variance is the thing that must appear in the corpus for the model to become invariant to it. If every session uses an identical, carefully reproduced mounting, you have partially defeated the point.
3. **Expect a single-session model to fail on a new session.** [7]: 20/100 cross-session tests above 60% vs 68.8% within-session. Do not validate within-session only.
4. **Pool sessions rather than picking one.** [8]: pooled/adapted target data reached 78.86% vs 68.8% single-session baseline.
5. **If forced into one long block, prefer RP/TS/CPC over SimCLR/BYOL.** DIRECT part: RP/TS are defined entirely within one recording [3]. INFERENCE part: therefore they degrade more gracefully on a one-session corpus. Not tested by anyone.
6. **Log per-session metadata (mounting, impedance, date, time-of-day) from day one.** Justification: [10] shows identity/1-f structure is a *removable linear axis*, and [1] shows session-as-pseudo-subject labels enable adversarial removal. Neither is possible retroactively without session labels. INFERENCE from the mechanics of both methods.
7. **The counter-case is real but weak.** [9] found only 2.5% drop at 1–2 day gaps. If your entire deployment horizon is a couple of days with a stable mounting, the session penalty may be modest. n=6, MDPI, short gaps — I would not design around it.

---

## Coverage Status

**Checked directly (read the source text):**
- arXiv:2007.04871 Subject-Aware Contrastive Learning for Biosignals — read methods, results, conclusion. Tables 1–4 did not render in ar5iv text; **numeric subject-ID probe accuracies not obtained.**
- arXiv:2007.16104 Banville et al. — read §2.2 (RP/TS/CPC sampling definitions), §3.1–3.3 (embedding structure, Fig. 6 setup clustering, negative-sampling ablation).
- PMC9436944 SHU multi-day MI dataset — read technical validation (WS, CS, CSA sections).
- MDPI Technologies 13(12):595 — read methods §2.4 and results §3.1–3.4.
- arXiv:2606.06647 Identity Trap — read abstract + introduction. **Did not read results tables.**
- Frontiers fnhum.2023.1111645 (ECoG 43 sessions) — read introduction + discussion/conclusions. **Did not read the learning-curve figures/numbers.**
- npj Digital Medicine s41746-024-01062-3 — read ablation section + discussion.
- arXiv:1911.05419 — abstract only (existence + scope verified).

**Not read, cited at abstract/snippet level only (flagged in table):** Zanini TBME 2018 [14], He & Wu 1808.05464 [15], BENDR [12], arXiv:2606.09189 [16].

**Questions with no published answer found (bounded by protocol below):**
- (a) EEG: no sessions-vs-hours ablation at fixed total duration. **Marked: no published answer.**
- (c) No paper *explicitly states* that within-recording pretext tasks are more robust to a single-session corpus; the closest is Banville's mitigation suggestion [4]. The strong version is my INFERENCE.
- (d) No paper reports "N sessions until a single-subject model stabilizes." No directly-read quantitative covariance-shift magnitude.

**Search protocol used (so the null results are bounded):** `web_search` with multi-angle query arrays, 6–8 results each, across: EEG SSL pretraining ablation phrasing (recordings vs hours, number of sessions at fixed duration); contrastive shortcut/subject-identity/confound phrasing; subject-aware contrastive biosignals; cross-session BCI accuracy drop; Euclidean/Riemannian alignment; longitudinal BCI session counts; wearable-HAR and ECG SSL data-quantity ablations. Direct fetch + slice-read of 8 primary sources. **Not searched:** MEG/fMRI session-effect literature, EMG/PPG SSL specifically, non-English sources, Semantic Scholar/OpenAlex citation-graph traversal from [1] or [3] (which is the highest-value next step for sub-question (a) — the ~77 citations of arXiv:2007.04871 and the citing set of Banville are the most likely place a sessions ablation would hide).

**Follow-up I could not complete in budget:**
1. Citation-graph traversal of arXiv:2007.04871 and arXiv:2007.16104 for a sessions-at-fixed-hours ablation.
2. Reading the Identity Trap results tables for per-model subject-probe accuracies.
3. Reading Zanini 2018 and He & Wu 2018 results for a covariance-shift magnitude number.
4. Confirming whether any ECG SSL scaling paper (arXiv:2605.12241, 2509.10369, 2605.17276) contains a per-patient recordings-count ablation.

---

## Sources

1. Cheng, Goh, Dogrusoz, Tuzel, Azemi — *Subject-Aware Contrastive Learning for Biosignals* (arXiv:2007.04871) — https://ar5iv.labs.arxiv.org/html/2007.04871 (also https://machinelearning.apple.com/research/subject-aware-contrastive-learning)
2. (same paper, subject-ID probe results) — https://ar5iv.labs.arxiv.org/html/2007.04871
3. Banville, Chehab, Hyvärinen, Engemann, Gramfort — *Uncovering the structure of clinical EEG signals with self-supervised learning* (arXiv:2007.16104) — https://ar5iv.labs.arxiv.org/html/2007.16104
4. (same paper, §3.2 / Fig. 6 acquisition-setup clustering) — https://ar5iv.labs.arxiv.org/html/2007.16104
5. (same paper, §3.3 negative-sampling ablation) — https://ar5iv.labs.arxiv.org/html/2007.16104
6. Banville et al. — *Self-supervised representation learning from electroencephalography signals* (arXiv:1911.05419) — https://arxiv.org/abs/1911.05419
7. SHU multi-day motor-imagery dataset, *Scientific Data* 2022 — https://pmc.ncbi.nlm.nih.gov/articles/PMC9436944/
8. (same, cross-session adaptation results) — https://pmc.ncbi.nlm.nih.gov/articles/PMC9436944/
9. *A Dual-Validation Framework for Temporal Robustness Assessment in Brain–Computer Interfaces for Motor Imagery*, Technologies 13(12):595 — https://www.mdpi.com/2227-7080/13/12/595
10. *The Identity Trap in EEG Foundation Models: A Diagnostic Audit* (arXiv:2606.06647) — https://arxiv.org/html/2606.06647v1
11. Yuan et al. — *Self-supervised learning for human activity recognition using 700,000 person-days of wearable data*, npj Digital Medicine 2024 — https://www.nature.com/articles/s41746-024-01062-3
12. Kostas, Aroca-Ouellette, Rudzicz — *BENDR*, Frontiers in Human Neuroscience 2021 — https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2021.653659/full
13. Śliwowski, Martin, et al. — *Impact of dataset size and long-term ECoG-based BCI usage on deep learning decoders performance*, Frontiers in Human Neuroscience 2023 — https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2023.1111645/full
14. Zanini et al. — *Transfer Learning: A Riemannian Geometry Framework With Applications to Brain–Computer Interfaces*, IEEE TBME 2018 — https://ieeexplore.ieee.org/document/8013808 / https://hal.science/hal-01923278/document
15. He & Wu — *Transfer Learning for Brain-Computer Interfaces: A Euclidean Space Data Alignment Approach* (arXiv:1808.05464) — https://ar5iv.labs.arxiv.org/html/1808.05464
16. *Pretrained, Frozen, Still Leaking: Auditing Cross-Encoder Attribute Transfer in EEG Foundation Models* (arXiv:2606.09189) — https://arxiv.org/html/2606.09189v1
