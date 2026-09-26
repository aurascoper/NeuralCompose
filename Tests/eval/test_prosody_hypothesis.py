"""Tests for the prosody MVP hypothesis analyzer."""

import contextlib
import importlib.util
import io
import json
import tempfile
from pathlib import Path


def _load_script():
    root = Path(__file__).resolve().parent.parent.parent
    path = root / "Scripts" / "analyze_prosody_hypothesis.py"
    spec = importlib.util.spec_from_file_location("analyze_prosody_hypothesis", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


aph = _load_script()


def _turn(index, outcome):
    return {
        "index": index,
        "heard": f"heard {index}",
        "outcome": outcome,
        "spokenText": None if outcome == "silent" else f"spoken {index}",
        "candidates": [],
        "tension": 0.2,
        "margin": 0.1,
        "selectionTemperature": 0.4,
        "glossScalar": 0.5,
    }


def _prosody(index, turn_index, pause_before, phase="measured"):
    return {
        "schema_version": "prosody-trace-v0",
        "index": index,
        "source_kind": "dialectical-turn-requested-prosody",
        "utterance_text": f"spoken {turn_index}",
        "dialogue_state": {"turn_index": turn_index},
        phase: {"pause_before": pause_before},
        "voice_identifier": "fixture-voice",
        "synthesizer_identifier": "fixture",
    }


def _run_analysis(pauses, outcomes, phase="measured", min_samples=6, min_synthesis=2):
    turns = [_turn(i, outcome) for i, outcome in enumerate(outcomes)]
    prosody = [
        _prosody(i, i, pause, phase=phase)
        for i, pause in enumerate(pauses)
    ]
    return aph.analyze(
        turns,
        prosody,
        dialectic_source=Path("turns.jsonl"),
        prosody_source=Path("prosody.jsonl"),
        phase=phase,
        min_samples=min_samples,
        min_synthesis=min_synthesis,
        include_samples=True,
    )


def test_supports_measured_pause_predicting_synthesis():
    outcomes = [
        "spoke:coherence-seeking",
        "synthesized:synthesis",
        "spoke:displacement-seeking",
        "synthesized:synthesis",
        "spoke:coherence-seeking",
        "synthesized:synthesis",
        "spoke:displacement-seeking",
        "synthesized:synthesis",
    ]
    pauses = [0.10, 0.90, 0.20, 0.80, 0.30, 0.70, 0.40, 1.00]

    result = _run_analysis(pauses, outcomes)

    assert result["decision"] == "supported"
    assert result["next_stage"] == "promote_to_julia_reference_modeling"
    assert result["metrics"]["roc_auc"] == 1.0
    assert result["threshold_probe"]["delta"] > 0
    assert result["sample_counts"]["eligible_spoken_turns"] == 8
    assert result["falsification_flags"] == []


def test_rejects_negative_pause_direction():
    outcomes = [
        "synthesized:synthesis",
        "spoke:coherence-seeking",
        "synthesized:synthesis",
        "spoke:displacement-seeking",
        "synthesized:synthesis",
        "spoke:coherence-seeking",
        "synthesized:synthesis",
        "spoke:displacement-seeking",
    ]
    pauses = [0.10, 0.90, 0.20, 0.80, 0.30, 0.70, 0.40, 1.00]

    result = _run_analysis(pauses, outcomes)

    assert result["decision"] == "rejected"
    assert result["next_stage"] == "revise_or_reject_hypothesis"
    assert result["metrics"]["roc_auc"] == 0.0
    assert any("effect direction is negative" in flag for flag in result["falsification_flags"])
    assert any("roc_auc" in flag for flag in result["falsification_flags"])


def test_requested_controls_cannot_satisfy_acceptance():
    outcomes = [
        "spoke:coherence-seeking",
        "synthesized:synthesis",
        "spoke:displacement-seeking",
        "synthesized:synthesis",
        "spoke:coherence-seeking",
        "synthesized:synthesis",
    ]
    pauses = [0.10, 0.90, 0.20, 0.80, 0.30, 0.70]

    result = _run_analysis(pauses, outcomes, phase="requested")

    assert result["decision"] == "not_testable"
    assert result["metrics"]["roc_auc"] == 1.0
    assert any("pipeline validation only" in flag for flag in result["falsification_flags"])
    assert result["acceptance"]["measured_prosody_required"] is True


def test_marks_underpowered_measured_telemetry_not_testable():
    result = _run_analysis(
        pauses=[0.90, 0.20],
        outcomes=["synthesized:synthesis", "spoke:coherence-seeking"],
        min_samples=6,
        min_synthesis=2,
    )

    assert result["decision"] == "not_testable"
    assert any("eligible spoken turns" in flag for flag in result["falsification_flags"])
    assert any("synthesis turns" in flag for flag in result["falsification_flags"])


def test_cli_stdout_is_json_when_no_output_path_is_given():
    outcomes = [
        "spoke:coherence-seeking",
        "synthesized:synthesis",
        "spoke:displacement-seeking",
        "synthesized:synthesis",
        "spoke:coherence-seeking",
        "synthesized:synthesis",
    ]
    pauses = [0.10, 0.90, 0.20, 0.80, 0.30, 0.70]

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        turn_path = tmp_path / "dialectic-turns.jsonl"
        prosody_path = tmp_path / "prosody-trace.jsonl"
        turn_path.write_text(
            "\n".join(json.dumps(_turn(i, outcome)) for i, outcome in enumerate(outcomes)) + "\n"
        )
        prosody_path.write_text(
            "\n".join(json.dumps(_prosody(i, i, pause)) for i, pause in enumerate(pauses)) + "\n"
        )

        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = aph.main([
                "--dialectic-turns", str(turn_path),
                "--prosody-trace", str(prosody_path),
                "--min-samples", "6",
                "--min-synthesis", "2",
                "--pretty",
            ])

    assert rc == 0
    payload = json.loads(out.getvalue())
    assert payload["schema_version"] == "prosody-hypothesis-analysis-v0"
    assert payload["hypothesis_id"] == "reflective_prosody_v1"
    assert payload["decision"] == "supported"


def test_cli_writes_analysis_artifact():
    outcomes = [
        "spoke:coherence-seeking",
        "synthesized:synthesis",
        "spoke:displacement-seeking",
        "synthesized:synthesis",
        "spoke:coherence-seeking",
        "synthesized:synthesis",
    ]
    pauses = [0.10, 0.90, 0.20, 0.80, 0.30, 0.70]

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        turn_path = tmp_path / "dialectic-turns.jsonl"
        prosody_path = tmp_path / "prosody-trace.jsonl"
        output_path = tmp_path / "analysis.json"
        turn_path.write_text(
            "\n".join(json.dumps(_turn(i, outcome)) for i, outcome in enumerate(outcomes)) + "\n"
        )
        prosody_path.write_text(
            "\n".join(json.dumps(_prosody(i, i, pause)) for i, pause in enumerate(pauses)) + "\n"
        )

        rc = aph.main([
            "--dialectic-turns", str(turn_path),
            "--prosody-trace", str(prosody_path),
            "--output", str(output_path),
            "--min-samples", "6",
            "--min-synthesis", "2",
            "--quiet",
        ])
        payload = json.loads(output_path.read_text())

    assert rc == 0
    assert payload["decision"] == "supported"
    assert payload["sample_counts"]["eligible_spoken_turns"] == 6


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    print("ok")
