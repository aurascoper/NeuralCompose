#!/usr/bin/env python3
"""Validate EXPERIMENT_LEDGER node citations and the commit SHAs they pin.

PROPOSAL PROTOTYPE. Advisory by default and deliberately not wired into CI.
See docs/architecture/experiment-ledger-citation-integrity.md.

Sibling of Scripts/check_adr_references.py, and structured to match it so the
two can be reviewed together and eventually merged into one entry point.

Validates:

1. Every ledger node heading is canonical:  ## <n> — <title> (<date>, commit <sha>)
2. No node number is defined twice in one ledger.
3. Every bare `node N` reference resolves to a node defined in the SAME ledger.
4. A reference to another numbering space must name it (`dialectic node 33`),
   because a bare number silently borrows this ledger's namespace.
5. Every pinned commit SHA resolves in this repository. `<pending>` is allowed;
   an unresolvable SHA is not.

Check 5 is the one that catches a citation pinned to an unpushed commit — the
failure this prototype exists for. Check 4 is the one the real ledger already
half-observes: "dialectic node 33" is qualified once and bare twelve times.

COMMIT MESSAGES ARE NOT FILES. A file scanner cannot see a citation that lives
only in a commit message, which is where the motivating defect occurred. Use
--commit-message for that path; it applies checks 3-5 to a message file and is
suitable for a commit-msg hook or a CI pass over a PR's commits.

Usage:
    python3 Scripts/check_ledger_references.py
    python3 Scripts/check_ledger_references.py --mode hard
    python3 Scripts/check_ledger_references.py --commit-message .git/COMMIT_EDITMSG
    python3 Scripts/check_ledger_references.py --root /path/to/worktree
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import DefaultDict, Dict, Iterable, List, Optional, Sequence, Set, Tuple


LEDGER_GLOB = "**/EXPERIMENT_LEDGER.md"

# Roots scanned for ledger citations. WorldModel/ is deliberately included:
# check_adr_references.py scans neither it nor any ledger, so the entire
# experiment lane is currently uncovered by either checker.
SCAN_ROOTS: Tuple[Path, ...] = (
    Path("WorldModel"),
    Path("docs/architecture"),
    Path("Scripts"),
)

SCAN_EXCLUSIONS: Set[Path] = {
    Path("Scripts/check_ledger_references.py"),
    Path("docs/architecture/experiment-ledger-citation-integrity.md"),
}

# ## 13 — Decoupling: epochs and latent_dim ... (2026-07-21, commit <pending>)
NODE_HEADING_RE = re.compile(
    r"^##\s+(?P<number>\d+)\s+—\s+(?P<title>.+?)\s*$"
)

# The trailing "(<date>, commit <sha>)" or "(<date>, commits <sha> + <sha>)".
NODE_PIN_RE = re.compile(
    r"\(\s*(?P<date>\d{4}-\d{2}-\d{2})\s*,\s*commits?\s+(?P<shas>[^)]+?)\s*\)\s*$"
)

SHA_RE = re.compile(r"\b(?P<sha>[0-9a-f]{7,40})\b")

# A citation. The optional qualifier is any single word immediately before
# "node" that is not an ordinary English connective — that is how a reference
# declares it belongs to another numbering space.
NODE_REFERENCE_RE = re.compile(
    r"(?:(?P<qualifier>[A-Za-z][A-Za-z-]*)\s+)?\bnodes?\s+(?P<number>\d+)\b",
    re.IGNORECASE,
)

# Namespaces recognised as external, as an ALLOWLIST. Extend deliberately.
#
# An earlier draft used a denylist of English connectives and flagged anything
# else as an unknown namespace. That fired on ordinary prose -- "if node 33",
# "refutes node 12", "across node 7" -- producing 9 false positives out of 18
# findings on the real ledger. A denylist of English words cannot be completed,
# so a word that is not on this list is treated as prose and the citation is
# resolved as bare. Being wrong in that direction costs a missed qualifier;
# being wrong in the other direction costs the checker its credibility.
KNOWN_NAMESPACES: Set[str] = {"dialectic", "session", "reflective"}

PENDING_TOKENS: Set[str] = {"<pending>", "pending", "tbd", "n/a"}


@dataclasses.dataclass(frozen=True)
class Finding:
    severity: str  # "error" or "warning"
    code: str
    path: Path
    line: Optional[int]
    message: str

    def sort_key(self) -> Tuple[str, int, str, str]:
        return (self.path.as_posix(), self.line or 0, self.code, self.message)


@dataclasses.dataclass(frozen=True)
class NodeDefinition:
    number: int
    path: Path
    line: int
    shas: Tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class LedgerRegistry:
    # ledger path -> {number -> definitions}
    by_ledger: Dict[Path, Dict[int, Tuple[NodeDefinition, ...]]]

    def numbers_for(self, path: Path) -> Set[int]:
        return set(self.by_ledger.get(path, {}))

    @property
    def all_numbers(self) -> Set[int]:
        return {n for table in self.by_ledger.values() for n in table}


@dataclasses.dataclass(frozen=True)
class AuditResult:
    findings: Tuple[Finding, ...]

    @property
    def errors(self) -> Tuple[Finding, ...]:
        return tuple(f for f in self.findings if f.severity == "error")

    @property
    def warnings(self) -> Tuple[Finding, ...]:
        return tuple(f for f in self.findings if f.severity == "warning")


def _relative(path: Path, root: Path) -> Path:
    try:
        return path.resolve().relative_to(root.resolve())
    except ValueError:
        return path


def _read_text(path: Path) -> Optional[str]:
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\x00" in raw:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _is_shallow(root: Path) -> bool:
    """True if this is a shallow clone, where absence proves nothing.

    actions/checkout defaults to fetch-depth 1. In that tree every historical
    SHA fails to resolve, so an unguarded existence check reports every pinned
    commit as missing -- confidently, and wrongly. Measured on this repository:
    a depth-1 checkout turns node 1's two real pins into two hard errors.
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--is-shallow-repository"],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.stdout.strip() == "true"


def _commit_exists(root: Path, sha: str) -> Optional[bool]:
    """True/False if resolvable; None if git itself is unavailable.

    None is reported distinctly rather than folded into False: "we could not
    check" and "the commit does not exist" are different claims, and conflating
    them would let a broken environment read as a clean tree.
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "cat-file", "-e", f"{sha}^{{commit}}"],
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.returncode == 0


def _iter_files(root: Path, locations: Sequence[Path]) -> Iterable[Path]:
    seen: Set[Path] = set()
    for location in locations:
        target = root / location
        if target.is_file():
            candidates: Iterable[Path] = (target,)
        elif target.is_dir():
            candidates = (
                p for p in target.rglob("*")
                if p.is_file() and not p.is_symlink() and p.suffix in {".md", ".py"}
            )
        else:
            continue
        for path in candidates:
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            yield path


def _build_registry(
    root: Path,
    severity: str,
    check_commits: bool,
) -> Tuple[LedgerRegistry, List[Finding]]:
    findings: List[Finding] = []
    shallow = _is_shallow(root) if check_commits else False
    by_ledger: Dict[Path, Dict[int, Tuple[NodeDefinition, ...]]] = {}

    for ledger in sorted(root.glob(LEDGER_GLOB)):
        if ".git" in ledger.parts:
            continue
        relative = _relative(ledger, root)
        text = _read_text(ledger)
        if text is None:
            findings.append(Finding(
                severity=severity,
                code="LEDGER_READ_ERROR",
                path=relative,
                line=None,
                message="ledger is not readable UTF-8 text",
            ))
            continue

        definitions: DefaultDict[int, List[NodeDefinition]] = defaultdict(list)

        for line_number, line in enumerate(text.splitlines(), start=1):
            heading = NODE_HEADING_RE.match(line)
            if heading is None:
                continue

            number = int(heading.group("number"))
            title = heading.group("title")
            pin = NODE_PIN_RE.search(title)

            if pin is None:
                findings.append(Finding(
                    severity=severity,
                    code="LEDGER_NODE_UNPINNED",
                    path=relative,
                    line=line_number,
                    message=(
                        f"node {number} heading has no '(<date>, commit <sha>)' "
                        "pin; an unpinned attribution is not a source"
                    ),
                ))
                shas: Tuple[str, ...] = ()
            else:
                raw = pin.group("shas")
                if raw.strip().lower() in PENDING_TOKENS:
                    shas = ()
                else:
                    shas = tuple(m.group("sha") for m in SHA_RE.finditer(raw))
                    if not shas:
                        findings.append(Finding(
                            severity=severity,
                            code="LEDGER_NODE_PIN_MALFORMED",
                            path=relative,
                            line=line_number,
                            message=(
                                f"node {number} pin {raw!r} is neither <pending> "
                                "nor a resolvable-looking SHA"
                            ),
                        ))

            if check_commits:
                for sha in shas:
                    exists = _commit_exists(root, sha)
                    if shallow and exists is False:
                        findings.append(Finding(
                            severity="warning",
                            code="LEDGER_COMMIT_UNVERIFIABLE_SHALLOW",
                            path=relative,
                            line=line_number,
                            message=(
                                f"node {number} pins {sha}; cannot verify in a "
                                "shallow checkout (set fetch-depth: 0 to make "
                                "this check meaningful)"
                            ),
                        ))
                    elif exists is None:
                        findings.append(Finding(
                            severity="warning",
                            code="LEDGER_COMMIT_UNCHECKED",
                            path=relative,
                            line=line_number,
                            message=(
                                f"could not run git to verify {sha}; "
                                "not treated as a pass"
                            ),
                        ))
                    elif not exists:
                        findings.append(Finding(
                            severity=severity,
                            code="LEDGER_COMMIT_UNRESOLVABLE",
                            path=relative,
                            line=line_number,
                            message=(
                                f"node {number} pins commit {sha}, which does "
                                "not resolve in this repository (unpushed?)"
                            ),
                        ))

            definitions[number].append(NodeDefinition(
                number=number, path=relative, line=line_number, shas=shas,
            ))

        for number, values in sorted(definitions.items()):
            if len(values) > 1:
                lines = ", ".join(str(v.line) for v in values)
                findings.append(Finding(
                    severity=severity,
                    code="LEDGER_NODE_DUPLICATE",
                    path=relative,
                    line=values[1].line,
                    message=f"node {number} is defined more than once (lines {lines})",
                ))

        by_ledger[relative] = {n: tuple(v) for n, v in definitions.items()}

    if not by_ledger:
        findings.append(Finding(
            severity="warning",
            code="LEDGER_NONE_FOUND",
            path=Path("."),
            line=None,
            message="no EXPERIMENT_LEDGER.md found; nothing to validate",
        ))

    return LedgerRegistry(by_ledger=by_ledger), findings


def _scan_line(
    line: str,
    line_number: int,
    relative: Path,
    local_numbers: Set[int],
    severity: str,
) -> List[Finding]:
    findings: List[Finding] = []

    for match in NODE_REFERENCE_RE.finditer(line):
        qualifier = (match.group("qualifier") or "").lower().strip(" -")
        number = int(match.group("number"))

        if qualifier in KNOWN_NAMESPACES:
            continue  # explicitly another numbering space; not ours to resolve

        if number in local_numbers:
            continue

        findings.append(Finding(
            severity=severity,
            code="LEDGER_NODE_REFERENCE_MISSING",
            path=relative,
            line=line_number,
            message=(
                f"bare 'node {number}' does not resolve in this ledger; "
                "name the numbering space (e.g. 'dialectic node "
                f"{number}') or cite a node that exists"
            ),
        ))

    return findings


def _scan_references(
    root: Path,
    registry: LedgerRegistry,
    severity: str,
) -> List[Finding]:
    findings: List[Finding] = []
    fallback = registry.all_numbers

    for path in sorted(_iter_files(root, SCAN_ROOTS), key=lambda p: p.as_posix()):
        relative = _relative(path, root)
        if relative in SCAN_EXCLUSIONS:
            continue
        text = _read_text(path)
        if text is None:
            continue

        # A ledger resolves against its own nodes; other files resolve against
        # the union, since there is currently one ledger and cross-file
        # citations do not yet name which one they mean.
        local = registry.numbers_for(relative) or fallback

        for line_number, line in enumerate(text.splitlines(), start=1):
            findings.extend(_scan_line(line, line_number, relative, local, severity))

    return findings


def audit_commit_message(
    root: Path,
    message_path: Path,
    severity: str,
    check_commits: bool,
) -> AuditResult:
    """Apply the citation rules to a commit message.

    This is the path a file scanner structurally cannot cover, and the one the
    motivating defect took: a commit body cited a ledger node that does not
    contain the numbers it claimed, and pinned a SHA that was never pushed.
    """
    registry, findings = _build_registry(root, severity, check_commits=False)
    findings = [f for f in findings if f.severity != "warning" or f.code != "LEDGER_NONE_FOUND"]

    text = _read_text(message_path)
    if text is None:
        return AuditResult(findings=(Finding(
            severity=severity,
            code="COMMIT_MESSAGE_UNREADABLE",
            path=message_path,
            line=None,
            message="commit message file is not readable UTF-8 text",
        ),))

    relative = _relative(message_path, root)
    numbers = registry.all_numbers
    out: List[Finding] = []

    for line_number, line in enumerate(text.splitlines(), start=1):
        if line.startswith("#"):
            continue  # git comment lines are stripped before commit
        out.extend(_scan_line(line, line_number, relative, numbers, severity))

        if check_commits:
            for match in SHA_RE.finditer(line):
                sha = match.group("sha")
                if len(sha) < 7:
                    continue
                exists = _commit_exists(root, sha)
                if exists is False and _is_shallow(root):
                    out.append(Finding(
                        severity="warning",
                        code="COMMIT_SHA_UNVERIFIABLE_SHALLOW",
                        path=relative,
                        line=line_number,
                        message=(
                            f"message cites {sha}; cannot verify in a shallow "
                            "checkout (set fetch-depth: 0)"
                        ),
                    ))
                elif exists is False:
                    out.append(Finding(
                        severity=severity,
                        code="COMMIT_SHA_UNRESOLVABLE",
                        path=relative,
                        line=line_number,
                        message=(
                            f"message cites commit {sha}, which does not resolve "
                            "in this repository (unpushed or mistyped?)"
                        ),
                    ))

    return AuditResult(findings=tuple(sorted(out, key=lambda f: f.sort_key())))


def audit_repository(root: Path, mode: str = "advisory") -> AuditResult:
    root = root.resolve()
    if mode not in {"hard", "advisory"}:
        raise ValueError(f"unsupported mode: {mode}")
    severity = "warning" if mode == "advisory" else "error"

    registry, findings = _build_registry(root, severity, check_commits=True)
    findings.extend(_scan_references(root, registry, severity))

    unique: Dict[Tuple[str, str, str, Optional[int], str], Finding] = {}
    for finding in findings:
        unique[(finding.severity, finding.code, finding.path.as_posix(),
                finding.line, finding.message)] = finding

    return AuditResult(findings=tuple(sorted(unique.values(), key=lambda f: f.sort_key())))


def _escape_github_command(value: str) -> str:
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _render_finding(finding: Finding, github_annotations: bool) -> None:
    location = finding.path.as_posix()
    if finding.line is not None:
        location = f"{location}:{finding.line}"

    if github_annotations:
        command = "error" if finding.severity == "error" else "warning"
        attributes = f"file={finding.path.as_posix()}"
        if finding.line is not None:
            attributes += f",line={finding.line}"
        print(f"::{command} {attributes}::"
              f"{_escape_github_command(f'[{finding.code}] {finding.message}')}")
        return

    print(f"{finding.severity.upper():7} {location} [{finding.code}] {finding.message}")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--mode", choices=("hard", "advisory"), default="advisory",
                        help="advisory reports without failing; hard fails on defects")
    parser.add_argument("--commit-message", type=Path, default=None,
                        help="validate a commit message file instead of the tree")
    parser.add_argument("--github-annotations", choices=("auto", "always", "never"),
                        default="auto")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"repository root does not exist: {root}")

    annotations = (
        args.github_annotations == "always"
        or (args.github_annotations == "auto"
            and os.environ.get("GITHUB_ACTIONS") == "true")
    )
    severity = "warning" if args.mode == "advisory" else "error"

    if args.commit_message is not None:
        result = audit_commit_message(root, args.commit_message, severity,
                                      check_commits=True)
        label = "Ledger citation (commit message)"
    else:
        result = audit_repository(root=root, mode=args.mode)
        label = "Ledger citation"

    for finding in result.findings:
        _render_finding(finding, github_annotations=annotations)

    if result.errors:
        print(f"{label}: FAIL ({len(result.errors)} error(s), "
              f"{len(result.warnings)} warning(s))")
        return 1

    print(f"{label}: PASS ({len(result.warnings)} warning(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
