#!/usr/bin/env python3
"""Contract tests for Scripts/check_adr_references.py.

Standard library only — `unittest`, no pytest, no NumPy, no MLX. The checker
runs as a direct `python3` step in the Swift CI job before any Python job
exists, so its own tests must not acquire dependencies the gate does not have.

Two kinds of test here, deliberately separated:

  * synthetic fixtures build throwaway trees and prove the checker *can* fail.
    A gate whose only evidence is that it never complained is not a gate.
  * one live test runs against the real repository and asserts hard mode
    passes. That is the gate itself.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Iterable, Optional


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

import check_adr_references as checker  # noqa: E402


class _FixtureTree:
    """A throwaway repository tree with a controllable ADR registry."""

    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="adr-fixture-"))
        (self.root / checker.ADR_DIRECTORY).mkdir(parents=True)
        for directory in ("Sources", "Tests", "Scripts", "docs/reviews"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def adr(self, filename: str, heading: Optional[str] = None) -> None:
        """Write an ADR. `heading` defaults to one matching the filename."""
        if heading is None:
            number = filename.split("-")[1]
            heading = f"# ADR-{number}: Fixture decision"
        path = self.root / checker.ADR_DIRECTORY / filename
        path.write_text(f"{heading}\n\n**Status**: Accepted\n", encoding="utf-8")

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def codes(self, mode: str = "hard", severity: str = "error") -> list[str]:
        result = checker.audit_repository(root=self.root, mode=mode)
        findings = result.errors if severity == "error" else result.warnings
        return sorted(finding.code for finding in findings)


class ADRRegistryTests(unittest.TestCase):
    """Registry-level defects: duplicates, headings, filenames."""

    def setUp(self) -> None:
        self.tree = _FixtureTree()
        self.addCleanup(self.tree.cleanup)

    def test_clean_registry_passes(self) -> None:
        self.tree.adr("ADR-001-first.md")
        self.tree.adr("ADR-002-second.md")
        self.assertEqual(self.tree.codes(), [])

    def test_duplicate_number_fails_once_not_per_citation(self) -> None:
        """The registry defect is the root cause and is reported one time.

        Reproduces main's actual state: two accepted documents claiming
        ADR-004, with several citations that would each otherwise be reported
        ambiguous. One finding, not N.
        """
        self.tree.adr("ADR-004-privacy.md")
        self.tree.adr("ADR-004-embedding.md")
        self.tree.write("Sources/A.swift", "// see ADR-004 §3.1\n")
        self.tree.write("Sources/B.swift", "// see ADR-004 §3.5\n")
        self.tree.write("Tests/C.swift", "// see ADR-004\n")

        self.assertEqual(self.tree.codes(), ["ADR_DUPLICATE"])

    def test_filename_heading_mismatch_fails(self) -> None:
        self.tree.adr("ADR-005-mismatch.md", heading="# ADR-006: Wrong number")
        self.assertIn("ADR_HEADING_MISMATCH", self.tree.codes())

    def test_missing_heading_fails(self) -> None:
        path = self.tree.root / checker.ADR_DIRECTORY / "ADR-007-noheading.md"
        path.write_text("Some prose with no ADR heading.\n", encoding="utf-8")
        self.assertIn("ADR_HEADING_MISSING", self.tree.codes())

    def test_malformed_filename_fails(self) -> None:
        path = self.tree.root / checker.ADR_DIRECTORY / "ADR-8-short.md"
        path.write_text("# ADR-008: Short number\n", encoding="utf-8")
        self.assertIn("ADR_FILENAME_MALFORMED", self.tree.codes())


class ADRReferenceTests(unittest.TestCase):
    """Reference-level defects in normative roots."""

    def setUp(self) -> None:
        self.tree = _FixtureTree()
        self.addCleanup(self.tree.cleanup)
        self.tree.adr("ADR-001-first.md")

    def test_dangling_reference_fails(self) -> None:
        self.tree.write("Sources/A.swift", "// governed by ADR-042\n")
        self.assertEqual(self.tree.codes(), ["ADR_REFERENCE_MISSING"])

    def test_resolvable_reference_passes(self) -> None:
        self.tree.write("Sources/A.swift", "// governed by ADR-001 §2\n")
        self.assertEqual(self.tree.codes(), [])

    def test_malformed_reference_fails(self) -> None:
        for token in ("ADR-1", "ADR-01", "ADR-0001", "ADR001", "ADR_001"):
            with self.subTest(token=token):
                self.tree.write("Sources/A.swift", f"// see {token}\n")
                self.assertIn("ADR_REFERENCE_MALFORMED", self.tree.codes())

    def test_renamed_file_leaves_dangling_full_filename_reference(self) -> None:
        """The trap that a section-marked sed pass leaves behind.

        Rewriting `ADR-004 §3.5` everywhere still misses a markdown link whose
        target is the old *filename*. On the real repository this was
        `README.md` and `ROADMAP.md`.
        """
        self.tree.write(
            "docs/architecture/ROADMAP.md",
            "see [contract](decision-log/ADR-001-renamed-away.md)\n",
        )
        self.assertEqual(self.tree.codes(), ["ADR_FILENAME_REFERENCE_MISSING"])

    def test_forward_reference_to_unlanded_adr_fails(self) -> None:
        """A normative document may not cite a number that does not exist yet.

        Found by running the repair: a ROADMAP note announcing that "ADR-009 is
        reserved for generation-runtime semantics" fails the very gate it
        announces, because ADR-009 lands later with lane A. Reserved numbers
        must be described without emitting a canonical token.
        """
        self.tree.write(
            "docs/architecture/ROADMAP.md",
            "ADR-009 is reserved for the runtime that lands later.\n",
        )
        self.assertEqual(self.tree.codes(), ["ADR_REFERENCE_MISSING"])

        self.tree.write(
            "docs/architecture/ROADMAP.md",
            "The intervening number is reserved for the runtime.\n",
        )
        self.assertEqual(self.tree.codes(), [])


class ADRPolicyBoundaryTests(unittest.TestCase):
    """Numeric gaps are legal; history is not normative."""

    def setUp(self) -> None:
        self.tree = _FixtureTree()
        self.addCleanup(self.tree.cleanup)

    def test_numeric_gap_passes(self) -> None:
        """ADR-010 may exist while 009 is reserved for unlanded work."""
        self.tree.adr("ADR-008-eighth.md")
        self.tree.adr("ADR-010-tenth.md")
        self.tree.write("Sources/A.swift", "// see ADR-010 §1\n")
        self.assertEqual(self.tree.codes(), [])

    def test_historical_review_is_advisory_not_normative(self) -> None:
        """The exact contradiction this two-mode design exists to avoid.

        `docs/reviews/` legitimately names numbers that did not exist when the
        review was written. Requiring the gate both to exclude reviews and to
        fail because of them cannot be satisfied.
        """
        self.tree.adr("ADR-001-first.md")
        self.tree.write(
            "docs/reviews/code-review.md",
            "Renumber the later one to ADR-009+.\n",
        )

        self.assertEqual(self.tree.codes(mode="hard"), [])
        self.assertEqual(
            self.tree.codes(mode="all", severity="warning"),
            ["ADR_REFERENCE_MALFORMED"],
        )

    def test_advisory_mode_never_reports_errors(self) -> None:
        self.tree.adr("ADR-004-one.md")
        self.tree.adr("ADR-004-two.md")
        result = checker.audit_repository(root=self.tree.root, mode="advisory")
        self.assertEqual(result.errors, ())
        self.assertTrue(result.warnings)

    def test_checker_and_its_tests_are_excluded_from_hard_scan(self) -> None:
        """Otherwise this file's own synthetic tokens would fail the gate."""
        self.tree.adr("ADR-001-first.md")
        self.tree.write("Scripts/check_adr_references.py", "# ADR-999 ADR_001\n")
        self.tree.write("Tests/eval/test_adr_references.py", "# ADR-999\n")
        self.assertEqual(self.tree.codes(), [])


class LiveRepositoryTests(unittest.TestCase):
    """The gate itself, against the tree this test is running in."""

    def test_repository_passes_hard_mode(self) -> None:
        result = checker.audit_repository(root=REPOSITORY_ROOT, mode="hard")
        self.assertEqual(
            result.errors,
            (),
            "\n".join(
                f"{f.path}:{f.line or 0} [{f.code}] {f.message}"
                for f in result.errors
            ),
        )

    def test_decision_log_exists_and_is_non_empty(self) -> None:
        """Guards against a vacuous pass if the directory is ever moved."""
        adr_directory = REPOSITORY_ROOT / checker.ADR_DIRECTORY
        self.assertTrue(adr_directory.is_dir(), f"missing {checker.ADR_DIRECTORY}")
        self.assertTrue(
            list(adr_directory.glob("ADR-*.md")),
            "decision log contains no ADRs — the gate would pass trivially",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
