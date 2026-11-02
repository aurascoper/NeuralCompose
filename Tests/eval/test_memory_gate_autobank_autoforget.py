import importlib.util
import json
import sqlite3
import sys
from pathlib import Path

GATE_PATH = Path(__file__).resolve().parents[2] / "Scripts" / "memory-gate.py"
spec = importlib.util.spec_from_file_location("memory_gate", str(GATE_PATH))
mg = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["memory_gate"] = mg
spec.loader.exec_module(mg)


def test_should_autobank_turn_warrant_and_collapse_gates():
    ok, reason = mg.should_autobank_turn(
        heard="Should we test out the Bluetooth muse BCI brain computer interface EEG connection to NeuralCompose",
        spoken="Muse S board 39 streams 256 Hz over native CoreBluetooth SimpleBLE.",
        outcome="spoke:coherence-seeking",
        self_similarity=0.8681,
    )
    assert ok is True
    assert reason == "warranted"

    ok, reason = mg.should_autobank_turn(
        heard="Sex sex sex",
        spoken="Any reply",
        outcome="spoke:coherence-seeking",
        self_similarity=0.50,
    )
    assert ok is False
    assert reason == "single_token_stutter"

    ok, reason = mg.should_autobank_turn(
        heard="Sex, sex, sex.",
        spoken="Any reply",
        outcome="spoke:coherence-seeking",
        self_similarity=0.50,
    )
    assert ok is False
    assert reason == "single_token_stutter"

    ok, reason = mg.should_autobank_turn(
        heard="Kind of",
        spoken="Any reply",
        outcome="spoke:coherence-seeking",
        self_similarity=0.50,
    )
    assert ok is False
    assert reason == "short_backchannel_or_hedge"

    ok, reason = mg.should_autobank_turn(
        heard="Turn off",
        spoken="Any reply",
        outcome="spoke:coherence-seeking",
        self_similarity=0.50,
    )
    assert ok is False
    assert reason == "transient_control_or_transit"

    ok, reason = mg.should_autobank_turn(
        heard="OK I should be good I'll be down in a second",
        spoken="Any reply",
        outcome="spoke:displacement-seeking",
        self_similarity=0.9114,
    )
    assert ok is False
    assert reason == "transient_control_or_transit"

    ok, reason = mg.should_autobank_turn(
        heard="How does the slow core interact with the fast wireframe in phase space",
        spoken="Collapsed reply",
        outcome="spoke:displacement-seeking",
        self_similarity=0.95,
    )
    assert ok is False
    assert reason.startswith("reflexive_collapse_gt_")

    ok, reason = mg.should_autobank_turn(
        heard="Basilisk is an open source Astro dynamic simulation framework developed by the university of Colorado's ABS lab in LA ASP la",
        spoken="Basilisk pairs a fast C/C++ modular dynamics core with SWIG-wrapped Python scripting for closed-loop spacecraft GNC.",
        outcome="spoke:coherence-seeking",
        self_similarity=0.9355,
        witness_attempted=True,
        max_candidate_potential=1.6701,
    )
    assert ok is True
    assert reason == "warranted_high_potential"

    ok_l25, reason_l25 = mg.should_autobank_turn(
        heard="What should they be for each",
        spoken="Give the $150 Hyperliquid sleeve the Fast Wireframe role and the $51 MEXC sleeve the Slow Core role, inverted against dollar size because redemption latency governs risk.",
        outcome="spoke:coherence-seeking",
        self_similarity=0.9403586,
        witness_attempted=True,
        max_candidate_potential=1.5364914,
    )
    assert ok_l25 is True
    assert reason_l25 == "warranted_high_potential"


def test_dialectic_payloads_disambiguates_multi_run_and_strips_dashes(tmp_path: Path):
    log_fp = tmp_path / "dialectic-turns-2026-11-01.jsonl"
    turns = [
        {
            "index": 0,
            "runID": "85C8E4B7-1111-2222-3333-444444444444",
            "recordedAt": "2026-11-01T18:41:43.257Z",
            "heard": "Testing the fast wireframe and slow core in phase space",
            "spokenText": "Fast wireframe tracks immediate sensory drive\u2014slow core holds the attractor\u2013shell.",
            "outcome": "spoke:coherence-seeking",
            "tension": 0.12,
            "glossScalar": 0.50,
            "selfSimilarity": 0.72,
        },
        {
            "index": 0,
            "runID": "B43AC522-5555-6666-7777-888888888888",
            "recordedAt": "2026-11-01T18:45:19.048Z",
            "heard": "Should we test out the Bluetooth muse BCI EEG connection to NeuralCompose",
            "spokenText": "Yes, test Muse S board 39 over native BLE or MindMonitor UDP 5000.",
            "outcome": "spoke:coherence-seeking",
            "tension": 0.06,
            "glossScalar": 0.10,
            "selfSimilarity": 0.8681,
        },
        {
            "index": 1,
            "runID": "B43AC522-5555-6666-7777-888888888888",
            "recordedAt": "2026-11-01T18:46:00.000Z",
            "heard": "Sex sex sex",
            "spokenText": "Filtered stutter turn",
            "outcome": "spoke:coherence-seeking",
            "tension": 0.04,
            "glossScalar": 0.50,
            "selfSimilarity": 0.88,
        },
    ]
    log_fp.write_text("\n".join(json.dumps(t) for t in turns) + "\n")

    payloads = list(mg.dialectic_payloads(log_fp))
    assert len(payloads) == 2
    assert payloads[0].key() != payloads[1].key()
    assert "run:85c8e4b7" in payloads[0].tags
    assert "run:b43ac522" in payloads[1].tags
    for p in payloads:
        assert "\u2014" not in p.text
        assert "\u2013" not in p.text


def test_sqlite_autobank_and_autoforget_roundtrip(tmp_path: Path):
    db_fp = tmp_path / "memory.sqlite"
    conn = sqlite3.connect(str(db_fp))
    conn.executescript(
        """
        CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES (3, 'MemoryRecord', 0, 0), (11, 'TagRecord', 0, 0);
        CREATE TABLE ZMEMORYRECORD (
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZTOMBSTONED INTEGER,
            ZCREATEDAT TIMESTAMP, ZOCCURREDAT TIMESTAMP, ZSENTIMENT FLOAT,
            ZCONVERSATIONID VARCHAR, ZLANGUAGE VARCHAR, ZSOURCE VARCHAR, ZTEXT VARCHAR, ZID BLOB
        );
        CREATE TABLE ZTAGRECORD (
            Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZNAME VARCHAR, ZID BLOB
        );
        CREATE TABLE Z_3TAGS (Z_3MEMORIES INTEGER, Z_11TAGS INTEGER, PRIMARY KEY (Z_3MEMORIES, Z_11TAGS));
        """
    )
    conn.commit()
    conn.close()

    valid_p = mg.RememberPayload(
        source="app-dialectic",
        text='heard "Should we test out the Bluetooth muse BCI connection" -> spoke "Muse S board 39 native BLE." (tension 0.06, self_sim 0.86)',
        occurred_at="2026-11-01T19:29:44.340Z",
        tags=["node:16", "dialectic", "spoke", "run:b43ac522"],
        conversation_id="dialectic-2026-11-01",
    )
    noisy_p = mg.RememberPayload(
        source="app-dialectic",
        text='heard "Kind of" -> spoke "Some reply" (tension 0.05, self_sim 0.94)',
        occurred_at="2026-11-01T19:30:00.000Z",
        tags=["node:17", "dialectic", "spoke", "run:b43ac522"],
        conversation_id="dialectic-2026-11-01",
    )

    stats1 = mg.sync_payloads_to_sql([valid_p, noisy_p], sqlite_path=db_fp, pg_dsn="postgresql://invalid/none")
    assert stats1["sqlite_inserted"] == 2
    stats2 = mg.sync_payloads_to_sql([valid_p, noisy_p], sqlite_path=db_fp, pg_dsn="postgresql://invalid/none")
    assert stats2["sqlite_inserted"] == 0
    assert stats2["sqlite_skipped"] == 2

    af = mg.autoforget_sql_and_logs(
        telemetry_dir=tmp_path,
        sqlite_path=db_fp,
        pg_dsn="postgresql://invalid/none",
        apply_sql=True,
    )
    assert af["sqlite_candidates"] == 1
    assert af["sqlite_tombstoned"] == 1

    # Verify PII redaction and short high-potential guard (len(words) >= 3 required even for high potential)
    scrubbed = mg._sanitize_dashes("Hunter and Kendra tested Speaker Speaker [REDACTED_NAME]")
    assert "hunter" not in scrubbed.lower()
    assert "kendra" not in scrubbed.lower()
    assert "speaker speaker" not in scrubbed.lower()

    short_ok, short_reason = mg.should_autobank_turn(
        heard="Two words",
        spoken="Long enough spoken response here to exceed five total words",
        outcome="spoke:coherence-seeking",
        self_similarity=0.93,
        max_self_similarity=0.92,
        witness_attempted=True,
        max_candidate_potential=1.68,
    )
    assert short_ok is False
    assert short_reason == "short_backchannel_or_hedge"

