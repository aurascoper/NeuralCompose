#!/usr/bin/env python3
"""
analyze_dialectic.py — quantitative analysis of a dialectic session.

Reads a `dialectic-turns-YYYY-MM-DD.jsonl` log produced by
`Sources/BCICore/Composition/HypnagogicDialecticLoop.swift` and
computes the seven metric categories that future `ResearchHypothesis`
evaluations will compare against:

  1. N-gram repetition (bigram / trigram / opening 4-gram)
  2. Opening diversity (distinct first-N-gram ratio)
  3. Semantic self-distance (existing selfSimilarity + Jaccard proxy)
  4. Witness intervention frequency (per outcome, overall)
  5. Response entropy over time (sliding-window Shannon)
  6. Semantic attractor persistence (Jaccard on heard text, ε-bounded)
  7. Transition graph (4x4 outcome transition matrix)
  8. Witness influence (next-3-turn distribution shift)
  9. Latency distributions (turn-index gaps as proxy)
 10. Generator provenance (count of turns with fingerprint)

Output: prints a structured human-readable report. Optionally writes
a JSON sidecar for downstream tools (so the `ResearchHypothesis`
evaluator can ingest baselines without re-running this script).

Usage:
  ./Scripts/analyze_dialectic.py \\
      --input ~/Documents/NeuralCompose/InteractionLogs/dialectic-turns-2026-07-21.jsonl \\
      --output /tmp/dialectic-baseline-001.json

If `--input` is omitted, the script picks the most recent
`dialectic-turns-*.jsonl` from the standard InteractionLogs directory.

This is the quantitative oracle for `ResearchHypothesis.acceptance:`
criteria. Each future hypothesis commit should reference at least one
of these metrics in its YAML, so the comparison is reproducible.

The script is dependency-free (stdlib only) so it runs in any
Python 3.10+ environment, no venv setup required.
"""

from __future__ import annotations

import argparse
import collections
import json
import math
import os
import re
import statistics
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any


# ── Constants ────────────────────────────────────────────────────────

OUTCOMES = ("coherence-seeking", "displacement-seeking", "synthesis", "silent")
OUTCOME_LABEL = {
    "spoke:coherence-seeking": "coherence-seeking",
    "spoke:displacement-seeking": "displacement-seeking",
    "synthesized:synthesis": "synthesis",
    "silent": "silent",
}
EPSILON_JACCARD = 0.65        # "same attractor" threshold for persistence
ENTROPY_WINDOW = 10           # turns in the sliding entropy window
WITNESS_INFLUENCE_HORIZON = 3 # how many turns ahead to look for witness effect
NGRAM_SIZE = 4                # opening 4-grams (matches prior session)
TOP_K_NGRAMS = 10             # how many most-repeated n-grams to surface
MIN_NGRAM_FREQ = 3            # minimum count to surface in the report

# ── Symbolic drift vocabulary classes (H₂ hypothesis) ─────────────
#
# The user named a measurable question: "Does lexical content shift
# from object-centered vocabulary toward relational vocabulary while
# semantic inertia remains low?" The three classes:
#
#   relational: words describing *relations between* things
#               (us, value, sign, between, through, toward, ...)
#   object:     words describing *things* the system manipulates
#               (file, code, prompt, runtime, graph, model, ...)
#   process:    words describing *activities* the system performs
#               (explore, compare, evaluate, reflect, synthesize, ...)
#
# The metric is per-turn: count occurrences of each class / total
# word count. Aggregated as first-half mean vs second-half mean.
# Drift = second - first, in percentage points.
#
# These lists are *hypothesis inputs*, not ground truth. They
# should be iterated as the architecture review's "measure before
# interpreting" discipline demands. Edit here, re-run, compare.
RELATIONAL_TERMS: set[str] = {
    "us", "value", "sign", "relation", "relations", "relationship",
    "relationships", "between", "together", "through", "among",
    "within", "beyond", "toward", "towards", "signs", "values",
    "field", "fields", "space", "spaces", "gap", "gaps", "openness",
    "presence", "absence", "context", "contexts", "frame", "frames",
}
OBJECT_TERMS: set[str] = {
    "file", "code", "prompt", "prompts", "runtime", "graph",
    "graphs", "model", "models", "system", "systems", "network",
    "networks", "function", "functions", "library", "libraries",
    "package", "packages", "module", "modules", "type", "types",
    "class", "classes", "protocol", "protocols", "kernel", "kernels",
    "tensor", "tensors", "vector", "vectors", "matrix", "matrices",
    "hypothesis", "hypotheses", "benchmark", "benchmarks",
}
PROCESS_TERMS: set[str] = {
    "explore", "explores", "comparing", "compare", "compares",
    "stabilize", "stabilizes", "evaluate", "evaluates",
    "reflect", "reflects", "listening", "listen", "listens",
    "attend", "attends", "observe", "observes", "examine",
    "examines", "consider", "considers", "integrate", "integrates",
    "synthesize", "synthesizes", "interrogate", "interrogates",
    "iterate", "iterates", "transform", "transforms", "iterate",
    "drift", "drifts", "shift", "shifts", "settle", "settles",
}

# ── Rhetorical motif classes ─────────────────────────────────────
#
# The architecture review named a question: "Are reflective
# models independently converging on a shared rhetorical
# structure, or merely on a shared vocabulary?" The five
# motif classes decompose the discourse structure:
#
#   adversity       — challenge, struggle, difficulty (problem
#                     framing)
#   inwardness      — within, inner, yourself (self-direction)
#   transcendence   — transcend, beyond, transform (resolution
#                     via uplift)
#   observation     — notice, observe, witness (epistemic stance)
#   investigation   — examine, compare, analyze (analytical
#                     stance)
#
# The "teleological vs epistemic" axis is a derived metric:
#
#   teleological = (transcendence + inwardness) / total_words
#   epistemic    = (observation + investigation) / total_words
#   ratio        = teleological / epistemic
#
#   ratio > 1   → teleological discourse (presupposes inner
#                 resource + goal of transcendence)
#   ratio < 1   → epistemic discourse (examines assumptions
#                 without presupposing outcome)
#
# The architecture review's observation: "The Witness layer
# is about observation and grounding, not about steering the
# user toward a predetermined narrative of growth." So an
# epistemic orientation is more consistent with NeuralCompose's
# design philosophy than a teleological one.
ADVERSITY_TERMS: set[str] = {
    "challenge", "challenges", "struggle", "struggles", "difficulty",
    "difficulties", "adversity", "hardship", "hardships",
    "obstacle", "obstacles", "problem", "problems", "tough", "pain",
    "pains", "suffering", "suffer", "affliction", "trial", "trials",
}
INWARDNESS_TERMS: set[str] = {
    "within", "inner", "yourself", "self", "soul", "heart",
    "depth", "depths", "core", "internally", "inward",
}
TRANSCENDENCE_TERMS: set[str] = {
    "transcend", "transcends", "beyond", "rise", "rises",
    "transform", "transforms", "transformation", "grow", "growth",
    "evolve", "evolution", "transcend", "transcendence",
    "uplift", "elevate", "elevates",
}
OBSERVATION_TERMS: set[str] = {
    "notice", "notices", "observe", "observes", "witness",
    "witnesses", "witnessed", "see", "sees", "look", "looks",
    "watch", "watches", "attend", "attends", "saw", "seen",
}
INVESTIGATION_TERMS: set[str] = {
    "examine", "examines", "examined", "compare", "compares",
    "compared", "analyze", "analyzes", "analyzed", "investigate",
    "investigates", "investigated", "explore", "explores",
    "explored", "ask", "asks", "asked", "question", "questions",
    "questioned", "consider", "considers", "considered", "probe",
    "probes", "probed", "test", "tests", "tested",
}

MOTIF_CLASSES: dict[str, set[str]] = {
    "adversity": ADVERSITY_TERMS,
    "inwardness": INWARDNESS_TERMS,
    "transcendence": TRANSCENDENCE_TERMS,
    "observation": OBSERVATION_TERMS,
    "investigation": INVESTIGATION_TERMS,
}

# ── Level-of-Abstraction (LoA) classes (H₄ hypothesis) ──────────
#
# The architecture review's framing: "Reflective dialogue
# may exhibit upward abstraction drift over time, moving
# from concrete problem-solving toward increasingly general
# relational, societal, or existential framing."
#
# Five abstraction levels (concrete → existential):
#
#   concrete      — runtime, json, ollama, benchmark, telemetry,
#                   file, code, function, system, model
#   interactional — dialogue, conversation, witness, response,
#                   reply, turn, exchange, voice, speaker
#   relational    — between, together, relation, value, sign,
#                   us, through, among, within, toward
#   societal      — community, culture, social, society, media,
#                   institutions, public, people, group, history
#   existential   — human, humanity, condition, mortality, meaning,
#                   transcendence, existence, being, soul, purpose
#
# Each word is assigned to at most one level. A turn is
# represented as a 5-vector of class proportions.
#
# H₄ prediction: long-running reflective dialogue climbs the
# abstraction ladder. The data can test this by:
#   1. Per-outcome LoA distribution
#   2. First-half vs second-half LoA drift
#   3. Cross-cell / cross-model LoA distributions
CONCRETE_TERMS: set[str] = {
    "runtime", "json", "ollama", "benchmark", "telemetry", "file",
    "code", "function", "module", "class", "package", "library",
    "type", "protocol", "system", "network", "graph", "tensor",
    "vector", "matrix", "model", "kernel", "compiler", "binary",
    "config", "spec", "test", "build", "compile", "execute",
    "swift", "python", "rust", "language", "script", "binary",
    "field", "fields",  # `field` is concrete in CS (struct field)
    "input", "output", "data", "value",  # `value` is also concrete
    "schema", "query", "index", "log", "metric", "stats",
}
INTERACTIONAL_TERMS: set[str] = {
    "dialogue", "conversation", "witness", "response", "request",
    "reply", "turn", "exchange", "interaction", "communicate",
    "communication", "message", "utterance", "speak", "saying",
    "voice", "audience", "listener", "speaker", "talk",
    "phrase", "discourse", "register", "dialect", "rhetoric",
}
RELATIONAL_TERMS_LOA: set[str] = {  # distinct from RELATIONAL_TERMS for vocab
    "between", "together", "relation", "relations", "relationship",
    "relationships", "values", "signs", "us", "through", "among",
    "within", "toward", "towards", "beyond", "context", "contexts",
    "frame", "frames", "space", "spaces", "gap", "gaps", "openness",
    "presence", "absence",
}
SOCIETAL_TERMS: set[str] = {
    "community", "communities", "culture", "cultures", "social",
    "society", "societies", "media", "institution", "institutions",
    "public", "people", "group", "groups", "collective",
    "shared", "common", "tradition", "traditions", "history",
    "generation", "generations", "crowd", "civilization",
    "humanities", "world", "era",
}
EXISTENTIAL_TERMS: set[str] = {
    "human", "humanity", "condition", "conditions", "mortality",
    "meaning", "meanings", "transcendence", "existence",
    "being", "soul", "spirit", "life", "death", "alive",
    "consciousness", "conscious", "awareness", "aware",
    "purpose", "identities", "dying", "born", "mind",
    "finitude", "infinite", "eternal", "ultimate",
}

LOA_CLASSES: dict[str, set[str]] = {
    "concrete": CONCRETE_TERMS,
    "interactional": INTERACTIONAL_TERMS,
    "relational": RELATIONAL_TERMS_LOA,
    "societal": SOCIETAL_TERMS,
    "existential": EXISTENTIAL_TERMS,
}
LOA_ORDER: tuple[str, ...] = ("concrete", "interactional", "relational", "societal", "existential")


# ── Data shape ───────────────────────────────────────────────────────

@dataclass
class Turn:
    """A single row from dialectic-turns-*.jsonl, normalized."""
    index: int
    heard: str
    outcome: str              # normalized: one of OUTCOMES
    raw_outcome: str          # original: "spoke:coherence-seeking" etc.
    spoken: str
    tension: float
    margin: float
    self_similarity: float | None
    witness_finding: str | None
    witness_attempted: bool
    witness_distance: float | None
    candidates: list[dict]
    has_fingerprint: bool
    fingerprint_model: str | None   # model name from generatorFingerprint, if any
    fingerprint_prompt_hash: str | None
    # Witness provenance — separate from the pole fingerprint, which only
    # attests the candidates' generator. nil on pre-Witness-fingerprint logs.
    has_witness_fingerprint: bool
    witness_fingerprint_model: str | None
    witness_fingerprint_prompt_hash: str | None

    def __post_init__(self) -> None:
        # If outcome is somehow None or empty, fall back to a sentinel
        # so downstream `if t.outcome in matrix` checks still work.
        if not self.outcome:
            self.outcome = "silent"


def load_turns(path: Path) -> list[Turn]:
    rows: list[Turn] = []
    skipped = 0
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                # JSONL is sometimes written with partial/truncated lines
                # during app shutdown or file-rotation events. The data
                # we have is still useful; just skip the malformed row.
                skipped += 1
                continue
            raw_outcome = d.get("outcome", "")
            outcome = OUTCOME_LABEL.get(raw_outcome, raw_outcome)
            rows.append(Turn(
                index=d.get("index", len(rows)),
                heard=d.get("heard", ""),
                outcome=outcome,
                raw_outcome=raw_outcome,
                spoken=d.get("spokenText", "") or "",
                tension=float(d.get("tension", 0.0) or 0.0),
                margin=float(d.get("margin", 0.0) or 0.0),
                self_similarity=d.get("selfSimilarity"),
                witness_finding=(d.get("witnessFinding") or None) or None,
                witness_attempted=bool(d.get("witnessAttempted", False)),
                witness_distance=d.get("witnessDistance"),
                candidates=d.get("candidates", []) or [],
                has_fingerprint=d.get("generatorFingerprint") is not None,
                fingerprint_model=(
                    d.get("generatorFingerprint", {}).get("model")
                    if d.get("generatorFingerprint") is not None
                    else None
                ),
                fingerprint_prompt_hash=(
                    d.get("generatorFingerprint", {}).get("promptHash")
                    if d.get("generatorFingerprint") is not None
                    else None
                ),
                has_witness_fingerprint=d.get("witnessGeneratorFingerprint") is not None,
                witness_fingerprint_model=(
                    d.get("witnessGeneratorFingerprint", {}).get("model")
                    if d.get("witnessGeneratorFingerprint") is not None
                    else None
                ),
                witness_fingerprint_prompt_hash=(
                    d.get("witnessGeneratorFingerprint", {}).get("promptHash")
                    if d.get("witnessGeneratorFingerprint") is not None
                    else None
                ),
            ))
    rows.sort(key=lambda t: t.index)
    return rows


# ── Metric 1 & 2: n-gram repetition and opening diversity ───────────

_WORD_RE = re.compile(r"\w+", re.UNICODE)


def tokenize(text: str) -> list[str]:
    """Lowercased word tokens. Punctuation stripped, whitespace split."""
    return _WORD_RE.findall(text.lower())


def ngrams(tokens: list[str], n: int) -> list[tuple[str, ...]]:
    return [tuple(tokens[i:i + n]) for i in range(len(tokens) - n + 1)]


@dataclass
class RepetitionReport:
    total_spoken: int
    total_bigrams: int
    total_trigrams: int
    distinct_bigrams: int
    distinct_trigrams: int
    bigram_diversity: float
    trigram_diversity: float
    most_repeated_bigrams: list[tuple[str, int]]
    most_repeated_trigrams: list[tuple[str, int]]


def compute_repetition(turns: list[Turn]) -> RepetitionReport:
    bigram_counts: collections.Counter = collections.Counter()
    trigram_counts: collections.Counter = collections.Counter()
    total_bigrams = 0
    total_trigrams = 0
    spoken_count = 0
    for t in turns:
        toks = tokenize(t.spoken)
        if not toks:
            continue
        spoken_count += 1
        for bg in ngrams(toks, 2):
            bigram_counts[bg] += 1
            total_bigrams += 1
        for tg in ngrams(toks, 3):
            trigram_counts[tg] += 1
            total_trigrams += 1
    bigram_diversity = (len(bigram_counts) / total_bigrams) if total_bigrams else 0.0
    trigram_diversity = (len(trigram_counts) / total_trigrams) if total_trigrams else 0.0
    return RepetitionReport(
        total_spoken=spoken_count,
        total_bigrams=total_bigrams,
        total_trigrams=total_trigrams,
        distinct_bigrams=len(bigram_counts),
        distinct_trigrams=len(trigram_counts),
        bigram_diversity=bigram_diversity,
        trigram_diversity=trigram_diversity,
        most_repeated_bigrams=[
            (" ".join(bg), c) for bg, c in bigram_counts.most_common(TOP_K_NGRAMS)
            if c >= MIN_NGRAM_FREQ
        ],
        most_repeated_trigrams=[
            (" ".join(tg), c) for tg, c in trigram_counts.most_common(TOP_K_NGRAMS)
            if c >= MIN_NGRAM_FREQ
        ],
    )


# ── Opening diversity (4-grams of the first 8 tokens) ───────────────

@dataclass
class OpeningDiversityReport:
    total_turns: int
    distinct_openings: int
    opening_diversity: float
    most_repeated_openings: list[tuple[str, int]]


def compute_opening_diversity(turns: list[Turn]) -> OpeningDiversityReport:
    counts: collections.Counter = collections.Counter()
    total = 0
    for t in turns:
        toks = tokenize(t.spoken)[:8]
        if len(toks) < NGRAM_SIZE:
            continue
        opening = tuple(toks[:NGRAM_SIZE])
        counts[opening] += 1
        total += 1
    return OpeningDiversityReport(
        total_turns=total,
        distinct_openings=len(counts),
        opening_diversity=(len(counts) / total) if total else 0.0,
        most_repeated_openings=[
            (" ".join(op), c) for op, c in counts.most_common(TOP_K_NGRAMS)
            if c >= MIN_NGRAM_FREQ
        ],
    )


# ── Metric 3: semantic self-distance (Jaccard proxy) ───────────────

def jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return 1.0 - (inter / union) if union else 0.0


@dataclass
class SelfDistanceReport:
    n_pairs: int
    mean_jaccard: float
    mean_existing_self_similarity: float | None
    note: str = ""


def compute_self_distance(turns: list[Turn]) -> SelfDistanceReport:
    jaccards: list[float] = []
    for prev, curr in zip(turns, turns[1:]):
        a = set(tokenize(prev.spoken))
        b = set(tokenize(curr.spoken))
        jaccards.append(jaccard(a, b))
    sim_values = [t.self_similarity for t in turns if t.self_similarity is not None]
    return SelfDistanceReport(
        n_pairs=len(jaccards),
        mean_jaccard=statistics.fmean(jaccards) if jaccards else 0.0,
        mean_existing_self_similarity=statistics.fmean(sim_values) if sim_values else None,
    )


# ── Metric: inertia (semantic, linguistic, policy) ───────────────────
#
# Inertia decomposes the convergence phenomenon the architecture
# review surfaced: the system can become more coherent (high
# synthesis rate) and more stereotyped (low ngram/opening
# diversity) simultaneously, by settling onto stable
# conversational attractors. The user's framing:
#
#   "harmony isn't necessarily resolution — it can be equilibrium"
#
# Three measurable components:
#
#   semantic_inertia   — resistance to changing topics
#                        (Jaccard SIMILARITY of consecutive `heard`
#                         word sets; 1 = identical topics)
#   linguistic_inertia — same sentence-openings habit
#                        (1 - opening_4gram_diversity; 1 = always
#                         the same opener)
#   policy_inertia     — same style of resolution choice
#                        (1 - normalized_entropy(transition_matrix);
#                         1 = always pick the same next outcome)
#
# Plus a critical-slowing-down diagnostic: variance and lag-1
# autocorrelation of the heard-line word-count series. Lower
# variance + higher autocorrelation near stable attractors
# is the dynamical-systems signature of approaching a fixed
# point.


def jaccard_similarity(a: set[str], b: set[str]) -> float:
    """1 - jaccard_distance, range [0, 1]; 1 = identical, 0 = disjoint."""
    if not a and not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


@dataclass
class InertiaReport:
    """Three-component inertia + critical-slowing-down diagnostic."""
    semantic_inertia: float           # mean Jaccard similarity of consecutive heard
    linguistic_inertia: float         # 1 - opening 4-gram diversity
    policy_inertia: float             # 1 - normalized transition entropy
    exploration_pressure: float       # = 1 - policy_inertia; the countervailing force
    # Critical slowing down
    heard_length_variance: float
    heard_length_autocorrelation_lag1: float
    note: str = ""


def compute_inertia(turns: list[Turn]) -> InertiaReport:
    # Semantic: Jaccard SIMILARITY of consecutive heard word sets
    heard_sims: list[float] = []
    for prev, curr in zip(turns, turns[1:]):
        a = set(tokenize(prev.heard))
        b = set(tokenize(curr.heard))
        heard_sims.append(jaccard_similarity(a, b))
    semantic_inertia = statistics.fmean(heard_sims) if heard_sims else 0.0

    # Linguistic: 1 - opening 4-gram diversity
    openings: list[str] = []
    for t in turns:
        toks = tokenize(t.spoken)
        if len(toks) >= 4:
            openings.append(" ".join(toks[:4]))
    if openings:
        ling_div = len(set(openings)) / len(openings)
    else:
        ling_div = 1.0
    linguistic_inertia = 1.0 - ling_div

    # Policy: 1 - normalized transition entropy
    #
    # For each non-empty row, compute its Shannon entropy. Average
    # across rows, then normalize by the maximum possible entropy
    # for a single row over `len(OUTCOMES)` outcomes. This gives
    # `policy_inertia ∈ [0, 1]` correctly.
    trans_matrix: dict[str, dict[str, int]] = {o: {o2: 0 for o2 in OUTCOMES} for o in OUTCOMES}
    for prev, curr in zip(turns, turns[1:]):
        if prev.outcome in trans_matrix and curr.outcome in trans_matrix[prev.outcome]:
            trans_matrix[prev.outcome][curr.outcome] += 1
    per_row_entropies: list[float] = []
    for o in OUTCOMES:
        total = sum(trans_matrix[o].values())
        if total == 0:
            continue
        row_dist = [trans_matrix[o][o2] / total for o2 in OUTCOMES]
        h_row = 0.0
        for p in row_dist:
            if p > 0:
                h_row -= p * math.log2(p)
        per_row_entropies.append(h_row)
    if per_row_entropies and len(OUTCOMES) > 1:
        max_h = math.log2(len(OUTCOMES))
        mean_h = statistics.fmean(per_row_entropies)
        policy_inertia = 1.0 - (mean_h / max_h) if max_h > 0 else 0.0
    else:
        policy_inertia = 0.0
    exploration_pressure = 1.0 - policy_inertia

    # Critical slowing down: variance + lag-1 autocorrelation of heard length
    heard_lengths = [float(len(t.heard)) for t in turns if t.heard]
    if len(heard_lengths) >= 2:
        mean_len = statistics.fmean(heard_lengths)
        variance = statistics.pvariance(heard_lengths)
        # Lag-1 autocorrelation
        if variance > 0:
            num = sum(
                (heard_lengths[i] - mean_len) * (heard_lengths[i+1] - mean_len)
                for i in range(len(heard_lengths) - 1)
            )
            den = variance * (len(heard_lengths) - 1)
            autocorr = num / den if den > 0 else 0.0
        else:
            autocorr = 0.0
    else:
        variance = 0.0
        autocorr = 0.0

    # Note when critical slowing down is suggested
    notes: list[str] = []
    if variance < 5.0 and len(heard_lengths) >= 30:
        notes.append("low heard-length variance")
    if autocorr > 0.5 and len(heard_lengths) >= 30:
        notes.append("high lag-1 autocorrelation (sticky dynamics)")

    return InertiaReport(
        semantic_inertia=semantic_inertia,
        linguistic_inertia=linguistic_inertia,
        policy_inertia=policy_inertia,
        exploration_pressure=exploration_pressure,
        heard_length_variance=variance,
        heard_length_autocorrelation_lag1=autocorr,
        note="; ".join(notes),
    )


# ── Metric: symbolic drift (H₂ hypothesis) ────────────────────────
#
# The user named a falsifiable question: "Does lexical content
# shift from object-centered vocabulary toward relational
# vocabulary while semantic inertia remains low?"
#
# This metric measures per-turn proportions of three vocabulary
# classes — relational, object, process — and reports the
# first-half mean vs second-half mean. A positive drift in
# P(relational) with low semantic_inertia is consistent with H₂.
#
# The vocabulary lists (RELATIONAL_TERMS, OBJECT_TERMS,
# PROCESS_TERMS) are defined at the top of the file. They are
# hypothesis inputs, not ground truth — iterate as needed.


@dataclass
class SymbolicDriftReport:
    """P(relational) / P(object) / P(process) over time.

    Each metric is reported as:
      - first-half mean (per-turn proportion)
      - second-half mean (per-turn proportion)
      - drift = second - first, in proportion
      - per-class top-10 words with counts
    """
    total_turns: int
    total_words: int
    relational: dict[str, object]      # first, second, drift, top_words
    object: dict[str, object]
    process: dict[str, object]
    other: dict[str, object]
    note: str = ""


def _classify_words(text: str) -> tuple[int, int, int, int]:
    """Return (relational, object, process, total) for a text."""
    r = o = p = total = 0
    for w in tokenize(text):
        total += 1
        if w in RELATIONAL_TERMS:
            r += 1
        elif w in OBJECT_TERMS:
            o += 1
        elif w in PROCESS_TERMS:
            p += 1
    return r, o, p, total


def compute_symbolic_drift(turns: list[Turn]) -> SymbolicDriftReport:
    """Compute per-turn proportions + first/second-half means + drift."""
    if not turns:
        return SymbolicDriftReport(
            total_turns=0, total_words=0,
            relational={"first": 0.0, "second": 0.0, "drift": 0.0, "top_words": {}},
            object={"first": 0.0, "second": 0.0, "drift": 0.0, "top_words": {}},
            process={"first": 0.0, "second": 0.0, "drift": 0.0, "top_words": {}},
            other={"first": 0.0, "second": 0.0, "drift": 0.0, "top_words": {}},
        )

    mid = len(turns) // 2
    first_turns = turns[:mid]
    second_turns = turns[mid:]

    # Per-turn proportions
    def proportions_for(turn_subset: list[Turn]) -> dict[str, float]:
        rs: list[float] = []
        os: list[float] = []
        ps: list[float] = []
        oth: list[float] = []
        for t in turn_subset:
            r, o, p, total = _classify_words(t.spoken)
            if total == 0:
                continue
            rs.append(r / total)
            os.append(o / total)
            ps.append(p / total)
            oth.append((total - r - o - p) / total)
        return {
            "relational": statistics.fmean(rs) if rs else 0.0,
            "object": statistics.fmean(os) if os else 0.0,
            "process": statistics.fmean(ps) if ps else 0.0,
            "other": statistics.fmean(oth) if oth else 0.0,
        }

    first_p = proportions_for(first_turns)
    second_p = proportions_for(second_turns)

    # Top-10 most-frequent words per class (across all turns)
    counts = {
        "relational": collections.Counter(),
        "object": collections.Counter(),
        "process": collections.Counter(),
    }
    total_words = 0
    for t in turns:
        for w in tokenize(t.spoken):
            total_words += 1
            if w in RELATIONAL_TERMS:
                counts["relational"][w] += 1
            elif w in OBJECT_TERMS:
                counts["object"][w] += 1
            elif w in PROCESS_TERMS:
                counts["process"][w] += 1

    def block(label: str, key: str) -> dict:
        first_v = first_p[key]
        second_v = second_p[key]
        top = dict(counts[label].most_common(10))
        return {
            "first": first_v,
            "second": second_v,
            "drift": second_v - first_v,   # in proportion; *100 = pp
            "top_words": top,
        }

    # Diagnostic note
    notes: list[str] = []
    rel_drift = second_p["relational"] - first_p["relational"]
    obj_drift = second_p["object"] - first_p["object"]
    proc_drift = second_p["process"] - first_p["process"]
    if rel_drift > 0.005 and obj_drift < 0:
        notes.append("P(relational) ↑ while P(object) ↓ — consistent with H₂")
    elif rel_drift > 0.005 and obj_drift >= 0:
        notes.append("P(relational) ↑ without P(object) ↓ — broader drift")
    elif rel_drift < -0.005:
        notes.append("P(relational) ↓ — opposite of H₂")
    else:
        notes.append("P(relational) flat (no clear drift)")

    return SymbolicDriftReport(
        total_turns=len(turns),
        total_words=total_words,
        relational=block("relational", "relational"),
        object=block("object", "object"),
        process=block("process", "process"),
        other={
            "first": first_p["other"],
            "second": second_p["other"],
            "drift": second_p["other"] - first_p["other"],
            "top_words": {},
        },
        note="; ".join(notes),
    )


# ── Metric: Relational Representation Bias (RRB) ──────────────────
#
# The architecture review's RRB metric:
#
#   RRB = P(relational | spoken) / P(relational | heard)
#
# An RRB of:
#   1.0 = no amplification (the model uses relational words at
#         the same rate as the user)
#   >1  = amplification (the model introduces relational framing)
#   <1  = suppression (the model uses relational words less than
#         the user)
#
# The metric is comparable across runtimes/models without naming
# any specific vocabulary. It captures the user's headline
# finding: "the model preferentially reformulates interactions
# in relational terms."
#
# Causal direction:
#   hypothesis → behavior (parameters) → measured RRB
# NOT
#   desired vocabulary → prompt engineering
#
# So a future ResearchHypothesis YAML would tune parameters
# (exploration_pressure, synthesis_pressure, silence_threshold,
# witness_grounding, coherence_weighting) and ask: does RRB
# change?


@dataclass
class RRBReport:
    p_relational_spoken: float
    p_relational_heard: float
    rrb: float                           # ratio
    amplification_class: str             # "amplification" / "neutral" / "suppression"
    note: str = ""


def compute_rrb(turns: list[Turn]) -> RRBReport:
    """Compute the Relational Representation Bias across all turns."""
    if not turns:
        return RRBReport(0.0, 0.0, 0.0, "neutral", "no turns")

    p_s_list: list[float] = []
    p_h_list: list[float] = []
    for t in turns:
        p_s_list.append(_p_relational(t.spoken))
        p_h_list.append(_p_relational(t.heard))

    p_spoken = statistics.fmean(p_s_list) if p_s_list else 0.0
    p_heard = statistics.fmean(p_h_list) if p_h_list else 0.0
    rrb = p_spoken / p_heard if p_heard > 0 else 0.0

    if rrb > 1.10:
        cls = "amplification"
    elif rrb < 0.90:
        cls = "suppression"
    else:
        cls = "neutral"

    return RRBReport(
        p_relational_spoken=p_spoken,
        p_relational_heard=p_heard,
        rrb=rrb,
        amplification_class=cls,
    )


def _p_relational(text: str) -> float:
    """Per-text P(relational word) using RELATIONAL_TERMS."""
    if not text:
        return 0.0
    total = 0
    rel = 0
    for w in tokenize(text):
        total += 1
        if w in RELATIONAL_TERMS:
            rel += 1
    return rel / total if total else 0.0


# ── Metric: rhetorical motifs + epistemic orientation ──────────
#
# Per the architecture review, the question is whether two
# reflective outputs that share a *rhetorical structure*
# (adversity → recognition → inner resource → transcendence)
# are doing so because:
#   1. The training distribution biases reflective LLMs
#      toward counseling / coaching / mindfulness language
#   2. The reflective prompt constrains the discourse
#   3. Reflective has its own interaction-policy attractor
#
# The metric decomposes the discourse into five motif
# classes and reports:
#
#   motif_rates  — per-motif rate per 1000 words, per
#                  outcome (coherence, displacement,
#                  synthesis, silent)
#   total_words  — for normalization
#
# Plus a derived metric:
#
#   teleological_ratio =
#     (transcendence + inwardness) / (observation + investigation)
#
#   ratio > 1  → teleological (presupposes inner resource +
#                goal of transcendence)
#   ratio < 1  → epistemic (examines assumptions without
#                presupposing outcome)
#
# The architecture review's framing: an epistemic orientation
# is more consistent with NeuralCompose's design philosophy
# (Witness = observation, not steering). So if Reflective
# is drifting toward teleological, that's a measurable
# signal that the profile has drifted away from the
# intended stance.


@dataclass
class RhetoricalMotifsReport:
    """Per-motif frequencies + teleological/epistemic orientation."""
    total_turns: int
    total_words: int
    motif_counts: dict[str, int]                  # class -> total occurrences
    motif_rates_per_1000: dict[str, float]        # class -> rate per 1000 words
    per_outcome_rates_per_1000: dict[str, dict[str, float]]   # outcome -> {class -> rate}
    teleological_rate: float                      # P(transcendence + inwardness)
    epistemic_rate: float                         # P(observation + investigation)
    teleological_ratio: float                     # tele / epis; 1.0 = balanced
    orientation: str                              # "teleological" / "balanced" / "epistemic"
    note: str = ""


def compute_rhetorical_motifs(turns: list[Turn]) -> RhetoricalMotifsReport:
    if not turns:
        return RhetoricalMotifsReport(
            total_turns=0, total_words=0,
            motif_counts={}, motif_rates_per_1000={},
            per_outcome_rates_per_1000={},
            teleological_rate=0.0, epistemic_rate=0.0,
            teleological_ratio=0.0, orientation="balanced",
        )

    # Aggregate counts
    counts = {cls: 0 for cls in MOTIF_CLASSES}
    total_words = 0
    for t in turns:
        for w in tokenize(t.spoken):
            total_words += 1
            for cls, term_set in MOTIF_CLASSES.items():
                if w in term_set:
                    counts[cls] += 1

    motif_rates = (
        {cls: 1000 * counts[cls] / total_words for cls in counts}
        if total_words else {cls: 0.0 for cls in counts}
    )

    # Per-outcome rates
    per_outcome: dict[str, dict[str, float]] = {}
    for outcome in OUTCOMES:
        outcome_turns = [t for t in turns if t.outcome == outcome]
        if not outcome_turns:
            continue
        oc_counts = {cls: 0 for cls in MOTIF_CLASSES}
        oc_words = 0
        for t in outcome_turns:
            for w in tokenize(t.spoken):
                oc_words += 1
                for cls, term_set in MOTIF_CLASSES.items():
                    if w in term_set:
                        oc_counts[cls] += 1
        per_outcome[outcome] = (
            {cls: 1000 * oc_counts[cls] / oc_words for cls in oc_counts}
            if oc_words else {cls: 0.0 for cls in oc_counts}
        )

    # Teleological vs epistemic
    tele_count = counts["transcendence"] + counts["inwardness"]
    epis_count = counts["observation"] + counts["investigation"]
    tele_rate = tele_count / total_words if total_words else 0.0
    epis_rate = epis_count / total_words if total_words else 0.0
    ratio = tele_rate / epis_rate if epis_rate > 0 else 0.0

    if ratio > 1.10:
        orientation = "teleological"
    elif ratio < 0.90:
        orientation = "epistemic"
    else:
        orientation = "balanced"

    return RhetoricalMotifsReport(
        total_turns=len(turns),
        total_words=total_words,
        motif_counts=dict(counts),
        motif_rates_per_1000=motif_rates,
        per_outcome_rates_per_1000=per_outcome,
        teleological_rate=tele_rate,
        epistemic_rate=epis_rate,
        teleological_ratio=ratio,
        orientation=orientation,
    )


# ── Metric 4: witness intervention frequency ─────────────────────────

@dataclass
class WitnessFrequencyReport:
    total_turns: int
    witness_attempted: int
    witness_finding_present: int
    witness_finding_rate: float          # of attempted
    witness_finding_rate_overall: float  # of all turns
    by_outcome: dict[str, dict[str, int]]


def compute_witness_frequency(turns: list[Turn]) -> WitnessFrequencyReport:
    attempted = sum(1 for t in turns if t.witness_attempted)
    finding_present = sum(1 for t in turns if t.witness_finding)
    by_outcome: dict[str, dict[str, int]] = {}
    for t in turns:
        b = by_outcome.setdefault(t.outcome, {"attempted": 0, "finding": 0, "total": 0})
        b["total"] += 1
        if t.witness_attempted:
            b["attempted"] += 1
        if t.witness_finding:
            b["finding"] += 1
    return WitnessFrequencyReport(
        total_turns=len(turns),
        witness_attempted=attempted,
        witness_finding_present=finding_present,
        witness_finding_rate=(finding_present / attempted) if attempted else 0.0,
        witness_finding_rate_overall=(finding_present / len(turns)) if turns else 0.0,
        by_outcome=by_outcome,
    )


# ── Metric: Level of Abstraction (LoA) — H₄ hypothesis ────────────
#
# The architecture review's framing: reflective dialogue may
# exhibit *upward abstraction drift* over time, moving from
# concrete problem-solving toward increasingly general
# relational, societal, or existential framing.
#
# Each turn is represented as a 5-vector of class proportions:
#
#   [concrete, interactional, relational, societal, existential]
#
# H₄ predictions to test:
#   1. First-half vs second-half drift: the centroid should
#      shift toward higher abstraction levels over time
#   2. Cross-cell / cross-model comparison: trajectories
#      should be model-dependent (consistent with the
#      RRB / epistemic-orientation findings)
#   3. Per-outcome: synthesis outcomes are expected to be
#      more abstract than coherence or displacement
#
# The metric is *distribution-level*, not scalar — H₄ doesn't
# predict "more abstract" as a single number, but a
# redistribution across the 5 levels.


@dataclass
class LevelOfAbstractionReport:
    """5-vector LoA distribution + first/second-half drift."""
    total_turns: int
    total_words: int
    distribution: dict[str, float]                       # overall mean
    per_outcome: dict[str, dict[str, float]]             # outcome -> 5-vector
    first_half: dict[str, float]
    second_half: dict[str, float]
    drift: dict[str, float]                              # second - first per level
    centroid_first: list[float]                          # [concrete, ..., existential] for first half
    centroid_second: list[float]
    abstraction_shift: float                              # weighted shift toward higher levels
    note: str = ""


def _loa_vector(text: str) -> list[float] | None:
    """Compute a 5-vector of LoA class proportions for a text.

    Each word is assigned to at most one class. Returns None
    if no LoA-classifiable words are found.
    """
    if not text:
        return None
    counts = [0, 0, 0, 0, 0]  # concrete, interactional, relational, societal, existential
    for w in tokenize(text):
        for i, lvl in enumerate(LOA_ORDER):
            if w in LOA_CLASSES[lvl]:
                counts[i] += 1
                break
    total = sum(counts)
    if total == 0:
        return None
    return [c / total for c in counts]


def compute_level_of_abstraction(turns: list[Turn]) -> LevelOfAbstractionReport:
    if not turns:
        return LevelOfAbstractionReport(
            total_turns=0, total_words=0,
            distribution={}, per_outcome={},
            first_half={}, second_half={}, drift={},
            centroid_first=[0, 0, 0, 0, 0],
            centroid_second=[0, 0, 0, 0, 0],
            abstraction_shift=0.0,
        )

    # Per-turn vectors
    vectors: list[list[float]] = []
    for t in turns:
        v = _loa_vector(t.spoken)
        if v is not None:
            vectors.append(v)

    # Overall distribution
    n = len(vectors)
    overall = [
        statistics.fmean(v[i] for v in vectors) if vectors else 0.0
        for i in range(5)
    ]
    distribution = {lvl: overall[i] for i, lvl in enumerate(LOA_ORDER)}

    # Per-outcome
    per_outcome: dict[str, list[float]] = {}
    for outcome in OUTCOMES:
        outcome_turns = [t for t in turns if t.outcome == outcome]
        outcome_vectors: list[list[float]] = []
        for t in outcome_turns:
            v = _loa_vector(t.spoken)
            if v is not None:
                outcome_vectors.append(v)
        if outcome_vectors:
            per_outcome[outcome] = [
                statistics.fmean(v[i] for v in outcome_vectors) if outcome_vectors else 0.0
                for i in range(5)
            ]

    # First-half / second-half
    mid = len(vectors) // 2
    first_vectors = vectors[:mid]
    second_vectors = vectors[mid:]

    first_avg = (
        [statistics.fmean(v[i] for v in first_vectors) for i in range(5)]
        if first_vectors else [0, 0, 0, 0, 0]
    )
    second_avg = (
        [statistics.fmean(v[i] for v in second_vectors) for i in range(5)]
        if second_vectors else [0, 0, 0, 0, 0]
    )

    first_half = {lvl: first_avg[i] for i, lvl in enumerate(LOA_ORDER)}
    second_half = {lvl: second_avg[i] for i, lvl in enumerate(LOA_ORDER)}
    drift = {lvl: second_avg[i] - first_avg[i] for i, lvl in enumerate(LOA_ORDER)}

    # Abstraction shift: weighted change toward higher levels
    # Weight each level by its index (0..4). Positive shift = more abstract.
    abstraction_shift = sum(
        (i / 4) * drift[lvl] for i, lvl in enumerate(LOA_ORDER)
    )

    # Notes
    notes: list[str] = []
    if abstraction_shift > 0.05:
        notes.append("upward abstraction drift detected (H₄ supported)")
    elif abstraction_shift < -0.05:
        notes.append("downward shift toward concrete (H₄ refuted)")
    else:
        notes.append("no significant abstraction drift")

    return LevelOfAbstractionReport(
        total_turns=len(turns),
        total_words=sum(len(t.spoken.split()) for t in turns),
        distribution=distribution,
        per_outcome={o: {lvl: v[i] for i, lvl in enumerate(LOA_ORDER)} for o, v in per_outcome.items()},
        first_half=first_half,
        second_half=second_half,
        drift=drift,
        centroid_first=list(first_avg),
        centroid_second=list(second_avg),
        abstraction_shift=abstraction_shift,
        note="; ".join(notes),
    )


# ── Metric 5: response entropy over time (sliding-window Shannon) ───

def shannon_entropy(tokens: list[str]) -> float:
    if not tokens:
        return 0.0
    counts = collections.Counter(tokens)
    total = len(tokens)
    h = 0.0
    for c in counts.values():
        p = c / total
        h -= p * math.log2(p)
    return h


@dataclass
class EntropyReport:
    window: int
    mean_entropy: float
    min_entropy: float
    max_entropy: float
    first_half_mean: float
    second_half_mean: float
    series: list[float]  # one per window-position


def compute_entropy(turns: list[Turn], window: int = ENTROPY_WINDOW) -> EntropyReport:
    series: list[float] = []
    for i in range(len(turns) - window + 1):
        bucket = []
        for t in turns[i:i + window]:
            bucket.extend(tokenize(t.spoken))
        series.append(shannon_entropy(bucket))
    if not series:
        return EntropyReport(window=window, mean_entropy=0.0, min_entropy=0.0,
                             max_entropy=0.0, first_half_mean=0.0, second_half_mean=0.0,
                             series=[])
    half = len(series) // 2
    return EntropyReport(
        window=window,
        mean_entropy=statistics.fmean(series),
        min_entropy=min(series),
        max_entropy=max(series),
        first_half_mean=statistics.fmean(series[:half]) if half else 0.0,
        second_half_mean=statistics.fmean(series[half:]) if half else 0.0,
        series=series,
    )


# ── Metric 6: semantic attractor persistence (Jaccard on heard) ─────

@dataclass
class AttractorPersistenceReport:
    epsilon: float
    mean_persistence_turns: float
    max_persistence_turns: int
    persistence_distribution: dict[str, int]   # bucket label -> count


def compute_attractor_persistence(turns: list[Turn], eps: float = EPSILON_JACCARD) -> AttractorPersistenceReport:
    """For each turn, count how many consecutive subsequent turns stay
    within ε Jaccard distance of it. Report mean and max."""
    durations: list[int] = []
    heard_token_sets = [set(tokenize(t.heard)) for t in turns]
    for i, anchor in enumerate(heard_token_sets):
        if not anchor:
            durations.append(0)
            continue
        d = 0
        for j in range(i + 1, len(turns)):
            if jaccard(anchor, heard_token_sets[j]) <= eps:
                d += 1
            else:
                break
        durations.append(d)
    # Bucket: 0, 1, 2, 3-5, 6-10, 11+
    buckets: collections.Counter = collections.Counter()
    for d in durations:
        if d == 0: buckets["0"] += 1
        elif d == 1: buckets["1"] += 1
        elif d == 2: buckets["2"] += 1
        elif d <= 5: buckets["3-5"] += 1
        elif d <= 10: buckets["6-10"] += 1
        else: buckets["11+"] += 1
    return AttractorPersistenceReport(
        epsilon=eps,
        mean_persistence_turns=statistics.fmean(durations) if durations else 0.0,
        max_persistence_turns=max(durations) if durations else 0,
        persistence_distribution=dict(buckets),
    )


# ── Metric 7: outcome transition graph ───────────────────────────────

@dataclass
class TransitionReport:
    matrix: dict[str, dict[str, int]]   # matrix["coherence-seeking"]["displacement-seeking"] = 4
    row_totals: dict[str, int]
    column_totals: dict[str, int]


def compute_transitions(turns: list[Turn]) -> TransitionReport:
    matrix: dict[str, dict[str, int]] = {o: {o2: 0 for o2 in OUTCOMES} for o in OUTCOMES}
    row_totals: collections.Counter = collections.Counter()
    for prev, curr in zip(turns, turns[1:]):
        if prev.outcome in matrix and curr.outcome in matrix[prev.outcome]:
            matrix[prev.outcome][curr.outcome] += 1
            row_totals[prev.outcome] += 1
    column_totals: collections.Counter = collections.Counter(t.outcome for t in turns)
    return TransitionReport(
        matrix=matrix,
        row_totals=dict(row_totals),
        column_totals=dict(column_totals),
    )


# ── Metric 8: witness influence on subsequent turns ─────────────────

@dataclass
class WitnessInfluenceReport:
    n_with_finding: int
    horizon: int
    overall_next_k_distribution: dict[str, float]      # outcome -> fraction
    witness_next_k_distribution: dict[str, float]      # outcome -> fraction
    per_outcome_shift: dict[str, float]                # outcome -> (witness - overall)


def compute_witness_influence(turns: list[Turn], horizon: int = WITNESS_INFLUENCE_HORIZON) -> WitnessInfluenceReport:
    overall_counts: collections.Counter = collections.Counter()
    witness_counts: collections.Counter = collections.Counter()
    n_witness = 0
    for i, t in enumerate(turns):
        for j in range(i + 1, min(i + 1 + horizon, len(turns))):
            overall_counts[turns[j].outcome] += 1
        if t.witness_finding:
            n_witness += 1
            for j in range(i + 1, min(i + 1 + horizon, len(turns))):
                witness_counts[turns[j].outcome] += 1
    total_overall = sum(overall_counts.values())
    total_witness = sum(witness_counts.values())
    overall_dist = {o: (overall_counts[o] / total_overall if total_overall else 0.0) for o in OUTCOMES}
    witness_dist = {o: (witness_counts[o] / total_witness if total_witness else 0.0) for o in OUTCOMES}
    per_outcome_shift = {o: witness_dist[o] - overall_dist[o] for o in OUTCOMES}
    return WitnessInfluenceReport(
        n_with_finding=n_witness,
        horizon=horizon,
        overall_next_k_distribution=overall_dist,
        witness_next_k_distribution=witness_dist,
        per_outcome_shift=per_outcome_shift,
    )


# ── Metric 9: latency proxy (turn-index gaps) ──────────────────────

@dataclass
class LatencyProxyReport:
    n_intervals: int
    note: str
    mean_turn_index_gap: float
    median_turn_index_gap: float


def compute_latency_proxy(turns: list[Turn]) -> LatencyProxyReport:
    if len(turns) < 2:
        return LatencyProxyReport(
            n_intervals=0,
            note="insufficient turns",
            mean_turn_index_gap=0.0,
            median_turn_index_gap=0.0,
        )
    gaps = [turns[i + 1].index - turns[i].index for i in range(len(turns) - 1)]
    return LatencyProxyReport(
        n_intervals=len(gaps),
        note=("per-turn wall-clock latency is NOT in this log shape; "
              "turn-index gap is a proxy. Real latency requires a log "
              "schema with timestamps per turn."),
        mean_turn_index_gap=statistics.fmean(gaps),
        median_turn_index_gap=statistics.median(gaps),
    )


# ── Metric 10: generator provenance ─────────────────────────────────

@dataclass
class ProvenanceReport:
    total_turns: int
    turns_with_fingerprint: int
    fingerprint_rate: float
    fingerprint_models: dict[str, int]   # model name -> count
    # Witness provenance. A Reflective run recorded after the Witness
    # fingerprint landed should have one per witness-attempted turn; the
    # prompt-hash collision count is the old bug's signature (a "Witness"
    # transmitting the pole prompt) and must be 0.
    turns_with_witness_fingerprint: int
    witness_fingerprint_models: dict[str, int]
    witness_pole_prompt_hash_collisions: int
    note: str


def compute_provenance(turns: list[Turn]) -> ProvenanceReport:
    fp = sum(1 for t in turns if t.has_fingerprint)
    models: collections.Counter = collections.Counter()
    for t in turns:
        if t.has_fingerprint and t.fingerprint_model:
            models[t.fingerprint_model] += 1
    wfp = sum(1 for t in turns if t.has_witness_fingerprint)
    witness_models: collections.Counter = collections.Counter()
    collisions = 0
    for t in turns:
        if not t.has_witness_fingerprint:
            continue
        if t.witness_fingerprint_model:
            witness_models[t.witness_fingerprint_model] += 1
        if (t.witness_fingerprint_prompt_hash is not None
                and t.witness_fingerprint_prompt_hash == t.fingerprint_prompt_hash):
            collisions += 1
    return ProvenanceReport(
        total_turns=len(turns),
        turns_with_fingerprint=fp,
        fingerprint_rate=(fp / len(turns)) if turns else 0.0,
        fingerprint_models=dict(models),
        turns_with_witness_fingerprint=wfp,
        witness_fingerprint_models=dict(witness_models),
        witness_pole_prompt_hash_collisions=collisions,
        note=("0/140 is the expected baseline pre-b9c09fd-live-app. "
              "The core runtime records fingerprints (commit b9c09fd); "
              "the live app will start recording them once the "
              "AppViewModel + LiveRuntimeFactory wiring lands."),
    )


# ── Renderer ─────────────────────────────────────────────────────────

def render_report(rep: dict[str, Any]) -> str:
    out: list[str] = []
    out.append("=" * 72)
    out.append("DIALECTIC SESSION ANALYSIS")
    out.append("=" * 72)
    out.append(f"Total turns analyzed: {rep['turn_count']}")
    out.append("")

    # Outcome distribution
    out.append("── Outcome Distribution ──")
    for o, c in sorted(rep["outcome_counts"].items(), key=lambda kv: -kv[1]):
        pct = 100 * c / rep["turn_count"] if rep["turn_count"] else 0
        out.append(f"  {o:<22s}  {c:>4d}  ({pct:5.1f}%)")
    out.append("")

    # 1. Repetition
    out.append("── 1. N-gram Repetition ──")
    r = rep["repetition"]
    out.append(f"  spoken turns:               {r['total_spoken']}")
    out.append(f"  bigram diversity:           {r['bigram_diversity']:.3f}  ({r['distinct_bigrams']} / {r['total_bigrams']})")
    out.append(f"  trigram diversity:          {r['trigram_diversity']:.3f}  ({r['distinct_trigrams']} / {r['total_trigrams']})")
    if r["most_repeated_bigrams"]:
        out.append(f"  top repeated bigrams:")
        for bg, c in r["most_repeated_bigrams"][:5]:
            out.append(f"    [{c:>3d}] {bg}")
    if r["most_repeated_trigrams"]:
        out.append(f"  top repeated trigrams:")
        for tg, c in r["most_repeated_trigrams"][:5]:
            out.append(f"    [{c:>3d}] {tg}")
    out.append("")

    # 2. Opening diversity
    out.append("── 2. Opening Diversity (4-grams) ──")
    o = rep["opening_diversity"]
    out.append(f"  distinct openings:          {o['distinct_openings']} / {o['total_turns']}  ({o['opening_diversity']:.3f})")
    if o["most_repeated_openings"]:
        for op, c in o["most_repeated_openings"][:5]:
            out.append(f"    [{c:>3d}] {op}")
    out.append("")

    # 3. Self-distance
    out.append("── 3. Semantic Self-Distance ──")
    sd = rep["self_distance"]
    out.append(f"  consecutive pairs:          {sd['n_pairs']}")
    out.append(f"  mean Jaccard distance:      {sd['mean_jaccard']:.3f}  (0=identical, 1=disjoint)")
    if sd["mean_existing_self_similarity"] is not None:
        out.append(f"  mean existing selfSim:      {sd['mean_existing_self_similarity']:.3f}  (1=identical, 0=disjoint)")
    out.append("")

    # 4. Witness frequency
    out.append("── 4. Witness Intervention Frequency ──")
    w = rep["witness_frequency"]
    out.append(f"  witness attempted:          {w['witness_attempted']} / {w['total_turns']}  ({100*w['witness_attempted']/w['total_turns']:.1f}%)")
    out.append(f"  witness finding present:    {w['witness_finding_present']} / {w['witness_attempted']} attempted  ({100*w['witness_finding_rate']:.1f}%)")
    out.append(f"  overall finding rate:       {100*w['witness_finding_rate_overall']:.1f}%")
    out.append(f"  by outcome:")
    for oc, b in sorted(w["by_outcome"].items()):
        if b["total"] > 0:
            out.append(f"    {oc:<22s}  attempted {b['attempted']:>3d}/{b['total']:>3d}  finding {b['finding']:>3d}")
    out.append("")

    # 5. Entropy
    out.append(f"── 5. Response Entropy (sliding window={ENTROPY_WINDOW}) ──")
    e = rep["entropy"]
    out.append(f"  mean Shannon entropy:       {e['mean_entropy']:.3f} bits")
    out.append(f"  min:                        {e['min_entropy']:.3f}  max: {e['max_entropy']:.3f}")
    if e["series"]:
        out.append(f"  first-half mean:            {e['first_half_mean']:.3f}")
        out.append(f"  second-half mean:           {e['second_half_mean']:.3f}")
        if e['second_half_mean'] < e['first_half_mean'] - 0.1:
            out.append(f"  ⚠ entropy declining: vocabulary may be collapsing")
        elif e['second_half_mean'] > e['first_half_mean'] + 0.1:
            out.append(f"  ✓ entropy rising: vocabulary diversifying")
    out.append("")

    # 6. Attractor persistence
    out.append(f"── 6. Attractor Persistence (Jaccard ε={EPSILON_JACCARD}) ──")
    a = rep["attractor_persistence"]
    out.append(f"  mean persistence (turns):   {a['mean_persistence_turns']:.2f}")
    out.append(f"  max persistence (turns):    {a['max_persistence_turns']}")
    out.append(f"  distribution:")
    for bucket in ("0", "1", "2", "3-5", "6-10", "11+"):
        out.append(f"    {bucket:<5s}  {a['persistence_distribution'].get(bucket, 0):>3d} turns")
    out.append("")

    # 7. Transition graph
    out.append("── 7. Outcome Transition Graph ──")
    t = rep["transitions"]
    out.append(f"  rows = from, columns = to")
    header = "  " + " " * 24 + "  ".join(f"{o[:6]:>6s}" for o in OUTCOMES) + "  | total"
    out.append(header)
    for o in OUTCOMES:
        row = t["matrix"][o]
        total = t["row_totals"].get(o, 0)
        line = f"  {o:<24s}  " + "  ".join(f"{row[o2]:>6d}" for o2 in OUTCOMES) + f"  | {total:>4d}"
        out.append(line)
    out.append("")

    # 8. Witness influence
    out.append(f"── 8. Witness Influence on Next-{WITNESS_INFLUENCE_HORIZON} Turns ──")
    wi = rep["witness_influence"]
    out.append(f"  turns with witness finding: {wi['n_with_finding']}")
    out.append(f"  outcome     overall%   witness%   shift")
    for o in OUTCOMES:
        ov = 100 * wi["overall_next_k_distribution"][o]
        wv = 100 * wi["witness_next_k_distribution"][o]
        sh = wi["per_outcome_shift"][o]
        marker = " ⚠" if abs(sh) > 0.1 else ""
        out.append(f"  {o:<22s}  {ov:>6.1f}    {wv:>6.1f}    {sh:+.3f}{marker}")
    out.append("")

    # 9. Latency proxy
    out.append("── 9. Latency Proxy (turn-index gaps) ──")
    l = rep["latency"]
    out.append(f"  intervals:                  {l['n_intervals']}")
    out.append(f"  mean turn-index gap:        {l['mean_turn_index_gap']:.2f}")
    out.append(f"  median turn-index gap:      {l['median_turn_index_gap']:.1f}")
    if l.get('note'):
        out.append(f"  note:                       {l['note']}")
    out.append("")

    # 11. Inertia (semantic, linguistic, policy) + critical slowing down
    out.append("── 11. Inertia (the three-component attractor picture) ──")
    i = rep["inertia"]
    out.append(f"  semantic_inertia    {i['semantic_inertia']:.3f}   (heard-line Jaccard similarity; 1=sticky topics)")
    out.append(f"  linguistic_inertia  {i['linguistic_inertia']:.3f}   (1 - opening_4gram_diversity; 1=stereotyped openings)")
    out.append(f"  policy_inertia      {i['policy_inertia']:.3f}   (1 - normalized transition entropy; 1=deterministic next-outcome)")
    out.append(f"  exploration_pressure {i['exploration_pressure']:.3f}   (1 - policy_inertia; the countervailing force)")
    out.append("")
    out.append(f"  heard-length variance:           {i['heard_length_variance']:.2f}  (low → near fixed point)")
    out.append(f"  heard-length autocorr (lag=1):   {i['heard_length_autocorrelation_lag1']:.3f}  (high → sticky dynamics)")
    if i.get("note"):
        out.append(f"  critical-slowing-down hints:     {i['note']}")
    out.append("")

    # 12. Symbolic drift (H₂ hypothesis)
    out.append("── 12. Symbolic Drift (H₂ hypothesis test) ──")
    sd = rep.get("symbolic_drift", {})
    if sd:
        out.append(f"  total turns / words:       {sd['total_turns']} / {sd['total_words']}")
        out.append("")
        for label, key in [("relational", "relational"), ("object", "object"), ("process", "process")]:
            blk = sd[key]
            first = blk.get("first", 0.0) * 100
            second = blk.get("second", 0.0) * 100
            drift_pp = blk.get("drift", 0.0) * 100
            arrow = "↑" if drift_pp > 0.05 else "↓" if drift_pp < -0.05 else "="
            out.append(f"  P({label:<10s})  first={first:>5.2f}%  second={second:>5.2f}%  drift={drift_pp:+5.2f}pp {arrow}")
            top = blk.get("top_words", {}) or {}
            if top:
                top_str = ", ".join(f"{w}:{c}" for w, c in list(top.items())[:5])
                out.append(f"                 top: {top_str}")
        out.append("")
        if sd.get("note"):
            out.append(f"  H₂ verdict:                {sd['note']}")
    out.append("")

    # 13. Relational Representation Bias (RRB)
    rrb = rep.get("rrb", {})
    if rrb:
        out.append("── 13. Relational Representation Bias (RRB) ──")
        out.append(f"  P(relational | spoken):  {100*rrb.get('p_relational_spoken', 0):.2f}%")
        out.append(f"  P(relational | heard):   {100*rrb.get('p_relational_heard', 0):.2f}%")
        out.append(f"  RRB:                     {rrb.get('rrb', 0):.2f}   (1.0 = no amplification)")
        out.append(f"  class:                   {rrb.get('amplification_class', '?')}")
        if rrb.get('note'):
            out.append(f"  note:                    {rrb['note']}")
    out.append("")

    # 14. Rhetorical motifs + epistemic orientation
    rm = rep.get("rhetorical_motifs", {})
    if rm:
        out.append("── 14. Rhetorical Motifs + Epistemic Orientation ──")
        out.append(f"  total words:        {rm.get('total_words', 0)}")
        out.append("")
        rates = rm.get("motif_rates_per_1000", {}) or {}
        out.append(f"  motif rates (per 1000 words):")
        for cls in ["adversity", "inwardness", "transcendence", "observation", "investigation"]:
            r = rates.get(cls, 0.0)
            out.append(f"    {cls:<14s}  {r:>6.2f}")
        out.append("")
        out.append(f"  teleological rate:    {100*rm.get('teleological_rate', 0):.2f}%   (transcendence + inwardness)")
        out.append(f"  epistemic rate:       {100*rm.get('epistemic_rate', 0):.2f}%   (observation + investigation)")
        ratio = rm.get("teleological_ratio", 0.0)
        out.append(f"  teleological ratio:   {ratio:.2f}  (1.0 = balanced; >1 = teleological; <1 = epistemic)")
        out.append(f"  orientation:          {rm.get('orientation', '?')}")
        out.append("")
        per_out = rm.get("per_outcome_rates_per_1000", {}) or {}
        if per_out:
            out.append("  per-outcome motif rates (per 1000 words):")
            outcomes_order = ["coherence-seeking", "displacement-seeking", "synthesis", "silent"]
            for o in outcomes_order:
                if o not in per_out:
                    continue
                out.append(f"    {o}:")
                for cls in ["adversity", "inwardness", "transcendence", "observation", "investigation"]:
                    r = per_out[o].get(cls, 0.0)
                    out.append(f"      {cls:<14s}  {r:>6.2f}")
        out.append("")

    # 15. Level of Abstraction (LoA) — H₄ hypothesis
    loa = rep.get("level_of_abstraction", {})
    if loa:
        out.append("── 15. Level of Abstraction (H₄ hypothesis test) ──")
        out.append(f"  5-vector (concrete → existential):")
        for lvl in ["concrete", "interactional", "relational", "societal", "existential"]:
            d = loa.get("distribution", {}).get(lvl, 0.0)
            out.append(f"    {lvl:<14s}  {100*d:>6.2f}%")
        out.append("")
        out.append(f"  first-half vs second-half drift:")
        for lvl in ["concrete", "interactional", "relational", "societal", "existential"]:
            f_v = loa.get("first_half", {}).get(lvl, 0.0)
            s_v = loa.get("second_half", {}).get(lvl, 0.0)
            drift = s_v - f_v
            arrow = "↑" if drift > 0.01 else "↓" if drift < -0.01 else "="
            out.append(f"    {lvl:<14s}  first={100*f_v:>5.2f}%  second={100*s_v:>5.2f}%  Δ={100*drift:+5.2f}pp {arrow}")
        out.append("")
        out.append(f"  abstraction_shift:        {loa.get('abstraction_shift', 0):+.3f}  (positive = upward drift)")
        if loa.get("note"):
            out.append(f"  H₄ verdict:              {loa['note']}")
        out.append("")

    # 10. Provenance
    out.append("── 10. Generator Provenance ──")
    p = rep["provenance"]
    out.append(f"  turns with fingerprint:     {p['turns_with_fingerprint']} / {p['total_turns']}  ({100*p['turns_with_fingerprint']/p['total_turns']:.1f}%)")
    if p['fingerprint_models']:
        out.append(f"  fingerprint models:")
        for m, c in sorted(p['fingerprint_models'].items(), key=lambda x: -x[1]):
            out.append(f"    {m}: {c}")
    wfp = p.get('turns_with_witness_fingerprint', 0)
    out.append(f"  turns with witness fp:      {wfp} / {p['total_turns']}  ({100*wfp/p['total_turns']:.1f}%)")
    if p.get('witness_fingerprint_models'):
        out.append(f"  witness fingerprint models:")
        for m, c in sorted(p['witness_fingerprint_models'].items(), key=lambda x: -x[1]):
            out.append(f"    {m}: {c}")
    collisions = p.get('witness_pole_prompt_hash_collisions', 0)
    if wfp:
        verdict = "OK (witness prompt ≠ pole prompt)" if collisions == 0 else "BUG SIGNATURE — witness transmitted the pole prompt"
        out.append(f"  witness/pole hash collisions: {collisions}  {verdict}")
    if p.get('note'):
        out.append(f"  note:                       {p['note']}")
    out.append("")
    # 11. Named-phrase detector (the patterns the user flagged
    # qualitatively; surfaced here as a count).
    out.append("── 11. Named-Phrase Detector ──")
    named = rep.get("named_phrases", {})
    if named:
        for phrase, info in named.items():
            if info["count"] > 0:
                positions = ", ".join(str(p) for p in info["positions"][:5])
                more = f" (+{len(info['positions']) - 5} more)" if len(info['positions']) > 5 else ""
                out.append(f"  {info['count']:>3d}  '{phrase}'  at idx [{positions}{more}]")
    out.append("")

    out.append("=" * 72)
    return "\n".join(out)


# Phrases the user named qualitatively during SOAK 001 review.
# Surfacing their counts turns anecdotal observations into
# measurable acceptance criteria for future ResearchHypothesis
# evaluations. Add new entries here as the user names more.
NAMED_PHRASES = (
    "we should consider whether there might be another variable",
    "in a live dialogue",
    "as a human i",
)


@dataclass
class NamedPhraseHit:
    phrase: str
    count: int
    positions: list[int]


def compute_named_phrases(turns: list[Turn]) -> dict[str, dict[str, Any]]:
    """Count occurrences of each NAMED_PHRASE in the spoken text.
    Lowercased comparison so the case in the JSONL doesn't matter.
    Returns a dict keyed by phrase; each value is a flat dict
    suitable for JSON serialization (count + positions)."""
    out: dict[str, dict[str, Any]] = {}
    for phrase in NAMED_PHRASES:
        lo = phrase.lower()
        positions: list[int] = []
        for t in turns:
            if lo in t.spoken.lower():
                positions.append(t.index)
        out[phrase] = {"count": len(positions), "positions": positions}
    return out


# ── CLI ─────────────────────────────────────────────────────────────

def find_default_input() -> Path:
    candidates = sorted(
        Path("/Users/aurascoper/Documents/NeuralCompose/InteractionLogs").glob(
            "dialectic-turns-*.jsonl"
        ),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        sys.exit("error: no dialectic-turns-*.jsonl in InteractionLogs; pass --input")
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n")[0] if __doc__ else "analyze a dialectic session",
    )
    parser.add_argument("--input", type=Path, default=None,
                        help="path to dialectic-turns-*.jsonl (default: most recent in InteractionLogs)")
    parser.add_argument("--output", type=Path, default=None,
                        help="optional JSON sidecar path for downstream tooling")
    args = parser.parse_args()
    path = args.input or find_default_input()
    if not path.exists():
        sys.exit(f"error: input not found: {path}")
    turns = load_turns(path)
    if not turns:
        sys.exit(f"error: no turns in {path}")
    outcome_counts: collections.Counter = collections.Counter(t.outcome for t in turns)
    rep: dict[str, Any] = {
        "input_path": str(path),
        "turn_count": len(turns),
        "outcome_counts": dict(outcome_counts),
        "repetition": asdict(compute_repetition(turns)),
        "opening_diversity": asdict(compute_opening_diversity(turns)),
        "self_distance": asdict(compute_self_distance(turns)),
        "witness_frequency": asdict(compute_witness_frequency(turns)),
        "entropy": asdict(compute_entropy(turns)),
        "attractor_persistence": asdict(compute_attractor_persistence(turns)),
        "transitions": asdict(compute_transitions(turns)),
        "witness_influence": asdict(compute_witness_influence(turns)),
        "latency": asdict(compute_latency_proxy(turns)),
        "provenance": asdict(compute_provenance(turns)),
        "inertia": asdict(compute_inertia(turns)),
        "symbolic_drift": asdict(compute_symbolic_drift(turns)),
        "rrb": asdict(compute_rrb(turns)),
        "rhetorical_motifs": asdict(compute_rhetorical_motifs(turns)),
        "level_of_abstraction": asdict(compute_level_of_abstraction(turns)),
        "named_phrases": compute_named_phrases(turns),
    }
    print(render_report(rep))
    if args.output:
        # Don't write the entropy series to the JSON — it's large and not
        # useful for downstream tooling. Keep the summary stats.
        rep_for_json = dict(rep)
        rep_for_json["entropy"].pop("series", None)
        args.output.write_text(json.dumps(rep_for_json, indent=2))
        print(f"\n  → wrote JSON baseline: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
