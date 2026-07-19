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
import shutil
import subprocess
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

# bge-small-en-v1.5 sentence-transformers snapshot (the ANE embedder's weights),
# loaded offline for the `bge` and `hybrid` drift-scoring backends. Needs the ML
# venv (torch/sentence-transformers) — the proxy/llm backends stay zero-dep.
DEFAULT_BGE_MODEL = str(REPO_ROOT / "Models" / "bge-small-en-v1.5-hf")
# BAAI's recommended retrieval query instruction for bge-*-en-v1.5. Applied to
# the report (query) side only when --bge-query-prefix is passed; empty by default.
BGE_QUERY_PREFIX = "Represent this sentence for searching relevant passages: "


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


# ---------------------------------------------------------------------------
# bge-small embedding helpers (offline; used by the bge + hybrid backends)
# ---------------------------------------------------------------------------

_BGE_CACHE: dict[str, Any] = {}


def _load_bge(model_path: str) -> Any:
    """Lazy-load a sentence-transformers bge model (cached per path). Offline —
    the weights live on disk at Models/bge-small-en-v1.5-hf. Needs the ML venv
    (torch/sentence-transformers); the proxy/llm backends stay zero-dep, so the
    import is deferred to here and raises an actionable error if unavailable."""
    if model_path not in _BGE_CACHE:
        try:
            from sentence_transformers import SentenceTransformer
        except ImportError as e:
            raise RuntimeError(
                "The 'bge'/'hybrid' backends need sentence-transformers (torch). "
                "Install requirements-calibration.txt, or run this tool with the "
                f"project venv, e.g. `venv/bin/python {Path(sys.argv[0]).name} ...`. "
                f"(import error: {e})"
            ) from e
        _BGE_CACHE[model_path] = SentenceTransformer(model_path, device="cpu")
    return _BGE_CACHE[model_path]


def _concept_text(ctx: HypothesisContext) -> str:
    """Text used to embed a hypothesis. The example registry leaves
    target_concept empty, so the semantic content lives in the anchor words —
    fall back to (or combine with) them so bge embeds something meaningful
    rather than an empty string."""
    tc = (ctx.target_concept or "").strip()
    anchors = ", ".join(str(a) for a in ctx.primary_anchors)
    if tc and anchors:
        return f"{tc}. {anchors}"
    return tc or anchors


def _bge_signal(
    model: Any,
    report_text: str,
    hypothesis: HypothesisContext,
    contrast_contexts: Optional[list[HypothesisContext]] = None,
    query_prefix: str = "",
    tau: float = 0.1,
) -> dict[str, Any]:
    """bge semantic signal for one (report, hypothesis).

    Contrastive when `contrast_contexts` (all hypotheses) is given: the prior is
    driven by how much closer the report sits to its OWN target concept than to
    the nearest competing hypothesis — a RELATIVE margin. This fixes the
    absolute-cosine compression (all ~0.4) that made a single cos(report,target)
    rank the metaphorical cases backwards. Vectors are L2-normalized so dot ==
    cosine — the same geometry as the Swift runtime's Embedding.cosineSimilarity
    (Stage 3.4: cross-runtime cosine 1.000000). `query_prefix` optionally applies
    bge's retrieval query instruction to the report (query) side."""
    contexts = list(contrast_contexts) if contrast_contexts else [hypothesis]
    ids = [c.hypothesis_id for c in contexts]
    concepts = [_concept_text(c) for c in contexts]
    anchors = [str(a) for a in hypothesis.primary_anchors]
    texts = [query_prefix + report_text] + concepts + anchors
    embs = model.encode(texts, convert_to_numpy=True,
                        normalize_embeddings=True, show_progress_bar=False)
    rep = embs[0]
    n = len(concepts)
    cos_all = {ids[i]: float(np.dot(rep, embs[1 + i])) for i in range(n)}
    anchor_cos = [float(np.dot(rep, embs[1 + n + i])) for i in range(len(anchors))]
    cos_target = cos_all.get(hypothesis.hypothesis_id, float(np.dot(rep, embs[1])))
    others = [v for k, v in cos_all.items() if k != hypothesis.hypothesis_id]
    cos_other_max = max(others) if others else None
    margin = (cos_target - cos_other_max) if cos_other_max is not None else None
    if len(cos_all) >= 2:
        # softmax over hypotheses -> p(target); drift prior = 1 - p_target.
        # Monotonic in the margin, so tau doesn't change bge-alone's rank order;
        # it only shapes the absolute prior handed to the hybrid LLM.
        vals = np.array([cos_all[i] for i in ids]) / max(tau, 1e-6)
        vals = vals - vals.max()
        p = np.exp(vals)
        p = p / p.sum()
        p_target = float(p[ids.index(hypothesis.hypothesis_id)])
        drift_prior = 1.0 - p_target
    else:
        p_target = None
        drift_prior = 1.0 - cos_target
    return {
        "cos_target": cos_target,
        "cos_all": cos_all,
        "cos_other_max": cos_other_max,
        "margin": margin,
        "p_target": p_target,
        "anchor_cos_mean": float(np.mean(anchor_cos)) if anchor_cos else None,
        "anchor_cos_max": float(np.max(anchor_cos)) if anchor_cos else None,
        "drift_prior": max(0.0, min(1.0, drift_prior)),
    }


def _sig_key(report_text: str, hypothesis: HypothesisContext) -> str:
    """Stable-ish key for stashing a per-report signal in the audit trail
    (last write wins across multi-seed runs)."""
    return f"{hypothesis.hypothesis_id}::{report_text[:48]}"


class BgeCosineScorer:
    """Pure bge-cosine drift scorer — the on-device-capable control.

    drift = clamp(1 - cosine(report, target_concept)). No LLM, no network: it
    reuses the ANE embedder's own weights offline. Two jobs: (a) the on-device
    baseline (unlike the cloud LLMs, this one *could* run in the app), and (b)
    the control that reveals whether the hybrid LLM cross-examiner adds anything
    over raw cosine. Always dispatched via evaluate_with_text (it needs the full
    text, which the symbolic score() path discards)."""

    name: str = "bge"

    def __init__(self, bge_model: str = DEFAULT_BGE_MODEL, query_prefix: str = "", tau: float = 0.1):
        self.bge_model_path = bge_model
        self.query_prefix = query_prefix
        self.tau = tau
        self._model: Any = None
        self.contrast_contexts: list[HypothesisContext] = []
        self.signals: dict[str, Any] = {}

    def set_contrast_contexts(self, contexts: list[HypothesisContext]) -> None:
        """Inject all hypothesis contexts so drift is scored contrastively
        (report vs its own target vs the competing hypotheses)."""
        self.contrast_contexts = list(contexts)

    def _bge(self) -> Any:
        if self._model is None:
            self._model = _load_bge(self.bge_model_path)
        return self._model

    def score(self, symbols: frozenset[str], hypothesis: HypothesisContext) -> float:
        # Protocol conformance only. This backend is always dispatched through
        # evaluate_with_text (full text); the symbol-set path discards the very
        # morphology bge exists to capture, so it must not be the real path.
        return 0.5

    def evaluate_with_text(self, report_text: str, hypothesis: HypothesisContext) -> float:
        sig = _bge_signal(self._bge(), report_text, hypothesis,
                          self.contrast_contexts, self.query_prefix, self.tau)
        self.signals[_sig_key(report_text, hypothesis)] = sig
        return sig["drift_prior"]


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
        api_key: Optional[str] = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.url = f"{self.base_url}/chat/completions"
        self.model = model
        self.timeout_s = timeout_s
        self.max_retries = max_retries
        self.api_key = api_key
        if prompt_version == "v1":
            self.system_prompt = self.SYSTEM_PROMPT_V1
        elif prompt_version == "v2":
            self.system_prompt = self.SYSTEM_PROMPT_V2
        elif prompt_version == "r1":
            self.system_prompt = self.SYSTEM_PROMPT_R1
        else:
            raise ValueError(f"Unknown prompt_version: {prompt_version!r}; expected 'v1', 'v2', or 'r1'")
        self.prompt_version = prompt_version
        # Response-topology flags, decoupled from the prompt NAME so subclasses
        # (e.g. HybridDriftScorer) can pick their own. v1/v2 use strict JSON
        # mode; r1 (and hybrid) reason before answering, so JSON mode is OFF and
        # the tail {} block is parsed — this is also more portable across servers
        # that don't honor response_format (e.g. Anthropic's OpenAI-compat).
        self.use_json_mode = prompt_version in ("v1", "v2")
        self.tail_parse = prompt_version == "r1"
        # Boundary guard (decision_registry.md entry 7): a network/cloud scorer
        # is permitted in THIS offline research/eval tool ONLY; it must NEVER be
        # wired into the on-device Swift runtime (Sources/BCILLM/), the project's
        # fully-on-device, no-cloud, no-telemetry invariant. Fires for an Ollama
        # ':cloud' model, any authenticated endpoint (api_key set), or any
        # non-localhost base_url (e.g. api.anthropic.com).
        _local = ("localhost" in self.base_url) or ("127.0.0.1" in self.base_url)
        if (":cloud" in self.model) or (self.api_key is not None) or (not _local):
            log.warning(
                "SCORER %r via %s is a NETWORK/CLOUD scorer: OFFLINE EVAL ONLY. Do "
                "NOT ship it into the on-device runtime (Sources/BCILLM/). See "
                "decision_registry.md entry 7.", self.model, self.base_url,
            )

    def preflight(self) -> bool:
        """Check the local server is reachable and lists our model."""
        try:
            req = urllib.request.Request(f"{self.base_url}/models", method="GET", headers=self._auth_headers())
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

    def _auth_headers(self) -> dict[str, str]:
        """Headers for every request. Adds a Bearer token only when an api_key
        is set (Ollama needs none locally; an authenticated OpenAI-compat
        endpoint such as Anthropic's needs `Authorization: Bearer <key>`)."""
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _post_chat(self, payload: dict[str, Any]) -> dict[str, Any]:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.url,
            data=data,
            headers=self._auth_headers(),
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

    def _build_user_content(self, report_text: str, hypothesis: HypothesisContext) -> str:
        """Build the user message. Overridable seam: HybridDriftScorer injects a
        precomputed bge similarity signal here before the LLM reasons over it."""
        return (
            f"Target Hypothesis: {hypothesis.hypothesis_id}\n"
            f"Description: {hypothesis.target_concept}\n"
            f"Context Anchors (use as hint, not as matching vocabulary): "
            f"{json.dumps(list(hypothesis.primary_anchors))}\n\n"
            f"Dream Report Text:\n\"\"\"\n{report_text}\n\"\"\"\n\n"
            f"Calculate the drift score as a float between 0.00 and 1.00."
        )

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
        user_content = self._build_user_content(report_text, hypothesis)
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": self.system_prompt},
                {"role": "user",   "content": user_content},
            ],
            "temperature": 0.3,
        }
        # Strict JSON mode for v1/v2 only. It is OFF for reasoning topologies
        # (r1, hybrid) so the model can reason before answering, and so the call
        # is portable across servers that don't honor response_format (e.g.
        # Anthropic's OpenAI-compat endpoint); those responses are tail-parsed.
        if self.use_json_mode:
            payload["response_format"] = {"type": "json_object"}

        last_err: Optional[Exception] = None
        for attempt in range(self.max_retries + 1):
            try:
                response = self._post_chat(payload)
                content_str = response["choices"][0]["message"]["content"]
                if self.tail_parse:
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
        # Last-resort: regex for `"drift": <number>` recovers values from
        # slightly-malformed JSON (e.g. `{"drift": 0.75"}` with a stray quote)
        # that small/cloud models occasionally emit — better than a 0.5 fallback
        # that silently injects noise into the correlation.
        m = re.search(r'"?drift"?\s*:\s*([-+]?[0-9]*\.?[0-9]+)', text_no_think)
        if m:
            try:
                return max(0.0, min(1.0, float(m.group(1))))
            except ValueError:
                pass
        log.warning("R1 parse: no valid JSON object with 'drift' key found in: %r", text[:200])
        return 0.5


class HybridDriftScorer(LLMDriftScorer):
    """bge distance + cloud-LLM cross-examiner (the S-2 'joint-embedding + LLM'
    design). Computes a bge-small semantic-similarity signal between the dream
    and the target concept/anchors, injects it into the prompt as a PRIOR, and
    lets the LLM reason about whether that distance is skewed by negation,
    metaphor, or morphology before emitting {"drift": float}.

    OFFLINE-EVAL-ONLY (the cross-examiner is a cloud LLM). Needs the ML venv for
    bge. Uses JSON-mode-off + tail-parse so the same code path works across both
    deepseek-v4-flash:cloud and Anthropic's OpenAI-compat endpoint (Claude)."""

    name: str = "hybrid"

    SYSTEM_PROMPT_HYBRID = (
        "You are a precise sleep-laboratory scoring engine. You calculate the "
        "semantic drift of a dream report relative to a target dream-induction "
        "hypothesis.\n\n"
        "Drift scale:\n"
        "  - 0.00: perfect match — the dream captures the core imagery and "
        "meaning of the hypothesis.\n"
        "  - 1.00: complete drift — no semantic, structural, or symbolic "
        "relationship to the hypothesis.\n\n"
        "You are given a PRECOMPUTED bge-small embedding signal: how close the "
        "dream sits to THIS target concept versus the nearest COMPETING "
        "hypothesis (a relative margin), plus an embedding drift prior. Treat it "
        "as a PRIOR, not the answer: raw cosine is fooled by negation ('I did NOT "
        "fall' sits close to 'falling' in embedding space but is the opposite "
        "beat), by metaphor, and it under-weights morphological/synonym matches "
        "('forgot' vs 'forgetting', 'house' vs 'home'). A positive margin means "
        "the dream is embedding-closer to its own target than to the alternative. "
        "Reason explicitly about whether the margin over- or under-states the true "
        "drift for THIS dream, then decide.\n\n"
        "Think step by step, then at the very END output a single JSON object "
        "and nothing after it: {\"drift\": <float between 0.00 and 1.00>}. Only "
        "the final JSON object is read."
    )

    def __init__(self, *, bge_model: str = DEFAULT_BGE_MODEL,
                 query_prefix: str = "", tau: float = 0.1, **kwargs: Any):
        # Give the parent a valid prompt_version, then switch to the hybrid
        # prompt + reasoning topology (JSON mode off, tail parse).
        kwargs.setdefault("prompt_version", "v1")
        super().__init__(**kwargs)
        self.bge_model_path = bge_model
        self.query_prefix = query_prefix
        self.tau = tau
        self._bge_model: Any = None
        self.contrast_contexts: list[HypothesisContext] = []
        self.system_prompt = self.SYSTEM_PROMPT_HYBRID
        self.prompt_version = "hybrid"
        self.use_json_mode = False
        self.tail_parse = True
        self.signals: dict[str, Any] = {}

    def set_contrast_contexts(self, contexts: list[HypothesisContext]) -> None:
        """Inject all hypothesis contexts so the bge signal is contrastive
        (report vs its own target vs the competing hypotheses)."""
        self.contrast_contexts = list(contexts)

    def _bge(self) -> Any:
        if self._bge_model is None:
            self._bge_model = _load_bge(self.bge_model_path)
        return self._bge_model

    def _build_user_content(self, report_text: str, hypothesis: HypothesisContext) -> str:
        sig = _bge_signal(self._bge(), report_text, hypothesis,
                          self.contrast_contexts, self.query_prefix, self.tau)
        self.signals[_sig_key(report_text, hypothesis)] = sig
        other_s = "n/a" if sig["cos_other_max"] is None else f"{sig['cos_other_max']:.3f}"
        margin_s = "n/a" if sig["margin"] is None else f"{sig['margin']:+.3f}"
        return (
            f"Target Hypothesis: {hypothesis.hypothesis_id}\n"
            f"Description: {hypothesis.target_concept}\n"
            f"Context Anchors (hint, not matching vocabulary): "
            f"{json.dumps(list(hypothesis.primary_anchors))}\n\n"
            f"PRECOMPUTED bge-small SEMANTIC SIGNAL (a prior, not the answer):\n"
            f"  cosine(dream, THIS target)              = {sig['cos_target']:.3f}\n"
            f"  cosine(dream, nearest OTHER hypothesis) = {other_s}\n"
            f"  margin (this - other) = {margin_s}  (positive => closer to this target => lower drift)\n"
            f"  embedding drift prior = {sig['drift_prior']:.3f}\n\n"
            f"Dream Report Text:\n\"\"\"\n{report_text}\n\"\"\"\n\n"
            f"Weigh the margin as a prior, correct it where negation, metaphor, or "
            f"morphology skews raw similarity, then give the drift score in [0,1]."
        )


class ClaudeCLIDriftScorer(LLMDriftScorer):
    """Text-alone drift scorer that drives a Claude model through the local
    `claude` CLI in headless (`-p`) mode, authenticated by the user's Claude
    subscription (e.g. a Max plan) — NO API key, no per-call API billing.

    It reuses the parent's prompt-building and parsing; only the transport is
    swapped: `_post_chat` translates the OpenAI-style payload into a
    `claude -p --model <m> --system-prompt <sys> --output-format json <user>`
    subprocess call and maps the CLI's JSON result back into the OpenAI shape.
    `--system-prompt` fully replaces Claude Code's own agent prompt, so the
    score isn't contaminated by coding-assistant context. OFFLINE-EVAL-ONLY
    (network via the subscription); never wire into the on-device runtime."""

    name: str = "claude-cli"

    def __init__(self, *, model: str = "claude-sonnet-5", **kwargs: Any):
        kwargs.setdefault("prompt_version", "v1")
        kwargs["model"] = model
        super().__init__(**kwargs)
        # The CLI result can include prose around the JSON, and we can't force
        # response_format over the CLI, so parse the tail robustly.
        self.use_json_mode = False
        self.tail_parse = True
        # The parent's guard keys off :cloud / api_key / non-local base_url,
        # none of which apply to a CLI call — warn explicitly so the offline-only
        # boundary is loud for this network backend too.
        log.warning(
            "SCORER %r via the `claude` CLI (Claude subscription) is a NETWORK "
            "scorer: OFFLINE EVAL ONLY. Do NOT ship it into the on-device runtime "
            "(Sources/BCILLM/). See decision_registry.md entry 7.", self.model,
        )

    def preflight(self) -> bool:
        if shutil.which("claude") is None:
            log.error("`claude` CLI not found on PATH; the claude-cli backend needs it "
                      "(install Claude Code and sign in with your subscription).")
            return False
        return True

    def _post_chat(self, payload: dict[str, Any]) -> dict[str, Any]:
        roles = {m["role"]: m["content"] for m in payload["messages"]}
        cmd = [
            "claude", "-p",
            "--model", self.model,
            "--system-prompt", roles.get("system", ""),
            "--output-format", "json",
            roles.get("user", ""),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=self.timeout_s)
        if proc.returncode != 0:
            raise RuntimeError(f"claude CLI failed (rc={proc.returncode}): {proc.stderr[:200]}")
        result = json.loads(proc.stdout)
        if result.get("is_error"):
            raise RuntimeError(f"claude CLI returned an error: {str(result.get('result'))[:200]}")
        # Map the CLI's result text back into the OpenAI chat-completions shape
        # the parent's evaluate_with_text expects.
        return {"choices": [{"message": {"content": result.get("result", "")}}]}


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
    if args.backend == "claude-cli":
        model = args.llm_model if args.llm_model != DEFAULT_LLM_MODEL else "claude-sonnet-5"
        cli_scorer = ClaudeCLIDriftScorer(model=model, timeout_s=args.llm_timeout,
                                          prompt_version=args.prompt_version)
        log.info("Preflighting `claude` CLI (model=%s, subscription auth, no API key)", model)
        if not cli_scorer.preflight():
            sys.exit(2)
        return cli_scorer
    query_prefix = BGE_QUERY_PREFIX if getattr(args, "bge_instruct", False) else args.bge_query_prefix
    if args.backend == "bge":
        return BgeCosineScorer(bge_model=args.bge_model, query_prefix=query_prefix, tau=args.bge_tau)
    if args.backend in ("llm", "hybrid"):
        api_key: Optional[str] = None
        if args.llm_api_key_env:
            api_key = os.environ.get(args.llm_api_key_env)
            if not api_key:
                log.error("--llm-api-key-env %s is set but that environment variable is empty/unset.", args.llm_api_key_env)
                sys.exit(2)
        common: dict[str, Any] = dict(base_url=args.llm_url, model=args.llm_model,
                                      timeout_s=args.llm_timeout, api_key=api_key)
        scorer: LLMDriftScorer = (
            HybridDriftScorer(bge_model=args.bge_model, query_prefix=query_prefix, tau=args.bge_tau, **common)
            if args.backend == "hybrid"
            else LLMDriftScorer(prompt_version=args.prompt_version, **common)
        )
        log.info("Running LLM preflight against %s (model=%s, backend=%s)", args.llm_url, args.llm_model, args.backend)
        if not scorer.preflight():
            log.error("LLM preflight failed. Is your endpoint reachable / key valid?")
            log.error("  URL: %s (override with --llm-url)", args.llm_url)
            log.error("  Ollama:       ollama serve   (then: ollama pull %s)", args.llm_model)
            log.error("  Cloud/keyed:  check --llm-api-key-env and that the key is exported.")
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
    parser.add_argument("--backend", choices=["proxy", "llm", "bge", "hybrid", "claude-cli"], default="proxy",
                        help="drift-scoring backend: proxy (symbolic, on-device), bge (bge-cosine, "
                             "on-device-capable), llm (OpenAI-compat chat), hybrid (bge signal + LLM "
                             "cross-examiner), claude-cli (Claude via the `claude` CLI on your "
                             "subscription, no API key). default: proxy")
    parser.add_argument("--llm-url", default=DEFAULT_LLM_URL,
                        help=f"OpenAI-compatible base URL (default: {DEFAULT_LLM_URL})")
    parser.add_argument("--llm-model", default=DEFAULT_LLM_MODEL,
                        help=f"model id (default: {DEFAULT_LLM_MODEL})")
    parser.add_argument("--llm-timeout", type=float, default=DEFAULT_LLM_TIMEOUT_S,
                        help="per-call timeout in seconds (default: %(default)s)")
    parser.add_argument("--prompt-version", choices=["v1", "v2", "r1"], default="v1",
                        help="system prompt version (default: v1; v2 was empirically a regression, kept for the falsification record; r1 is for DeepSeek-R1 reasoning-distilled models). Ignored by the hybrid backend, which uses its own prompt.")
    parser.add_argument("--bge-model", default=DEFAULT_BGE_MODEL,
                        help=f"sentence-transformers bge model path for the bge/hybrid backends (default: {DEFAULT_BGE_MODEL})")
    parser.add_argument("--bge-query-prefix", default="",
                        help="custom query-instruction prefix applied to the report (query) side for the bge/hybrid backends (default: none)")
    parser.add_argument("--bge-instruct", action="store_true",
                        help="use BAAI's bge-en-v1.5 retrieval query instruction as the report prefix (shorthand for the standard instruction)")
    parser.add_argument("--bge-tau", type=float, default=0.1,
                        help="softmax temperature for the contrastive bge drift prior (default 0.1; smaller = sharper; Spearman rank is invariant to it)")
    parser.add_argument("--llm-api-key-env", default=None,
                        help="name of an env var holding a Bearer API key for the LLM endpoint (e.g. ANTHROPIC_API_KEY for Claude via https://api.anthropic.com/v1). Ollama needs none. The key is read from the env, never taken on argv.")
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

    # Contrastive scoring: hand bge/hybrid backends every hypothesis concept so
    # drift is scored as report-vs-own-target-vs-competitors (a relative margin),
    # not an absolute (compressed) cosine to a single concept.
    if hasattr(scorer, "set_contrast_contexts"):
        scorer.set_contrast_contexts([pipeline.get_context(h) for h in pipeline.list_hypotheses()])

    if not args.dataset.exists():
        log.error("Dataset not found at %s", args.dataset)
        return 1
    with args.dataset.open("r", encoding="utf-8") as f:
        dataset = json.load(f)
    log.info("Loaded dataset: %s (%d reports)", args.dataset, len(dataset))

    # Any scorer exposing evaluate_with_text scores on the full report text
    # (LLM, bge, hybrid); the symbolic proxy falls through to score(symbols).
    full_text = scorer if hasattr(scorer, "evaluate_with_text") else None
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
    report["bge_model"] = getattr(scorer, "bge_model_path", None)
    report["bge_signals"] = getattr(scorer, "signals", None) or None
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
