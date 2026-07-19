#!/usr/bin/env python3
"""
dream_mode_hypothesis_registry.py — Thin config manager for the
decoupled dream-mode hypothesis registry.

Loads `Evaluation/corpora/dream_mode_hypothesis_registry.json` and provides
type-safe access to the routing / cascades / policies schema. This is the
**offline** config manager for Stage 3.5 — it does not talk to any LLM, does
not play audio, does not run any FSM logic. The runtime FSM and TTS path are
Swift (`Sources/BCICore/Sleep/`, `Sources/BCIVoice/AVSpeechSynthesizerService`)
and stay deferred to Stage 4 per the boundary contract in
`Evaluation/reports/decision_registry.md` entry 7.

Companion to `Scripts/dream_extraction.py` (drift scorer) and
`Scripts/dream_session_replay.py` (offline FSM replay harness).

Schema (mirrors the JSON):
  GlobalPolicies:
    max_interventions_per_rem_cycle: int
    global_cooldown_seconds: float
    abort_on_repeated_arousal: bool
    arousal_threshold_count: int

  HypothesisDefinition:
    target_concept: str
    routing: Routing
    policies: Policies
    cascades: Cascades

  Routing:
    primary_anchors: list[str]
    semantic_domain: str
    drift_tolerance: float  # in [0.0, 1.0]

  Policies:
    intervention_intensity: "low" | "medium" | "high" | "adaptive"
    require_debounce: bool
    allowed_tones: list[str]

  Cascades:
    on_drift_timeout: Optional[str]   # hypothesis_id or terminal name
    on_arousal: Optional[str]
    on_lucidity_detected: Optional[str]

  Terminal cascade names (string keys, not hypothesis ids):
    "abort_to_restorative_sleep"
    "trigger_active_confrontation"

Usage:
  ./Scripts/dream_mode_hypothesis_registry.py
  ./Scripts/dream_mode_hypothesis_registry.py /path/to/registry.json

Importable:
  from dream_mode_hypothesis_registry import DreamModeHypothesisRegistry
  reg = DreamModeHypothesisRegistry()
  h = reg.get_hypothesis("hyp_fear_failure_01")
  target = reg.get_cascade_target("hyp_fear_failure_01", "on_arousal")
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


# Terminal cascade names. These are NOT hypothesis ids — they are string
# sentinels that the FSM recognises as "stop the experiment" or "switch to
# a fundamentally different mode". Surfaced as constants so a typo doesn't
# silently fall through to "no cascade rule".
TERMINAL_ABORT = "abort_to_restorative_sleep"
TERMINAL_CONFRONT = "trigger_active_confrontation"
TERMINAL_NAMES = frozenset({TERMINAL_ABORT, TERMINAL_CONFRONT})

# Cascade trigger event names. Surfaced as constants for the same reason.
TRIGGER_DRIFT_TIMEOUT = "on_drift_timeout"
TRIGGER_AROUSAL = "on_arousal"
TRIGGER_LUCIDITY = "on_lucidity_detected"
TRIGGER_NAMES = frozenset({TRIGGER_DRIFT_TIMEOUT, TRIGGER_AROUSAL, TRIGGER_LUCIDITY})


@dataclass(frozen=True)
class GlobalPolicies:
    max_interventions_per_rem_cycle: int
    global_cooldown_seconds: float
    abort_on_repeated_arousal: bool
    arousal_threshold_count: int


@dataclass(frozen=True)
class Routing:
    primary_anchors: tuple[str, ...]
    semantic_domain: str
    drift_tolerance: float  # [0.0, 1.0]


@dataclass(frozen=True)
class Policies:
    intervention_intensity: str  # "low" | "medium" | "high" | "adaptive"
    require_debounce: bool
    allowed_tones: tuple[str, ...]


@dataclass(frozen=True)
class Cascades:
    on_drift_timeout: Optional[str]
    on_arousal: Optional[str]
    on_lucidity_detected: Optional[str]


@dataclass(frozen=True)
class HypothesisDefinition:
    target_concept: str
    routing: Routing
    policies: Policies
    cascades: Cascades


@dataclass(frozen=True)
class DreamModeHypothesisRegistry:
    """
    Frozen, in-memory view of the dream-mode hypothesis registry.

    Construction validates the JSON shape end-to-end. Any malformed entry
    raises `ValueError` at construction time so the offline tool fails
    fast instead of surfacing a confusing AttributeError downstream.

    Hypotheses live in two blocks in the source JSON:
      - `hypotheses`: the pre-registered design-input hypotheses (S-1..S-4).
        These follow the canonical {id, title, question, metric, ...} shape
        and are NOT routed — they are governance records, not experiment
        configs.
      - `example_hypotheses_for_schema_validation`: the two pasted
        examples (hyp_fear_failure_01, hyp_safe_exploration_01) and their
        global_policies block. THESE are the routable experiment configs.
        Any tool that walks cascades / reads drift_tolerance / counts
        arousal limits should look here, not in `hypotheses`.

    This split is intentional: the governance block and the experiment
    block have different lifecycles. Premature merging would force the
    governance records to carry fields they don't need (target_concept,
    routing, cascades) and the experiment configs to carry fields they
    don't need (success_criterion, status_note).
    """

    source_path: Path
    version: int
    global_policies: GlobalPolicies
    # Experiment configs (routable, walkable, executable).
    experiment_hypotheses: dict[str, HypothesisDefinition]
    # Governance records (pre-registered design inputs, not routable).
    governance_hypotheses: tuple[dict, ...]  # raw dicts — shape is the canonical hypothesis_registry shape, not this schema

    @classmethod
    def load(cls, file_path: Optional[Path | str] = None) -> "DreamModeHypothesisRegistry":
        if file_path is None:
            # Default: relative to the repo root. The script lives in
            # Scripts/, so two levels up is the repo root.
            file_path = Path(__file__).resolve().parent.parent / "Evaluation" / "corpora" / "dream_mode_hypothesis_registry.json"
        else:
            file_path = Path(file_path)

        if not file_path.exists():
            raise FileNotFoundError(f"dream-mode hypothesis registry not found: {file_path}")

        with file_path.open("r", encoding="utf-8") as f:
            raw = json.load(f)

        meta = raw.get("_meta", {})
        if meta.get("version") != 1:
            raise ValueError(f"unsupported dream-mode registry version: {meta.get('version')!r} (expected 1)")

        # Global policies live in `example_hypotheses_for_schema_validation`
        # block today; that may change in v2. Look in both places.
        example_block = raw.get("example_hypotheses_for_schema_validation")
        if example_block is None or "global_policies" not in example_block:
            raise ValueError(
                "dream-mode registry missing `example_hypotheses_for_schema_validation.global_policies` "
                f"(source: {file_path})"
            )
        gp_raw = example_block["global_policies"]
        global_policies = GlobalPolicies(
            max_interventions_per_rem_cycle=int(gp_raw["max_interventions_per_rem_cycle"]),
            global_cooldown_seconds=float(gp_raw["global_cooldown_seconds"]),
            abort_on_repeated_arousal=bool(gp_raw["abort_on_repeated_arousal"]),
            arousal_threshold_count=int(gp_raw["arousal_threshold_count"]),
        )

        # Experiment hypotheses (routable).
        experiment_raw = example_block.get("hypotheses", {})
        experiment_hypotheses: dict[str, HypothesisDefinition] = {}
        for hyp_id, h in experiment_raw.items():
            experiment_hypotheses[hyp_id] = _parse_hypothesis(hyp_id, h)

        # Governance hypotheses (pre-registered design inputs).
        governance_raw = raw.get("hypotheses", [])
        if not isinstance(governance_raw, list):
            raise ValueError(
                f"`hypotheses` (governance block) must be a list, got {type(governance_raw).__name__}"
            )
        # Light shape check on each governance record — not full parse, since
        # governance records don't follow the experiment schema.
        for i, g in enumerate(governance_raw):
            if not isinstance(g, dict) or "id" not in g or "status" not in g:
                raise ValueError(
                    f"governance hypothesis at index {i} missing required fields (id, status); got keys: {sorted(g.keys()) if isinstance(g, dict) else type(g).__name__}"
                )

        return cls(
            source_path=file_path,
            version=int(meta["version"]),
            global_policies=global_policies,
            experiment_hypotheses=experiment_hypotheses,
            governance_hypotheses=tuple(governance_raw),
        )

    # --- experiment-hypothesis accessors ---

    def get_hypothesis(self, hyp_id: str) -> HypothesisDefinition:
        """Look up an experiment hypothesis by id. Raises KeyError on miss."""
        if hyp_id in TERMINAL_NAMES:
            raise KeyError(
                f"'{hyp_id}' is a TERMINAL cascade name, not an experiment hypothesis id. "
                f"Use `is_terminal_cascade_target(...)` to check for it, or pick a routable "
                f"hypothesis from the registry."
            )
        try:
            return self.experiment_hypotheses[hyp_id]
        except KeyError:
            available = sorted(self.experiment_hypotheses.keys())
            raise KeyError(f"experiment hypothesis '{hyp_id}' not found. Available: {available}") from None

    def has_hypothesis(self, hyp_id: str) -> bool:
        return hyp_id in self.experiment_hypotheses

    def get_cascade_target(self, current_hyp_id: str, trigger_event: str) -> Optional[str]:
        """
        Return the cascade target for (current_hypothesis, trigger_event),
        or None if no cascade rule exists.

        Raises ValueError on bad trigger name or bad current hypothesis.
        Raises nothing for terminal targets — the caller decides what to do
        with them (typically: stop the experiment or switch mode).
        """
        if trigger_event not in TRIGGER_NAMES:
            raise ValueError(
                f"unknown trigger event '{trigger_event}'; expected one of: {sorted(TRIGGER_NAMES)}"
            )
        h = self.get_hypothesis(current_hyp_id)
        target = getattr(h.cascades, trigger_event)
        return target

    def is_terminal_cascade_target(self, target: Optional[str]) -> bool:
        """True iff `target` is a terminal cascade name (not an experiment hypothesis)."""
        return target in TERMINAL_NAMES

    # --- governance accessors ---

    def governance_ids(self) -> tuple[str, ...]:
        return tuple(g["id"] for g in self.governance_hypotheses)

    def get_governance(self, hyp_id: str) -> dict:
        for g in self.governance_hypotheses:
            if g["id"] == hyp_id:
                return g
        available = self.governance_ids()
        raise KeyError(f"governance hypothesis '{hyp_id}' not found. Available: {list(available)}")


def _parse_hypothesis(hyp_id: str, raw: dict) -> HypothesisDefinition:
    if not isinstance(raw, dict):
        raise ValueError(f"experiment hypothesis '{hyp_id}' must be a dict, got {type(raw).__name__}")
    for required in ("target_concept", "routing", "policies", "cascades"):
        if required not in raw:
            raise ValueError(f"experiment hypothesis '{hyp_id}' missing required field '{required}'")

    r = raw["routing"]
    if "drift_tolerance" not in r or not (0.0 <= float(r["drift_tolerance"]) <= 1.0):
        raise ValueError(
            f"experiment hypothesis '{hyp_id}' has invalid drift_tolerance: {r.get('drift_tolerance')!r} "
            f"(must be in [0.0, 1.0])"
        )

    p = raw["policies"]
    if p.get("intervention_intensity") not in {"low", "medium", "high", "adaptive"}:
        raise ValueError(
            f"experiment hypothesis '{hyp_id}' has invalid intervention_intensity: {p.get('intervention_intensity')!r}"
        )

    c = raw["cascades"]
    # Cascade targets may be: another hypothesis id, a terminal name, or
    # null. The lookup at use time will validate; here we just sanity-check
    # types.
    for trigger in TRIGGER_NAMES:
        v = c.get(trigger)
        if v is not None and not isinstance(v, str):
            raise ValueError(
                f"experiment hypothesis '{hyp_id}' cascade {trigger} must be a string or null, got {type(v).__name__}"
            )

    return HypothesisDefinition(
        target_concept=str(raw["target_concept"]),
        routing=Routing(
            primary_anchors=tuple(r["primary_anchors"]),
            semantic_domain=str(r["semantic_domain"]),
            drift_tolerance=float(r["drift_tolerance"]),
        ),
        policies=Policies(
            intervention_intensity=str(p["intervention_intensity"]),
            require_debounce=bool(p["require_debounce"]),
            allowed_tones=tuple(p.get("allowed_tones", ())),
        ),
        cascades=Cascades(
            on_drift_timeout=c.get(TRIGGER_DRIFT_TIMEOUT),
            on_arousal=c.get(TRIGGER_AROUSAL),
            on_lucidity_detected=c.get(TRIGGER_LUCIDITY),
        ),
    )


# --- self-test (run as a script) ---

def _selftest() -> int:
    reg = DreamModeHypothesisRegistry.load()
    print(f"✅ Loaded: {reg.source_path}")
    print(f"   version: {reg.version}")
    print(f"   global_policies: {reg.global_policies}")
    print(f"   experiment_hypotheses: {sorted(reg.experiment_hypotheses.keys())}")
    print(f"   governance_hypotheses: {reg.governance_ids()}")
    print()

    # Walk a cascade end-to-end and prove the chain terminates safely.
    fear = reg.get_hypothesis("hyp_fear_failure_01")
    print(f"   hyp_fear_failure_01.target_concept: {fear.target_concept!r}")
    print(f"   hyp_fear_failure_01.drift_tolerance: {fear.routing.drift_tolerance}")
    print(f"   hyp_fear_failure_01.intervention_intensity: {fear.policies.intervention_intensity}")
    print(f"   hyp_fear_failure_01.allowed_tones: {fear.policies.allowed_tones}")
    arousal_target = reg.get_cascade_target("hyp_fear_failure_01", "on_arousal")
    print(f"   on_arousal -> {arousal_target!r} (terminal? {reg.is_terminal_cascade_target(arousal_target)})")
    drift_target = reg.get_cascade_target("hyp_fear_failure_01", "on_drift_timeout")
    print(f"   on_drift_timeout -> {drift_target!r} (terminal? {reg.is_terminal_cascade_target(drift_target)})")
    # That cascades to hyp_safe_exploration_01, which cascades to terminal.
    if not reg.is_terminal_cascade_target(drift_target) and drift_target is not None:
        deeper = reg.get_cascade_target(drift_target, "on_drift_timeout")
        print(f"   {drift_target}.on_drift_timeout -> {deeper!r} (terminal? {reg.is_terminal_cascade_target(deeper)})")
    print()

    # Verify safe probes for missing / terminal / bad names.
    try:
        reg.get_hypothesis("does_not_exist")
        print("❌ expected KeyError on missing hypothesis")
        return 1
    except KeyError as e:
        print(f"   missing-hypothesis probe: KeyError ✓ ({e})")

    try:
        reg.get_hypothesis(TERMINAL_ABORT)
        print("❌ expected KeyError on terminal-as-hypothesis lookup")
        return 1
    except KeyError as e:
        print(f"   terminal-as-hypothesis probe: KeyError ✓")

    try:
        reg.get_cascade_target("hyp_fear_failure_01", "on_nonsense")
        print("❌ expected ValueError on bad trigger")
        return 1
    except ValueError as e:
        print(f"   bad-trigger probe: ValueError ✓")

    # Governance block — confirm pre-registered design inputs are accessible.
    s1 = reg.get_governance("S-1-routing-cascades-policies-schema")
    print(f"   S-1.status: {s1['status']}")
    print(f"   S-1.status_note first 80 chars: {s1['status_note'][:80]!r}...")

    print()
    print("✅ Self-test passed.")
    return 0


if __name__ == "__main__":
    sys.exit(_selftest())
