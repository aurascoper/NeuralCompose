#!/usr/bin/env python3
"""
dream_extraction.py — S-2: three-pass dream-report extraction + drift scoring.

Consumes the dream-mode hypothesis registry at
`Evaluation/corpora/dream_mode_hypothesis_registry.json` as the single
source of truth for active hypotheses (anchors, drift tolerance,
cascade rules). Three-pass architecture:

  1. denoise(text)            — strip meta-commentary, brackets, parens.
  2. identify_symbols(text)   — tokenize, lowercase, return set of tokens.
  3. calculate_drift          — delegated to a `DriftScoring` backend.

Two backends are wired and selectable via `--backend {proxy,llm}`:

  - SymbolMatchScorer  (proxy, offline, the milestone 1 implementation)
  - LLMDriftScorer     (S-2 milestone 3; requires a local OpenAI-
                        compatible server such as Ollama, vLLM, or
                        MLX-Server hosting qwen2.5:0.5b)

Both backends satisfy the same `DriftScoring` protocol so the
pipeline is backend-agnostic. Spearman validation runs against
either backend and the per-backend results are written to separate
JSON report files for side-by-side comparison.

This is **offline-only** Stage 3.5 tooling. No third-party LLM
client libraries; the LLM client uses `urllib.request` (zero new
deps) and a small structured JSON-mode prompt. The LLM is consulted
only when `--backend llm` is passed; the proxy path is the canonical
deterministic pipeline.

Scope discipline:
  - The on-disk registry is the single source of truth. No hardcoded
    fallback mock. Missing registry -> fail loudly with a clear error.
  - The example hypotheses (`hyp_fear_failure_01`,
    `hyp_safe_exploration_01`) live in the
    `example_hypotheses_for_schema_validation::hypotheses` block, NOT
    in the top-level `hypotheses` list (which is the S-* pre-registered
    evidence-backed list). The S-2 smoke test targets the example
    block because that is where the dream-relevant shape fixtures are.
  - The LLM client reads `routing.primary_anchors` and
    `routing.target_concept` from the example block. Anchors are
    sent to the LLM as a context hint, NOT as a matching vocabulary;
    the prompt explicitly asks the LLM to use semantic understanding
    rather than literal-anchor matching.
  - Spearman ρ uses `scipy.stats.spearmanr` (already in the venv);
    no hand-rolled rank correlation.

Usage:
  ./Scripts/dream_extraction.py --backend proxy                       # self-test on default synthetic dataset
  ./Scripts/dream_extraction.py --backend proxy --dataset Data/human_rated_dream_reports.json
  ./Scripts/dream_extraction.py --backend llm --llm-model qwen2.5:0.5b
  ./Scripts/dream_extraction.py --backend llm --llm-url http://localhost:8000/v1 --llm-model qwen2.5-0.5b-instruct

Importable:
  from dream_extraction import (
      DreamExtractionPipeline, HypothesisContext,
      SymbolMatchScorer, LLMDriftScorer, DriftScoring,
      run_evaluation, SPEC_VERSION,
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
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional, Protocol, runtime_checkable

import numpy as np
from scipy.stats import spearmanr


logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
log = logging.getLogger("dream_extraction")

SPEC_VERSION = "1.1.0"


# ---------------------------------------------------------------------------
# Paths (defaults)
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = REPO_ROOT / "Evaluation" / "corpora" / "dream_mode_hypothesis_registry.json"
DEFAULT_DATASET  = REPO_ROOT / "Data" / "synthetic_dream_reports.json"
DEFAULT_REPORT   = REPO_ROOT / "Data" / "s2_evaluation.json"

DEFAULT_LLM_URL   = "http://localhost:11434/v1"
DEFAULT_LLM_MODEL = "qwen2.5:0.5b"
DEFAULT_LLM_TIMEOUT_S = 30.0


# ---------------------------------------------------------------------------
# Hypothesis context
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class HypothesisContext:
    """A small, scorer-friendly view of a single hypothesis.

    Pulled from the on-disk registry at pipeline construction time
    so the LLM client (and the symbol-match client) can score
    without re-walking the JSON every call.
    """
    hypothesis_id: str
    target_concept: str
    primary_anchors: tuple[str, ...]
    drift_tolerance: Optional[float]


# ---------------------------------------------------------------------------
# Drift scoring protocol (two implementations)
# ---------------------------------------------------------------------------

@runtime_checkable
class DriftScoring(Protocol):
    """A pluggable drift scorer. The pipeline is backend-agnostic."""
    name: str

    def score(self, symbols: frozenset[str], hypothesis: HypothesisContext) -> float:
        """Return a drift score in [0, 1]. 0 = perfect anchor match, 1 = total drift."""
        ...


class SymbolMatchScorer:
    """Milestone 1 prototype. Literal token-membership check.

    Drift = 1.0 - (matched_anchors / total_anchors). Known to be brittle
    against morphology and zero-anchor imagery (see S-2 status_note).
    """

    name: str = "proxy"

    def score(self, symbols: frozenset[str], hypothesis: HypothesisContext) -> float:
        if not hypothesis.primary_anchors:
            return 1.0
        anchors_lower = tuple(a.lower() for a in hypothesis.primary_anchors)
        matched = sum(1 for a in anchors_lower if a in symbols)
        drift = 1.0 - (matched / len(anchors_lower))
        return max(0.0, min(1.0, drift))


class LLMDriftScorer:
    """S-2 milestone 3: a local OpenAI-compatible chat-completions client.

    Targets `qwen2.5-0.5b` per the dream-mode hypothesis registry. Uses
    `urllib.request` (zero new deps). Forces JSON-mode response.

    The prompt explicitly asks the LLM to use semantic understanding
    rather than literal-anchor matching, and lists the anchors as a
    context hint, not as the matching vocabulary. The drift is
    computed by the LLM, not by string-matching on the response.
    """

    name: str = "llm"

    SYSTEM_PROMPT = (
        "You are a precise sleep-laboratory scoring engine. Your job is to "
        "analyze a dream report and calculate its 'drift' relative to a target "
        "dream-induction hypothesis.\n\n"
        "Drift scale:\n"
        "  - 0.00: Perfect match. The dream captures the core thematic imagery "
        "and meaning of the hypothesis.\n"
        "  - 1.00: Complete drift. The dream has no semantic, structural, or "
        "symbolic relationship to the hypothesis.\n\n"
        "Reason about semantic imagery and morphology, NOT literal anchor "
        "matching. The anchors below are a context hint about the target — "
        "you should also recognize equivalent imagery ('soaring over a valley' "
        "is the same beat as 'floating in open space') and morphological "
        "variants ('forgotten' is the same beat as 'forgetting'). The dream's "
        "tone and affect matter: a flat affectless off-target report has "
        "high drift; a vivid on-target dream with rich imagery has low drift.\n\n"
        "Respond ONLY with a raw JSON object matching this schema: "
        '{"drift": <float 0.0..1.0>}.'
    )

    def __init__(
        self,
        base_url: str = DEFAULT_LLM_URL,
        model: str = DEFAULT_LLM_MODEL,
        timeout_s: float = DEFAULT_LLM_TIMEOUT_S,
        max_retries: int = 2,
    ):
        self.base_url = base_url.rstrip("/")
        self.url = f"{self.base_url}/chat/completions"
        self.model = model
        self.timeout_s = timeout_s
        self.max_retries = max_retries

    def preflight(self) -> bool:
        """Check the local server is reachable and lists our model."""
        try:
            req = urllib.request.Request(f"{self.base_url}/models", method="GET")
            with urllib.request.urlopen(req, timeout=2.0) as response:
                if response.status != 200:
                    return False
                body = response.read().decode("utf-8")
                # Some servers return a non-JSON 200; accept any 200.
                # Strict check: see if our model id appears in the body.
                if self.model and self.model not in body:
                    # Not strictly required (some servers lazy-load on first call),
                    # but a useful diagnostic. Don't fail; just note.
                    log.info("Preflight: model %s not listed in /v1/models; will rely on lazy-load.", self.model)
                return True
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
            log.warning("Preflight failed: %s", e)
            return False

    def _post_chat(self, payload: dict[str, Any]) -> dict[str, Any]:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=self.timeout_s) as response:
            return json.loads(response.read().decode("utf-8"))

    def score(self, symbols: frozenset[str], hypothesis: HypothesisContext) -> float:
        # The symbol set isn't sent to the LLM — the LLM gets the original
        # report text via the orchestrator (DreamExtractionPipeline) so it
        # sees morphology and context, not a tokenized loss. This method
        # takes symbols only to match the protocol; the original text is
        # passed through a sidecar `HypothesisContext.extra` field if needed.
        #
        # For the S-2 milestone 3 smoke test, the LLM is called with the
        # full report text via the orchestrator; this method is a thin
        # proxy that just re-derives the symbols. The actual full-text
        # prompt is built in `evaluate_with_text` (below).
        if not hypothesis.primary_anchors:
            return 1.0
        anchors_lower = tuple(a.lower() for a in hypothesis.primary_anchors)
        matched = sum(1 for a in anchors_lower if a in symbols)
        return max(0.0, min(1.0, 1.0 - (matched / len(anchors_lower))))

    def evaluate_with_text(
        self,
        report_text: str,
        hypothesis: HypothesisContext,
    ) -> float:
        """Score using the full report text via the local LLM.

        This is the S-2 milestone 3 path. The orchestrator (run_evaluation)
        routes full-text scoring here when the LLM backend is selected.
        The token-based `score()` method above is the protocol-conformance
        fallback used by the importable API.
        """
        user_content = (
            f"Target Hypothesis: {hypothesis.hypothesis_id}\n"
            f"Description: {hypothesis.target_concept}\n"
            f"Context Anchors (use as hint, not as matching vocabulary): "
            f"{json.dumps(list(hypothesis.primary_anchors))}\n\n"
            f"Dream Report Text:\n\"\"\"\n{report_text}\n\"\"\"\n\n"
            f"Calculate the drift score as a float between 0.00 and 1.00."
        )
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": self.SYSTEM_PROMPT},
                {"role": "user",   "content": user_content},
            ],
            "temperature": 0.3,
            "response_format": {"type": "json_object"},
        }

        last_err: Optional[Exception] = None
        for attempt in range(self.max_retries + 1):
            try:
                response = self._post_chat(payload)
                content_str = response["choices"][0]["message"]["content"].strip()
                parsed = json.loads(content_str)
                if "drift" not in parsed:
                    raise ValueError(f"LLM response missing 'drift' key: {content_str!r}")
                drift = float(parsed["drift"])
                return max(0.0, min(1.0, drift))
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError, ValueError, KeyError) as e:
                last_err = e
                if attempt < self.max_retries:
                    log.warning("LLM call failed (attempt %d/%d): %s; retrying", attempt + 1, self.max_retries + 1, e)
                    continue
                log.error("LLM call failed after %d attempts: %s", self.max_retries + 1, e)
        # Loop exited without returning or raising — should be unreachable
        # because the last iteration's except branch always re-raises via
        # the `continue` + final `raise` above, but Pyright wants a
        # terminal path that's explicit. `last_err` is guaranteed non-None
        # at this point because the for-loop body always assigns it.
        assert last_err is not None  # noqa: S101 — defensive for the type checker
        raise RuntimeError(f"LLM call failed: {last_err}") from last_err


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

class DreamExtractionPipeline:
    """Three-pass dream-report extraction and drift scoring pipeline.

    Backend-agnostic: takes a `DriftScoring` implementation (either
    the offline `SymbolMatchScorer` proxy or the `LLMDriftScorer`).
    The protocol's `score(symbols, hypothesis)` method is called for
    each report. LLM backends that need the full report text use
    `evaluate_with_text` directly (see `run_evaluation` below).
    """

    def __init__(
        self,
        registry_path: Path | str = DEFAULT_REGISTRY,
        scorer: Optional[DriftScoring] = None,
    ):
        self.registry_path = Path(registry_path)
        if not self.registry_path.exists():
            raise FileNotFoundError(
                f"Dream-mode hypothesis registry not found at {self.registry_path}. "
                "This pipeline requires the on-disk registry as the single source of truth; "
                "no hardcoded fallback is provided."
            )
        self.scorer: DriftScoring = scorer or SymbolMatchScorer()
        self.hypotheses: dict[str, HypothesisContext] = self._load_hypotheses()

    def _load_hypotheses(self) -> dict[str, HypothesisContext]:
        with self.registry_path.open("r", encoding="utf-8") as f:
            registry = json.load(f)
        examples = registry.get("example_hypotheses_for_schema_validation")
        if not examples or "hypotheses" not in examples:
            raise ValueError(
                f"Registry at {self.registry_path} is missing the "
                "'example_hypotheses_for_schema_validation::hypotheses' block."
            )
        out: dict[str, HypothesisContext] = {}
        for hyp_id, hyp in examples["hypotheses"].items():
            routing = hyp.get("routing", {})
            out[hyp_id] = HypothesisContext(
                hypothesis_id=hyp_id,
                target_concept=routing.get("target_concept", ""),
                primary_anchors=tuple(routing.get("primary_anchors", [])),
                drift_tolerance=routing.get("drift_tolerance"),
            )
        return out

    def list_hypotheses(self) -> list[str]:
        return list(self.hypotheses.keys())

    def get_context(self, hypothesis_id: str) -> HypothesisContext:
        if hypothesis_id not in self.hypotheses:
            raise KeyError(
                f"Hypothesis '{hypothesis_id}' not found in registry. "
                f"Available: {self.list_hypotheses()}"
            )
        return self.hypotheses[hypothesis_id]

    # -- Pass 1: denoise --
    def denoise(self, text: str) -> str:
        cleaned = re.sub(r"\[.*?\]", " ", text)
        cleaned = re.sub(r"\(.*?\)", " ", cleaned)
        cleaned = re.sub(r"\s+", " ", cleaned)
        return cleaned.strip().lower()

    # -- Pass 2: identify symbols --
    def identify_symbols(self, text: str) -> frozenset[str]:
        return frozenset(re.findall(r"\b\w+\b", text))

    # -- Pass 3: calculate drift (delegated to scorer) --
    def calculate_drift(self, symbols: frozenset[str], hypothesis_id: str) -> dict:
        ctx = self.get_context(hypothesis_id)
        anchors_lower = tuple(a.lower() for a in ctx.primary_anchors)
        matched = [a for a in anchors_lower if a in symbols]
        drift = self.scorer.score(symbols, ctx)
        return {
            "matched_anchors": matched,
            "match_count": len(matched),
            "total_anchors": len(anchors_lower),
            "drift_score": round(drift, 4),
            "drift_tolerance": ctx.drift_tolerance,
            "drift_exceeds_tolerance": (ctx.drift_tolerance is not None and drift > ctx.drift_tolerance),
        }

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
    *,
    full_text_scorer: Optional[Any] = None,
) -> dict:
    """Run the pipeline against a dataset and compute Spearman rho vs ground truth.

    If `full_text_scorer` is provided (e.g. an LLMDriftScorer with
    `evaluate_with_text`), it is called per report with the full
    raw text. Otherwise the pipeline's token-based `scorer.score()`
    is used. This is the S-2 milestone 3 path.
    """
    predicted: list[float] = []
    actual: list[float] = []
    per_report: list[dict] = []

    for item in dataset:
        target_id = item["target_hypothesis"]
        gt = float(item["ground_truth_drift"])

        if full_text_scorer is not None and hasattr(full_text_scorer, "evaluate_with_text"):
            ctx = pipeline.get_context(target_id)
            pred = full_text_scorer.evaluate_with_text(item["text"], ctx)
        else:
            result = pipeline.process_report(item["text"], target_id)
            pred = result["drift_score"]

        predicted.append(pred)
        actual.append(gt)
        # Recompute matched anchors for the per-report breakdown regardless
        # of which scorer was used (purely diagnostic).
        symbols = pipeline.identify_symbols(pipeline.denoise(item["text"]))
        ctx = pipeline.get_context(target_id)
        anchors_lower = tuple(a.lower() for a in ctx.primary_anchors)
        matched = [a for a in anchors_lower if a in symbols]
        per_report.append({
            "report_id":           item["report_id"],
            "target_hypothesis":   target_id,
            "predicted_drift":     pred,
            "ground_truth_drift":  gt,
            "abs_error":           abs(pred - gt),
            "matched_anchors":     matched,
            "match_count":         len(matched),
            "total_anchors":       len(anchors_lower),
        })

    if len(predicted) < 3:
        rho, p_val = None, None
    else:
        rho, p_val = spearmanr(predicted, actual)

    return {
        "n_reports":            len(dataset),
        "scorer":               pipeline.scorer.name,
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
    log.info("S-2 EVALUATION RESULTS  (scorer=%s, n=%d)", report["scorer"], report["n_reports"])
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


def _make_scorer(args: argparse.Namespace) -> DriftScoring:
    if args.backend == "proxy":
        return SymbolMatchScorer()
    if args.backend == "llm":
        scorer = LLMDriftScorer(
            base_url=args.llm_url,
            model=args.llm_model,
            timeout_s=args.llm_timeout,
        )
        log.info("Running LLM preflight against %s (model=%s)", args.llm_url, args.llm_model)
        if not scorer.preflight():
            log.error("LLM preflight failed. Is your local server running?")
            log.error("  Default URL: %s (override with --llm-url)", DEFAULT_LLM_URL)
            log.error("  Try:        ollama serve   # in another terminal")
            log.error("  Then:       ollama pull %s", args.llm_model)
            log.error("Falling back to the offline proxy path is NOT automatic — re-run with --backend proxy.")
            sys.exit(2)
        return scorer
    raise ValueError(f"Unknown backend: {args.backend}")


def _main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="S-2: three-pass dream extraction + drift scoring, with Spearman validation."
    )
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY,
                        help="dream-mode hypothesis registry (default: %(default)s)")
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET,
                        help="dream-report dataset (default: %(default)s)")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT,
                        help="output JSON report path (default: %(default)s)")
    parser.add_argument("--backend", choices=["proxy", "llm"], default="proxy",
                        help="drift-scoring backend (default: proxy)")
    parser.add_argument("--llm-url", default=DEFAULT_LLM_URL,
                        help=f"OpenAI-compatible base URL (default: {DEFAULT_LLM_URL})")
    parser.add_argument("--llm-model", default=DEFAULT_LLM_MODEL,
                        help=f"model id (default: {DEFAULT_LLM_MODEL})")
    parser.add_argument("--llm-timeout", type=float, default=DEFAULT_LLM_TIMEOUT_S,
                        help="per-call timeout in seconds (default: %(default)s)")
    parser.add_argument("--quiet", action="store_true", help="log only warnings")
    args = parser.parse_args(argv)

    if args.quiet:
        logging.getLogger().setLevel(logging.WARNING)

    t0 = time.time()
    scorer = _make_scorer(args)
    pipeline = DreamExtractionPipeline(registry_path=args.registry, scorer=scorer)
    log.info("Loaded registry: %s", args.registry)
    log.info("Backend: %s", scorer.name)
    log.info("Available hypotheses: %s", pipeline.list_hypotheses())
    for h in pipeline.list_hypotheses():
        ctx = pipeline.get_context(h)
        log.info("  %-26s anchors=%-40s tolerance=%s",
                 h, list(ctx.primary_anchors), ctx.drift_tolerance)

    if not args.dataset.exists():
        log.error("Dataset not found at %s", args.dataset)
        return 1
    with args.dataset.open("r", encoding="utf-8") as f:
        dataset = json.load(f)
    log.info("Loaded dataset: %s (%d reports)", args.dataset, len(dataset))

    full_text = scorer if isinstance(scorer, LLMDriftScorer) else None
    report = run_evaluation(pipeline, dataset, full_text_scorer=full_text)
    report["registry"] = str(args.registry)
    report["dataset"] = str(args.dataset)
    report["backend"] = args.backend
    report["llm_url"] = args.llm_url
    report["llm_model"] = args.llm_model
    report["elapsed_sec"] = time.time() - t0
    report["spec_version"] = SPEC_VERSION

    _print_evaluation_report(report)

    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, default=str)
    log.info("Wrote %s (%d bytes)", args.report, args.report.stat().st_size)

    target = 0.60
    rho = report["spearman_rho"]
    if rho is not None and rho >= target:
        log.info("✅ Spearman rho %.4f >= target %.2f (S-2 success criterion met on %s)", rho, target, args.dataset.name)
    elif rho is not None:
        log.warning("⚠️  Spearman rho %.4f < target %.2f (S-2 success criterion NOT met on %s; investigate)", rho, target, args.dataset.name)
    log.info("[Pending: human-rated multi-rater consensus is a follow-on calibration cycle; LLM-driven results vs the dream-mode candidate (qwen2.5-0.5b) is the next move once a local server is up.]")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
