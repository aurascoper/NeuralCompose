#!/usr/bin/env python3
"""Contract tests for Scripts/check_ledger_references.py.

Standard library only — `unittest`, no pytest, no NumPy, no MLX. Same
constraint as test_adr_references.py: the checker runs as a direct `python3`
step in the Swift CI job, so its tests must not acquire dependencies the gate
does not have.

Same two kinds of test, deliberately separated:

  * synthetic fixtures build throwaway trees and prove the checker *can* fail.
    A gate whose only evidence is that it never complained is not a gate.
  * live tests run against the real repository and assert hard mode passes.

The shallow-clone tests are the load-bearing ones. actions/checkout defaults to
fetch-depth 1, and an unguarded existence check reports every historical pin as
missing — confidently and wrongly. Measured before the guard existed: a depth-1
checkout of this repository turned node 1's two real pins into two hard errors.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Optional


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "Scripts"))

import check_ledger_references as checker  # noqa: E402


def _git_available() -> bool:
    try:
        subprocess.run(["git", "--version"], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return True


class _FixtureTree:
    """A throwaway tree with a controllable EXPERIMENT_LEDGER."""

    def __init__(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="ledger-fixture-"))
        for directory in ("WorldModel", "docs/architecture", "Scripts"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)

    def cleanup(self) -> None:
        shutil.rmtree(self.root, ignore_errors=True)

    def ledger(self, body: str, relative: str = "WorldModel/EXPERIMENT_LEDGER.md") -> None:
        (self.root / relative).write_text(body, encoding="utf-8")

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def codes(self, mode: str = "hard") -> list[str]:
        result = checker.audit_repository(root=self.root, mode=mode)
        return [f.code for f in result.findings]


def _node(number: int, pin: str = "<pending>", title: str = "Fixture") -> str:
    return f"## {number} — {title} (2026-07-20, commit {pin})\n- Category: Benchmark\n"


class LedgerRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = _FixtureTree()
        self.addCleanup(self.tree.cleanup)

    def test_clean_ledger_passes(self) -> None:
        self.tree.ledger(_node(0) + _node(1))
        self.assertEqual(self.tree.codes(), [])

    def test_duplicate_node_number_fails(self) -> None:
        self.tree.ledger(_node(0) + _node(1) + _node(1))
        self.assertIn("LEDGER_NODE_DUPLICATE", self.tree.codes())

    def test_unpinned_heading_fails(self) -> None:
        self.tree.ledger("## 0 — Fixture with no pin at all\n")
        self.assertIn("LEDGER_NODE_UNPINNED", self.tree.codes())

    def test_pending_pin_is_allowed(self) -> None:
        self.tree.ledger(_node(0, pin="<pending>"))
        self.assertEqual(self.tree.codes(), [])

    def test_malformed_pin_fails(self) -> None:
        self.tree.ledger(_node(0, pin="sometime-later"))
        self.assertIn("LEDGER_NODE_PIN_MALFORMED", self.tree.codes())


class LedgerReferenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = _FixtureTree()
        self.addCleanup(self.tree.cleanup)
        self.tree.ledger(_node(0) + _node(1) + _node(2))

    def test_resolvable_bare_reference_passes(self) -> None:
        self.tree.write("docs/architecture/x.md", "As shown in node 2, the arm held.\n")
        self.assertEqual(self.tree.codes(), [])

    def test_dangling_bare_reference_fails(self) -> None:
        self.tree.write("docs/architecture/x.md", "As shown in node 99, the arm held.\n")
        self.assertIn("LEDGER_NODE_REFERENCE_MISSING", self.tree.codes())

    def test_qualified_foreign_namespace_passes(self) -> None:
        self.tree.write("docs/architecture/x.md", "Per dialectic node 99, log-compress.\n")
        self.assertEqual(self.tree.codes(), [])

    def test_unqualified_foreign_namespace_fails(self) -> None:
        """The exact defect found in the real ledger: 'node 33' with no namespace."""
        self.tree.write("docs/architecture/x.md", "Per node 33, log-compress.\n")
        self.assertIn("LEDGER_NODE_REFERENCE_MISSING", self.tree.codes())

    def test_ordinary_prose_before_node_is_not_a_namespace(self) -> None:
        """Regression: a denylist of English connectives produced 9 false
        positives out of 18 findings on the real ledger ('if node 33',
        'refutes node 12', 'across node 7'). Only the allowlist counts."""
        self.tree.write(
            "docs/architecture/x.md",
            "This refutes node 2, and across node 1 the same holds; symlog node 0 too.\n",
        )
        self.assertEqual(self.tree.codes(), [])

    def test_advisory_mode_never_reports_errors(self) -> None:
        self.tree.write("docs/architecture/x.md", "See node 99.\n")
        result = checker.audit_repository(root=self.tree.root, mode="advisory")
        self.assertTrue(result.findings)
        self.assertEqual(result.errors, ())


class ShallowCloneTests(unittest.TestCase):
    """A shallow checkout must never be reported as a missing commit.

    'We could not check' and 'it does not exist' are different claims, and
    conflating them turns every historical pin into a false hard failure under
    actions/checkout's default fetch-depth of 1.
    """

    def setUp(self) -> None:
        if not _git_available():
            self.skipTest("git unavailable")
        self.origin = Path(tempfile.mkdtemp(prefix="ledger-origin-"))
        self.addCleanup(shutil.rmtree, self.origin, ignore_errors=True)
        self._run(["git", "init", "-q", "-b", "main"], self.origin)
        self._run(["git", "config", "user.email", "t@example.invalid"], self.origin)
        self._run(["git", "config", "user.name", "T"], self.origin)

        (self.origin / "WorldModel").mkdir(parents=True, exist_ok=True)
        (self.origin / "seed.txt").write_text("seed\n", encoding="utf-8")
        self._run(["git", "add", "-A"], self.origin)
        self._run(["git", "commit", "-qm", "seed"], self.origin)
        self.old_sha = self._out(["git", "rev-parse", "HEAD"], self.origin)[:7]

        (self.origin / "WorldModel" / "EXPERIMENT_LEDGER.md").write_text(
            _node(0, pin=self.old_sha), encoding="utf-8")
        self._run(["git", "add", "-A"], self.origin)
        self._run(["git", "commit", "-qm", "ledger"], self.origin)

    @staticmethod
    def _run(cmd, cwd) -> None:
        subprocess.run(cmd, cwd=cwd, capture_output=True, check=True, timeout=30)

    @staticmethod
    def _out(cmd, cwd) -> str:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              check=True, timeout=30).stdout.strip()

    def test_full_clone_resolves_the_pin(self) -> None:
        self.assertFalse(checker._is_shallow(self.origin))
        result = checker.audit_repository(root=self.origin, mode="hard")
        self.assertEqual([f.code for f in result.findings], [])

    def test_shallow_clone_warns_instead_of_failing(self) -> None:
        shallow = Path(tempfile.mkdtemp(prefix="ledger-shallow-")) / "c"
        self.addCleanup(shutil.rmtree, shallow.parent, ignore_errors=True)
        subprocess.run(
            ["git", "clone", "-q", "--depth", "1", self.origin.as_uri(), str(shallow)],
            capture_output=True, check=True, timeout=60,
        )
        self.assertTrue(checker._is_shallow(shallow),
                        "fixture must actually be shallow or this proves nothing")

        result = checker.audit_repository(root=shallow, mode="hard")
        codes = [f.code for f in result.findings]
        self.assertIn("LEDGER_COMMIT_UNVERIFIABLE_SHALLOW", codes)
        self.assertNotIn("LEDGER_COMMIT_UNRESOLVABLE", codes)
        self.assertEqual(result.errors, (), "a shallow checkout must not fail the gate")

    def test_genuinely_missing_commit_still_fails_in_a_full_clone(self) -> None:
        """The other polarity: the guard must not disarm the check itself."""
        (self.origin / "WorldModel" / "EXPERIMENT_LEDGER.md").write_text(
            _node(0, pin="deadbee"), encoding="utf-8")
        result = checker.audit_repository(root=self.origin, mode="hard")
        codes = [f.code for f in result.findings]
        self.assertIn("LEDGER_COMMIT_UNRESOLVABLE", codes)
        self.assertTrue(result.errors)


class CommitMessageTests(unittest.TestCase):
    """The gap a file scanner structurally cannot cover."""

    def setUp(self) -> None:
        self.tree = _FixtureTree()
        self.addCleanup(self.tree.cleanup)
        self.tree.ledger(_node(0) + _node(1))
        self.message = self.tree.root / "MSG"

    def _codes(self, text: str) -> list[str]:
        self.message.write_text(text, encoding="utf-8")
        result = checker.audit_commit_message(
            self.tree.root, self.message, "error", check_commits=False)
        return [f.code for f in result.findings]

    def test_dangling_node_citation_fails(self) -> None:
        self.assertIn("LEDGER_NODE_REFERENCE_MISSING",
                      self._codes("fix: something\n\nPer node 99, this holds.\n"))

    def test_resolvable_node_citation_passes(self) -> None:
        self.assertEqual(self._codes("fix: something\n\nPer node 1, this holds.\n"), [])

    def test_git_comment_lines_are_ignored(self) -> None:
        """Lines starting with # are stripped by git before the commit exists,
        so flagging them would fail a commit on text that never lands."""
        self.assertEqual(self._codes("fix: x\n\n# Per node 99, ignore me.\n"), [])


class LiveRepositoryTests(unittest.TestCase):
    def test_repository_passes_hard_mode(self) -> None:
        result = checker.audit_repository(root=REPOSITORY_ROOT, mode="hard")
        self.assertEqual(
            [f"{f.path}:{f.line} [{f.code}] {f.message}" for f in result.errors], [])

    def test_ledger_exists_and_defines_nodes(self) -> None:
        registry, _ = checker._build_registry(REPOSITORY_ROOT, "error", check_commits=False)
        self.assertTrue(registry.all_numbers, "no ledger nodes found — is the glob right?")


if __name__ == "__main__":
    unittest.main(verbosity=1)
