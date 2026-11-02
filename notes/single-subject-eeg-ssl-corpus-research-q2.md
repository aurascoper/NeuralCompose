# Q2 — Actual pretraining corpus size for low-channel (≤8 EEG channel) SSL results

**Scope:** every self-supervised EEG result I could verify where the *pretraining* signal was ≤8 EEG channels
(plus a small set of "high-channel pretrain → low-channel downstream" cases, flagged separately).
**Excluded from the main table as upper anchors only:** LaBraM, CBraMod, EEGPT, SleepFM, SingLEM, FEMBA (10³–10⁵ h, ≥19 channels).

**Verification convention used throughout:**
- **VERIFIED** = I read the number in the paper's own text/table (via full-text pull), or computed it directly from the primary dataset files.
- **DERIVED** = arithmetic I performed from VERIFIED primitives; the arithmetic is shown inline.
- **UNVERIFIED** = from abstract, vendor page, or secondary source only.
- **not stated** = the paper does not report it. I never silently estimated.

---

## Evidence table (sources)

| # | Source | URL | Key claim | Type | Confidence |
|---|--------|-----|-----------|------|------------|
| 1 | Banville, Chehab, Hyvärinen, Engemann, Gramfort (2021), *Uncovering the structure of clinical EEG signals with self-supervised learning*, J Neural Eng 18(4):046020 | https://arxiv.org/abs/2007.16104 · https://doi.org/10.1088/1741-2552/abca18 | PC18 sleep experiments used **2 channels** (F3-M2, F4-M1) at 100 Hz downsampled from 200 Hz; 994 recordings from **994 unique subjects**; StagerNet = **62,307 trainable params**; SSL train split = 595 recordings; best downstream 72.3% balanced accuracy (5-class) | primary | high |
| 2 | Banville, Moffat, Albuquerque, Engemann, Hyvärinen, Gramfort (2019), *Self-supervised representation learning from EEG signals*, IEEE MLSP | https://arxiv.org/abs/1911.05419 · https://doi.org/10.1109/MLSP.2019.8918693 | MASS-SS3 experiments used **3 channels** (Fz, Cz, Oz), 256 Hz → 128 Hz, **62 recordings from 62 subjects (1 night each)**, train = subjects 1–41, encoder = **67,173 params**. Sleep-EDF arm: 2 bipolar channels, 153 recordings/83 subjects, **55,545 params** | primary | high |
| 3 | Estevan, Sierra-Torralba, López-Larraz, Montesano (2025), *A Systematic Evaluation of SSL for Label-Efficient Sleep Staging with Wearable EEG* | https://arxiv.org/abs/2510.07960 · https://arxiv.org/html/2510.07960v3 | Ikon Sleep headband, **2 frontal electrodes AF7/AF8 @ 256 Hz** (downsampled to 128 Hz); pretraining on HOGAR = **239 overnight recordings**; BOAS = 128 overnight recordings; **hours never stated**; authors explicitly state they **did not** analyse SSL pretraining-set size | primary | high |
| 4 | BOAS dataset, OpenNeuro ds005555 v1.1.1 (Bitbrain Open Access Sleep) | https://openneuro.org/datasets/ds005555 · https://github.com/OpenNeuroDatasets/ds005555 | Computed from `participants.tsv` + `*acq-headband_events.tsv`: **128 nights, 100 unique `pid`s** (80 subjects ×1 night, 12 ×2 nights, 8 ×3 nights); headband EEG total **1,000.8 h**, mean **7.82 h/night**; headband channels HB_1/HB_2 ≈ AF7/AF8 | primary (dataset) | high |
| 5 | Eldele, Ragab, Chen, Wu, Kwoh, Li (2023), *SSL for Label-Efficient Sleep Stage Classification: A Comprehensive Evaluation*, IEEE TNSRE 31:1333–1342 | https://arxiv.org/abs/2210.06286 · https://doi.org/10.1109/TNSRE.2023.3245285 · code https://github.com/emadeldeen24/eval_ssl_ssc | **Single-channel** setups: Sleep-EDF Fpz-Cz@100 Hz (20 subj, 42,308 epochs), SHHS C4-A1@125 Hz (20 subj, 20,021 epochs), **ISRUC-III C4-A1@200 Hz (10 subj, 8,889 epochs)**; 5-fold subject-wise CV; feature extractors 1D-CNN **83,168**, AttnSleep **407,600**, DeepSleepNet **604,928** params | primary | high |
| 6 | Eldele et al. (2021), *Time-Series Representation Learning via Temporal and Contextual Contrasting (TS-TCC)*, IJCAI | https://arxiv.org/abs/2106.14112 | Sleep-EDF, **1 channel Fpz-Cz @100 Hz**, **25,612 training epochs** (60/20/20 subject-wise split of 20 subjects); linear-eval ACC 83.00±0.71 vs supervised 83.41±1.44 vs random-init 35.61±6.96 | primary | high |
| 7 | Yang, Hong, Sun (2023), *Self-Supervised EEG Representation Learning for Automatic Sleep Staging (ContraWR)*, JMIR AI 2:e46769 | https://arxiv.org/abs/2110.15278 · https://ai.jmir.org/2023/1/e46769 · https://pmc.ncbi.nlm.nih.gov/articles/PMC10715804/ | Sleep EDF: **2 channels** (Fpz-Cz/Pz-Oz), 153 recordings, **415,089 epochs**; SHHS: **2 channels** (C3/A2, C4/A1), 5,445 recordings, 4,535,949 epochs; pretrain/train/test subject split **90/5/5%** (SleepEDF, MGH) and **98/1/1%** (SHHS); ContraWR+ 86.90% vs supervised 84.98% on Sleep EDF | primary | high |
| 8 | Chien, Goh, Sandino, Cheng (2022), *MAEEG: Masked Auto-encoder for EEG Representation Learning*, NeurIPS 2022 Workshop (Apple) | https://arxiv.org/abs/2211.02625 · https://openreview.net/forum?id=kttuLV59ZuJ · https://machinelearning.apple.com/research/masked-auto-encoder | Pretraining on PC18: **6-channel EEG @ 100 Hz**, 994 subjects, *"around 7,000 hours of data"*, split 596/198/200 subjects; best downstream **90% accuracy** (5-class) fine-tuned **from ONE subject's labels**; ~5% accuracy gain over no-pretrain in the few-label regime | primary | high |
| 9 | Kostas, Aleksei, Rudzicz (2021), *BENDR*, Front. Hum. Neurosci. 15:653659 | https://arxiv.org/abs/2101.12037 · https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2021.653659/full | Pretraining = TUEG v1.1/1.2, **~1.5 TB EDF, 20 channels (UI 10/20)** — NOT low-channel. Downstream SSC = Sleep-EDF, **2 channels (FPz-Cz, Pz-Oz mapped to FPz, Pz)**, 100 Hz, 83 subjects, 10 folds | primary | high |
| 10 | Grieger, Mehrkanoon, Bialonski (2024), *Data-Efficient Sleep Staging with Synthetic Time Series Pretraining* | https://arxiv.org/abs/2403.08592 | **3 derivations** (C3-M2, F3-M2, EOG1) for DODO/H (Dreem headband), 250 Hz → 100 Hz. SimCLR/VICReg pretrained on **synthetic sine-sum signals (0 h of EEG)** vs on real EEG (ISRUC + Sleep-EDFx). Low-data fine-tune = **50 sleep epochs from ONE subject**. MF1 low-data: synth-SimCLR 0.44, EEG-SimCLR 0.43, synth-VICReg 0.44, EEG-VICReg 0.45, frequency-pretrain 0.44 — **no significant difference (Wilcoxon p>0.05)** | primary | high |
| 11 | Niu, Ravi, Florez Torres, Baum, Morshedzadeh, Aimone, Abou Jaoude (2025), *Foundation Models on Wearable EEG using Self-Supervised Learning*, IEEE EMBC 2025 | https://doi.org/10.1109/EMBC58623.2025.11254670 · https://pubmed.ncbi.nlm.nih.gov/41337335/ | Contrastive SSL on the **Muse Meditation Dataset (MMD)**, participant-level vs segment-level contrast; encoders ShallowNet and EEGConformer; downstream age and sex classification; SSL embeddings beat fully supervised **especially in low-label scenarios**. Corpus hours **not obtainable** (paywalled; abstract only) | primary abstract | medium |
| 12 | Banville, Wood, Aimone, Engemann, Gramfort (2024), *Do try this at home: Age prediction from sleep and meditation with large-scale low-cost mobile EEG*, Imaging Neuroscience 2 | https://doi.org/10.1162/imag_a_00189 | Defines MMD: **4,191 meditation recordings from unique individuals, ≥5 min each**; Muse S = **dry, 4 channels TP9, Fp1, Fp2, TP10, ref Fpz, 256 Hz**; AMUSeD = 1,020 overnight sleep recordings, 5–11 h, unique individuals; MMD-long / AMUSeD-long = 497 / 539 recordings from **4 subjects each** (longitudinal, weeks–months) | primary | high |
| 13 | Grieger et al. dataset provenance — Dreem Open Datasets (DODO/DODH), Guillot, Sauvet, During, Thorey (2020), IEEE TNSRE 28(9):1955–1965 | https://github.com/Dreem-Organization/dreem-learning-open | DODO 55 recordings (OSA) + DODH 25 recordings (healthy) = **80 recordings, each from a different subject** (1 session/subject) | primary (via [10]) | high |
| 14 | Sleep-EDF Expanded (Sleep Cassette), PhysioNet | https://physionet.org/content/sleep-edfx/1.0.0/ | SC subset = **153 recordings from 78 subjects, two recordings (two nights) per subject**, except subjects 13, 36, 52 who have one (per [10]); Fpz-Cz, Pz-Oz @100 Hz | primary (via [10]) | high |
| 15 | Kiessner, Schirrmeister, Boedecker, Ball — *Reaching the Ceiling? Empirical Scaling Behaviour for Deep EEG Pathology Decoding* | https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4611029 · dataset paper https://pmc.ncbi.nlm.nih.gov/articles/PMC10432245/ | Generalization error follows a **saturating power law** in both training-set size and model size; recording-level accuracy plateaus at ~85–87%. **21-channel TUAB/TUABEXB, supervised, not SSL, not low-channel** — adjacent evidence only | secondary summary | medium |
| 16 | Braindecode tutorial: *Self-supervised learning on EEG with relative positioning* | https://braindecode.org/dev/auto_examples/advanced_training/plot_relative_positioning.html | Working reference implementation of Banville RP on Sleep Physionet (2-channel) | primary (docs) | high |
| 17 | LoMI-SSL: *Motor Imagery EEG benchmark with compact self-supervised encoders (<100k params)* | https://github.com/kshitijshresth/LoMI-SSL | Repo exists (HTTP 200). Claims few-shot MI-BCI benchmark on BNCI2014_001 → PhysionetMI with <100k-param encoders. **No peer-reviewed paper found; contents not inspected — do not rely on** | self-reported | low |
| 18 | Ghassemi et al. (2018) PhysioNet/CinC Challenge 2018 (PC18) | https://physionet.org/content/challenge-2018/1.0.0/ | Source dataset for [1] and [8]: 6 EEG channels @ 200 Hz (F3-M2, F4-M1, C3-M2, C4-M1, O1-M2, O2-M1), overnight, one night per individual | primary (via [1],[8]) | high |

---

## Main table — low-channel SSL pretraining corpora

Every cell is tagged. `V` = VERIFIED, `D` = DERIVED (arithmetic shown below the table), `U` = UNVERIFIED, `NS` = not stated in the paper.

| # | Paper | Year | arXiv / DOI | # EEG ch (pretrain) | Electrodes | Sampling rate | **Pretraining HOURS** | **# SUBJECTS (pretrain)** | **SESSIONS / SUBJECT** | Encoder params | SSL objective | Downstream task + result |
|---|-------|------|-------------|---------------------|-----------|---------------|-----------------------|---------------------------|------------------------|----------------|---------------|--------------------------|
| A | Eldele et al. TNSRE — **ISRUC-III arm** [5] | 2023 | arXiv:2210.06286 / 10.1109/TNSRE.2023.3245285 | **1** `V` | C4-A1 `V` | 200 Hz `V` | **≈59 h** `D` (of 74.1 h total `D`) | **8** `D` (10 total `V`) | **1** `V` (10 recordings / 10 subjects) | 1D-CNN **83,168** `V` (also AttnSleep 407,600; DeepSleepNet 604,928) `V` | SimCLR / CPC / TS-TCC / ClsTran; fine-tune `V` | 5-class sleep staging @1% labels: TS-TCC+1D-CNN **65.9% ACC / 62.5 MF1** vs supervised 46.3/41.5 (**+19.6 pts**) `V` |
| B | Eldele et al. TNSRE — **SHHS-20 arm** [5] | 2023 | same | **1** `V` | C4-A1 `V` | 125 Hz `V` | **≈133 h** `D` (of 166.8 h `D`) | **16** `D` (20 total `V`) | **1** `V` (visit-1 only) | same `V` | same `V` | @1% labels: SimCLR+1D-CNN **74.2% / 59.6 MF1** vs supervised 56.9/42.9 `V` |
| C | TS-TCC [6] | 2021 | arXiv:2106.14112 | **1** `V` | Fpz-Cz `V` | 100 Hz `V` | **≈213 h** `D` | **≈12** `D` (20 total `V`) | **2** `V` (Sleep-EDF SC; see [14]) | not stated `NS` (3-block 1D CNN + 4-layer Transformer, h=64) `V` | Temporal + Contextual Contrasting `V` | 5-class linear eval **83.00±0.71 ACC / 73.57 MF1**, vs supervised 83.41, random-init 35.61 `V`; 10% labels ≈ 100% supervised `V` |
| D | Banville MLSP — **MASS-SS3 arm** [2] | 2019 | arXiv:1911.05419 / 10.1109/MLSP.2019.8918693 | **3** `V` | Fz, Cz, Oz `V` | 256 Hz → 128 Hz `V` | **≈317 h** `D` (of 478.7 h `D`) | **41** `V` (subjects 1–41; 62 total `V`) | **1** `V` ("a single whole-night sleep recording for 62 healthy subjects") | **67,173** `V` | Relative Positioning (RP) + Temporal Shuffling (TS) `V` | 5-class sleep staging, linear probe on frozen features; SSL > random-init and > AE (this is the "<100 recordings" result Banville 2021 cites) `V` |
| E | Estevan et al. — **Scenario 3, intra-BOAS SSL** [3],[4] | 2025 | arXiv:2510.07960 | **2** `V` | **AF7, AF8** `V` | **256 Hz** → 128 Hz `V` | **≈500 h @50% split → ≈926 h @92.5% split** `D` (paper states **NS**) | ≈50–92 `D` (100 unique in BOAS `V` via [4]) | **1.28 mean** `V` via [4]: 80×1 night, 12×2, 8×3 | not stated `NS` (CNN epoch encoder → h∈ℝ⁶⁴; arch in Esparza-Iaizzo et al. 2026) | SimCLR / BYOL / SimSiam / Barlow Twins / ContraWR / BENDR / MAEEG `V` | 5-class, 92.5%-unlabeled + 7.5%-labeled: SimCLR **78.36±5.63** vs supervised 69.46±4.04 (**+8.9**) `V`; at 50/50: SimCLR 85.34 vs supervised 85.70 (**no gain**) `V` |
| F | Estevan et al. — **Scenarios 1 & 2, HOGAR SSL** [3] | 2025 | arXiv:2510.07960 | **2** `V` | AF7, AF8 `V` | 256 Hz → 128 Hz `V` | **not stated** `NS`; ≈1,870 h `D` if HOGAR nights ≈ BOAS 7.82 h | **not stated** `NS` (239 recordings `V`, subject count never given) | **not stated** `NS` (home self-recorded; repeats plausible but unreported) | not stated `NS` | same set `V` | 5-class on BOAS @7.5% labels: Barlow Twins **80.19±3.97** vs supervised 72.11±5.97 (**+8.08**), vs LaBraM-Base 74.95, CBraMod 74.00, SleepFM 66.30 `V`. Full labels: SimCLR **87.21** `V` |
| G | ContraWR — **Sleep EDF arm** [7] | 2021/23 | arXiv:2110.15278 / JMIR AI 2:e46769 | **2** `V` | Fpz-Cz, Pz-Oz `V` | 100 Hz `V` | **≈3,113 h** `D` (of 3,459 h `D`) | **≈70** `D` (78 in SC `V` via [14]) | **2** `V` via [14] | not stated `NS` (2D-ResNet on spectrogram; 128/256/192-unit heads `V`) | ContraWR (world-representation triplet w/ Gaussian kernel) `V` | 5-class linear probe with only ~5% labeled subjects: ContraWR+ **86.90±0.23** vs supervised 84.98±0.36, untrained encoder 77.83 `V` |
| H | ContraWR — **SHHS arm** [7] | 2021/23 | same | **2** `V` | C3/A2, C4/A1 `V` | 125 Hz `V` | **≈37,043 h** `D` (of 37,800 h `D`) | not stated `NS` (5,445 recordings `V`) | not stated `NS` | as above | ContraWR `V` | ContraWR+ **77.97±0.27** vs supervised 75.61±0.93 `V` |
| I | Banville et al. J Neural Eng — **PC18** [1] | 2021 | arXiv:2007.16104 / 10.1088/1741-2552/abca18 | **2** `V` (of 6 recorded) | **F3-M2, F4-M1** `V` | 200 Hz → 100 Hz `V` | **≈4,447 h** `D` (of 7,431 h `D`; cross-checked against MAEEG's *"around 7,000 hours"* for the same corpus `V` [8]) | **595** `V` | **1** `V` (994 recordings / 994 unique subjects, Table 1) | StagerNet **62,307** `V` (ShallowNet 170,860 `V`) | Relative Positioning, Temporal Shuffling, CPC `V` | 5-class sleep staging, **linear** probe on frozen SSL features: up to **72.3% balanced accuracy** (chance 20%) `V`; beats fully supervised in low-label regimes `V` |
| J | MAEEG [8] | 2022 | arXiv:2211.02625 | **6** `V` | F3-M2, F4-M1, C3-M2, C4-M1, O1-M2, O2-M1 `V` via [18] | 100 Hz `V` | **≈4,196 h** `D` (paper states *"around 7,000 hours"* for all 994 subjects `V`) | **596** `V` | **1** `V` via [1],[18] | BENDR-style conv encoder + Transformer; count **not stated** `NS` | Masked reconstruction in signal space (MAE) `V` | 5-class sleep staging fine-tuned with **one subject's labels**: MAEEG-100s best; peak **90% accuracy** `V`; ~5% gain over BENDR/supervised in few-label regime `V` |
| K | Muse wearable SSL [11] (+ corpus def. [12]) | 2025 | 10.1109/EMBC58623.2025.11254670 | **4** `U` | TP9, Fp1, Fp2, TP10 (ref Fpz) `V` via [12] | **256 Hz** `V` via [12] | **not stated / not accessible** `NS`; MMD = 4,191 recordings ≥5 min `V` via [12] → **≥349 h** `D` lower bound only | 4,191 unique individuals in MMD `V` via [12]; whether EMBC used all of MMD `U` | **1** `V` via [12] ("recordings from unique individuals") | ShallowNet / EEGConformer `U` (counts not stated) | Contrastive, **participant-level vs segment-level** `U` | Age + sex classification; SSL embeddings > fully supervised, "particularly in low-label scenarios"; participant-level contrast > segment-level; EEGConformer > ShallowNet `U` |
| L | Grieger et al. — **EEG-pretrained SSL arm** [10] | 2024 | arXiv:2403.08592 | **3** `V` (2 EEG + 1 EOG) | C3-M2, F3-M2, EOG1 (DODO/H); pretrain on ISRUC C3-A2/F3-A2/LOC-A2 + Sleep-EDFx Fpz-Cz/Pz-Oz/EOGh `V` | 250/200/100 Hz → 100 Hz `V` | **not stated** `NS` (277 recordings: 124 ISRUC + 153 Sleep-EDFx `V`) | 100+8+10 ISRUC + 78 Sleep-EDFx `V` | ISRUC-I 1, ISRUC-II **2**, ISRUC-III 1, Sleep-EDFx **2** `V` | not stated `NS` | SimCLR, VICReg `V` | Fine-tune on **50 epochs from ONE DODO/H subject**: EEG-SimCLR MF1 **0.43**, EEG-VICReg **0.45** — statistically indistinguishable from synthetic pretraining (0.44/0.44) `V` |
| M | Grieger et al. — **synthetic (zero-EEG) arm** [10] | 2024 | arXiv:2403.08592 | 3 (synthetic) `V` | n/a | 100 Hz `V` | **0 h of EEG** `V` | **0** `V` | n/a | not stated `NS` | Frequency Pretraining (multi-label freq-bin prediction on summed sines); also SimCLR/VICReg on synthetic `V` | Same protocol: FPT MF1 **0.44** low-data / **0.81** high-data — matches or beats EEG-pretrained SSL `V` |
| — | *BENDR (reference anchor)* [9] | 2021 | arXiv:2101.12037 | pretrain **20** `V` — NOT low-channel | UI 10/20 19 ch + 1 relative-amplitude ch `V` | 256 Hz `V` | not stated `NS` (**~1.5 TB EDF**, TUEG v1.1/1.2, >10,000 people `V`) | >10,000 `V` | multi-session (up to 8 months apart) `V` | not stated `NS` | wav2vec-2.0-style contrastive masked prediction `V` | Downstream SSC on Sleep-EDF **2 channels**, 83 subjects, 10 folds `V` — the canonical "big-pretrain → 2-channel-downstream" case |

### Arithmetic for every `D` cell

All sleep epochs are 30 s (VERIFIED in every paper listed).

- **A (ISRUC-III):** Table II of [5] gives 1,817+1,248+2,678+2,035+1,111 = **8,889 epochs**. 8,889 × 30 s = 266,670 s = **74.08 h** across 10 recordings (7.41 h/recording). 5-fold **subject-wise** CV ⇒ pretraining fold = 8 of 10 subjects ⇒ 8 × 7.41 = **≈59.3 h**.
- **B (SHHS-20):** 4,741+783+8,204+2,747+3,546 = **20,021 epochs** × 30 s = 600,630 s = **166.8 h** / 20 subjects = 8.34 h each. 4/5 fold ⇒ 16 × 8.34 = **≈133.5 h**.
- **B′ (Sleep-EDF arm of [5], for completeness):** 8,285+2,804+17,799+5,703+7,717 = **42,308 epochs** × 30 s = **352.6 h** / 20 subjects (2 nights each). 4/5 fold ⇒ **≈282 h from 16 subjects / 32 nights**.
- **C (TS-TCC):** Table 1 of [6] gives **25,612 training samples**, each a 30-s Fpz-Cz epoch ⇒ 768,360 s = **213.4 h**. Split is 60/20/20 subject-wise over 20 subjects ⇒ **≈12 subjects, ≈24 nights**.
- **D (MASS-SS3):** Table 1 of [2] gives 6,131+4,709+28,920+7,362+10,323 = **57,445 epochs** × 30 s = 1,723,350 s = **478.7 h** across 62 recordings = 7.72 h/recording. Train = subjects 1–41 ⇒ 41 × 7.72 = **≈316.6 h**.
- **D′ (Sleep-EDF arm of [2]):** 59,982+21,522+69,132+13,039+25,835 = **189,510 epochs** × 30 s = **1,579.3 h** / 153 recordings = 10.32 h/recording (Sleep-EDF SC recordings include ~24 h of daytime). Train = subjects 40–82 minus missing subjects 68,69,78,79 and missing session sub-52-sess-1 ⇒ ≈77 recordings × 10.32 = **≈795 h from ≈39 subjects**. Marked approximate — the exclusion footnote is ambiguous.
- **E (Estevan Scenario 3):** BOAS headband duration computed directly from ds005555 `*acq-headband_events.tsv`: **1,000.8 h over 128 nights, mean 7.82 h/night** (`V`, [4]). Scenario-3 SSL split "92.5–7.5" ⇒ 0.925 × 128 ≈ 118 nights × 7.82 = **≈926 h**; "50–50" ⇒ 64 nights × 7.82 = **≈500 h**.
- **F (Estevan Scenarios 1–2):** 239 HOGAR nights. Paper gives **no durations**. If HOGAR nights resemble BOAS nights (7.82 h), 239 × 7.82 = **≈1,869 h** — this is an *assumption-based* estimate, not a paper claim. HOGAR is elderly, home-based, self-administered, so night length is plausibly different.
- **G (ContraWR Sleep EDF):** Table 1 of [7]: **415,089 epochs** × 30 s = 12,452,670 s = **3,459.1 h**. Pretrain split = 90% of subjects ⇒ **≈3,113 h from ≈70 subjects**.
- **H (ContraWR SHHS):** 4,535,949 epochs × 30 s = **37,799.6 h**; 98% ⇒ **≈37,043 h**.
- **I (Banville 2021 PC18):** Table 1 of [1]: 158,020+136,858+377,426+102,492+116,872 = **891,668 windows** × 30 s = 26,750,040 s = **7,430.6 h** across 994 recordings = 7.47 h/recording. Table 3: SSL train split = **595 recordings** ⇒ 595 × 7.47 = **≈4,447 h**. Independent cross-check: MAEEG [8] describes the same corpus as *"around 7,000 hours of data"* for 994 subjects — consistent.
- **J (MAEEG):** stated ~7,000 h / 994 subjects = 7.04 h each; train = 596 subjects ⇒ **≈4,196 h**.
- **K (MMD lower bound):** 4,191 recordings × ≥5 min = ≥20,955 min = **≥349 h**. This is a floor, not an estimate — actual mean recording length is not published.

---

## Findings

### 1. The verified low end is ~59 hours / 8 subject-nights at 1 channel

The smallest pretraining corpus I can verify producing a *usable* SSL representation at ≤8 channels is the
**ISRUC-subgroup-III arm of Eldele et al. 2023 [5]: ≈59 h of single-channel C4-A1 EEG from 8 subjects, one night each**
(derivation above). At 1% labels this produced 65.9% ACC / 62.5 MF1 with TS-TCC on a 83k-param 1D-CNN, versus a
supervised baseline at 46.3% ACC / 41.5 MF1 — a **+19.6 point** gap, the largest low-label gap in any paper here [5].
Notably the gap is *largest* on the *smallest* dataset, which is the opposite of a naïve scaling intuition; the mechanism
is that the supervised baseline collapses faster than the SSL representation degrades.

Ranked ladder of verified low-channel pretraining corpora (hours / subjects / sessions-per-subject):

| Rank | Corpus | Hours | Subjects | Sessions/subj | Channels |
|---|---|---|---|---|---|
| 1 | ISRUC-III [5] | **≈59** `D` | 8 | 1 | 1 |
| 2 | SHHS-20 [5] | ≈133 `D` | 16 | 1 | 1 |
| 3 | Sleep-EDF (TS-TCC) [6] | ≈213 `D` | ≈12 | 2 | 1 |
| 4 | Sleep-EDF (Eldele) [5] | ≈282 `D` | 16 | 2 | 1 |
| 5 | MASS-SS3 [2] | ≈317 `D` | 41 | 1 | 3 |
| 6 | BOAS 50% (Estevan Sc.3) [3],[4] | ≈500 `D` | ≈50 | 1.28 | 2 (AF7/AF8, 256 Hz) |
| 7 | Sleep-EDF (Banville MLSP) [2] | ≈795 `D` | ≈39 | 2 | 2 |
| 8 | BOAS 92.5% (Estevan Sc.3) [3],[4] | ≈926 `D` | ≈92 | 1.28 | 2 (AF7/AF8, 256 Hz) |
| 9 | HOGAR (Estevan Sc.1–2) [3] | **not stated** (≈1,870 assumed) | **not stated** | **not stated** | 2 (AF7/AF8, 256 Hz) |
| 10 | Sleep EDF (ContraWR) [7] | ≈3,113 `D` | ≈70 | 2 | 2 |
| 11 | PC18 (Banville 2021) [1] | ≈4,447 `D` | 595 | 1 | 2 |
| 12 | PC18 (MAEEG) [8] | ≈4,196 `D` | 596 | 1 | 6 |
| 13 | SHHS (ContraWR) [7] | ≈37,043 `D` | not stated | not stated | 2 |

**No paper in this survey pretrained on a single subject at ≤8 channels.** The minimum subject count anywhere in the
verified set is **8** [5]. This is an inference from an exhaustive-within-my-search absence, not a stated claim, but it is
a strong absence: every SSL result here draws negatives from *across* recordings/subjects, and several methods
(SimCLR-family, ContraWR, Barlow Twins) structurally require multi-recording batches to avoid representational collapse.

### 2. Sessions per subject — the load-bearing distinction

Corrected, verified session structure for every corpus in the table:

| Corpus | Recordings | Subjects | Sessions/subject | Status |
|---|---|---|---|---|
| PC18 (Banville 2021, MAEEG) [1],[8] | 994 | 994 | **1** | `V` — Table 1 of [1] lists "# unique subjects 994 / # recordings 994" |
| MASS-SS3 [2] | 62 | 62 | **1** | `V` — "a single whole-night sleep recording for 62 healthy subjects" |
| **Sleep-EDF Cassette** [10],[14] | 153 | 78 | **2** (except subj. 13, 36, 52 = 1) | `V` — stated explicitly in [10] §4.2.1 |
| ISRUC subgroup I [10] | 100 | 100 | **1** | `V` |
| **ISRUC subgroup II** [10] | 16 | 8 | **2** | `V` |
| ISRUC subgroup III [5],[10] | 10 | 10 | **1** | `V` |
| DODO/H [10],[13] | 80 | 80 | **1** | `V` — "Each recording stems from a different subject" |
| **BOAS (ds005555)** [4] | 128 | **100 unique `pid`s** | **80×1, 12×2, 8×3** (mean 1.28) | `V` — computed directly from `participants.tsv` |
| HOGAR [3] | 239 | **not stated** | **not stated** | `NS` |
| Muse MMD [12] | 4,191 | 4,191 | **1** | `V` |
| **Muse MMD-long / AMUSeD-long** [12] | 497 / 539 | **4 / 4** | **≈124 / ≈135** | `V` — the only genuinely longitudinal single-subject-scale wearable EEG corpora I found |
| TUEG (BENDR pretrain) [9] | ~16k+ | >10,000 | multi-session, up to 8 months apart | `V` (qualitative) |

Two corrections worth flagging to the parent:

- **BOAS is not one-night-per-subject.** Estevan et al. [3] describe BOAS as "128 overnight recordings from healthy
  adults" and run all cross-validation **recording-wise**, not subject-wise. The dataset itself has only **100 unique
  participant IDs**, with 12 subjects contributing 2 nights and 8 contributing 3 nights [4]. Twenty subjects (48 of 128
  nights, 37.5% of the corpus) appear more than once. Recording-wise CV therefore leaks the same subject across
  train/test folds for those 48 nights. The dataset README additionally states "108 unique individuals," which does not
  match the 100 distinct `pid` values I counted in `participants.tsv` v1.1.1 — an unresolved discrepancy in the dataset
  documentation itself, not in the paper.
- **HOGAR's subject count and sessions-per-subject are never reported anywhere** [3]. Since HOGAR is home-based
  self-administered recording from an ongoing longitudinal cognitive-decline project, repeat nights per participant are
  *likely*, which would mean the "239 recordings" number substantially overstates subject diversity. This is an
  inference, not a claim in the paper, and HOGAR is not publicly released so it cannot be checked.

### 3. Encoder sizes at low channel count are tiny — 55k to 600k params

Verified parameter counts: **55,545** (Banville MLSP, 2-ch Sleep-EDF) [2]; **62,307** (StagerNet, Banville 2021) [1];
**67,173** (Banville MLSP, 3-ch MASS) [2]; **83,168** (1D-CNN feature extractor, Eldele) [5]; **170,860** (ShallowNet) [1];
**407,600** (AttnSleep FE) [5]; **604,928** (DeepSleepNet FE) [5]. For contrast, the foundation models Estevan
benchmarked are **LaBraM-Base 5.8M**, **CBraMod 4.0M**, **SleepFM 4.4M** [3] — and all three were *beaten by the
supervised baseline* at most label fractions on 2-channel AF7/AF8 data [3].

Estevan's own encoder produces a 64-dim per-epoch feature vector; the parameter count is not stated in [3] and lives in a
separate architecture paper (Esparza-Iaizzo et al., Computers in Biology and Medicine 205:111560, 2026) that I did not
retrieve. Marked `NS`.

### 4. The data-scaling question: no clean curve exists at low channel count

**Direct answer: no paper in this survey reports a clean performance-vs-pretraining-hours scaling curve at ≤8 channels.**
The three closest artifacts, in decreasing order of usefulness:

**(a) Estevan et al. Scenario 3 [3] — the closest thing, but confounded.** Table III varies the unlabeled/labeled split
within BOAS across 92.5–7.5, 80–20, 70–30, 60–40, 50–50. Verified numbers (SimCLR / Barlow Twins / supervised baseline):

| unlabeled–labeled | SSL hours `D` | Supervised | SimCLR (BOAS→BOAS) | Barlow Twins (BOAS→BOAS) | SimCLR (HOGAR→BOAS) | Barlow Twins (HOGAR→BOAS) |
|---|---|---|---|---|---|---|
| 92.5 – 7.5 | ≈926 h | 69.46±4.04 | **78.36±5.63** | 77.72±5.24 | **79.44±4.69** | 77.08±7.79 |
| 80 – 20 | ≈801 h | 82.44±1.29 | 83.65±0.36 | **84.57±1.00** | 83.76±1.05 | 84.21±1.31 |
| 70 – 30 | ≈701 h | 83.70±0.95 | 84.82±1.43 | 85.11±0.68 | 84.76±0.97 | 84.65±0.82 |
| 60 – 40 | ≈601 h | 85.25±0.36 | 84.89±0.69 | 85.10±0.12 | 84.92±0.13 | **85.33±0.55** |
| 50 – 50 | ≈500 h | 85.70±0.56 | 85.34±1.22 | 85.81±0.21 | 85.60±0.62 | **86.22±0.11** |

The confound is fatal for reading this as a pretraining-scaling curve: **the unlabeled and labeled fractions are
complementary**, so as SSL hours go *down*, labeled data goes *up*. The apparent "SSL gain shrinks with more SSL data"
is really "SSL gain shrinks with more labels." The authors say so themselves, verbatim [3]:

> "we did not analyze the impact of SSL pre-training dataset size due to its limited scale. We believe that at least an
> order of magnitude more would be needed to draw reliable conclusions, as the effect of unlabeled data availability is
> not comparable to that of labeled data (see the smaller impact in Table III)."

What *is* readable from Table III, and is decision-relevant: pretraining on **≈500 h of 2-channel AF7/AF8 @256 Hz from
≈50 subjects** (the 50–50 row) yielded essentially **zero** downstream benefit over supervised (85.34–86.22 vs 85.70),
whereas at the same corpus scale but with labels scarce (92.5–7.5, ≈926 h SSL) it yielded **+8.9 points**. The SSL benefit
at low channel count is governed almost entirely by *label* scarcity, not by pretraining-corpus size, over this range.

**(b) Grieger et al. [10] — the strongest negative result on pretraining-corpus value.** At **3 channels**, with
fine-tuning restricted to **50 sleep epochs from ONE subject** of the Dreem-headband DODO/H dataset, SimCLR and VICReg
pretrained on **synthetic summed-sine signals (zero hours of real EEG)** performed *statistically indistinguishably*
from the same methods pretrained on 277 real recordings of ISRUC + Sleep-EDFx (MF1 0.44/0.44 synthetic vs 0.43/0.45
EEG; two-sided Wilcoxon signed-rank p>0.05 for all comparisons) [10]. In the high-data regime the difference was
0.80 vs 0.81 MF1 — also not significant [10]. **Inference (mine, not the authors'):** if a few-hundred-hour real-EEG
pretraining corpus buys nothing over synthetic sine mixtures at 3 channels, the marginal value of the *first* few hundred
hours of a self-collected low-channel corpus is likely near zero for a frequency-driven task like sleep staging. The
authors' own framing is weaker — they claim the synthetic task encodes a useful *frequency prior* — but the equivalence
result is directly stated and directly measured.

**(c) MAEEG [8] — a label-scaling curve, not a pretraining-hours curve.** Figures 2A/2B vary *downstream* subjects
(1 / 10 / 50) at fixed ≈4,196 h of 6-channel pretraining. Result: with **one subject's labels**, MAEEG-100s reached the
best performance of any configuration, peaking at **90% accuracy** on 5-class sleep staging [8]. Also verified: at 0.1%
labels (≈4 h of labeled data), 75%-masking single-chunk beat 50%/25% masking, and *every* MAEEG-pretrained variant beat
the no-pretrain baseline [8]. This is the best available evidence that a modest-parameter model over ≤6 channels can be
adapted to a *single* subject — but the pretraining corpus behind it was ~4,200 hours from 596 subjects, not one subject.

**(d) Adjacent, not low-channel:** Kiessner et al. found a **saturating power law** in dataset size for EEG pathology
decoding, plateauing at 85–87% recording-level accuracy [15]. This is supervised, 21-channel TUAB/TUABEXB, and should
*not* be transferred to a 4-channel single-subject SSL setting without heavy caveats. Estevan cites it precisely to
explain why their own SSL gains vanish above ~85% [3].

### 5. Consumer-headband SSL specifically

- **Muse (4 ch, 256 Hz — closest hardware match to the user's setup).** The only SSL result I could find on Muse data is
  Niu, Ravi et al., IEEE EMBC 2025 [11]: contrastive SSL on the Muse Meditation Dataset, ShallowNet and EEGConformer
  encoders, downstream **age and sex** classification (not sleep staging, not BCI). The paper reports SSL embeddings
  beating fully supervised models "particularly in low-label scenarios," and **participant-level contrastive learning
  outperforming segment-level** [11]. I could not obtain the full text (IEEE paywall), so **corpus hours, subject counts,
  encoder sizes, and effect sizes are all UNVERIFIED**. The underlying MMD corpus is defined in [12] as **4,191
  meditation recordings ≥5 min each from unique individuals** on Muse S (TP9, Fp1, Fp2, TP10, ref Fpz, 256 Hz), giving a
  **floor of ≥349 h** — whether the EMBC work used all of MMD is unknown.
- **The one directly relevant longitudinal single-subject artifact:** [12] describes **MMD-long (497 recordings from
  4 subjects)** and **AMUSeD-long (539 overnight recordings from 4 subjects)**, spanning weeks to months on Muse S
  hardware. These are the only corpora I found with the shape the user is heading toward (one subject × many sessions).
  They were used for *brain-age stability analysis*, **not** for SSL pretraining [12]. No SSL result exists on them.
- **Bitbrain Ikon Sleep (2 ch AF7/AF8 @ 256 Hz)** [3] is the closest *published SSL* match on sampling rate and frontal
  electrode placement, and its BOAS half is fully open [4].
- **Ear-EEG / in-ear / around-ear SSL:** I searched and found **no** SSL pretraining paper on ear-EEG. The ear-EEG
  literature I surfaced is supervised (SSVEP classification, sleep staging validation). **Reporting this as an absence,
  not a negative claim** — my search may not be exhaustive.

### 6. Low-channel motor imagery / P300 SSL

I found **no verified, peer-reviewed SSL result whose pretraining corpus was ≤8 channels** for motor imagery or P300.
What I did find:
- **BENDR** [9] evaluates downstream on BCI-IV 2a, MMI, ERN, P300 — but pretrains on 20 channels of TUEG.
- **Subject-Aware Contrastive Learning for Biosignals** (arXiv:2007.04871, Apple) is a strong few-subject SSL paper, but
  its EEG arm uses the **64-channel** PhysioNet Motor Movement/Imagery dataset (109 volunteers, 160 Hz, 288k-param
  ResNet encoder, SSL on 90 subjects, tested on 16 held-out). **Out of scope for ≤8 channels** — recorded for the parent
  because its subject-invariance/subject-specific-contrast machinery is directly transferable to a low-channel design.
  https://arxiv.org/abs/2007.04871
- **LoMI-SSL** [17] claims exactly the target regime (<100k-param encoders, few-shot 5/10/20/50 trials per class,
  leakage-safe session/run splits, BNCI2014_001 → PhysionetMI transfer). The repo exists (HTTP 200 verified) but I found
  **no associated paper** and did **not** inspect its contents. **Do not cite as a result.**

---

## Direct answers to the two decision questions

**Q: What is the smallest pretraining corpus at ≤8 channels that demonstrably produced a working SSL representation?**

**≈59 hours / 8 subject-nights / 1 channel** — the ISRUC-subgroup-III arm of Eldele et al. 2023 [5], with an 83k-param
1D-CNN, TS-TCC or CPC objective, evaluated at 1% labels (+19.6 points over supervised). Runner-up at 2 channels and the
user's exact sampling rate: **≈500 h / ≈50 subjects / 64 nights of AF7-AF8 @256 Hz** in Estevan Scenario 3 [3],[4] — but
at that corpus size the SSL gain over supervised was **zero** (85.3–86.2 vs 85.7). The smallest corpus that produced a
*meaningful gain* at 2 channels/256 Hz was **≈926 h / ≈92 subjects / 118 nights**, and only when labels were held to 7.5%
(+8.9 points) [3].

**Every one of these is multi-subject.** The minimum subject count in any verified low-channel SSL pretraining corpus is
**8**. Zero papers pretrained on a single subject.

**Q: Did any paper run a data-scaling ablation showing performance vs pretraining hours at low channel count?**

**No.** The closest is Estevan Table III [3], which is confounded (unlabeled and labeled fractions are complementary) and
which the authors explicitly disclaim as not being a pretraining-size analysis. The most decision-relevant substitute is
Grieger et al. [10]: at 3 channels with single-subject fine-tuning, **zero hours** of real EEG pretraining (synthetic
sine-mixture pretraining) matched **hundreds of hours** of real EEG pretraining with no significant difference. That
null result is arguably more informative for a from-zero collection protocol than any scaling curve would be, because it
bounds the value of the first several hundred hours at approximately nothing for frequency-driven sleep tasks.

---

## Coverage Status

**Checked directly (full text pulled and read, or dataset files inspected):**
- Banville 2021 arXiv:2007.16104 — full text, Tables 1/2/3, §2.4 architecture, §2.6 datasets, §3.1 results, §4 discussion. `done`
- Banville 2019 MLSP arXiv:1911.05419 — full text, Table 1, §3.1–3.2. `done`
- Estevan 2025 arXiv:2510.07960v3 — full text incl. Appendices A/B/C; Tables I/II/III extracted from raw HTML. `done`
- BOAS ds005555 v1.1.1 — cloned; `participants.tsv` pid distribution and all 128 `acq-headband_events.tsv` durations computed directly. `done`
- Eldele 2023 arXiv:2210.06286 — full text, Tables I/II, supplementary Table S.1 (param counts). `done`
- TS-TCC arXiv:2106.14112 — full text, Tables 1/2/4, §4.2. `done`
- ContraWR arXiv:2110.15278 — full text, Tables 1/2/3, problem formulation splits. `done`
- MAEEG arXiv:2211.02625 — full text, §3.1, §4.1, §4.2. `done`
- BENDR arXiv:2101.12037 — full text, §2.2–2.3, Table 1. `done`
- Grieger 2024 arXiv:2403.08592 — full text, §2.1–2.3, §4.2.1, Table 1. `done`
- Subject-Aware Contrastive arXiv:2007.04871 — full text §4.1 (confirmed out of scope: 64 ch). `done`

**Uncertain / could not verify:**
- **Muse EMBC 2025 [11]** — IEEE paywall; abstract only. Corpus hours, subject count, encoder params, and all effect
  sizes are UNVERIFIED. This is the single most relevant paper to the user's hardware and the biggest gap in this
  report. `needs follow-up` — an institutional IEEE Xplore pull would close it.
- **HOGAR subject count and sessions-per-subject** — never stated in [3]; dataset not public. `blocked`.
- **HOGAR and BOAS pretraining hours as used by Estevan** — hours never stated in the paper; my BOAS figure (1,000.8 h)
  is computed from the public dataset and is exact, but the HOGAR figure (~1,870 h) rests on an assumed 7.82 h/night.
  `needs follow-up` — authors accept data requests.
- **Estevan encoder parameter count** — lives in Esparza-Iaizzo et al., Comput Biol Med 205:111560 (2026), which I did
  not retrieve. `needs follow-up`.
- **Banville 2019 Sleep-EDF training-split hours (≈795 h)** — the missing-subject/missing-session footnote is ambiguous
  about which exclusions fall inside the train range; treat ±10%. `needs follow-up` (low priority).
- **Sleep-EDF version ambiguity** — [2] says 153 recordings / **83** subjects; [10] and PhysioNet say 153 recordings /
  **78** subjects. Both are reported as stated; I did not reconcile them. `needs follow-up` (low priority).
- **BOAS README "108 unique individuals" vs 100 distinct `pid`s I counted** in v1.1.1 `participants.tsv`. Documentation
  discrepancy inside the dataset. `needs follow-up` (low priority; does not change the "repeat nights exist" conclusion).

**Could not complete / searched and found nothing:**
- **Ear-EEG / in-ear / around-ear SSL pretraining** — no paper found. Absence reported, not a negative claim. `blocked`
- **≤8-channel motor-imagery or P300 SSL pretraining** — no peer-reviewed result found; only the unvetted LoMI-SSL repo
  [17] and 64-channel work. `blocked`
- **SeqCLR, SleepDPC, CoSleep, mulEEG** — surfaced in search and cited by [3], but I did not pull their full texts and
  therefore report **no** numbers for them. mulEEG: https://arxiv.org/abs/2204.03272 (exists, unread). `needs follow-up`
- **PARS pretraining (arXiv:2511.11940)** and **Apple "Label-Efficient Sleep Staging Using Transformers Pre-trained with
  Position Prediction"** (https://machinelearning.apple.com/research/label-efficient-sleep-staging) — both surfaced,
  neither read. Channel counts unknown. `needs follow-up`

**Nothing in this report is stated without a URL, and no paper contents are described that I did not read.**

---

## Sources

1. Banville, Chehab, Hyvärinen, Engemann, Gramfort — *Uncovering the structure of clinical EEG signals with self-supervised learning*, J Neural Eng 18(4):046020 (2021) — https://arxiv.org/abs/2007.16104 · https://doi.org/10.1088/1741-2552/abca18
2. Banville, Moffat, Albuquerque, Engemann, Hyvärinen, Gramfort — *Self-supervised representation learning from electroencephalography signals*, IEEE MLSP (2019) — https://arxiv.org/abs/1911.05419 · https://doi.org/10.1109/MLSP.2019.8918693
3. Estevan, Sierra-Torralba, López-Larraz, Montesano — *A Systematic Evaluation of Self-Supervised Learning for Label-Efficient Sleep Staging with Wearable EEG* (2025) — https://arxiv.org/abs/2510.07960 · https://arxiv.org/html/2510.07960v3
4. Bitbrain Open Access Sleep (BOAS) dataset, OpenNeuro ds005555 v1.1.1 — https://openneuro.org/datasets/ds005555 · https://github.com/OpenNeuroDatasets/ds005555
5. Eldele, Ragab, Chen, Wu, Kwoh, Li — *Self-Supervised Learning for Label-Efficient Sleep Stage Classification: A Comprehensive Evaluation*, IEEE TNSRE 31:1333–1342 (2023) — https://arxiv.org/abs/2210.06286 · https://pubmed.ncbi.nlm.nih.gov/37022869/ · https://github.com/emadeldeen24/eval_ssl_ssc
6. Eldele, Ragab, Chen, Wu, Kwoh, Li, Guan — *Time-Series Representation Learning via Temporal and Contextual Contrasting (TS-TCC)*, IJCAI (2021) — https://arxiv.org/abs/2106.14112
7. Yang, Hong, Sun — *Self-Supervised Electroencephalogram Representation Learning for Automatic Sleep Staging (ContraWR)*, JMIR AI 2:e46769 (2023) — https://arxiv.org/abs/2110.15278 · https://ai.jmir.org/2023/1/e46769 · https://pmc.ncbi.nlm.nih.gov/articles/PMC10715804/
8. Chien, Goh, Sandino, Cheng — *MAEEG: Masked Auto-encoder for EEG Representation Learning* (2022) — https://arxiv.org/abs/2211.02625 · https://openreview.net/forum?id=kttuLV59ZuJ · https://machinelearning.apple.com/research/masked-auto-encoder
9. Kostas, Aleksei, Rudzicz — *BENDR: Using Transformers and a Contrastive Self-Supervised Learning Task to Learn From Massive Amounts of EEG Data*, Front. Hum. Neurosci. 15:653659 (2021) — https://arxiv.org/abs/2101.12037 · https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2021.653659/full
10. Grieger, Mehrkanoon, Bialonski — *Data-Efficient Sleep Staging with Synthetic Time Series Pretraining* (2024) — https://arxiv.org/abs/2403.08592
11. Niu, Ravi, Florez Torres, Baum, Morshedzadeh, Aimone, Abou Jaoude — *Foundation Models on Wearable EEG using Self-Supervised Learning*, IEEE EMBC (2025) — https://doi.org/10.1109/EMBC58623.2025.11254670 · https://pubmed.ncbi.nlm.nih.gov/41337335/
12. Banville, Wood, Aimone, Engemann, Gramfort — *Do try this at home: Age prediction from sleep and meditation with large-scale low-cost mobile EEG*, Imaging Neuroscience 2 (2024) — https://doi.org/10.1162/imag_a_00189
13. Guillot, Sauvet, During, Thorey — *Dreem Open Datasets*, IEEE TNSRE 28(9):1955–1965 (2020) — https://github.com/Dreem-Organization/dreem-learning-open
14. Sleep-EDF Database Expanded (Sleep Cassette), PhysioNet — https://physionet.org/content/sleep-edfx/1.0.0/
15. Kiessner, Schirrmeister, Boedecker, Ball — *Reaching the Ceiling? Empirical Scaling Behaviour for Deep EEG Pathology Decoding* — https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4611029 ; dataset paper *An extended clinical EEG dataset with 15,300 automatically labelled recordings* — https://pmc.ncbi.nlm.nih.gov/articles/PMC10432245/
16. Braindecode — *Self-supervised learning on EEG with relative positioning* (reference implementation) — https://braindecode.org/dev/auto_examples/advanced_training/plot_relative_positioning.html
17. LoMI-SSL (unvetted repo, no paper found) — https://github.com/kshitijshresth/LoMI-SSL
18. PhysioNet/CinC Challenge 2018 (PC18) — https://physionet.org/content/challenge-2018/1.0.0/
19. Cheng, Goh, Dogrusoz, Tuzel, Azemi — *Subject-Aware Contrastive Learning for Biosignals* (2020) — https://arxiv.org/abs/2007.04871 *(64-channel; out of scope, listed for method transfer only)*
20. mulEEG: *A Multi-View Representation Learning on EEG Signals*, MICCAI (2022) — https://arxiv.org/abs/2204.03272 *(surfaced, not read — no numbers reported here)*
