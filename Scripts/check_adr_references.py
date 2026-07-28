#!/usr/bin/env python3
"""Validate NeuralCompose's ADR registry and ADR references.

Hard mode validates:

1. Every ADR file has a canonical filename:
       ADR-NNN-descriptive-slug.md
2. Every ADR file has one matching top-level heading:
       # ADR-NNN: Title
3. No ADR number is assigned to more than one file.
4. Every well-formed ADR reference in normative repository roots resolves
   to exactly one ADR file.
5. Full-filename references name an ADR file that actually exists.
6. Malformed numeric ADR references fail.

Numeric gaps are allowed. For example, ADR-010 may exist while ADR-009 is
reserved for work that has not landed yet.

Historical review documents are not normative. Advisory mode scans them and
reports findings without failing.

Usage:
    python3 Scripts/check_adr_references.py
    python3 Scripts/check_adr_references.py --mode hard
    python3 Scripts/check_adr_references.py --mode advisory
    python3 Scripts/check_adr_references.py --mode all
    python3 Scripts/check_adr_references.py --root /path/to/worktree
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import DefaultDict, Dict, Iterable, List, Optional, Sequence, Set, Tuple


ADR_DIRECTORY = Path("docs/architecture/decision-log")

HARD_ROOTS: Tuple[Path, ...] = (
    Path("Sources"),
    Path("Tests"),
    Path("Scripts"),
    Path("docs/architecture"),
)

ADVISORY_ROOTS: Tuple[Path, ...] = (
    Path("README.md"),
    Path("docs/reviews"),
    Path("Evaluation/reports"),
)

# These files necessarily contain synthetic malformed references and checker
# terminology. They test the policy; they are not normative ADR consumers.
HARD_SCAN_EXCLUSIONS: Set[Path] = {
    Path("Scripts/check_adr_references.py"),
    Path("Tests/eval/test_adr_references.py"),
}

ADR_FILENAME_RE = re.compile(
    r"^ADR-(?P<number>\d{3})-[A-Za-z0-9][A-Za-z0-9._-]*\.md$"
)

ADR_HEADING_RE = re.compile(
    r"^#\s+ADR-(?P<number>\d{3}):(?:\s|$)"
)

# Used to produce a better diagnostic when a heading resembles an ADR heading
# but does not use exactly three digits and the required hyphen.
ADR_HEADING_LIKE_RE = re.compile(
    r"^#\s+ADR(?P<separator>[-_ ]?)(?P<number>\d{1,4})\s*:"
)

# A strict number reference. The next character must not continue a number,
# identifier, or the historical "ADR-009+" recommendation syntax.
ADR_REFERENCE_RE = re.compile(
    r"\bADR-(?P<number>\d{3})(?![0-9A-Za-z_+])"
)

FULL_ADR_FILENAME_REFERENCE_RE = re.compile(
    r"\b(?P<filename>"
    r"ADR-(?P<number>\d{3})-[A-Za-z0-9][A-Za-z0-9._-]*\.md"
    r")\b"
)

# Detect numeric ADR-like strings that are not canonical references:
# ADR-9, ADR-09, ADR-0009, ADR009, ADR_009, ADR 009, ADR-009+.
#
# Generic placeholders such as ADR-NNN are deliberately not matched.
ADR_LIKE_RE = re.compile(
    r"\bADR"
    r"(?P<separator>[-_ ]?)"
    r"(?P<number>\d{1,4})"
    r"(?P<plus>\+?)"
)


@dataclasses.dataclass(frozen=True)
class Finding:
    severity: str  # "error" or "warning"
    code: str
    path: Path
    line: Optional[int]
    message: str

    def sort_key(self) -> Tuple[str, int, str, str]:
        return (
            self.path.as_posix(),
            self.line or 0,
            self.code,
            self.message,
        )


@dataclasses.dataclass(frozen=True)
class ADRDefinition:
    number: str
    path: Path
    heading_line: int


@dataclasses.dataclass(frozen=True)
class Registry:
    by_number: Dict[str, Tuple[ADRDefinition, ...]]
    by_filename: Dict[str, ADRDefinition]
    duplicate_numbers: Set[str]


@dataclasses.dataclass(frozen=True)
class AuditResult:
    findings: Tuple[Finding, ...]

    @property
    def errors(self) -> Tuple[Finding, ...]:
        return tuple(
            finding for finding in self.findings
            if finding.severity == "error"
        )

    @property
    def warnings(self) -> Tuple[Finding, ...]:
        return tuple(
            finding for finding in self.findings
            if finding.severity == "warning"
        )


def _relative(path: Path, root: Path) -> Path:
    try:
        return path.resolve().relative_to(root.resolve())
    except ValueError:
        return path


def _read_text(path: Path) -> Optional[str]:
    """Read a probable text file, returning None for binary/non-UTF-8 files."""
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


def _iter_files(root: Path, locations: Sequence[Path]) -> Iterable[Path]:
    seen: Set[Path] = set()

    for location in locations:
        target = root / location

        if target.is_file():
            candidates = (target,)
        elif target.is_dir():
            candidates = (
                path for path in target.rglob("*")
                if path.is_file() and not path.is_symlink()
            )
        else:
            continue

        for path in candidates:
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            yield path


def _definition_registry(
    root: Path,
    severity: str,
) -> Tuple[Registry, List[Finding]]:
    adr_directory = root / ADR_DIRECTORY
    findings: List[Finding] = []
    definitions: DefaultDict[str, List[ADRDefinition]] = defaultdict(list)
    by_filename: Dict[str, ADRDefinition] = {}

    if not adr_directory.is_dir():
        findings.append(Finding(
            severity=severity,
            code="ADR_DIRECTORY_MISSING",
            path=ADR_DIRECTORY,
            line=None,
            message="canonical ADR directory does not exist",
        ))
        return (
            Registry(
                by_number={},
                by_filename={},
                duplicate_numbers=set(),
            ),
            findings,
        )

    for path in sorted(adr_directory.glob("ADR-*")):
        if not path.is_file():
            continue

        relative_path = _relative(path, root)
        filename_match = ADR_FILENAME_RE.fullmatch(path.name)

        if filename_match is None:
            findings.append(Finding(
                severity=severity,
                code="ADR_FILENAME_MALFORMED",
                path=relative_path,
                line=None,
                message=(
                    "ADR filename must match "
                    "ADR-NNN-descriptive-slug.md"
                ),
            ))
            continue

        filename_number = filename_match.group("number")
        text = _read_text(path)

        if text is None:
            findings.append(Finding(
                severity=severity,
                code="ADR_READ_ERROR",
                path=relative_path,
                line=None,
                message="ADR file is not readable UTF-8 text",
            ))
            continue

        exact_headings: List[Tuple[int, str]] = []
        heading_like: Optional[Tuple[int, str]] = None

        for line_number, line in enumerate(text.splitlines(), start=1):
            exact = ADR_HEADING_RE.match(line)
            if exact is not None:
                exact_headings.append(
                    (line_number, exact.group("number"))
                )
                continue

            approximate = ADR_HEADING_LIKE_RE.match(line)
            if approximate is not None and heading_like is None:
                heading_like = (line_number, line.strip())

        if not exact_headings:
            if heading_like is not None:
                findings.append(Finding(
                    severity=severity,
                    code="ADR_HEADING_MALFORMED",
                    path=relative_path,
                    line=heading_like[0],
                    message=(
                        "top-level ADR heading must match "
                        "'# ADR-NNN: Title'; found "
                        f"{heading_like[1]!r}"
                    ),
                ))
            else:
                findings.append(Finding(
                    severity=severity,
                    code="ADR_HEADING_MISSING",
                    path=relative_path,
                    line=None,
                    message=(
                        "ADR file requires one top-level heading matching "
                        "'# ADR-NNN: Title'"
                    ),
                ))
            continue

        if len(exact_headings) > 1:
            findings.append(Finding(
                severity=severity,
                code="ADR_HEADING_MULTIPLE",
                path=relative_path,
                line=exact_headings[1][0],
                message=(
                    "ADR file contains more than one canonical "
                    "top-level ADR heading"
                ),
            ))
            continue

        heading_line, heading_number = exact_headings[0]

        if heading_number != filename_number:
            findings.append(Finding(
                severity=severity,
                code="ADR_HEADING_MISMATCH",
                path=relative_path,
                line=heading_line,
                message=(
                    f"filename claims ADR-{filename_number}, "
                    f"heading claims ADR-{heading_number}"
                ),
            ))

        definition = ADRDefinition(
            number=filename_number,
            path=relative_path,
            heading_line=heading_line,
        )
        definitions[filename_number].append(definition)
        by_filename[path.name] = definition

    duplicate_numbers: Set[str] = {
        number
        for number, values in definitions.items()
        if len(values) > 1
    }

    # One finding per duplicate number. Reference scanning deliberately avoids
    # emitting one ambiguity error per citation; the registry defect is the
    # root cause and should be reported once.
    for number in sorted(duplicate_numbers):
        paths = ", ".join(
            definition.path.as_posix()
            for definition in sorted(
                definitions[number],
                key=lambda item: item.path.as_posix(),
            )
        )
        findings.append(Finding(
            severity=severity,
            code="ADR_DUPLICATE",
            path=ADR_DIRECTORY,
            line=None,
            message=f"ADR-{number} is assigned to multiple files: {paths}",
        ))

    registry = Registry(
        by_number={
            number: tuple(values)
            for number, values in definitions.items()
        },
        by_filename=by_filename,
        duplicate_numbers=duplicate_numbers,
    )
    return registry, findings


def _scan_references(
    root: Path,
    locations: Sequence[Path],
    registry: Registry,
    severity: str,
    exclusions: Set[Path],
) -> List[Finding]:
    findings: List[Finding] = []

    for path in sorted(
        _iter_files(root, locations),
        key=lambda value: value.as_posix(),
    ):
        relative_path = _relative(path, root)

        if relative_path in exclusions:
            continue

        text = _read_text(path)
        if text is None:
            continue

        for line_number, line in enumerate(text.splitlines(), start=1):
            malformed_spans: List[Tuple[int, int]] = []

            for match in ADR_LIKE_RE.finditer(line):
                separator = match.group("separator")
                number = match.group("number")
                plus = match.group("plus")

                is_canonical = (
                    separator == "-"
                    and len(number) == 3
                    and not plus
                )

                if is_canonical:
                    continue

                malformed_spans.append(match.span())
                findings.append(Finding(
                    severity=severity,
                    code="ADR_REFERENCE_MALFORMED",
                    path=relative_path,
                    line=line_number,
                    message=(
                        f"malformed ADR reference {match.group(0)!r}; "
                        "use ADR-NNN"
                    ),
                ))

            for match in FULL_ADR_FILENAME_REFERENCE_RE.finditer(line):
                filename = match.group("filename")

                if filename not in registry.by_filename:
                    findings.append(Finding(
                        severity=severity,
                        code="ADR_FILENAME_REFERENCE_MISSING",
                        path=relative_path,
                        line=line_number,
                        message=(
                            f"reference names ADR file {filename!r}, "
                            "but that exact file does not exist"
                        ),
                    ))

            for match in ADR_REFERENCE_RE.finditer(line):
                # Do not reinterpret part of a malformed token as a second,
                # otherwise ADR-009+ would produce both malformed and missing.
                if any(
                    start <= match.start() < end
                    for start, end in malformed_spans
                ):
                    continue

                number = match.group("number")

                # Duplicate numbers already produce one registry finding.
                if number in registry.duplicate_numbers:
                    continue

                definitions = registry.by_number.get(number, ())

                if not definitions:
                    findings.append(Finding(
                        severity=severity,
                        code="ADR_REFERENCE_MISSING",
                        path=relative_path,
                        line=line_number,
                        message=(
                            f"ADR-{number} is referenced but has no "
                            "canonical decision-log file"
                        ),
                    ))
                elif len(definitions) > 1:
                    # Defensive: normally covered by duplicate_numbers.
                    findings.append(Finding(
                        severity=severity,
                        code="ADR_REFERENCE_AMBIGUOUS",
                        path=relative_path,
                        line=line_number,
                        message=(
                            f"ADR-{number} resolves to more than one file"
                        ),
                    ))

    return findings


def audit_repository(root: Path, mode: str = "hard") -> AuditResult:
    """Audit one repository tree.

    Modes:
      hard:
        Registry and normative references are errors. Exit should fail.

      advisory:
        Registry, normative references, and historical prose are warnings.
        Exit should not fail.

      all:
        Registry/normative findings are errors; historical prose findings are
        warnings.
    """
    root = root.resolve()

    if mode not in {"hard", "advisory", "all"}:
        raise ValueError(f"unsupported mode: {mode}")

    hard_severity = "warning" if mode == "advisory" else "error"
    registry, findings = _definition_registry(
        root=root,
        severity=hard_severity,
    )

    findings.extend(_scan_references(
        root=root,
        locations=HARD_ROOTS,
        registry=registry,
        severity=hard_severity,
        exclusions=HARD_SCAN_EXCLUSIONS,
    ))

    if mode in {"advisory", "all"}:
        findings.extend(_scan_references(
            root=root,
            locations=ADVISORY_ROOTS,
            registry=registry,
            severity="warning",
            exclusions=set(),
        ))

    unique: Dict[
        Tuple[str, str, str, Optional[int], str],
        Finding,
    ] = {}

    for finding in findings:
        key = (
            finding.severity,
            finding.code,
            finding.path.as_posix(),
            finding.line,
            finding.message,
        )
        unique[key] = finding

    return AuditResult(
        findings=tuple(
            sorted(unique.values(), key=lambda value: value.sort_key())
        )
    )


def _escape_github_command(value: str) -> str:
    return (
        value.replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
    )


def _render_finding(finding: Finding, github_annotations: bool) -> None:
    location = finding.path.as_posix()
    if finding.line is not None:
        location = f"{location}:{finding.line}"

    if github_annotations:
        command = "error" if finding.severity == "error" else "warning"
        attributes = f"file={finding.path.as_posix()}"
        if finding.line is not None:
            attributes += f",line={finding.line}"

        message = _escape_github_command(
            f"[{finding.code}] {finding.message}"
        )
        print(f"::{command} {attributes}::{message}")
        return

    print(
        f"{finding.severity.upper():7} "
        f"{location} [{finding.code}] {finding.message}"
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.cwd(),
        help="repository root to audit; defaults to the current directory",
    )
    parser.add_argument(
        "--mode",
        choices=("hard", "advisory", "all"),
        default="hard",
        help=(
            "hard fails on normative defects; advisory reports everything "
            "without failing; all combines hard errors and advisory warnings"
        ),
    )
    parser.add_argument(
        "--github-annotations",
        choices=("auto", "always", "never"),
        default="auto",
        help="emit GitHub Actions workflow annotations",
    )
    args = parser.parse_args(argv)

    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"repository root does not exist: {root}")

    annotations = (
        args.github_annotations == "always"
        or (
            args.github_annotations == "auto"
            and os.environ.get("GITHUB_ACTIONS") == "true"
        )
    )

    result = audit_repository(root=root, mode=args.mode)

    for finding in result.findings:
        _render_finding(finding, github_annotations=annotations)

    if result.errors:
        print(
            f"ADR integrity: FAIL "
            f"({len(result.errors)} error(s), "
            f"{len(result.warnings)} warning(s))"
        )
        return 1

    print(
        f"ADR integrity: PASS "
        f"({len(result.warnings)} warning(s))"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
