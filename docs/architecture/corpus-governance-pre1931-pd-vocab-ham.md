# Three-Tier Corpus Governance: Pre-1931 Public Domain, Modern Vocabulary-Only, and Quarantined Local HAM

`[GOVERNANCE SPECIFICATION - NC-CORPUS-GOV-PRE1931-PD-VOCAB-HAM-001]`

Machine-readable manifest: `configs/corpus-governance-pre1931-pd-vocab-ham-v1.json`

## 1. Purpose and Scope

`NeuralCompose` enforces a strict three-tier boundary over all text, lexical priors, and autobiographical memory artifacts entering the dialectical runtime, ASR bias layer, and local memory stores:

1. **Tier 1 (`pre_1931_public_domain`)**: Full-text literary, philosophical, and scientific prose is admissible iff the source work was published on or before **December 31, 1930** (`publication_year <= 1930`) and carries verified public-domain provenance.
2. **Tier 2 (`vocabulary_only_modern`)**: Post-1930 scientific and technical sources (`publication_year >= 1931`) are restricted strictly to isolated domain vocabulary terms, mathematical/topological identifiers, and neurophysiological nomenclature (`<= 6` tokens, `<= 64` characters per entry, zero verbatim prose sentences).
3. **Tier 3 (`local_ham_quarantined`)**: First-party human-authored autobiographical memory (`HAM` in `claude-mind` SQLite/PostgreSQL) and dialectical interaction telemetry (`InteractionLogs/*.jsonl`) are governed by `ADR-005` and `docs/architecture/dialectic-corpus-quarantine.md` (`eligible_for_encoder_training: false`, `eligible_for_science: false`).

## 2. Tier 1: Pre-1931 Public-Domain Full-Text Boundary (`<= 1930`)

Full-text passages used for prosodic cadence priors, rhetorical rhythm modeling, or philosophical grounding must satisfy:

- `publication_year <= 1930` (US public-domain statutory cutoff).
- Explicit provenance fields (`work_id`, `title`, `author`, `publication_year`, `public_domain_basis`, `sha256_digest`).
- Canonical seed works include William James (*The Principles of Psychology*, 1890), Henri Poincare (*Analysis Situs*, 1895), Henri Bergson (*Matter and Memory*, 1896), Hans Berger (*Uber das Elektrenkephalogramm des Menschen*, 1929), and Alfred North Whitehead (*Process and Reality*, 1929).

## 3. Tier 2: Modern Vocabulary-Only Boundary (`>= 1931`)

For modern scientific concepts (e.g., `SIGReg`, `LeJEPA`, `ST-JEMA`, `Mahalanobis tension`, `Tarjan bridge`, `persistent homology`, `1/f spectral slope`), `NeuralCompose` never ingests copyrighted prose paragraphs or verbatim sentences. Instead:

- Only isolated technical terms (`max_tokens_per_term = 6`, `max_chars_per_term = 64`) are admitted into `Sources/BCICore/Composition/VoiceProfile.swift` (`coldVocabulary`) for Apple Speech / Whisper ASR phonetic biasing.
- Private household names and personal identifiers are strictly excluded from `VoiceProfile.coldVocabulary`.

## 4. Tier 3: Local HAM and Interaction-Log Warrant Gate (`ADR-005`)

First-party operator logs (`~/Documents/NeuralCompose/InteractionLogs/`, synchronized sanitized fixtures in `InteractionLogs/` and `Tests/Fixtures/InteractionLogs/`) and `claude-mind` memory records (`ZMEMORYRECORD` in SQLite and `memories` in PostgreSQL) are governed by two coupled gates:

1. **Autobank Warrant & Conditional Autoforgetting (`Scripts/memory-gate.py` & `DialecticalMemory.evaluateAutobankWarrant`)**:
   - Only `spoke:*` and `synthesized:*` turns with `>= 5` substantive tokens and `selfSimilarity <= 0.92` are banked into `dialectic-autobank-<date>.jsonl` and `autobank-manifest-<date>.jsonl`.
   - Silent turns, single-token stutters, short backchannels/hedges, routine transit/logistics commands, and reflexively collapsed turns (`selfSimilarity > 0.92`) are automatically rejected at ingestion and tombstoned when `memory-gate.py autoforget` runs.
2. **Permanent Scientific Quarantine (`ADR-005`)**:
   - Every local HAM and interaction-log artifact carries `eligible_for_encoder_training: false`, `eligible_for_policy_training: false`, and `eligible_for_science: false`.
   - All repository-tracked interaction-log fixtures and manifests enforce the zero em-dash and zero en-dash typography invariant.
