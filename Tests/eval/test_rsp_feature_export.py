import importlib.util
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "export_rsp_features.py"
SPEC = importlib.util.spec_from_file_location("rsp_export", SCRIPT)
assert SPEC and SPEC.loader
rsp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rsp)


def event(index, outcome="spoke:coherence-seeking", spoken=None, heard=None):
    return {
        "index": index,
        "heard": heard or f"heard {index}",
        "outcome": outcome,
        "spokenText": spoken if spoken is not None else f"spoken {index}",
        "tension": 0.2,
        "margin": 0.3,
        "candidates": [
            {"roleID": "coherence-seeking", "text": f"coherence {index}"},
            {"roleID": "displacement-seeking", "text": f"displacement {index}"},
        ],
        "generatorFingerprint": {
            "runtime": "ollama", "transport": "ollama-http", "provider": "ollama",
            "model": "fixture-model", "promptProfile": "focused",
            "interactionStyle": "dialectical", "promptHash": "fixture",
        },
    }


def fixture_vectors(events):
    texts = set()
    for row in events:
        texts.update([row["heard"], row["spokenText"]])
        texts.update(candidate["text"] for candidate in row["candidates"])
    return {text: [1.0, float(index % 3 + 1)] for index, text in enumerate(sorted(texts))}


def write_fixture(path, vectors):
    path.write_text(json.dumps({"vectors": vectors}))


def write_events(path, events):
    path.write_text("\n".join(json.dumps(row) for row in events) + "\n")


def test_export_builds_causal_rows_and_keeps_text_out_of_dataset():
    events = [event(index) for index in range(11)]
    events[5]["outcome"] = "synthesized:synthesis"
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        turns = root / "runs" / "fixture.jsonl"
        turns.parent.mkdir()
        write_events(turns, events)
        fixture = root / "vectors.json"
        write_fixture(fixture, fixture_vectors(events))
        dataset = rsp.build_dataset([turns], rsp.FixtureEncoder(fixture))

    assert dataset["schema_version"] == "rsp-dataset-v0"
    assert len(dataset["rows"]) == 1
    row = dataset["rows"][0]
    assert set(row["features"]) == set(rsp.FEATURE_NAMES)
    assert row["labels"]["recurrence_5"] >= row["labels"]["top2_mean_recurrence_5"]
    assert "heard 5" not in json.dumps(dataset)
    assert dataset["encoder"]["test_only"] is True


def test_future_changes_affect_labels_but_not_causal_features():
    first = [event(index) for index in range(11)]
    second = [event(index) for index in range(11)]
    first[5]["outcome"] = second[5]["outcome"] = "synthesized:synthesis"
    for index in range(6, 11):
        second[index]["spokenText"] = "repeated unresolved theme"
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = root / "vectors.json"
        write_fixture(fixture, fixture_vectors(first + second))
        encoder = rsp.FixtureEncoder(fixture)
        outputs = []
        for name, events in (("first", first), ("second", second)):
            path = root / name / "runs" / "fixture.jsonl"
            path.parent.mkdir(parents=True)
            write_events(path, events)
            outputs.append(rsp.build_dataset([path], encoder)["rows"][0])

    assert outputs[0]["features"] == outputs[1]["features"]
    assert outputs[0]["labels"]["recurrence_5"] != outputs[1]["labels"]["recurrence_5"]


def test_export_rejects_malformed_jsonl_and_censors_incomplete_horizon():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        malformed = root / "bad.jsonl"
        malformed.write_text("{not json}\n")
        fixture = root / "vectors.json"
        write_fixture(fixture, {"x": [1.0, 0.0]})
        try:
            rsp.build_dataset([malformed], rsp.FixtureEncoder(fixture))
            assert False, "expected malformed JSONL rejection"
        except ValueError as error:
            assert "malformed JSONL" in str(error)

        events = [event(index) for index in range(10)]
        events[5]["outcome"] = "synthesized:synthesis"
        turns = root / "runs" / "short.jsonl"
        turns.parent.mkdir()
        write_events(turns, events)
        write_fixture(fixture, fixture_vectors(events))
        assert rsp.build_dataset([turns], rsp.FixtureEncoder(fixture))["rows"] == []


if __name__ == "__main__":
    for name, function in sorted(globals().items()):
        if name.startswith("test_") and callable(function):
            function()
    print("ok")
