"""Tests for Goal 0 state trajectory reconstruction."""

import csv
import contextlib
import importlib.util
import io
import json
import tempfile
from pathlib import Path


def _load_script():
    root = Path(__file__).resolve().parent.parent.parent
    path = root / "Scripts" / "reconstruct_state_trajectory.py"
    spec = importlib.util.spec_from_file_location("reconstruct_state_trajectory", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


rst = _load_script()


def _candidate(role, potential, coherence, resonance, novelty, text=None):
    return {
        "roleID": role,
        "text": text or f"{role} text",
        "potential": potential,
        "coherence": coherence,
        "resonance": resonance,
        "novelty": novelty,
    }


def _event(index, outcome, spoken, tension, margin, tau, candidates, self_similarity=0.4):
    return {
        "index": index,
        "heard": f"heard {index}",
        "outcome": outcome,
        "spokenText": spoken,
        "tension": tension,
        "margin": margin,
        "selectionTemperature": tau,
        "glossScalar": 0.5,
        "selfSimilarity": self_similarity,
        "candidates": candidates,
    }


def test_reconstructs_resolved_candidate_state():
    displacement = _candidate(
        "displacement-seeking", 1.2, 0.62, 0.51, 0.77,
        text="resolved displacement",
    )
    coherence = _candidate("coherence-seeking", 0.8, 0.91, 0.44, 0.35)
    events = [
        _event(0, "spoke:displacement-seeking", "resolved displacement",
               0.3, 0.4, 0.35, [coherence, displacement]),
        _event(1, "spoke:coherence-seeking", "coherence-seeking text",
               0.5, 0.2, 0.28, [coherence, displacement]),
        _event(2, "silent", None, 0.8, 0.01, 0.2, [coherence, displacement]),
    ]

    result = rst.reconstruct(events, source=Path("fixture.jsonl"))
    first = result["rows"][0]
    silent = result["rows"][2]

    assert first["representative_candidate_source"] == "resolved_role_and_text"
    assert first["state"]["novelty"] == 0.77
    assert first["state"]["semantic_energy"] == 1.2
    assert 0.0 <= first["state"]["continuation_pressure"] <= 1.0
    assert silent["representative_candidate_source"] == "best_potential"
    assert result["diagnostics"]["turn_count"] == 3
    assert result["diagnostics"]["representable"] is True


def test_falsifies_underpowered_trajectory():
    event = _event(0, "silent", None, 0.0, 0.0, 0.0, [])
    result = rst.reconstruct([event], source=Path("one-turn.jsonl"))

    diagnostics = result["diagnostics"]
    assert diagnostics["representable"] is False
    assert diagnostics["verdict"] == "not_representable"
    assert any("requires at least" in flag for flag in diagnostics["falsification_flags"])
    assert any("trajectory has no measurable movement" in flag for flag in diagnostics["falsification_flags"])


def test_cli_writes_json_and_csv_artifacts():
    events = [
        _event(0, "spoke:coherence-seeking", "coherence-seeking text",
               0.1, 0.3, 0.4, [_candidate("coherence-seeking", 1.0, 0.9, 0.5, 0.2)]),
        _event(1, "spoke:coherence-seeking", "coherence-seeking text",
               0.2, 0.2, 0.3, [_candidate("coherence-seeking", 0.9, 0.8, 0.6, 0.3)]),
        _event(2, "spoke:coherence-seeking", "coherence-seeking text",
               0.3, 0.1, 0.2, [_candidate("coherence-seeking", 0.8, 0.7, 0.7, 0.4)]),
    ]

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        input_path = tmp_path / "turns.jsonl"
        json_path = tmp_path / "trajectory.json"
        csv_path = tmp_path / "trajectory.csv"
        input_path.write_text("\n".join(json.dumps(event) for event in events) + "\n")

        rc = rst.main([
            "--input", str(input_path),
            "--output", str(json_path),
            "--csv", str(csv_path),
            "--quiet",
        ])

        assert rc == 0
        data = json.loads(json_path.read_text())
        assert data["schema_version"] == "state-trajectory-v0"
        assert len(data["rows"]) == 3
        with csv_path.open() as f:
            rows = list(csv.DictReader(f))
        assert len(rows) == 3
        assert "continuation_pressure" in rows[0]


def test_cli_stdout_is_json_when_no_output_path_is_given():
    event = _event(
        0, "spoke:coherence-seeking", "coherence-seeking text",
        0.1, 0.3, 0.4, [_candidate("coherence-seeking", 1.0, 0.9, 0.5, 0.2)],
    )

    with tempfile.TemporaryDirectory() as tmp:
        input_path = Path(tmp) / "turns.jsonl"
        input_path.write_text(json.dumps(event) + "\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = rst.main(["--input", str(input_path), "--pretty"])

    assert rc == 0
    payload = json.loads(out.getvalue())
    assert payload["schema_version"] == "state-trajectory-v0"
    assert payload["diagnostics"]["verdict"] == "not_representable"


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("ok")
