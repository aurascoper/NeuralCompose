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

    def __post_init__(self) -> None:
        # If outcome is somehow None or empty, fall back to a sentinel
        # so downstream `if t.outcome in matrix` checks still work.
        if not self.outcome:
            self.outcome = "silent"


def load_turns(path: Path) -> list[Turn]:
    rows: list[Turn] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
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
    note: str


def compute_provenance(turns: list[Turn]) -> ProvenanceReport:
    fp = sum(1 for t in turns if t.has_fingerprint)
    return ProvenanceReport(
        total_turns=len(turns),
        turns_with_fingerprint=fp,
        fingerprint_rate=(fp / len(turns)) if turns else 0.0,
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
    out.append(f"  note: {l['note']}")
    out.append("")

    # 10. Provenance
    out.append("── 10. Generator Provenance ──")
    p = rep["provenance"]
    out.append(f"  turns with fingerprint:     {p['turns_with_fingerprint']} / {p['total_turns']}  ({100*p['fingerprint_rate']:.1f}%)")
    out.append(f"  note: {p['note']}")
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
