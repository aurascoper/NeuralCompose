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
    assert len(poller.ASR_PHONETIC_RECOVERY_DICTIONARY) >= 14

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

    r147 = poller.apply_asr_phonetic_recovery(
        "How did the spice kernels and Vasilis timelines with M7 mission clocks integrate with",
        147,
    )
    assert r147["has_phonetic_recovery"] is True
    assert "asr_rule_02_vizard_spice_julia_kernels" in _matched_ids(r147)
    assert "asr_rule_03_basilisk_space_exploration_software" in _matched_ids(r147)

    r151 = poller.apply_asr_phonetic_recovery(
        "Basilisk is an open source Astro dynamic simulation framework developed by the university of Colorado's ABS lab in LA ASP la",
        151,
    )
    assert r151["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in _matched_ids(r151)

    r153 = poller.apply_asr_phonetic_recovery(
        "Basilisk supports faster than real time spacecraft simulations including reputable Monte Carlo runs hardware in the loop and complex guidance control research all this could be relevant to Nutronix research and open MC engineering simulation",
        153,
    )
    assert r153["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in _matched_ids(r153)

    r154 = poller.apply_asr_phonetic_recovery(
        "A standalone visualization tool called wizard based on the unity engine can display the spacecraft local planets sensors and actuators and 3-D",
        154,
    )
    assert r154["has_phonetic_recovery"] is True
    assert "asr_rule_02_vizard_spice_julia_kernels" in _matched_ids(r154)

    r156 = poller.apply_asr_phonetic_recovery(
        "Sea spice itself returns to KM and KM over S and nothing and read me claims a conversion so treat spy.jail output as KM until you check SPKPOS on a known body yourself",
        156,
    )
    assert r156["has_phonetic_recovery"] is True
    assert "asr_rule_02_vizard_spice_julia_kernels" in _matched_ids(r156)


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
    base_content = "\n".join(json.dumps(t) for t in turns) + "\n"
    log_fp.write_text(base_content, encoding="utf-8")

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

    # Simulate TelemetryLogger.swift mid-flush writing an incomplete 76th JSONL line at EOF
    log_fp.write_text(base_content + '{"index": 75, "runID": "1824FBDB", "heard": "partial mid-flush', encoding="utf-8")
    res_mid_flush = poller.run_single_poll_pass(
        dialectic_log_path=log_fp,
        watermark_path=wm_fp,
        synthesis_out_path=synth_fp,
        sqlite_path=db_fp,
        pg_dsn="postgresql://invalid/none",
        sync_sql=True,
    )
    assert res_mid_flush["ground_truth_verification"]["dialectic_log_total_lines"] == 75
    wm_mid = json.loads(wm_fp.read_text(encoding="utf-8"))
    assert wm_mid["last_processed_line"] == 75
    assert wm_mid["monotonic_progression_verified"] is True

    # Complete the 76th JSONL line and verify the next poll pass advances watermark to 76
    turn76 = {
        "index": 75,
        "runID": "1824FBDB-C680-4103-B25D-98298A60D6E8",
        "recordedAt": "2026-11-02T05:53:47.089Z",
        "heard": "A standalone visualization tool called wizard based on the unity engine can display the spacecraft local planets sensors and actuators and 3-D",
        "spokenText": "Vizard renders spacecraft, local planets, sensor cones, and actuator gimbals in Unity 3D over ZeroMQ Protobuf streams from Basilisk.",
        "outcome": "spoke:coherence-seeking",
        "loopMode": "reflective",
        "witnessAttempted": True,
        "tension": 0.08,
        "glossScalar": 0.42,
        "selfSimilarity": 0.84,
        "candidates": [{"role": "Thesis", "potential": 1.60}],
    }
    log_fp.write_text(base_content + json.dumps(turn76) + "\n", encoding="utf-8")
    res_flushed = poller.run_single_poll_pass(
        dialectic_log_path=log_fp,
        watermark_path=wm_fp,
        synthesis_out_path=synth_fp,
        sqlite_path=db_fp,
        pg_dsn="postgresql://invalid/none",
        sync_sql=True,
    )
    assert res_flushed["ground_truth_verification"]["dialectic_log_total_lines"] == 76
    assert res_flushed["dialectical_runs_ground_truth_L75_to_L116"]["rescued_or_warranted_count_L75_to_end"] == 2
    wm_flushed = json.loads(wm_fp.read_text(encoding="utf-8"))
    assert wm_flushed["last_processed_line"] == 76


def test_rollover_2026_11_02_and_basilisk_m7_verified_audit():
    # Verify PII redaction scrubs Hunter, Kendra, and Brett
    scrubbed = poller._sanitize_dashes("Hello Hunter and Kendra and Brett on Hunter's MacBook Air")
    assert "hunter" not in scrubbed.lower()
    assert "kendra" not in scrubbed.lower()
    assert "brett" not in scrubbed.lower()
    assert "[REDACTED_PII]" in scrubbed

    # Verify 2026-11-02 L1..L11 ASR phonetic recoveries
    rec_l1 = poller.apply_asr_phonetic_recovery(
        "In velocities by one E3 2M over S at the boundary and carry the IAU frame DCM separately", 157
    )
    assert rec_l1["has_phonetic_recovery"] is True

    rec_l2 = poller.apply_asr_phonetic_recovery(
        "Is pro factor in this do the conversion and exactly one function with a unit test against a basis generated state for the same epoch", 158
    )
    assert rec_l2["has_phonetic_recovery"] is True

    rec_l4 = poller.apply_asr_phonetic_recovery(
        "Help me also instruct Antigravity Gemini for argon to orchestrate a sub agent for the open foam version", 160
    )
    assert rec_l4["has_phonetic_recovery"] is True

    rec_l8 = poller.apply_asr_phonetic_recovery(
        "So again on the Matlab categories we have cogeneration and simulant product family and simulator link and Simca electrical", 164
    )
    assert rec_l8["has_phonetic_recovery"] is True

    rec_l14 = poller.apply_asr_phonetic_recovery(
        "What is it floats and ants that are decimals", 170
    )
    assert rec_l14["has_phonetic_recovery"] is True
    assert "floats and ints" in (rec_l14["recovered_canonical_summary"] or "")

    rec_l15 = poller.apply_asr_phonetic_recovery(
        "Yeah that's problematic I mean I have a problem with your prophecy and that's OK", 171
    )
    assert rec_l15["has_phonetic_recovery"] is True

    rec_l16 = poller.apply_asr_phonetic_recovery(
        "Yeah I'm I just that's lost in translation on me because it's saying things like M71M8 I think you mean to say in 7.1 as a header versus a float or ant that classification in your metacognition", 172
    )
    assert rec_l16["has_phonetic_recovery"] is True

    rec_l18 = poller.apply_asr_phonetic_recovery(
        "What about selfish gene ancestral reconstruction", 174
    )
    assert rec_l18["has_phonetic_recovery"] is True

    rec_l19 = poller.apply_asr_phonetic_recovery(
        "Yeah I may be a little misguided and I think Nathaniel Confort might also be misguided as", 175
    )
    assert rec_l19["has_phonetic_recovery"] is True
    assert "Nathaniel Comfort" in (rec_l19["recovered_canonical_summary"] or "")

    rec_l20 = poller.apply_asr_phonetic_recovery(
        "Non-recursive self improvements for the Oklo viewer and Matt lab and basil skin you know those pipelines with lizard and open foam", 176
    )
    assert rec_l20["has_phonetic_recovery"] is True
    rule_ids_l20 = {r["rule_id"] for r in rec_l20["matched_rules"]}
    assert "asr_rule_01_viral_arc_capsid_openfoam_pymol_chimerax" in rule_ids_l20
    assert "asr_rule_02_vizard_spice_julia_kernels" in rule_ids_l20
    assert "asr_rule_03_basilisk_space_exploration_software" in rule_ids_l20

    rec_l21 = poller.apply_asr_phonetic_recovery(
        "How would we integrate of open foam in pH REEQC and flow cytometry pipeline that we already have set up in Julia onto Matt lab now that it's open for Antigravity to do so you can command them", 177
    )
    assert rec_l21["has_phonetic_recovery"] is True
    rule_ids_l21 = {r["rule_id"] for r in rec_l21["matched_rules"]}
    assert "asr_rule_01_viral_arc_capsid_openfoam_pymol_chimerax" in rule_ids_l21
    assert "asr_rule_03_basilisk_space_exploration_software" in rule_ids_l21

    rec_alara = poller.apply_asr_phonetic_recovery(
        "so we need to have you and neural compose working in MATLAB ASAP and ALARA when it comes to health physics hippocratisms", 178
    )
    assert rec_alara["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_alara["matched_rules"]}

    rec_l22 = poller.apply_asr_phonetic_recovery("Orderbook and balance engine", 178)
    assert rec_l22["has_phonetic_recovery"] is True

    rec_l23 = poller.apply_asr_phonetic_recovery(
        "The hyper liquid account is now funded with $150 approximately of USDC", 179
    )
    assert rec_l23["has_phonetic_recovery"] is True
    assert "Hyperliquid" in (rec_l23["recovered_canonical_summary"] or "")

    rec_l24 = poller.apply_asr_phonetic_recovery(
        "Write this other is a potentially MEXC6 boundary execution and yield control center that's staking $51", 180
    )
    assert rec_l24["has_phonetic_recovery"] is True
    assert "MEXC" in (rec_l24["recovered_canonical_summary"] or "")

    rec_l25 = poller.apply_asr_phonetic_recovery("What should they be for each", 181)
    assert rec_l25["has_phonetic_recovery"] is True

    rec_l28 = poller.apply_asr_phonetic_recovery(
        "Why isn't Antigravity opening up the Matlab fixture with NeuralCompose", 184
    )
    assert rec_l28["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l28["matched_rules"]}

    rec_l29 = poller.apply_asr_phonetic_recovery(
        "What wizard interactive visualization should we try to spec and verify between open foam bass mat labs file formats",
        185,
    )
    assert rec_l29["has_phonetic_recovery"] is True
    rule_ids_l29 = {r["rule_id"] for r in rec_l29["matched_rules"]}
    assert "asr_rule_01_viral_arc_capsid_openfoam_pymol_chimerax" in rule_ids_l29
    assert "asr_rule_02_vizard_spice_julia_kernels" in rule_ids_l29
    assert "asr_rule_03_basilisk_space_exploration_software" in rule_ids_l29

    rec_l30 = poller.apply_asr_phonetic_recovery(
        "So how do we make sure our swarm is doing this", 186
    )
    assert rec_l30["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l30["matched_rules"]}

    rec_l31 = poller.apply_asr_phonetic_recovery(
        "How does it work with the last two prompts coming to one", 187
    )
    assert rec_l31["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l31["matched_rules"]}

    rec_l32 = poller.apply_asr_phonetic_recovery(
        "Health physics relevant for open MC", 188
    )
    assert rec_l32["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l32["matched_rules"]}

    rec_l33 = poller.apply_asr_phonetic_recovery(
        "Yeah I'd like to be able to make pedagogy and bio feedback mechanism or at home learning you use research reactor in Columbia Missouri",
        189,
    )
    assert rec_l33["has_phonetic_recovery"] is True
    assert "MURR" in (rec_l33["recovered_canonical_summary"] or "")

    rec_l34 = poller.apply_asr_phonetic_recovery(
        "I have to forget about you know why can't we prose and more think about", 190
    )
    assert rec_l34["has_phonetic_recovery"] is True
    assert "Neurospora crassa" in (rec_l34["recovered_canonical_summary"] or "")

    rec_l35 = poller.apply_asr_phonetic_recovery(
        "Will need to update so first we have to clear about 75 to 125 GB of SSD on the macOS to update the Mac 27.2 S",
        191,
    )
    assert rec_l35["has_phonetic_recovery"] is True
    rule_ids_l35 = {r["rule_id"] for r in rec_l35["matched_rules"]}
    assert "asr_rule_14_symbolics_turing_jacc_enzyme_neurojax_evojax_neuroarc" in rule_ids_l35
    assert "asr_rule_03_basilisk_space_exploration_software" not in rule_ids_l35

    rec_l36 = poller.apply_asr_phonetic_recovery(
        "We need to scope the toolbox kits you know simulate DSP Simca electrical", 192
    )
    assert rec_l36["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l36["matched_rules"]}

    rec_l37 = poller.apply_asr_phonetic_recovery(
        "Performance analyzer TET monitor application compiler board set up and desktop real time", 193
    )
    assert rec_l37["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l37["matched_rules"]}

    rec_l38 = poller.apply_asr_phonetic_recovery(
        "Should we spec and scope the simulate DSP system toolbox Seca and Seca electrical categories and compartments of the visualization and wizard",
        194,
    )
    assert rec_l38["has_phonetic_recovery"] is True
    rule_ids_l38 = {r["rule_id"] for r in rec_l38["matched_rules"]}
    assert "asr_rule_02_vizard_spice_julia_kernels" in rule_ids_l38
    assert "asr_rule_03_basilisk_space_exploration_software" in rule_ids_l38

    rec_l39 = poller.apply_asr_phonetic_recovery(
        "Do you know much about the evidence bundle manifest.Jason as an alpha fold analysis", 195
    )
    assert rec_l39["has_phonetic_recovery"] is True
    rule_ids_l39 = {r["rule_id"] for r in rec_l39["matched_rules"]}
    assert "asr_rule_01_viral_arc_capsid_openfoam_pymol_chimerax" in rule_ids_l39
    assert "asr_rule_03_basilisk_space_exploration_software" not in rule_ids_l39

    rec_l40 = poller.apply_asr_phonetic_recovery(
        "So should the small modular bio reactors.JL incorporate do symmetry", 196
    )
    assert rec_l40["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l40["matched_rules"]}

    rec_l41 = poller.apply_asr_phonetic_recovery(
        "Maybe we also need to have a NeuralCompose Google play android app with Colin and Rust type script swift and iOS to promote wireless de bugging and send a link or simulation software running on macOS 27.2",
        197,
    )
    assert rec_l41["has_phonetic_recovery"] is True
    assert "asr_rule_14_symbolics_turing_jacc_enzyme_neurojax_evojax_neuroarc" in {r["rule_id"] for r in rec_l41["matched_rules"]}

    rec_l42 = poller.apply_asr_phonetic_recovery(
        "Yeah we just need something to do with model context protocol because this memory stuff is getting out of hand and out of memory",
        198,
    )
    assert rec_l42["has_phonetic_recovery"] is True
    assert "asr_rule_08_moores_law_subverted" in {r["rule_id"] for r in rec_l42["matched_rules"]}

    rec_l45 = poller.apply_asr_phonetic_recovery(
        "My friends application Brett the core of biofilms will be applying for the essential duties of the materials research technician that that is just now being established specimen preparation",
        201,
    )
    assert rec_l45["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l45["matched_rules"]}

    rec_l46 = poller.apply_asr_phonetic_recovery(
        "Compacting and salt and consolidating memory for essential duties", 202
    )
    assert rec_l46["has_phonetic_recovery"] is True
    assert "asr_rule_03_basilisk_space_exploration_software" in {r["rule_id"] for r in rec_l46["matched_rules"]}

    alara_rep = poller.evaluate_matlab_alara_hippocratism_gate()
    assert alara_rep["matlab_bridge_script"].endswith("/Scripts/matlab_alara_bridge.m")
    assert alara_rep["smbr_matlab_r2026b_verification_receipt"]["all_checks_passed"] is True
    assert alara_rep["neuralcompose_matlab_fixtures"]["receipt_present"] is True
    assert alara_rep["neuralcompose_matlab_fixtures"]["mat_v7_present"] is True
    assert alara_rep["neuralcompose_matlab_fixtures"]["mat_v73_hdf5_present"] is True
    nc_spec = alara_rep["neurospora_crassa_matlab_r2026b_4_block_state_spec"]
    assert nc_spec["block_1_frq_wc1_wc2_circadian_oscillator"]["states"] == ["M_frq", "F_c", "F_n", "phi(t)"]
    assert nc_spec["block_2_syncytial_hyphal_streaming_and_woronin_hex1"]["anastomosis_cycle_rank_beta_1_min"] == 1
    assert nc_spec["block_2_syncytial_hyphal_streaming_and_woronin_hex1"]["beta_1_verified"] == 3
    assert nc_spec["block_3_eight_chamber_vogels_medium_simscape_phreeqc_hydraulics"]["chamber_count"] == 8
    assert nc_spec["block_3_eight_chamber_vogels_medium_simscape_phreeqc_hydraulics"]["phreeqc_pH"] == 5.80
    assert nc_spec["block_3_eight_chamber_vogels_medium_simscape_phreeqc_hydraulics"]["phreeqc_pe"] == 6.40
    assert nc_spec["block_4_dhn_melanin_neurosporaxanthin_alara_point_kernel_shielding"]["closed_loop_actuators"] == [
        "u_valve(t)",
        "z_shield(t)",
        "Phi_light(t)",
    ]
    assert len(alara_rep["matlab_reactor_pools_and_biofilms_coordination"]["four_pool_biofilm_cascade"]) == 4
    assert alara_rep["controls_fixture_and_adaptor_schematic"]["control_loop_stable"] is True
    assert (
        alara_rep["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"].get("mat_v7_magic_valid")
        or alara_rep["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"].get("mat_v7_magic_header_valid")
    ) is True
    assert alara_rep["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v73_hdf5_magic_valid"] is True
    assert alara_rep["controls_fixture_and_adaptor_schematic"]["displacement_pole_collar_signal_source"]["beta_1_collar_cycle_rank"] == 2
    assert alara_rep["controls_fixture_and_adaptor_schematic"]["openfoam_basilisk_matlab_roundtrip_L29"]["roundtrip_beta1_invariant"] is True
    assert alara_rep["controls_fixture_and_adaptor_schematic"]["biconnected_swarm_verification_L30"]["beta_1_swarm_verification_cycles"] == 2
    synth_models = [s["model"] for s in alara_rep["multica_synthetic_warrant_sessions"]]
    assert synth_models == ["claude-sonnet-5", "claude-sonnet-5-5", "claude-haiku-4-5"]
    assert alara_rep["acyclic_tarjan_bridge"]["is_acyclic_dag"] is True
    assert alara_rep["acyclic_tarjan_bridge"]["recursion_depth"] == 0
    assert alara_rep["acyclic_tarjan_bridge"]["phreeqc_pH"] == 5.80
    assert alara_rep["acyclic_tarjan_bridge"]["phreeqc_pe"] == 6.40
    assert alara_rep["health_physics_alara_gate"]["alara_compliant"] is True
    assert alara_rep["hippocratism_primum_non_nocere_gate"]["primum_non_nocere_verified"] is True

    # Verify synthesis-v2 JSON includes basilisk_m7_planetary_reference_verified_audit and utc_midnight_rollover_2026_11_02_audit
    repo_synth = Path(__file__).resolve().parents[2] / "InteractionLogs" / "poller-self-improvement-synthesis-v2.json"
    doc_synth = poller.DEFAULT_SYNTHESIS_OUT
    candidate_paths = [p for p in [repo_synth, doc_synth] if p.exists()]
    assert candidate_paths, f"Neither repo_synth ({repo_synth}) nor doc_synth ({doc_synth}) found on disk"
    if repo_synth.exists() and doc_synth.exists():
        synth_data_repo = json.loads(repo_synth.read_text(encoding="utf-8"))
        synth_data_doc = json.loads(doc_synth.read_text(encoding="utf-8"))
        lines_repo = synth_data_repo.get("utc_midnight_rollover_2026_11_02_audit", {}).get("total_lines_in_file", 0)
        lines_doc = synth_data_doc.get("utc_midnight_rollover_2026_11_02_audit", {}).get("total_lines_in_file", 0)
        if lines_doc > lines_repo:
            poller._write_and_mirror(repo_synth, doc_synth.read_text(encoding="utf-8"), mirror_to_repo=False)
            synth_data = synth_data_doc
        else:
            synth_data = synth_data_repo
    elif repo_synth.exists():
        synth_data = json.loads(repo_synth.read_text(encoding="utf-8"))
    else:
        synth_data = json.loads(doc_synth.read_text(encoding="utf-8"))
    assert "basilisk_m7_planetary_reference_verified_audit" in synth_data
    audit = synth_data["basilisk_m7_planetary_reference_verified_audit"]
    assert len(audit["verified_claims_banked"]["m7_budget_closure_invariant_7_criteria"]) == 7
    assert "unverified_not_banked until spkpos is checked on a known body" in audit["unverified_claims_gated"]["status"]
    assert "utc_midnight_rollover_2026_11_02_audit" in synth_data
    assert synth_data["utc_midnight_rollover_2026_11_02_audit"]["total_lines_in_file"] >= 46
    assert "matlab_r2026b_alara_hippocratism_gate" in synth_data
    assert synth_data["matlab_r2026b_alara_hippocratism_gate"]["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v73_hdf5_magic_valid"] is True


def test_matlab_alara_gate_rejects_truncated_mat_v73_and_honors_smbr_root(tmp_path: Path, monkeypatch) -> None:
    fake_smbr = tmp_path / "SmallModularBioReactors.jl"
    fix_dir = fake_smbr / "matlab_fixtures"
    fix_dir.mkdir(parents=True)

    (fix_dir / "m7_matlab_r2026b_verification_receipt.json").write_text(
        json.dumps({"all_checks_passed": True, "mat_v7_and_v73_hdf5_saved": True}),
        encoding="utf-8",
    )
    (fix_dir / "m7_multiscale_3d_eda_fixture_v7.mat").write_bytes(b"MATLAB 5.0 MAT-file" + b"\x00" * 64)
    # Truncated MAT v7.3 (< 520 bytes)
    (fix_dir / "m7_multiscale_3d_eda_fixture_v73.mat").write_bytes(b"MATLAB 7.3 MAT-file" + b"\x00" * 100)

    monkeypatch.setenv("SMBR_ROOT", str(fake_smbr))
    rep = poller.evaluate_matlab_alara_hippocratism_gate()
    coherence = rep["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]
    assert coherence["mat_v7_magic_valid"] is True
    assert coherence["mat_v73_hdf5_magic_valid"] is False
    assert rep["smbr_matlab_r2026b_verification_receipt"]["mat_v7_and_v73_hdf5_saved"] is False
    assert rep["smbr_matlab_r2026b_verification_receipt"]["all_checks_passed"] is False

    # Valid MAT v7.3 HDF5 superblock at offset 512, but corrupted MAT v7 header
    (fix_dir / "m7_multiscale_3d_eda_fixture_v73.mat").write_bytes(b"MATLAB 7.3 MAT-file".ljust(512, b"\x00") + b"\x89HDF\r\n\x1a\n")
    (fix_dir / "m7_multiscale_3d_eda_fixture_v7.mat").write_bytes(b"CORRUPTED_MAT_V7___" + b"\x00" * 64)
    rep_bad_v7 = poller.evaluate_matlab_alara_hippocratism_gate()
    coherence_bad_v7 = rep_bad_v7["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]
    assert coherence_bad_v7["mat_v7_magic_valid"] is False
    assert coherence_bad_v7["mat_v73_hdf5_magic_valid"] is True
    assert rep_bad_v7["smbr_matlab_r2026b_verification_receipt"]["all_checks_passed"] is False

    # Both MAT v7 and MAT v7.3 magic bytes valid, but receipt reports all_checks_passed=False
    (fix_dir / "m7_multiscale_3d_eda_fixture_v7.mat").write_bytes(b"MATLAB 5.0 MAT-file" + b"\x00" * 64)
    (fix_dir / "m7_matlab_r2026b_verification_receipt.json").write_text(
        json.dumps({"all_checks_passed": False, "mat_v7_and_v73_hdf5_saved": True}),
        encoding="utf-8",
    )
    rep_failed_rec = poller.evaluate_matlab_alara_hippocratism_gate()
    assert rep_failed_rec["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v7_magic_valid"] is True
    assert rep_failed_rec["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v73_hdf5_magic_valid"] is True
    assert rep_failed_rec["smbr_matlab_r2026b_verification_receipt"]["mat_v7_and_v73_hdf5_saved"] is True
    assert rep_failed_rec["smbr_matlab_r2026b_verification_receipt"]["all_checks_passed"] is False

    # Valid HDF5 signature at offset 512, but corrupted MAT v7.3 ASCII preamble at offset 0
    (fix_dir / "m7_matlab_r2026b_verification_receipt.json").write_text(
        json.dumps({"all_checks_passed": True, "mat_v7_and_v73_hdf5_saved": True}),
        encoding="utf-8",
    )
    (fix_dir / "m7_multiscale_3d_eda_fixture_v73.mat").write_bytes(
        b"CORRUPTED_MAT_V73__".ljust(512, b"\x00") + b"\x89HDF\r\n\x1a\n"
    )
    rep_bad_v73_preamble = poller.evaluate_matlab_alara_hippocratism_gate()
    assert rep_bad_v73_preamble["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v7_magic_valid"] is True
    assert rep_bad_v73_preamble["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v73_hdf5_magic_valid"] is False
    assert rep_bad_v73_preamble["smbr_matlab_r2026b_verification_receipt"]["mat_v7_and_v73_hdf5_saved"] is False
    assert rep_bad_v73_preamble["smbr_matlab_r2026b_verification_receipt"]["all_checks_passed"] is False

    # Restore valid MAT v7.3 bytes, but write malformed JSON to receipt
    (fix_dir / "m7_multiscale_3d_eda_fixture_v73.mat").write_bytes(
        b"MATLAB 7.3 MAT-file".ljust(512, b"\x00") + b"\x89HDF\r\n\x1a\n"
    )
    (fix_dir / "m7_matlab_r2026b_verification_receipt.json").write_text("{malformed_json", encoding="utf-8")
    rep_malformed_rec = poller.evaluate_matlab_alara_hippocratism_gate()
    assert rep_malformed_rec["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v7_magic_valid"] is True
    assert rep_malformed_rec["controls_fixture_and_adaptor_schematic"]["coherence_pole_mat_vs_json"]["mat_v73_hdf5_magic_valid"] is True
    assert rep_malformed_rec["smbr_matlab_r2026b_verification_receipt"]["mat_v7_and_v73_hdf5_saved"] is False
    assert rep_malformed_rec["smbr_matlab_r2026b_verification_receipt"]["all_checks_passed"] is False


def test_cross_repo_matlab_fixtures_sha256_parity_and_receipt_invariants() -> None:
    import hashlib

    smbr_fix_dir = Path("/Users/aurascoper/Developer/SmallModularBioReactors.jl/matlab_fixtures")
    nc_fix_dir = REPO_ROOT / "matlab_fixtures"
    m7_fix_dir = Path("/Users/aurascoper/Developer/M7Multiscale/matlab_fixtures")
    m7_wb_dir = Path("/Users/aurascoper/Developer/M7Multiscale/workbench")
    fcm_fix_dir = Path("/Users/aurascoper/Developer/flow-cytometry-model-bridge/matlab_fixtures")
    assert smbr_fix_dir.is_dir(), f"Missing SMBR matlab_fixtures dir: {smbr_fix_dir}"
    assert nc_fix_dir.is_dir(), f"Missing NeuralCompose matlab_fixtures dir: {nc_fix_dir}"
    assert m7_fix_dir.is_dir(), f"Missing M7Multiscale matlab_fixtures dir: {m7_fix_dir}"
    assert m7_wb_dir.is_dir(), f"Missing M7Multiscale workbench dir: {m7_wb_dir}"
    assert fcm_fix_dir.is_dir(), f"Missing flow-cytometry-model-bridge matlab_fixtures dir: {fcm_fix_dir}"

    synced_filenames = [
        "m7_3d_eda_and_simulink_bridge.m",
        "m7_open_interactive_workbench.m",
        "m7_matlab_r2026b_verification_receipt.json",
        "m7_reactor_alara_closed_loop.slx",
        "m7_multiscale_3d_eda_fixture.json",
        "m7_multiscale_3d_eda_fixture_v7.mat",
        "m7_multiscale_3d_eda_fixture_v73.mat",
        "m7_3d_eda_spatiotemporal_summary.png",
        "m7_3d_eda_multiscale_1920x1080.png",
    ]
    for fname in synced_filenames:
        smbr_fp = smbr_fix_dir / fname
        assert smbr_fp.is_file(), f"Missing in SmallModularBioReactors.jl: {smbr_fp}"
        smbr_bytes = smbr_fp.read_bytes()
        assert len(smbr_bytes) > 0
        smbr_sha256 = hashlib.sha256(smbr_bytes).hexdigest()
        for repo_label, target_dir in [
            ("NeuralCompose", nc_fix_dir),
            ("M7Multiscale/matlab_fixtures", m7_fix_dir),
            ("M7Multiscale/workbench", m7_wb_dir),
            ("flow-cytometry-model-bridge", fcm_fix_dir),
        ]:
            target_fp = target_dir / fname
            assert target_fp.is_file(), f"Missing in {repo_label}: {target_fp}"
            target_sha256 = hashlib.sha256(target_fp.read_bytes()).hexdigest()
            assert smbr_sha256 == target_sha256, (
                f"SHA-256 mismatch for {fname}: SMBR={smbr_sha256} vs {repo_label}={target_sha256}"
            )

    # Verify Simulink SLX OPC/ZIP container header and non-trivial size
    slx_bytes = (nc_fix_dir / "m7_reactor_alara_closed_loop.slx").read_bytes()
    assert slx_bytes[:4] == b"PK\x03\x04"
    assert len(slx_bytes) >= 10000

    # Verify receipt schema, 8-pool Neurospora 4-block state, and Context7/API sync
    receipt = json.loads((nc_fix_dir / "m7_matlab_r2026b_verification_receipt.json").read_text(encoding="utf-8"))
    assert receipt["all_checks_passed"] is True
    assert receipt["neurospora_4block_8pool_verified"] is True
    assert receipt["neurospora_n_pool_vogels_chambers"] == 8
    assert receipt["matlab_api_and_context7_sync"]["context7_cli_version"] == "0.8.2"
    assert len(receipt["matlab_api_and_context7_sync"]["context7_verified_library_ids"]) == 7
    assert "block_1_frq_wc1_wc2_circadian_oscillator" in receipt["neurospora_crassa_matlab_r2026b_4_block_state_spec"]
    assert "block_4_dhn_melanin_neurosporaxanthin_alara_point_kernel_shielding" in receipt["neurospora_crassa_matlab_r2026b_4_block_state_spec"]

    # Verify zero em-dashes and zero en-dashes across text fixtures and MATLAB scripts
    for txt_fp in [
        nc_fix_dir / "m7_3d_eda_and_simulink_bridge.m",
        nc_fix_dir / "m7_open_interactive_workbench.m",
        nc_fix_dir / "m7_matlab_r2026b_verification_receipt.json",
        nc_fix_dir / "m7_multiscale_3d_eda_fixture.json",
        REPO_ROOT / "Scripts" / "matlab_alara_bridge.m",
    ]:
        txt = txt_fp.read_text(encoding="utf-8")
        assert "\u2014" not in txt and "\u2013" not in txt, f"Found dash in {txt_fp}"


def test_l89_to_l103_actionable_insights_and_asr_phonetic_recoveries() -> None:
    # 1. Verify ASR phonetic recovery for L101-L103 raw heard tokens
    rec_101 = poller.apply_asr_phonetic_recovery(
        "CsgAmak2 and magnetite are three different mechanisms that we could consider.",
        257,
    )
    assert rec_101["has_phonetic_recovery"] is True
    assert "asr_rule_10_santaneel_ghosh_polymer_nanospheres_pc12_cytometry" in _matched_ids(rec_101)

    rec_102 = poller.apply_asr_phonetic_recovery(
        "Dr. Gosia's work with respect to the five-link conceptual census.",
        258,
    )
    assert rec_102["has_phonetic_recovery"] is True
    assert "asr_rule_10_santaneel_ghosh_polymer_nanospheres_pc12_cytometry" in _matched_ids(rec_102)

    rec_103 = poller.apply_asr_phonetic_recovery(
        "Magneta reception versus radiotropism in coupon research.",
        259,
    )
    assert rec_103["has_phonetic_recovery"] is True
    assert "asr_rule_10_santaneel_ghosh_polymer_nanospheres_pc12_cytometry" in _matched_ids(rec_103)

    # 2. Verify evaluate_l89_to_l103_actionable_insights structure and invariants
    mock_rollover = [{"line_number": ln} for ln in range(89, 104)]
    rep = poller.evaluate_l89_to_l103_actionable_insights(mock_rollover)
    assert rep["schema"] == "neuralcompose-l89-to-l103-actionable-insights-v1"
    assert rep["evaluated_turn_count_in_window"] == 15
    assert rep["all_l89_to_l103_gates_verified"] is True

    m2_m5 = rep["l89_to_l100_m2_to_m5_milestone_fixture_inheritance"]
    assert m2_m5["milestones_inheriting"] == ["M2", "M3", "M4", "M5"]
    assert m2_m5["fixture_conformance_test"] is True
    assert m2_m5["empirical_validation_status"] == "Incomplete"
    assert m2_m5["conformance_vs_empirical_separated"] is True
    assert m2_m5["census_vs_allow_list_separated"] is True

    l101 = rep["l101_pc12_mechanistic_competitors_and_endocytic_ensemble"]
    assert len(l101["competitors"]) == 3
    assert l101["three_distinct_organization_levels_verified"] is True
    assert l101["none_independently_proves_pc12_internalization"] is True
    assert l101["endocytic_route_probability_sum"] == 1.0
    assert l101["neurite_outgrowth_achievable_without_deep_endosomal_escape"] is True

    l102 = rep["l102_five_link_conceptual_census_chain"]
    assert len(l102["nodes"]) == 5
    assert l102["forward_assays_pinned_count"] == 4
    assert l102["feedback_edge_cycle"]["beta_1"] == 1
    assert l102["terminal_readout_specificity_gate"]["is_specific_differentiation"] is True
    assert l102["chain_closed_and_falsifiable"] is True

    l103 = rep["l103_coupled_receptor_assay_transferability_and_modality_falsifiability"]
    assert l103["modalities_compared"] == ["magnetoreception", "radiotropism"]
    assert len(l103["shared_four_stage_assay_scaffold"]) == 4
    assert l103["assay_scaffold_transferable"] is True
    assert l103["measurement_maturity_gap_vs_ontology_recognized"] is True
    assert l103["co_occurring_modalities_in_single_organism_supported"] is True
    assert l103["epistemic_verdict"] == "Incomplete"

