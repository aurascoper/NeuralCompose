# Q1 — Does any published EEG self-supervised-learning result PRETRAIN on a SINGLE SUBJECT?

Research date: run of 2026-08 (arXiv IDs up to 2607.x observed in indices).
Scope: counterexample hunt OUTSIDE the sleep-staging low-channel SSL set already swept by the parent.

---

## BOTTOM LINE (plain answer)

**In EEG specifically: NO. I found no published result that performs self-supervised PRETRAINING on a single subject's EEG.** Every EEG SSL / EEG-foundation-model pretraining corpus I could verify uses ≥8 subjects, and the mainstream ones use 10³–10⁴ subjects [2][10][11][14].

**The nearest published counterexamples are in MEG, not EEG, and only one of them is genuinely single-subject:**

- **VERIFIED, single-subject pretraining, but SUPERVISED not self-supervised:** de Zuazo et al. 2026 (arXiv:2602.18253) pre-train a Conformer on **50 hours of MEG from ONE subject** (LibriBrain) and fine-tune on 5 min/subject across 18 new subjects, with statistically significant transfer gains [3][4]. The pretraining objective is binary speech/silence detection from voice-activity labels — it is transfer learning from a labelled single-subject corpus, **not SSL**. This is the closest existing analogue to "pretrain on one person" in non-invasive electrophysiology.
- **VERIFIED, SSL, but NOT single-subject:** MEG-XL (ICML 2026, arXiv:2602.02494) does masked-token SSL on ~300 h from CamCAN + MOUS + SMN4Lang (hundreds of subjects); LibriBrain (the deep single-subject set) is only an *evaluation/fine-tuning* target [5].

So: **the single-subject-pretraining cell of the design matrix is empty for EEG+SSL, occupied for MEG+supervised, and explicitly flagged as future work by the one team that got closest** ("Second, pre-training relied on a single subject, and future work should assess whether multi-subject pre-training improves generalization" [4]).

**On the most decision-relevant experiment (subjects vs. hours at fixed data):** no EEG *SSL* paper ablates this. But two directly-read papers give the deep-vs-broad answer in supervised non-invasive M/EEG, and both favour depth-per-subject:
- d'Ascoli et al., Nature Communications 2025: *"with a fixed recording budget, one should favor deep datasets (few participants over many sessions) than broad datasets (many participants over few sessions)"* [6].
- Wagner-style learning-curve study, J. Neural Eng. 2025 (10.1088/1741-2552/ae453d): explicitly *"distinguish between the effects of adding more subjects versus increasing the amount of data per subject"* across 16→10,240 subjects [7]. (I read the intro/methods; I did NOT read the results section that reports which axis wins — marked **needs follow-up**.)

---

## Evidence table

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Cheng, Goh, Dogrusoz, Tuzel, Azemi — *Subject-Aware Contrastive Learning for Biosignals* (arXiv:2007.04871) | https://ar5iv.labs.arxiv.org/html/2007.04871 | SSL pretraining uses **90 subjects** (PhysioNet MI). The "fewer subjects" ablation varies subjects used to train the **linear classifier** (4→64), NOT the pretraining set. No single/few-subject pretraining arm exists. | primary (read full text) | high |
| 2 | Cheng et al., same | https://machinelearning.apple.com/research/subject-aware-contrastive-learning | "In this regime of limited labels and subjects, intersubject variability **negatively impacts** model performance" → variability framed as nuisance | primary | high |
| 3 | Özdogan et al., *LibriBrain: Over 50 Hours of Within-Subject MEG* (arXiv:2506.02098) | https://arxiv.org/abs/2506.02098 | "largest single-subject MEG dataset to date for speech decoding, with over 50 hours of recordings" | primary (abstract/snippet via alphaXiv) | medium (abstract only) |
| 4 | de Zuazo et al., *MEG-to-MEG Transfer Learning and Cross-Task Speech/Silence Detection with Limited Data* (arXiv:2602.18253) | https://arxiv.org/html/2602.18253v1 | **Pre-trains on 50 h of ONE subject's MEG**, fine-tunes on 5 min/subject × 18 subjects; +1–4% in-task, +5–6% cross-task; "Second, pre-training relied on a single subject, and future work should assess whether multi-subject pre-training improves generalization." Pretraining objective = supervised binary speech detection. | primary (read full text) | high |
| 5 | Jayalath et al., *MEG-XL: Data-Efficient Brain-to-Text via Long-Context Pre-Training* (ICML 2026, arXiv:2602.02494) | https://arxiv.org/html/2602.02494v2 | SSL (masked token prediction) pretrained on ~300 h from CamCAN+MOUS+SMN4Lang — **multi-subject**. LibriBrain used only for fine-tuning/eval. Key result: "On LibriBrain, a deep single-subject dataset, both methods perform similarly until ~2.5 hours of training data, after which their supervised method pulls ahead." | primary (read full text) | high |
| 6 | d'Ascoli et al., *Towards decoding individual words from non-invasive brain recordings*, Nature Comms 2025 | https://pmc.ncbi.nlm.nih.gov/articles/PMC12658044/ | "decoding accuracy does not consistently vary with the dataset sizes … we observe a weak trend with the log volume of data **per subject** … with a fixed recording budget, one should favor **deep** datasets (few participants over many sessions) than **broad** datasets". Also: averaging over contexts within a subject beats averaging across subjects. Supervised contrastive, not SSL. | primary (read full text) | high |
| 7 | *How much EEG is needed for deep learning with CNNs?*, J. Neural Eng. (10.1088/1741-2552/ae453d) | https://beta.iopscience.iop.org/article/10.1088/1741-2552/ae453d/meta | "we distinguish between the effects of adding more subjects versus increasing the amount of data per subject"; 16 → 10,240 subjects; TUEG/TUAB/TDBRAIN; supervised CNNs (Mini-SpaTeN, ShallowConvNet, EEGNet) | primary (read intro+methods) | high for existence, **unread for the verdict** |
| 8 | Marty, Pereira, Bellec, Barbosa — *Self-supervised EEG pretraining amplifies individual differences in neural representations*, ICLR 2026 workshop | https://iclr.cc/virtual/2026/10022273 | Evaluates NeuroGPT on 18 subjects w/ simultaneous EEG-BOLD: "NeuroGPT embeddings reliably **amplify individual idiosyncrasies**… self-supervised pre-training **enriches, rather than homogenizes**, subject-level representational structure" | primary (abstract read; full PDF blocked by OpenReview bot check) | medium |
| 9 | Jayalath et al., *The Brain's Bitter Lesson: Scaling Speech Decoding with SSL* (ICML 2025) | https://proceedings.mlr.press/v267/jayalath25a.html | "progress … primarily driven by **large single-subject datasets**. However, due to individual variation … leveraging data across subjects and datasets remains challenging." Their contribution is the *opposite* direction: pool across subjects. | primary (abstract) | medium |
| 10 | REVE (NeurIPS 2025) | https://arxiv.org/html/2510.21585v1 | EEG foundation model, 25,000 subjects, 60k h | primary (abstract) | high |
| 11 | DIVER-1 (arXiv:2512.19097) | https://arxiv.org/html/2512.19097v1 | 54k h EEG + 5.3k h iEEG, 17.7k subjects; "first systematic scaling law analysis spanning both EEG and iEEG … a distinct **data-constrained** characteristic" | primary (abstract) | medium |
| 12 | Banville et al., *Do try this at home*, Imaging Neuroscience 2024 | https://doi.org/10.1162/imag_a_00189 | Muse MMD / AMUSeD / longitudinal subsets used for **supervised/filter-bank age regression**, not SSL pretraining | secondary (abstract + bioRxiv full text snippets) | medium |
| 13 | Mahdi, *Epileptic Seizure Prediction Using Patient-Adaptive Transformer Networks* (arXiv:2603.26821) | https://arxiv.org/abs/2603.26821 | "self-supervised pretraining is first used to learn general EEG temporal representations … followed by **patient-specific fine-tuning**"; "Experiments conducted on **subjects** from the TUH EEG dataset" (plural) | primary (abstract read) | medium — pretraining subject count not stated in abstract |
| 14 | Cheng et al. (Apple), *Large-scale Training of Foundation Models for Wearable Biosignals*, ICLR 2024 | https://openreview.net/pdf?id=pC3WJHf51j | PPG/ECG SSL, **141,207 participants**; cross-modality reference point for "how many subjects the field thinks it needs" | primary (abstract) | high |
| 15 | Pulse-PPG (arXiv:2502.01108) | https://arxiv.org/pdf/2502.01108 | PPG foundation model, ~200M seconds from **120 participants** — cross-modality "deep, few-subject" precedent | primary (abstract) | medium |
| 16 | Banville et al. 2021 / BENDR / ContraWR etc. (parent's prior sweep) | https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2021.653659/full | BENDR explicitly motivates SSL as "learn from many people, sessions, and tasks" — multi-subject is the stated design premise | primary | high |

---

## Findings

### 1. Single-subject SSL pretraining in EEG: absent

Every EEG SSL pretraining corpus I could verify is multi-subject, and the multi-subject-ness is usually *stated as the point of the method*. BENDR's own framing: *"We present a methodology that can learn from many people, sessions, and tasks using unlabeled data; in other words, it samples the more general distribution of EEG data"* [16]. The scale race has gone the other way entirely — REVE at 25,000 subjects [10], DIVER-1 at 17.7k subjects [11].

Targeted searches for the specific concept ("subject-specific self-supervised pretraining", "personalized EEG foundation model", "within-subject contrastive pretraining", "single-subject dense sampling EEG deep learning") returned **zero** EEG papers where the *pretraining* set is one person. What they return instead falls into three recurring non-answers:
- **subject-adaptive architectures** pretrained on many subjects then personalized (Subject-Conditioned Layer / low-rank adapters, https://openreview.net/pdf?id=vDtsuVfBmG) — multi-subject pretraining;
- **patient-specific fine-tuning** after generic SSL (seizure prediction [13]) — multi-subject pretraining, single-subject head;
- **subject-invariance objectives** that explicitly try to delete the individual [1][2].

This is the distinction the parent asked me to police: single-subject *evaluation/fine-tuning* is everywhere; single-subject *pretraining* is not in the EEG literature I can reach.

### 2. The one real single-subject pretraining result is MEG and supervised

de Zuazo et al. 2026 [4] is the counterexample, with a caveat that changes its status. Read directly from the paper: *"We pre-train a Conformer-based model on 50 hours of single-subject listening data (LibriBrain) and fine-tune on just 5 minutes per subject across 18 participants."* The pretraining task is *"the binary Speech Detection task, which distinguishes speech from silence based on voice-activity labels"* — i.e. **supervised**, using stimulus-derived labels. So it is not an SSL counterexample; it is a **single-subject-corpus-pretraining** counterexample.

Its results are the useful part for the parent's decision. In-task transfer to 18 new subjects: +3.7% acc / +2.6% F1 / +7.3% AUC on listening (p=0.005); cross-task gains up to +6.3% acc (p<0.001). And their own limitation section states plainly: *"Second, pre-training relied on a single subject, and future work should assess whether multi-subject pre-training improves generalization."* **Inference (mine, not theirs):** the fact that a single subject's 50 hours yields significant positive transfer to 18 unseen subjects across a language change (English→Spanish) and a task change (perception→production) is direct evidence that single-subject corpora carry non-idiosyncratic, transferable structure.

### 3. The deep-vs-broad evidence (the closest thing to a subjects-vs-hours ablation)

**No EEG SSL paper holds total hours fixed and varies subject count.** I searched for it directly and could not find one. The two closest results, both read directly:

**(a) d'Ascoli et al., Nature Comms 2025 [6]** — supervised contrastive word decoding across 723 participants / 772 h of M/EEG. Direct quotes:
> "while decoding accuracy does not consistently vary with the datasets sizes (Fig. 2F), we observe a weak trend with the log volume of data *per subject* (Fig. 2G, p < 0.05). This suggests that with a fixed recording budget, one should favor *deep* datasets (few participants over many sessions) than *broad* datasets (many participants over few sessions)."

and

> "decoding performance increases substantially more rapidly when averaging over contexts than over subjects"

and their own caveat:
> "collecting a lot of data from a few individuals may limit other goals, such as the possibility to train a model that could decode language from the brain activity of unseen participants."

This is a *cross-dataset correlational* comparison (datasets differ in device, language, task), not a controlled ablation — the authors say so. Confidence: the direction is stated; the causal claim is weak by their own admission.

**(b) MEG-XL, ICML 2026 [5]** — the crispest single data point on when pretraining stops helping a deep single-subject corpus:
> "On LibriBrain, a deep single-subject dataset, both methods perform similarly until approximately 2.5 hours of training data, after which their supervised method pulls ahead. This suggests pre-training may substitute for subject-specific data as when recordings are scarce, learned priors help. In rare cases where recordings are abundant, learning from scratch eventually wins."

MEG-XL also restates the d'Ascoli finding as: *"their analyses showing hours-per-subject matters more than total hours."*

**(c) EEG supervised learning curves, J. Neural Eng. 2025 [7]** — the only EEG paper I found that explicitly separates the two axes: *"we distinguish between the effects of adding more subjects versus increasing the amount of data per subject"*, sweeping 16→10,240 subjects on TUEG/TUAB/TDBRAIN. **I did not read the results section**; this is flagged `needs follow-up` and is the highest-value single follow-up read available.

**Cross-modality (explicitly labelled as such):** wearable-biosignal SSL runs at 141,207 participants [14], but Pulse-PPG [15] pretrains on ~200M seconds from only **120 participants** — a "deep, few-subject" field-data precedent. I did **not** find a subjects-vs-hours-at-fixed-total ablation in ECG/PPG/EMG/HAR SSL either. Absence here is weaker evidence than in EEG because my search depth in that literature was one query round.

### 4. Muse longitudinal corpora (MMD-long / AMUSeD-long)

Banville et al. 2024, Imaging Neuroscience, doi 10.1162/imag_a_00189 [12] is a **supervised age-prediction / brain-age** paper (filterbank-covariance + Riemannian pipelines), not an SSL pretraining paper. The longitudinal subsets are described as *"curated to study the long-term dynamics of EEG-based brain age … weeks and months"*. Targeted alphaXiv search for `"Muse headband longitudinal EEG self-supervised pretraining MMD AMUSeD"` returned **zero results**. **VERIFIED absence within my protocol:** I found no published SSL pretraining result on MMD-long or AMUSeD-long. Single-source claim — treat as "not found", not "proven nonexistent". Note the data are InteraXon-internal and not public, which independently explains the absence.

### 5. Dense-sampling M/EEG datasets — who ran SSL pretraining on one subject?

| Dataset | Structure | SSL pretraining on ONE subject? |
|---|---|---|
| LibriBrain (Özdogan 2025) [3] | 52 h, 1 subject, MEG | **No SSL.** Used for *supervised* single-subject pretraining in [4]; used only as fine-tune/eval target in MEG-XL [5]. Keyword-spotting paper on it explicitly says it evaluates "without exploring richer encoders, self-supervised pretraining" (arXiv:2510.21038). |
| Armeni et al. 2022 | 3 subjects × 10 h, MEG | No. Used as *evaluation* set in MEG-XL [5] and as pretraining component in "The Brain's Bitter Lesson" (multi-dataset) [9]. |
| THINGS-MEG (ds004212) | 4 subjects, dense | https://openneuro.org/datasets/ds004212/versions/3.0.0 — no single-subject SSL pretraining found. |
| CamCAN / MOUS / SMN4Lang | 100s of subjects | Used as MEG-XL's multi-subject SSL pretraining corpus [5]. |
| Individual Brain Charting | fMRI, 12 subjects dense | **Not checked** — out of time. `needs follow-up`. |
| Nakuci | — | **Not checked**. `needs follow-up`. |

**Inference (mine):** the deep single-subject M/EEG corpora that would make single-subject SSL pretraining possible *now exist* (LibriBrain 52 h is the clearest case), and the community has so far used them exclusively on the *label* side. The experiment appears un-run rather than run-and-negative.

### 6. Inter-subject variability quotes — what role does it play?

Requested: is variability (i) nuisance, (ii) needed negatives/diversity, or (iii) load-bearing? Answer: overwhelmingly **(i) nuisance**, with one recent dissent for (iii).

1. **(i) Nuisance — Cheng et al. 2020, Abstract [1]:** *"In this regime of limited labels and subjects, intersubject variability negatively impacts model performance. Thus, we introduce subject-aware learning through (1) a subject-specific contrastive loss, and (2) an adversarial training to promote subject-invariance during the self-supervised learning."*
2. **(i) Nuisance, and SSL actively fights it — Cheng et al. 2020, §3.1 [1]:** *"With the variability in how the sensors are setup and how the signals behave for each subject, the learned embeddings will be dominated by subject-specific characteristics. To promote the extraction of subject-invariant features, we apply adversarial training."*
3. **(i)/(ii) hybrid — Cheng et al. 2020, §3.1 [1]:** *"The noise estimation can be based only on the data distribution of a single subject. This procedure focuses the loss on differences in time for a single subject, and does not consider differences between subjects. We refer to this approach as subject-specific self-supervised learning."* — i.e. the paper *defines* a within-subject negative-sampling regime, but still runs it over 90 subjects' data.
4. **(ii) Diversity needed — Cheng et al. 2020, §4.1 [1]:** *"For intersubject testing, the different variants of SSL performed comparably… The training set was sufficiently large (90 subjects) to generalize to unseen subjects."* — subject count matters only up to a saturation point; at 90 subjects, subject-awareness stops mattering.
5. **(iii) Load-bearing / SSL amplifies rather than removes it — Marty, Pereira, Bellec & Barbosa, ICLR 2026 workshop [8]:** *"NeuroGPT embeddings reliably amplify individual idiosyncrasies and improve BOLD prediction relative to raw EEG and randomly initialized models. These results suggest that self-supervised pre-training enriches, rather than homogenizes, subject-level representational structure."*
6. **(i) Nuisance, motivating pooling — Jayalath et al., ICML 2025 [9]:** *"due to individual variation, such as anatomy, and differences in task design and scanning hardware, leveraging data across subjects and datasets remains challenging."*

**Inference (mine):** claim (5) is the most decision-relevant for a single-subject pretraining plan — if SSL pretraining *amplifies* subject-specific structure rather than averaging it out, the standard "you need many subjects so the model learns what's common" argument is weaker than it is usually asserted to be. But this is a single workshop paper and I could only read its abstract (OpenReview PDF blocked). **Flagged single-source.**

---

## Search protocol (bounding the absence)

**Tools:** `web_search` (multi-provider, 3 rounds × 2–4 queries), `fetch_content` (11 URLs, 6 read in full), `feynman alpha search` (alphaXiv semantic index, 5 queries), `get_search_content`.

**Indices searched:** general web/provider indices; arXiv (via arxiv.org, ar5iv, alphaXiv semantic search); OpenReview (mostly bot-blocked — see limitations); PMLR; NeurIPS/ICLR virtual sites; IOPscience; Nature Communications / PMC; MIT Press Imaging Neuroscience; OpenNeuro; Hugging Face; GitHub.

**Exact query strings issued:**
1. `subject-specific self-supervised pretraining EEG single subject`
2. `personalized EEG foundation model individual subject pretraining`
3. `within-subject contrastive pretraining EEG own unlabeled data`
4. `number of pretraining subjects ablation EEG self-supervised scaling`
5. `Subject-Aware Contrastive Learning for Biosignals arXiv 2007.04871`
6. `Banville 2024 Imaging Neuroscience Muse longitudinal MMD-long AMUSeD-long`
7. `EEG self-supervised pretraining single subject dense sampling deep imaging Barbosa`
8. `SSL pretraining number of subjects versus amount of data per subject ablation ECG PPG wearable`
9. `Marty Pereira Bellec Barbosa self-supervised EEG pretraining amplifies individual differences`
10. `self-supervised pretraining on a single subject's MEG data representation learning Armeni THINGS-MEG`
11. `EEG self-supervised pretraining subject's own unlabeled data calibration reduction BCI within-subject`
12. `how many subjects needed pretraining data diversity ablation EEG foundation model subjects vs hours`
13. `DIVER-1 scaling law EEG iEEG number of subjects diversity versus hours data-constrained`
14. `MEG-GPT foundation model magnetoencephalography number of subjects pretraining`
15. `d'Ascoli 2025 decoding words MEG hours per subject matters more than number of subjects`
16. `Brain's Bitter Lesson Jayalath scaling speech decoding self-supervised number of subjects within-subject data`

**alphaXiv semantic queries:**
- `self-supervised pretraining single subject EEG`
- `number of pretraining subjects ablation EEG self-supervised`
- `pretraining on a single subject own data EEG MEG self-supervised within-subject`
- `ablation number of subjects versus recording hours self-supervised physiological signals`
- `LibriBrain single subject 50 hours MEG self-supervised pretraining`
- `Muse headband longitudinal EEG self-supervised pretraining MMD AMUSeD` → **0 results**

**Read in full (not snippet-inferred):** [1] ar5iv 2007.04871 (58k chars, ~30k read), [4] arXiv 2602.18253v1 HTML (full), [5] arXiv 2602.02494v2 HTML (30k/73k), [6] PMC12658044 (30k/86k incl. all scaling-law sections), [7] IOP ae453d (9k/64k, intro+methods only), [8] iclr.cc abstract, [13] arXiv 2603.26821 abstract.

**Strength of the absence claim:** medium-high for EEG SSL. 16 web queries + 6 semantic queries across the three most likely phrasings each returned zero single-subject-pretraining EEG hits, and the two most likely enabling datasets (LibriBrain, Muse longitudinal) were checked individually. It is a negative result from search, not from an exhaustive index scan, so it bounds rather than proves.

---

## Coverage Status

**Checked directly (VERIFIED):**
- Apple 2007.04871 pretraining subject count = 90; its "fewer subjects" ablation is on the classifier, not the pretraining set — **done**, and this specifically answers the parent's question 4b in the negative.
- arXiv:2602.18253 single-subject pretraining (MEG, supervised) — **done**, full text read.
- MEG-XL pretraining corpus = multi-subject; LibriBrain only for fine-tuning — **done**, full text read.
- d'Ascoli Nature Comms deep-vs-broad quote — **done**, verbatim.
- Muse MMD-long / AMUSeD-long SSL — **done** (none found; single-source negative).
- Inter-subject variability quotes (6 collected, ≥ the 3–5 requested) — **done**.

**Unverified / single-source (FLAGGED):**
- [8] Marty et al. — abstract only; OpenReview PDF blocked by bot check. The "amplifies individual differences" claim is load-bearing for the parent's thesis and rests on one unread paper. **Recommend a direct PDF retrieval.**
- [3] LibriBrain "largest single-subject MEG dataset" — from alphaXiv snippet + [4]'s description, not from the LibriBrain paper itself.
- [13] seizure-prediction patient-adaptive transformer — abstract says SSL-then-patient-specific but does not state the pretraining subject count. Could in principle be single-patient. **needs follow-up.**
- [12] Muse SSL absence — one negative semantic query + one abstract read.

**Not completed / needs follow-up:**
1. **HIGHEST VALUE:** read the *Results* of J. Neural Eng. 10.1088/1741-2552/ae453d [7] — it is the only EEG paper that explicitly separates "more subjects" from "more data per subject", and I only read intro+methods. This is the parent's item 5 in EEG form (supervised, but EEG and controlled).
2. Retrieve Marty et al. full PDF (OpenReview `peVU8rdBVq`) to verify the "amplifies individual differences" result and its methodology.
3. Individual Brain Charting and Nakuci datasets — not checked at all.
4. DIVER-1's scaling-law section: it claims a "data-constrained" regime; whether it decomposes data into subjects × hours is unverified (abstract only).
5. Cross-modality subjects-vs-hours ablation in ECG/EMG/PPG/HAR — one query round only; absence there is weakly bounded.
6. Confirm the seizure paper's [13] pretraining subject count.
