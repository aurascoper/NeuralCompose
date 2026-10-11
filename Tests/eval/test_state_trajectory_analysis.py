"""Tests for Goal 1 state trajectory analysis."""

import contextlib
import importlib.util
import io
import json
import tempfile
from pathlib import Path


def _load_script():
    root = Path(__file__).resolve().parent.parent.parent
    path = root / "Scripts" / "analyze_state_trajectory.py"
    spec = importlib.util.spec_from_file_location("analyze_state_trajectory", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ast = _load_script()


def _row(index, coherence, continuation_pressure):
    return {
        "index": index,
        "outcome": "spoke:fixture",
        "state": {
            "coherence": coherence,
            "continuation_pressure": continuation_pressure,
        },
        "axis_completeness": 1.0,
        "missing_axes": [],
    }


def _trajectory(points, representable=True):
    return {
        "schema_version": "state-trajectory-v0",
        "source": "fixture.jsonl",
        "source_kind": "dialectical_turn_jsonl",
        "axis_order": ["coherence", "continuation_pressure"],
        "rows": [
            _row(index, coherence, pressure)
            for index, (coherence, pressure) in enumerate(points)
        ],
        "diagnostics": {
            "representable": representable,
            "verdict": "representable" if representable else "not_representable",
        },
    }


def test_supports_converging_pressure_attractor_proxy():
    data = _trajectory([
        (0.00, 0.10),
        (0.45, 0.55),
        (0.68, 0.70),
        (0.80, 0.80),
        (0.88, 0.87),
        (0.93, 0.92),
        (0.96, 0.95),
        (0.98, 0.975),
        (0.99, 0.99),
    ])

    result = ast.analyze(data, source=Path("fixture-trajectory.json"))

    assert result["decision"] == "supported"
    assert result["next_stage"] == "promote_to_dynamical_modeling"
    assert [h["decision"] for h in result["hypotheses"]] == ["supported", "supported"]


def test_rejects_expanding_pressure_attractor_proxy():
    data = _trajectory([
        (0.00, 0.10),
        (0.01, 0.25),
        (0.03, 0.40),
        (0.08, 0.55),
        (0.18, 0.70),
        (0.35, 0.82),
        (0.58, 0.90),
        (0.85, 0.96),
        (1.00, 0.99),
    ])

    result = ast.analyze(data, source=Path("fixture-trajectory.json"))

    assert result["decision"] == "rejected"
    assert result["next_stage"] == "revise_or_reject_hypothesis"
    assert any(
        "late/early step ratio" in flag
        for flag in result["hypotheses"][0]["falsification_flags"]
    )
    assert any(
        "pressure/next-step correlation" in flag
        for flag in result["hypotheses"][1]["falsification_flags"]
    )


def test_marks_unrepresentable_input_as_not_testable():
    data = _trajectory([(0.0, 0.1), (0.0, 0.1)], representable=False)

    result = ast.analyze(data, source=Path("not-representable.json"))

    assert result["decision"] == "not_testable"
    assert result["next_stage"] == "collect_or_reconstruct_more_telemetry"
    assert any(
        "input trajectory is not representable" in flag
        for flag in result["hypotheses"][0]["falsification_flags"]
    )


def test_cli_stdout_is_json_when_no_output_path_is_given():
    data = _trajectory([
        (0.00, 0.10),
        (0.45, 0.55),
        (0.68, 0.70),
        (0.80, 0.80),
        (0.88, 0.87),
        (0.93, 0.92),
        (0.96, 0.95),
        (0.98, 0.975),
        (0.99, 0.99),
    ])

    with tempfile.TemporaryDirectory() as tmp:
        input_path = Path(tmp) / "trajectory.json"
        input_path.write_text(json.dumps(data) + "\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = ast.main(["--input", str(input_path), "--pretty"])

    assert rc == 0
    payload = json.loads(out.getvalue())
    assert payload["schema_version"] == "state-trajectory-analysis-v0"
    assert payload["decision"] == "supported"


def test_cli_writes_analysis_artifact():
    data = _trajectory([
        (0.00, 0.10),
        (0.45, 0.55),
        (0.68, 0.70),
        (0.80, 0.80),
        (0.88, 0.87),
        (0.93, 0.92),
        (0.96, 0.95),
        (0.98, 0.975),
        (0.99, 0.99),
    ])

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        input_path = tmp_path / "trajectory.json"
        output_path = tmp_path / "analysis.json"
        input_path.write_text(json.dumps(data) + "\n")

        rc = ast.main([
            "--input", str(input_path),
            "--output", str(output_path),
            "--quiet",
        ])

        assert rc == 0
        payload = json.loads(output_path.read_text())
        assert payload["combined_hypothesis"]["id"] == "H_continuation_pressure_attractor_v0"


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("ok")
