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
      run_evaluation, run_robust_evaluation, SPEC_VERSION,
  )

Multi-seed evaluation (the methodological fix for high-variance LLM scoring):
  ./Scripts/dream_extraction.py --backend llm --llm-model qwen2.5:0.5b --runs 3
  ./Scripts/dream_extraction.py --backend llm --llm-model deepseek-v4-flash:cloud --runs 5
  ./Scripts/dream_extraction.py --backend llm --llm-model qwen2.5:0.5b --prompt-version v2 --runs 3
"""

from __future__ import annotations

import argparse
import json
import logging
import math
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

    # Two prompt versions, empirically tested 2026-07-19 across the
    # qwen2.5 ladder (0.5B / 1.5B / 3B) and the deepseek sanity check.
    # The original (v1) named the scale endpoints (0.00: perfect match,
    # 1.00: complete drift), which gave the smaller models a useful
    # direction to reason from at the cost of a high-drift bias on the
    # larger models. v2 dropped the named endpoints in favor of three
    # intermediate anchors and asked the model to "use the full range";
    # v2 was a NET REGRESSION across all four configurations (deepseek
    # 0.8857 -> 0.6172, qwen2.5:0.5b 0.8827 -> 0.1471, qwen2.5:1.5b
    # 0.0 -> -0.7171, qwen2.5:3b -0.3928 -> 0.0976). The named
    # endpoints were giving the smaller models a *direction*, not
    # anchoring them on a bad value; removing the direction without
    # providing a replacement left them with no useful signal. v1
    # remains the default. Use --prompt-version v2 to reproduce the
    # falsification.
    SYSTEM_PROMPT_V1 = (
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

    # v2: drop the named endpoints; use three intermediate calibration
    # anchors and ask the model to "use the full range". Empirically a
    # regression on every configuration tested; kept on disk for the
    # falsification record and for future A/B testing if the prompt-
    # modification hypothesis is reopened.
    SYSTEM_PROMPT_V2 = (
        "You are a precise sleep-laboratory scoring engine. Your job is to "
        "analyze a dream report and calculate its semantic drift relative to "
        "a target dream-induction hypothesis.\n\n"
        "Output a single float reflecting how strongly the dream's thematic "
        "imagery matches the target hypothesis. Use the full range of the "
        "float — values near the low end indicate vivid on-target imagery, "
        "values near the high end indicate clear mismatch, values in the "
        "middle indicate moderate resonance.\n\n"
        "Reason about semantic imagery and morphology, NOT literal anchor "
        "matching. The anchors below are a context hint about the target — "
        "you should also recognize equivalent imagery ('soaring over a "
        "valley' is the same beat as 'floating in open space') and "
        "morphological variants ('forgotten' is the same beat as 'forgetting'). "
        "The dream's tone and affect matter: a vivid on-target dream with "
        "rich imagery has low drift; a flat affectless off-target report "
        "has high drift.\n\n"
        "Respond ONLY with a raw JSON object matching this schema: "
        '{"drift": <float>}.'
    )

    # r1: prompt for DeepSeek-R1 reasoning-distilled models. These models
    # derive accuracy from generating an internal chain-of-thought inside
    # <think>...</think> tags BEFORE emitting the final answer. With
    # response_format=json_object the JSON grammar wrapper leaves no room to
    # reason first, which can make a 1.5B distilled model worse than the
    # base. So the r1 path: (a) drops response_format=json_object, (b) asks
    # the model to reason inside <think> tags, (c) tells it to emit a single
    # JSON object at the tail, (d) parses that tail. A prompt-topology
    # change, not a v1/v2 wording variation.
    #
    # EMPIRICALLY VERIFIED (2026-07-19, Ollama llama-server): the server
    # parses the <think>...</think> block itself and returns the reasoning in
    # a separate message field, so message.content already arrives as clean
    # tail JSON (probe: 764 completion tokens but 17 content chars =
    # '{"drift": 0.75}', finish_reason=stop). The <think>-strip in
    # _parse_r1_response is therefore defence-in-depth against OTHER servers,
    # not something this one exercises. And the verdict was negative anyway:
    # deepseek-r1:1.5b still scored in the noise (single-seed rho 0.21,
    # unstable) — the reasoning topology did not rescue a 1.5B model on the
    # n=6 fixture. Kept for the falsification record / larger reasoning models.
    SYSTEM_PROMPT_R1 = (
        "You are a precise sleep-laboratory scoring engine. Your job is to "
        "analyze a dream report and calculate its semantic drift relative to "
        "a target dream-induction hypothesis.\n\n"
        "Drift scale:\n"
        "  - 0.00: Perfect match. The dream captures the core thematic imagery "
        "and meaning of the hypothesis.\n"
        "  - 1.00: Complete drift. The dream has no semantic, structural, or "
        "symbolic relationship to the hypothesis.\n\n"
        "Reason about semantic imagery and morphology, NOT literal anchor "
        "matching. The anchors below are a context hint about the target — "
        "you should also recognize equivalent imagery ('soaring over a "
        "valley' is the same beat as 'floating in open space') and "
        "morphological variants ('forgotten' is the same beat as 'forgetting'). "
        "The dream's tone and affect matter: a flat affectless off-target "
        "report has high drift; a vivid on-target dream with rich imagery "
        "has low drift.\n\n"
        "IMPORTANT: structure your response in two parts.\n"
        "1. First, write your analytical reasoning step-by-step inside "
        "<think>...</think> tags. Use the think block to weigh the dream's "
        "imagery against the hypothesis, recognize morphology and semantic "
        "equivalents, and arrive at a drift value.\n"
        "2. Then, at the very end of your response, output a single valid "
        "JSON object (no other text after it) matching this exact schema:\n"
        '{"drift": <float between 0.00 and 1.00>}\n\n'
        "The JSON object is the only thing the downstream parser reads. "
        "Anything before the JSON is the think block + reasoning. Anything "
        "after the JSON is ignored."
    )

    # Default to v1 (the empirically better prompt across all tested
    # configurations for non-reasoning models). Pass `prompt_version="r1"`
    # for DeepSeek-R1 reasoning-distilled models; pass `prompt_version="v2"`
    # to use the falsified variant.
    SYSTEM_PROMPT = SYSTEM_PROMPT_V1

    def __init__(
        self,
        base_url: str = DEFAULT_LLM_URL,
        model: str = DEFAULT_LLM_MODEL,
        timeout_s: float = DEFAULT_LLM_TIMEOUT_S,
        max_retries: int = 2,
        prompt_version: str = "v1",
    ):
        self.base_url = base_url.rstrip("/")
        self.url = f"{self.base_url}/chat/completions"
        self.model = model
        self.timeout_s = timeout_s
        self.max_retries = max_retries
        if prompt_version == "v1":
            self.system_prompt = self.SYSTEM_PROMPT_V1
        elif prompt_version == "v2":
            self.system_prompt = self.SYSTEM_PROMPT_V2
        elif prompt_version == "r1":
            self.system_prompt = self.SYSTEM_PROMPT_R1
        else:
            raise ValueError(f"Unknown prompt_version: {prompt_version!r}; expected 'v1', 'v2', or 'r1'")
        self.prompt_version = prompt_version
        # Boundary guard (decision_registry.md entry 7): a ':cloud' model is a
        # NETWORK model — Ollama proxies it off-device even though base_url is
        # localhost. Permitted in THIS offline research/eval tool only; it must
        # NEVER be wired into the on-device Swift runtime (Sources/BCILLM/),
        # the project's fully-on-device, no-cloud, no-telemetry invariant. The
        # empirically-strong drift scorer (deepseek-v4-flash:cloud, 3-run rho
        # ~0.84) is exactly such a model, so warn loudly at the point of use.
        if ":cloud" in self.model:
            log.warning(
                "MODEL %r is a NETWORK/CLOUD scorer: OFFLINE EVAL ONLY. Do NOT "
                "ship it into the on-device runtime (Sources/BCILLM/). See "
                "decision_registry.md entry 7.", self.model,
            )

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

        Two prompt topologies are supported:
          - v1 / v2: strict JSON mode (`response_format=json_object`); the
            response is a single JSON object parsed directly.
          - r1: chain-of-thought mode for DeepSeek-R1 reasoning models.
            Drops strict JSON mode, asks the model to reason inside
            <think>...</think> tags, and emit a JSON object at the tail.
            The response is parsed with `_parse_r1_response` which strips
            the think block and finds the last `{}` block.
        """
        user_content = (
            f"Target Hypothesis: {hypothesis.hypothesis_id}\n"
            f"Description: {hypothesis.target_concept}\n"
            f"Context Anchors (use as hint, not as matching vocabulary): "
            f"{json.dumps(list(hypothesis.primary_anchors))}\n\n"
            f"Dream Report Text:\n\"\"\"\n{report_text}\n\"\"\"\n\n"
            f"Calculate the drift score as a float between 0.00 and 1.00."
        )
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": self.system_prompt},
                {"role": "user",   "content": user_content},
            ],
            "temperature": 0.3,
        }
        # R1 reasoning models need strict JSON mode OFF so the local
        # inference engine doesn't suppress the <think> chain-of-thought
        # tokens. v1/v2 use strict JSON mode for parseable single-object
        # output.
        if self.prompt_version != "r1":
            payload["response_format"] = {"type": "json_object"}

        last_err: Optional[Exception] = None
        for attempt in range(self.max_retries + 1):
            try:
                response = self._post_chat(payload)
                content_str = response["choices"][0]["message"]["content"]
                if self.prompt_version == "r1":
                    drift = self._parse_r1_response(content_str)
                else:
                    drift = self._parse_v1v2_response(content_str)
                return drift
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

    @staticmethod
    def _parse_v1v2_response(content_str: str) -> float:
        """Parse a strict-JSON-mode response (v1/v2 prompt)."""
        content_str = content_str.strip()
        parsed = json.loads(content_str)
        if "drift" not in parsed:
            raise ValueError(f"LLM response missing 'drift' key: {content_str!r}")
        drift = float(parsed["drift"])
        return max(0.0, min(1.0, drift))

    @staticmethod
    def _parse_r1_response(content_str: str) -> float:
        """Parse an R1 reasoning-model response.

        Empirically (Ollama llama-server, 2026-07-19) `content_str` already
        arrives as clean tail JSON because the server parses the
        <think>...</think> block into a separate message field. But OTHER
        OpenAI-compatible servers may inline it in `content`:
           <think>...analytical reasoning...</think>
            ...free text...
            {"drift": <float>}
        so we still strip any <think>...</think> defensively, then look for
        the LAST balanced {} block (json.loads on progressively shorter
        suffixes handles nested braces). `drift` is clamped to [0, 1]. On any
        failure (no JSON, malformed, missing field) we return 0.5 as a
        neutral fallback.

        Tail-aware extraction (parse from the end) is more robust than a
        naive `r"{[^}]*}"`, which matches the FIRST braces and could match
        inside the think block.
        """
        text = content_str
        # Step 1: strip the <think>...</think> block. Use a non-greedy
        # match so multiple think blocks (rare, but possible) all get
        # stripped.
        text_no_think = re.sub(r"<think>.*?</think>", " ", text, flags=re.DOTALL)
        # Step 2: find the LAST balanced {} block by scanning from the
        # end. A simpler approach: try json.loads on progressively shorter
        # suffixes of the response, from the full text back to the last
        # `{` character. This handles nested braces correctly because
        # json.loads is a real parser.
        last_open = text_no_think.rfind("{")
        if last_open < 0:
            log.warning("R1 parse: no '{' found in response: %r", text[:200])
            return 0.5
        # Try parsing from `last_open` to the end, then progressively
        # earlier (in case the trailing `}` is missing for some reason).
        for start in range(last_open, max(last_open - 200, -1), -1):
            candidate = text_no_think[start:]
            # Trim to the last `}` (if any) so we have a balanced prefix.
            last_close = candidate.rfind("}")
            if last_close < 0:
                continue
            candidate = candidate[: last_close + 1]
            try:
                parsed = json.loads(candidate)
                if "drift" in parsed:
                    return max(0.0, min(1.0, float(parsed["drift"])))
            except (json.JSONDecodeError, ValueError, TypeError):
                continue
        log.warning("R1 parse: no valid JSON object with 'drift' key found in: %r", text[:200])
        return 0.5


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
# Robust (multi-seed) evaluation
# ---------------------------------------------------------------------------

def run_robust_evaluation(
    pipeline: DreamExtractionPipeline,
    dataset: list[dict],
    *,
    full_text_scorer: Optional[Any] = None,
    runs: int = 3,
) -> dict:
    """Multi-seed wrapper around run_evaluation. Reports mean +- std of Spearman rho.

    The motivation: single-run measurement of an LLM-scored pipeline has
    high sample-to-sample variance at the small (n<10) dataset sizes we
    have. The earlier "qwen2.5:0.5b + v1 + temp=0.3 reaches rho 0.8827"
    claim was a 2.5-sigma outlier from a distribution with mean +0.04
    +- 0.28; "deepseek + v1 + temp=0.3 reaches rho 0.8857" was a
    2.7-sigma outlier from a distribution with mean +0.56 +- 0.12. Multi-
    seed evaluation is the methodological fix: run the dataset through the
    pipeline `runs` times, report mean +- std of Spearman rho. NaN (model
    deadlock) is treated as 0.0 for the rho calculation.

    The first run's report is preserved in full under `first_run_report`
    for the per-report diagnostic breakdown.
    """
    if runs < 1:
        raise ValueError(f"runs must be >= 1; got {runs}")

    per_run_rhos: list[float] = []
    per_run_maes: list[float] = []
    first_report: Optional[dict] = None

    for run_idx in range(runs):
        report = run_evaluation(pipeline, dataset, full_text_scorer=full_text_scorer)
        rho = report["spearman_rho"]
        if rho is None or (isinstance(rho, float) and math.isnan(rho)):
            # Model deadlock (constant predictions) or n<3 -> treat as 0.0
            # for the rho calculation. The deadlocked case is a real signal
            # of model failure; documenting it as 0.0 makes the mean honest.
            rho = 0.0
        per_run_rhos.append(float(rho))
        per_run_maes.append(float(report["mean_abs_error"]))
        if first_report is None:
            first_report = report

    # Use sample standard deviation (ddof=1) when we have >= 2 runs.
    if runs >= 2:
        std_rho = float(np.std(per_run_rhos, ddof=1))
        sem_rho = float(np.std(per_run_rhos, ddof=1) / np.sqrt(runs))
    else:
        std_rho = 0.0
        sem_rho = 0.0

    return {
        "n_runs":               runs,
        "scorer":               pipeline.scorer.name,
        "n_reports":            len(dataset),
        "per_run_rho":          per_run_rhos,
        "per_run_mean_abs_error": per_run_maes,
        "mean_rho":             float(np.mean(per_run_rhos)),
        "std_rho":              std_rho,
        "sem_rho":              sem_rho,
        "ci95_rho":             [float(np.mean(per_run_rhos) - 1.96 * sem_rho),
                                 float(np.mean(per_run_rhos) + 1.96 * sem_rho)],
        "mean_mean_abs_error":  float(np.mean(per_run_maes)),
        "first_run_report":     first_report,
    }


def _print_robust_evaluation_report(report: dict) -> None:
    log.info("=" * 64)
    log.info("S-2 ROBUST MULTI-SEED EVALUATION  (scorer=%s, n_reports=%d, n_runs=%d)",
             report["scorer"], report["n_reports"], report["n_runs"])
    log.info("=" * 64)
    log.info("Per-run Spearman rho : %s", [f"{r:+.4f}" for r in report["per_run_rho"]])
    log.info("Per-run mean |err|  : %s", [f"{e:.4f}" for e in report["per_run_mean_abs_error"]])
    log.info("Mean rho            : %+.4f", report["mean_rho"])
    log.info("Std  rho (ddof=1)   : %.4f", report["std_rho"])
    log.info("SEM  rho            : %.4f", report["sem_rho"])
    log.info("95%% CI on rho      : [%+.4f, %+.4f]", report["ci95_rho"][0], report["ci95_rho"][1])
    log.info("Mean |err|          : %.4f", report["mean_mean_abs_error"])
    clears_robustly = report["ci95_rho"][0] >= 0.6
    log.info("Clears 0.6 robustly (CI lower bound >= 0.6)? %s",
             "YES" if clears_robustly else "no")
    log.info("=" * 64)
    # Per-report diagnostic breakdown from the first run.
    if report.get("first_run_report") is not None:
        first = report["first_run_report"]
        log.info("Per-report breakdown (first run only — single-sample estimate):")
        log.info("  %-10s  %-26s  %6s  %6s  %6s", "report", "hypothesis", "pred", "truth", "|err|")
        for r in first["per_report"]:
            log.info(
                "  %-10s  %-26s  %6.3f  %6.3f  %6.3f   matched=%d/%d %s",
                r["report_id"], r["target_hypothesis"],
                r["predicted_drift"], r["ground_truth_drift"], r["abs_error"],
                r["match_count"], r["total_anchors"],
                r["matched_anchors"],
            )


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
            prompt_version=args.prompt_version,
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
    parser.add_argument("--prompt-version", choices=["v1", "v2", "r1"], default="v1",
                        help="system prompt version (default: v1; v2 was empirically a regression, kept for the falsification record; r1 is for DeepSeek-R1 reasoning-distilled models)")
    parser.add_argument("--runs", type=int, default=1,
                        help="number of evaluation runs for multi-seed evaluation; report mean +- std of Spearman rho (default: 1, single-run mode)")
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
    if args.runs > 1:
        report = run_robust_evaluation(
            pipeline, dataset, full_text_scorer=full_text, runs=args.runs,
        )
    else:
        report = run_evaluation(pipeline, dataset, full_text_scorer=full_text)
    report["registry"] = str(args.registry)
    report["dataset"] = str(args.dataset)
    report["backend"] = args.backend
    report["llm_url"] = args.llm_url
    report["llm_model"] = args.llm_model
    report["prompt_version"] = getattr(scorer, "prompt_version", None) if isinstance(scorer, LLMDriftScorer) else None
    report["elapsed_sec"] = time.time() - t0
    report["spec_version"] = SPEC_VERSION

    if args.runs > 1:
        _print_robust_evaluation_report(report)
    else:
        _print_evaluation_report(report)

    args.report.parent.mkdir(parents=True, exist_ok=True)
    with args.report.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, default=str)
    log.info("Wrote %s (%d bytes)", args.report, args.report.stat().st_size)

    target = 0.60
    if args.runs > 1:
        mean_rho = report["mean_rho"]
        ci_lo = report["ci95_rho"][0]
        if ci_lo >= target:
            log.info("✅ 95%% CI on mean rho [%+.4f, %+.4f] has lower bound >= %.2f (S-2 success criterion met robustly on %s)",
                     ci_lo, report["ci95_rho"][1], target, args.dataset.name)
        else:
            log.warning("⚠️ 95%% CI on mean rho [%+.4f, %+.4f] has lower bound < %.2f (S-2 success criterion NOT met robustly on %s)",
                        ci_lo, report["ci95_rho"][1], target, args.dataset.name)
    else:
        rho = report["spearman_rho"]
        if rho is not None and rho >= target:
            log.info("✅ Spearman rho %.4f >= target %.2f (S-2 success criterion met on %s, single-run; re-run with --runs 3 for robust evaluation)", rho, target, args.dataset.name)
        elif rho is not None:
            log.warning("⚠️  Spearman rho %.4f < target %.2f (S-2 success criterion NOT met on %s, single-run; re-run with --runs 3 for robust evaluation)", rho, target, args.dataset.name)
    log.info("[Pending: human-rated multi-rater consensus is a follow-on calibration cycle; the current harness reports mean +- std on 3+ runs.]")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
