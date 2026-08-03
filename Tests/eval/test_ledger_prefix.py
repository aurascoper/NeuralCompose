"""Fixtures for the ledger integrity gate.

A commit message saying "I verified it fails on both failures" is the class of
claim this project keeps getting bitten by -- the shim that was never
committed, the canary pointed at the wrong OS, and the first run of this very
gate, which piped through `head` and so reported the exit status of `head`
rather than the script. Each was a check that appeared to verify and did not.

So the verification is a fixture rather than a note. Every case here is a
ledger that MUST be rejected; a passing ledger is checked once at the end so a
gate that rejects everything cannot pass this file either.

Style A (pytest-style + __main__ runner); pytest is absent from the venv.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "Scripts" / "check_ledger_prefix.py"
LEDGER_REL = "WorldModel/EXPERIMENT_LEDGER.md"


def _run_gate(ledger_text: str, tmp: Path) -> int:
    """Run the gate against a synthetic repo whose upstream is a fixed base.

    Builds a throwaway git repo rather than mutating the real ledger: a test
    that edits the tracked file and restores it leaves the tree dirty if it
    fails partway, and this gate is precisely about not trusting that kind of
    manual restore.
    """
    repo = tmp / "repo"
    (repo / "WorldModel").mkdir(parents=True, exist_ok=True)
    (repo / "Scripts").mkdir(parents=True, exist_ok=True)
    (repo / "Scripts" / "check_ledger_prefix.py").write_bytes(GATE.read_bytes())

    base = (
        "# Ledger\n\nEntry template:\n\n"
        "## 0 — Groundwork (2026-01-01, commit a)\n- Category: Integrate\n- Hypothesis: x\n\n"
        "---\n\n"
        "## 1 — Second thing (2026-01-02, commit b)\n- Category: Benchmark\n- Hypothesis: y\n"
    )
    ledger = repo / LEDGER_REL
    ledger.write_text(base)

    def git(*args: str) -> None:
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)

    if not (repo / ".git").exists():
        git("init", "-q", "-b", "main")
        git("config", "user.email", "t@t")
        git("config", "user.name", "t")
    git("add", "-A")
    git("commit", "-qm", "base")
    # `origin/main` is what the gate compares against; point it at ourselves.
    subprocess.run(
        ["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
        cwd=repo, check=True, capture_output=True,
    )

    ledger.write_text(ledger_text)
    result = subprocess.run(
        [sys.executable, "Scripts/check_ledger_prefix.py"],
        cwd=repo, capture_output=True, text=True,
    )
    return result.returncode


BASE_PREFIX = (
    "# Ledger\n\nEntry template:\n\n"
    "## 0 — Groundwork (2026-01-01, commit a)\n- Category: Integrate\n- Hypothesis: x\n\n"
    "---\n\n"
    "## 1 — Second thing (2026-01-02, commit b)\n- Category: Benchmark\n- Hypothesis: y\n"
)


def test_rejects_a_node_overwritten_in_an_occupied_slot(tmp_path: Path) -> None:
    """The failure that occurred: a different experiment written into node 1
    because the branch's tail was stale."""
    stale = BASE_PREFIX.replace("## 1 — Second thing", "## 1 — A DIFFERENT experiment")
    assert _run_gate(stale, tmp_path) == 1


def test_rejects_a_content_change_with_separators_untouched(tmp_path: Path) -> None:
    """Independent of the `---` normalizer.

    The splitter strips a trailing separator so that appending a node does not
    make its predecessor spuriously differ. That normalizer is load-bearing: a
    bug in it could make two different ledgers compare equal. This edits a node
    body and leaves every separator alone, so it fails only if real content is
    compared."""
    edited = BASE_PREFIX.replace("- Hypothesis: x", "- Hypothesis: SOMETHING ELSE")
    assert _run_gate(edited, tmp_path) == 1


def test_rejects_a_new_node_without_a_harness(tmp_path: Path) -> None:
    appended = BASE_PREFIX + (
        "\n---\n\n## 2 — New work (2026-01-03, commit c)\n"
        "- Category: Benchmark\n- Hypothesis: z\n"
    )
    assert _run_gate(appended, tmp_path) == 1


def test_rejects_a_duplicate_node_number(tmp_path: Path) -> None:
    duped = BASE_PREFIX + (
        "\n---\n\n## 1 — Duplicate (2026-01-03, commit c)\n"
        "- Category: Benchmark\n- Harness: e / f / g\n- Hypothesis: z\n"
    )
    assert _run_gate(duped, tmp_path) == 1


def test_rejects_a_dropped_upstream_node(tmp_path: Path) -> None:
    """Deleting an upstream entry is as much a divergence as overwriting one."""
    truncated = BASE_PREFIX[: BASE_PREFIX.index("## 1 —")]
    assert _run_gate(truncated, tmp_path) == 1


def test_accepts_a_correctly_extended_ledger(tmp_path: Path) -> None:
    """The negative control. Without it, a gate that rejected every input
    would pass every test above."""
    extended = BASE_PREFIX + (
        "\n---\n\n## 2 — New work (2026-01-03, commit c)\n"
        "- Category: Benchmark\n- Harness: synthetic_1f / forward_eval.py / CEM\n"
        "- Hypothesis: z\n"
    )
    assert _run_gate(extended, tmp_path) == 0


if __name__ == "__main__":
    import tempfile

    failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_") or not callable(fn):
            continue
        with tempfile.TemporaryDirectory() as d:
            try:
                fn(Path(d))
                print(f"PASS {name}")
            except Exception as exc:  # noqa: BLE001
                failed += 1
                print(f"FAIL {name}: {exc}")
    print(f"\n{len(
        [k for k in globals() if k.startswith('test_')]
    ) - failed}/{len([k for k in globals() if k.startswith('test_')])} passed")
    sys.exit(1 if failed else 0)
