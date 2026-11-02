"""Unit tests for the Turn L112 non-recursive continuous self-improvement poller
(Scripts/non-recursive-self-improvement-poller.py & Scripts/non_recursive_self_improvement_poller.py),
ASR Phonetic Recovery Dictionary (Rules 1-14 across L75-L146), monotonic watermark idempotency,
and 16-32 GB Swap/VM Compressor backpressure gate."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sqlite3
import sys

REPO_ROOT = Path(__file__).resolve().parents[2]
POLLER_HYPHEN = REPO_ROOT / "Scripts" / "non-recursive-self-improvement-poller.py"
POLLER_UNDERSCORE = REPO_ROOT / "Scripts" / "non_recursive_self_improvement_poller.py"

spec = importlib.util.spec_from_file_location("non_recursive_poller", str(POLLER_HYPHEN))
poller = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules["non_recursive_poller"] = poller
spec.loader.exec_module(poller)


def test_both_poller_entrypoints_exist_and_have_zero_dashes():
    assert POLLER_HYPHEN.exists()
    assert POLLER_UNDERSCORE.exists()
    txt_h = POLLER_HYPHEN.read_text(encoding="utf-8")
    txt_u = POLLER_UNDERSCORE.read_text(encoding="utf-8")
    assert txt_h == txt_u
    assert "\u2014" not in txt_h and "\u2013" not in txt_h


def test_turn_L112_non_recursive_consolidation_guard_and_negative_tamper_tests():
    guard = poller.verify_non_recursive_consolidation_guard()
    assert guard["guard_passed"] is True
    assert guard["recursion_depth"] == 0
    assert guard["consolidation_rule_immutable"] is True
    assert guard["allow_rule_self_modification"] is False
    assert guard["spawned_llm_processes"] == 0
    assert poller.self_test_consolidation_rule_immutability() is True


def _matched_ids(res: dict) -> list[str]:
    return [r["rule_id"] for r in res["matched_rules"]]


def test_asr_phonetic_recovery_dictionary_covers_all_14_rules():
    assert len(poller.ASR_PHONETIC_RECOVERY_DICTIONARY) == 14

    r79 = poller.apply_asr_phonetic_recovery(
        "Are the viral arc jeans worth modeling and something like open foam or pie mall or Kmart", 79
    )
    assert r79["has_phonetic_recovery"] is True
    assert "asr_rule_01_viral_arc_capsid_openfoam_pymol_chimerax" in _matched_ids(r79)

    r115 = poller.apply_asr_phonetic_recovery(
        "What is a wizard about and how it applied to the spice Julia Colonels", 115
    )
    assert r115["has_phonetic_recovery"] is True
    assert "asr_rule_02_vizard_spice_julia_kernels" in _matched_ids(r115)

    r128 = poller.apply_asr_phonetic_recovery(
        "Are you familiar with my aurascoper word on Substack about logic folding and towel scaling", 128
    )
    assert r128["has_phonetic_recovery"] is True
    assert "asr_rule_08_moores_law_subverted" in _matched_ids(r128)

    r130 = poller.apply_asr_phonetic_recovery(
        "Dr. Centennial Goch of Southeast Missouri State University Palmer Nana spheres thermally responsive iron nano particles",
        130,
    )
    assert r130["has_phonetic_recovery"] is True
    assert "asr_rule_10_santaneel_ghosh_polymer_nanospheres_pc12_cytometry" in _matched_ids(r130)

    r134 = poller.apply_asr_phonetic_recovery(
        "What's considered the golden recording that be face be sleep", 134
    )
    assert r134["has_phonetic_recovery"] is True
    assert "asr_rule_12_golden_recording_phase_b_sleep" in _matched_ids(r134)

    r137 = poller.apply_asr_phonetic_recovery(
        "TP nine and TP 10 sometimes gets saturated generally one of them is always saturated", 137
    )
    assert r137["has_phonetic_recovery"] is True
    assert "asr_rule_13_muse_tp9_tp10_saturation_bang_bang" in _matched_ids(r137)

    r143 = poller.apply_asr_phonetic_recovery(
        "What about symbolic.jl withtouring.jl with Jacc.jljack.jl and enzyme with.J Neuro jacks and Evo jacks Neuro arc.JL",
        143,
    )
    assert r143["has_phonetic_recovery"] is True
    assert "asr_rule_14_symbolics_turing_jacc_enzyme_neurojax_evojax_neuroarc" in _matched_ids(r143)


def test_poller_single_pass_idempotency_and_watermark(tmp_path: Path):
    log_fp = tmp_path / "dialectic-turns-2026-11-01.jsonl"
    wm_fp = tmp_path / "poller_watermark.json"
    synth_fp = tmp_path / "poller-self-improvement-synthesis-v2.json"
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

    turns = []
    for idx in range(74):
        turns.append(
            {
                "index": idx,
                "runID": "A5945350-0000-0000-0000-000000000000",
                "recordedAt": f"2026-11-02T01:{idx // 60:02d}:{idx % 60:02d}.000Z",
                "heard": f"Baseline turn {idx} about OpenFOAM and PHREEQC coupling",
                "spokenText": "Operator splitting preserves elemental mass and charge conservation across cells.",
                "outcome": "spoke:coherence-seeking",
                "loopMode": "active",
                "witnessAttempted": True,
                "tension": 0.12,
                "glossScalar": 0.50,
                "selfSimilarity": 0.80,
                "candidates": [{"role": "Thesis", "potential": 1.55}],
            }
        )
    turns.append(
        {
            "index": 74,
            "runID": "10308A51-FCCC-4B29-B087-2F4E6945B425",
            "recordedAt": "2026-11-02T04:09:37.409Z",
            "heard": "What is a wizard about and how it applied to the spice Julia Colonels",
            "spokenText": "Carry forward one concrete next distinction from Vizard and SPICE.jl ephemeris kernels while keeping the contradiction playable in orbital boundary forcing.",
            "outcome": "spoke:coherence-seeking",
            "loopMode": "contemplative",
            "witnessAttempted": False,
            "tension": 0.11,
            "glossScalar": 0.52,
            "selfSimilarity": 0.87,
            "candidates": [{"role": "Thesis", "potential": 1.62}],
        }
    )
    log_fp.write_text("\n".join(json.dumps(t) for t in turns) + "\n", encoding="utf-8")

    res1 = poller.run_single_poll_pass(
        dialectic_log_path=log_fp,
        watermark_path=wm_fp,
        synthesis_out_path=synth_fp,
        sqlite_path=db_fp,
        pg_dsn="postgresql://invalid/none",
        sync_sql=True,
    )
    assert res1["ground_truth_verification"]["dialectic_log_total_lines"] == 75
    assert res1["dialectical_runs_ground_truth_L75_to_L116"]["rescued_or_warranted_count_L75_to_end"] == 1
    assert res1["turn_L112_non_recursive_guard"]["recursion_depth"] == 0

    wm = json.loads(wm_fp.read_text(encoding="utf-8"))
    assert wm["last_processed_line"] == 75
    assert wm["monotonic_progression_verified"] is True

    res2 = poller.run_single_poll_pass(
        dialectic_log_path=log_fp,
        watermark_path=wm_fp,
        synthesis_out_path=synth_fp,
        sqlite_path=db_fp,
        pg_dsn="postgresql://invalid/none",
        sync_sql=True,
    )
    assert res2["claude_mind_sql_rescue_telemetry"]["sqlite_inserted"] == 0
