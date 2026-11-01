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

    forbidden_private = {"uncle tom", "ellen wan", "andrew hoffman"}
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
    assert len(data["files"]) == 6

    for entry in data["files"]:
        for rel_path in entry["repo_paths"]:
            fp = REPO_ROOT / rel_path
            assert fp.exists(), f"Missing synchronized log fixture: {rel_path}"
            content_bytes = fp.read_bytes()
            sha = hashlib.sha256(content_bytes).hexdigest()
            assert sha == entry["repo_sanitized_sha256"]
            text = content_bytes.decode("utf-8")
            assert "\u2014" not in text and "\u2013" not in text
            lines = [ln for ln in text.splitlines() if ln.strip()]
            assert len(lines) == entry["repo_lines"]
            # Validate first and last JSONL record
            json.loads(lines[0])
            json.loads(lines[-1])
