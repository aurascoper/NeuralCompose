#!/usr/bin/env python3
"""Validation for governance-only research decision-register entries.

An entry records why a method may be studied. It cannot authorize a dependency,
runtime feature, model run, experiment, or promotion decision.
"""

from __future__ import annotations

import json
from typing import Any, Mapping


DECISION_REGISTER_SCHEMA = "nc-research-decision-register-v0"
PASSES = frozenset({1, 2, 3, 4})
OWNERS = frozenset({"science", "engineering", "computation"})
DATA_GATES = frozenset({"D0", "D1", "D2", "D3", "post_encoder"})
IMPLEMENTATION_STATUSES = frozenset({"deferred", "study_only", "eligible_for_experiment"})
REQUIRED_FIELDS = frozenset(
    {
        "schema_version",
        "topic",
        "pass",
        "owner",
        "registered_question",
        "decision_it_can_change",
        "required_data_gate",
        "falsification_criterion",
        "implementation_status",
        "runtime_dependency_authorized",
    }
)


class DecisionRegisterError(ValueError):
    pass


def _required_text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise DecisionRegisterError(f"{name} must be a nonempty string")
    return value


def validate_decision_register_entry(value: Mapping[str, Any]) -> dict[str, Any]:
    """Strictly validate a metadata-only entry without granting implementation."""
    if set(value) != REQUIRED_FIELDS:
        raise DecisionRegisterError("decision register entry has missing or unsupported fields")
    if value.get("schema_version") != DECISION_REGISTER_SCHEMA:
        raise DecisionRegisterError("decision register schema version is invalid")
    if isinstance(value.get("pass"), bool) or value.get("pass") not in PASSES:
        raise DecisionRegisterError("pass must be an integer in [1, 4]")
    if value.get("owner") not in OWNERS:
        raise DecisionRegisterError("owner is invalid")
    if value.get("required_data_gate") not in DATA_GATES:
        raise DecisionRegisterError("required_data_gate is invalid")
    if value.get("implementation_status") not in IMPLEMENTATION_STATUSES:
        raise DecisionRegisterError("implementation_status is invalid")
    if value.get("runtime_dependency_authorized") is not False:
        raise DecisionRegisterError("decision registers never authorize runtime dependencies")
    for field in ("topic", "registered_question", "decision_it_can_change", "falsification_criterion"):
        _required_text(value.get(field), field)
    return json.loads(json.dumps(dict(value), sort_keys=True))
