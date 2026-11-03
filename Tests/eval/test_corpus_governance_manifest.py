"""Tests for the Three-Tier Corpus Governance Manifest
(configs/corpus-governance-pre1931-pd-vocab-ham-v1.json),
VoiceProfile cold-vocabulary constraints, and synchronized 2026-11-01
InteractionLogs fixtures."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re

REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "configs" / "corpus-governance-pre1931-pd-vocab-ham-v1.json"
DOC_PATH = REPO_ROOT / "docs" / "architecture" / "corpus-governance-pre1931-pd-vocab-ham.md"
VOICE_PROFILE_PATH = REPO_ROOT / "Sources" / "BCICore" / "Composition" / "VoiceProfile.swift"


def test_corpus_governance_manifest_schema_and_tiers():
    assert MANIFEST_PATH.exists()
    assert DOC_PATH.exists()

    raw_json = MANIFEST_PATH.read_text()
    raw_doc = DOC_PATH.read_text()
    assert "\u2014" not in raw_json and "\u2013" not in raw_json
    assert "\u2014" not in raw_doc and "\u2013" not in raw_doc

    manifest = json.loads(raw_json)
    assert manifest["schema_version"] == "corpus-governance-pre1931-pd-vocab-ham-v1"
    tiers = manifest["tiers"]

    # Tier 1: Pre-1931 Public Domain
    t1 = tiers["pre_1931_public_domain"]
    assert t1["max_publication_year"] == 1930
    assert t1["full_text_prose_allowed"] is True
    req_fields = set(t1["required_provenance_fields"])
    for work in t1["canonical_seed_works"]:
        assert work["publication_year"] <= 1930
        assert req_fields.issubset(work.keys()), f"Missing required provenance fields in {work['work_id']}"
        assert len(work["sha256_digest"]) == 64

    # Tier 2: Post-1930 Vocabulary-Only
    t2 = tiers["vocabulary_only_modern"]
    assert t2["min_publication_year"] == 1931
    assert t2["full_text_prose_allowed"] is False
    assert t2["verbatim_sentence_ingestion_allowed"] is False

    # Tier 3: Local HAM Quarantined
    t3 = tiers["local_ham_quarantined"]
    disp = t3["disposition"]
    assert disp["eligible_for_encoder_training"] is False
    assert disp["eligible_for_science"] is False
    assert disp["development_only_permanent"] is True

    swift_gate_path, swift_gate_sym = t3["warrant_and_autoforget_gate"]["swift_gate"].split("::")
    swift_src = (REPO_ROOT / swift_gate_path).read_text()
    assert f"func {swift_gate_sym}" in swift_src


def test_voice_profile_cold_vocabulary_satisfies_tier2_constraints():
    manifest = json.loads(MANIFEST_PATH.read_text())
    t2 = manifest["tiers"]["vocabulary_only_modern"]
    max_tokens = t2["max_tokens_per_term"]
    max_chars = t2["max_chars_per_term"]

    vp_text = VOICE_PROFILE_PATH.read_text()
    block_match = re.search(
        r"public static let defaultRecognitionVocabulary:\s*\[String\]\s*=\s*\[(.*?)\]",
        vp_text,
        re.DOTALL,
    )
    assert block_match is not None
    terms = re.findall(r'"([^"]+)"', block_match.group(1))
    assert len(terms) >= 20

    forbidden_private = {"uncle tom", "ellen wan", "andrew hoffman", "hunter", "kendra"}
    for term in terms:
        assert "\u2014" not in term and "\u2013" not in term
        assert len(term) <= max_chars, f"Term exceeds {max_chars} chars: {term}"
        assert len(term.split()) <= max_tokens, f"Term exceeds {max_tokens} tokens: {term}"
        assert term.lower() not in forbidden_private, f"Private identifier in coldVocabulary: {term}"


def test_synchronized_interaction_logs_and_manifest_integrity():
    manifest_file = REPO_ROOT / "InteractionLogs" / "INTERACTION_LOGS_MANIFEST_2026-11-01.json"
    assert manifest_file.exists()
    raw_manifest = manifest_file.read_text()
    assert "\u2014" not in raw_manifest and "\u2013" not in raw_manifest

    data = json.loads(raw_manifest)
    assert data["eligible_for_science"] is False
    assert data["eligible_for_encoder_training"] is False
    files_obj = data["files"]
    assert len(files_obj) >= 6

    if isinstance(files_obj, dict):
        items = []
        for fname, meta in files_obj.items():
            if fname.startswith(("health-", "prosody-trace-", "spoken-trace-")):
                continue
            items.append((f"InteractionLogs/{fname}", meta))
    else:
        items = [
            (rel_path, entry)
            for entry in files_obj
            for rel_path in entry["repo_paths"]
            if not Path(rel_path).name.startswith(("health-", "prosody-trace-", "spoken-trace-"))
        ]

    for rel_path, entry in items:
        fp = REPO_ROOT / rel_path
        assert fp.exists(), f"Missing synchronized log fixture: {rel_path}"
        content_bytes = fp.read_bytes()
        assert b"\x00" not in content_bytes, f"NUL byte detected in {rel_path}"
        sha = hashlib.sha256(content_bytes).hexdigest()
        expected_sha = entry.get("sha256") or entry.get("repo_sanitized_sha256")
        assert sha == expected_sha, f"SHA mismatch for {rel_path}: {sha} != {expected_sha}"
        text = content_bytes.decode("utf-8")
        assert "\u2014" not in text and "\u2013" not in text
        lower_text = text.lower()
        for priv in ("kendra", "hunter", "uncle tom", "ellen wan", "andrew hoffman", "hunter's macbook", "hunter hunter"):
            assert priv not in lower_text, f"Unscrubbed private identifier {priv!r} in {rel_path}"
        raw_lines = text.splitlines()
        non_empty_lines = [ln for ln in raw_lines if ln.strip()]
        expected_lines = entry["lines"] if "lines" in entry else entry.get("repo_lines")
        assert len(raw_lines) == expected_lines, f"Line count mismatch for {rel_path}: {len(raw_lines)} != {expected_lines}"
        if rel_path.endswith(".jsonl"):
            assert len(non_empty_lines) == expected_lines
            json.loads(non_empty_lines[0])
            json.loads(non_empty_lines[-1])
        elif rel_path.endswith(".json"):
            json.loads(text)

    # Verify append-only corpus and prefix invariance on 2026-11-02 (28, 51, 73, 76, 87, 88, and current lines)
    f_1031 = (REPO_ROOT / "InteractionLogs" / "dialectic-turns-2026-10-31.jsonl").read_bytes()
    f_1101 = (REPO_ROOT / "InteractionLogs" / "dialectic-turns-2026-11-01.jsonl").read_bytes()
    f_1102 = (REPO_ROOT / "InteractionLogs" / "dialectic-turns-2026-11-02.jsonl").read_bytes()
    assert hashlib.sha256(f_1031).hexdigest() == "d6d1921f6cd02ca27fde497100462cb33475b7049d7b2712a10ec839f55de0d2"
    assert hashlib.sha256(f_1101).hexdigest() == "8e27c4784b265d77c8c16828fe98786d1d926849446ab4bf59ff2f720374ffe7"
    assert hashlib.sha256(f_1102[:100060]).hexdigest() == "a3966f7816eb7d4ee13d838bf2453146ed9e74c8952b1304acf57df53a221013"
    assert hashlib.sha256(f_1102[:175552]).hexdigest() == "4bed458a31ac5e5b549bb2b02afde1013cd1ef13dac2202adf5c06db8bbdb786"
    assert hashlib.sha256(f_1102[:228000]).hexdigest() == "fdf0ce09c3c75c1d5e9529cca223d5822ce8d91e925a504ad9c02fd7b38bf30f"
    assert hashlib.sha256(f_1102[:237030]).hexdigest() == "4ccc43665ebb7dfa8f098e0c306d3ca92f6763b0537571b7a4ed261ab90d5e8f"
    assert hashlib.sha256(f_1102[:259128]).hexdigest() == "f9369fa28e2ca5b486e8dfb6fe996b3e50b22df50ff92adeafa5ec51d73a5abf"
    assert hashlib.sha256(f_1102[:261800]).hexdigest() == "432ec1bc11e9da1f7bae2c93cdd4d1f5705f240cf8b13e65048ecdef1195be97"
    entry_1102 = files_obj["dialectic-turns-2026-11-02.jsonl"]
    assert hashlib.sha256(f_1102).hexdigest() == entry_1102["sha256"]
    n_1031 = len(f_1031.decode("utf-8").splitlines())
    n_1101 = len(f_1101.decode("utf-8").splitlines())
    n_1102 = len(f_1102.decode("utf-8").splitlines())
    assert (n_1031, n_1101) == (122, 156)
    assert n_1102 >= 88 and n_1102 == entry_1102["lines"]
    assert n_1031 + n_1101 + n_1102 == data["append_only_dialectic_corpus_summary"]["total_turns_across_3_files"]
