#!/usr/bin/env python3
"""
dream_extraction.py — S-2: three-pass dream-report extraction + drift scoring.

Consumes the dream-mode hypothesis registry at
`Evaluation/corpora/dream_mode_hypothesis_registry.json` as the single
source of truth for active hypotheses (anchors, drift tolerance,
cascade rules). Passes:

  1. denoise(text)            — strip meta-commentary, brackets, parens.
  2. identify_symbols(text)   — tokenize, lowercase, return set of tokens.
  3. calculate_drift(symbols, hypothesis_id) — 0.0 (perfect anchor match)
     to 1.0 (zero anchor matches), via len(matched_anchors) / len(anchors).

This is **offline-only** Stage 3.5 tooling. No LLM dependency at
milestone 1 (the symbolic approach is the right MVP for a
pipeline-integration check; the LLM-driven version is S-2 milestone
2 and is queued behind the boundary contract).

Scope discipline vs the pasted sketch:
  - The on-disk registry is the single source of truth. No hardcoded
    fallback mock. Missing registry -> fail loudly with a clear error.
  - The synthetic dataset (`Data/synthetic_dream_reports.json`) is
    hand-curated to the on-disk anchor vocabulary, not to an inline
    mock's vocabulary.
  - drift formula is `1.0 - len(matched)/len(anchors)` directly, no
    arbitrary `min(..., 3)` cap on the denominator.
  - The success criterion (Spearman rho >= 0.6) is measured and
    reported. No fabricated prior-art numbers in the governance docs.

Usage:
  ./Scripts/dream_extraction.py                              # self-test
  ./Scripts/dream_extraction.py --dataset Data/synthetic_dream_reports.json
  ./Scripts/dream_extraction.py --report Data/s2_evaluation.json

Importable:
  from dream_extraction import (
      DreamExtractionPipeline, run_evaluation,
  )
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import time
from pathlib import Path
from typing import Optional

import numpy as np
from scipy.stats import spearmanr


logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger("dream_extraction")


# ---------------------------------------------------------------------------
# Paths (defaults)
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = REPO_ROOT / "Evaluation" / "corpora" / "dream_mode_hypothesis_registry.json"
DEFAULT_DATASET  = REPO_ROOT / "Data" / "synthetic_dream_reports.json"
DEFAULT_REPORT   = REPO_ROOT / "Data" / "s2_evaluation.json"


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

class DreamExtractionPipeline:
    """
    Three-pass dream-report extraction and drift scoring pipeline.

    Anchors are loaded from the dream-mode hypothesis registry. The two
    example hypotheses (`hyp_fear_failure_01`, `hyp_safe_exploration_01`)
    are the S-2 smoke-test targets; the pipeline is hypothesis-agnostic
    for any hypothesis with a `primary_anchors` list.
    """

    def __init__(self, registry_path: Path | str = DEFAULT_REGISTRY):
        self.registry_path = Path(registry_path)
        if not self.registry_path.exists():
            raise FileNotFoundError(
                f"Dream-mode hypothesis registry not found at {self.registry_path}. "
                "This pipeline requires the on-disk registry as the single source of truth; "
                "no hardcoded fallback is provided (per the S-2 schema-validation contract)."
            )
        self.hypotheses: dict[str, dict] = self._load_hypotheses()

    def _load_hypotheses(self) -> dict[str, dict]:
        """Load the example-hypotheses block from the registry.

        The S-2 test targets `example_hypotheses_for_schema_validation::hypotheses`
        (the documented shape fixtures for S-1). The four pre-registered
        `S-*` hypotheses are Stage 4 / future-Eval targets and don't
        have a hand-curated dream corpus yet.
        """
        with self.registry_path.open("r", encoding="utf-8") as f:
            registry = json.load(f)
        examples = registry.get("example_hypotheses_for_schema_validation")
        if not examples or "hypotheses" not in examples:
            raise ValueError(
                f"Registry at {self.registry_path} is missing the "
                "'example_hypotheses_for_schema_validation::hypotheses' block. "
                "The S-2 smoke test requires the two documented shape fixtures."
            )
        return examples["hypotheses"]

    def list_hypotheses(self) -> list[str]:
        return list(self.hypotheses.keys())

    def get_anchors(self, hypothesis_id: str) -> list[str]:
        hyp = self.hypotheses.get(hypothesis_id)
        if hyp is None:
            raise KeyError(
                f"Hypothesis '{hypothesis_id}' not found in registry. "
                f"Available: {self.list_hypotheses()}"
            )
        return list(hyp.get("routing", {}).get("primary_anchors", []))

    def get_drift_tolerance(self, hypothesis_id: str) -> Optional[float]:
        hyp = self.hypotheses.get(hypothesis_id)
        if hyp is None:
            return None
        return hyp.get("routing", {}).get("drift_tolerance")

    # -- Pass 1: denoise --
    def denoise(self, text: str) -> str:
        """Strip meta-commentary (brackets, parens), collapse whitespace, lowercase."""
        cleaned = re.sub(r"\[.*?\]", " ", text)  # [Note: ...] meta-commentary
        cleaned = re.sub(r"\(.*?\)", " ", cleaned)  # (parenthetical asides)
        cleaned = re.sub(r"\s+", " ", cleaned)  # collapse whitespace
        return cleaned.strip().lower()

    # -- Pass 2: identify symbols --
    def identify_symbols(self, text: str) -> set[str]:
        """Tokenize on word boundaries, lowercase, return a set of unique tokens."""
        return set(re.findall(r"\b\w+\b", text))

    # -- Pass 3: calculate drift --
    def calculate_drift(self, symbols: set[str], hypothesis_id: str) -> dict:
        """
        Map symbols to the active hypothesis's anchors.

        Returns a dict with the matched anchor list, match count, total
        anchor count, and the drift score (0.0 perfect match, 1.0 zero
        matches). Missing hypothesis -> drift 1.0 (full drift, fail safe).
        """
        anchors = self.get_anchors(hypothesis_id)
        if not anchors:
            # No anchors defined = hypothesis is not yet calibrated.
            # Treat as full drift per the S-2 spec.
            return {
                "matched_anchors": [],
                "match_count": 0,
                "total_anchors": 0,
                "drift_score": 1.0,
                "drift_tolerance": None,
                "drift_exceeds_tolerance": True,
            }

        # Membership check: each anchor must appear as a token in symbols.
        # Anchors in the on-disk registry are single words; if a multi-word
        # anchor ever lands, the tokenization loses it — flagged in the
        # status_note as a known limitation of milestone 1.
        anchors_lower = [a.lower() for a in anchors]
        matched = [a for a in anchors_lower if a in symbols]

        match_count = len(matched)
        total = len(anchors_lower)
        match_ratio = match_count / total
        drift = max(0.0, min(1.0, 1.0 - match_ratio))

        tolerance = self.get_drift_tolerance(hypothesis_id)
        exceeds = (tolerance is not None) and (drift > tolerance)

        return {
            "matched_anchors": matched,
            "match_count": match_count,
            "total_anchors": total,
            "drift_score": round(drift, 4),
            "drift_tolerance": tolerance,
            "drift_exceeds_tolerance": bool(exceeds),
        }

    # -- Composite: process a report end-to-end --
    def process_report(self, raw_text: str, hypothesis_id: str) -> dict:
        cleaned = self.denoise(raw_text)
        symbols = self.identify_symbols(cleaned)
        drift = self.calculate_drift(symbols, hypothesis_id)
        return {
            "cleaned_text": cleaned,
            "extracted_symbols": sorted(symbols),
            **drift,
        }


# ---------------------------------------------------------------------------
# Evaluation harness
# ---------------------------------------------------------------------------

def run_evaluation(
    pipeline: DreamExtractionPipeline,
    dataset: list[dict],
) -> dict:
    """Run the pipeline against a dataset and compute Spearman rho vs ground truth."""
    predicted: list[float] = []
    actual: list[float] = []
    per_report: list[dict] = []

    for item in dataset:
        result = pipeline.process_report(item["text"], item["target_hypothesis"])
        predicted.append(result["drift_score"])
        actual.append(float(item["ground_truth_drift"]))
        per_report.append({
            "report_id":           item["report_id"],
            "target_hypothesis":   item["target_hypothesis"],
            "predicted_drift":     result["drift_score"],
            "ground_truth_drift":  float(item["ground_truth_drift"]),
            "abs_error":           abs(result["drift_score"] - float(item["ground_truth_drift"])),
            "matched_anchors":     result["matched_anchors"],
            "match_count":         result["match_count"],
            "total_anchors":       result["total_anchors"],
        })

    # Spearman rho with midrank tie handling. n>=3 is the minimum for the
    # scipy implementation; smaller datasets would be diagnostic-only.
    # Two-arg form returns a 2-tuple (rho, pvalue); older API keeps
    # Pyright happy without needing the SignificanceResult stubs from
    # scipy >= 1.10.
    if len(predicted) < 3:
        rho, p_val = None, None
    else:
        rho, p_val = spearmanr(predicted, actual)

    return {
        "n_reports":            len(dataset),
        "predicted_drift":      predicted,
        "ground_truth_drift":   actual,
        "per_report":           per_report,
        "spearman_rho":         rho,
        "spearman_pvalue":      p_val,
        "mean_abs_error":       float(np.mean([r["abs_error"] for r in per_report])),
        "max_abs_error":        float(np.max([r["abs_error"] for r in per_report])),
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_evaluation_report(report: dict) -> None:
    log.info("=" * 60)
    log.info("S-2 EVALUATION RESULTS (%d reports)", report["n_reports"])
    log.info("=" * 60)
    log.info("Per-report breakdown:")
    log.info("  %-10s  %-26s  %6s  %6s  %6s", "report", "hypothesis", "pred", "truth", "|err|")
    for r in report["per_report"]:
        log.info(
            "  %-10s  %-26s  %6.3f  %6.3f  %6.3f   matched=%d/%d %s",
            r["report_id"], r["target_hypothesis"],
            r["predicted_drift"], r["ground_truth_drift"], r["abs_error"],
            r["match_count"], r["total_anchors"],
            r["matched_anchors"],
        )
    rho = report["spearman_rho"]
    p = report["spearman_pvalue"]
    if rho is not None:
        log.info("Spearman rho : %.4f  (p=%.4f)", rho, p)
    else:
        log.info("Spearman rho : n/a (n<3)")
    log.info("Mean |error|: %.4f", report["mean_abs_error"])
    log.info("Max  |error|: %.4f", report["max_abs_error"])


def _main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="S-2: three-pass dream extraction + drift scoring, with Spearman validation."
    )
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY,
                        help="dream-mode hypothesis registry (default: %(default)s)")
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET,
                        help="synthetic dream-report dataset (default: %(default)s)")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT,
                        help="output JSON report path (default: %(default)s)")
    parser.add_argument("--quiet", action="store_true", help="log only warnings")
    args = parser.parse_args(argv)

    if args.quiet:
        logging.getLogger().setLevel(logging.WARNING)

    t0 = time.time()
    pipeline = DreamExtractionPipeline(registry_path=args.registry)
    log.info("Loaded registry: %s", args.registry)
    log.info("Available hypotheses: %s", pipeline.list_hypotheses())
    for h in pipeline.list_hypotheses():
        log.info("  %-26s anchors=%-40s tolerance=%s",
                 h, pipeline.get_anchors(h), pipeline.get_drift_tolerance(h))

    if not args.dataset.exists():
        log.error("Dataset not found at %s", args.dataset)
        return 1
    with args.dataset.open("r", encoding="utf-8") as f:
        dataset = json.load(f)
    log.info("Loaded dataset: %s (%d reports)", args.dataset, len(dataset))

    report = run_evaluation(pipeline, dataset)
    report["registry"] = str(args.registry)
    report["dataset"] = str(args.dataset)
    report["elapsed_sec"] = time.time() - t0

    _print_evaluation_report(report)

    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, default=str)
    log.info("Wrote %s (%d bytes)", args.report, args.report.stat().st_size)

    target = 0.60
    rho = report["spearman_rho"]
    if rho is not None and rho >= target:
        log.info("✅ Spearman rho %.4f >= target %.2f (S-2 success criterion met on synthetic)", rho, target)
    elif rho is not None:
        log.warning("⚠️  Spearman rho %.4f < target %.2f (S-2 success criterion NOT met on synthetic; investigate)", rho, target)
    log.info("[Pending: human-rated baseline + LLM-driven 3-pass upgrade are S-2 milestone 2/3; held behind boundary contract.]")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
