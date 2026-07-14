#!/usr/bin/env python3
"""
Shared provenance capture for Python-side benchmark artifacts.

The Swift harnesses (EmbeddingBench/SystemInfo.swift, GenerationEval/GitInfo.swift)
already stamp git SHA, device, and macOS version into their outputs. This module
brings the Python pipeline up to the same standard so every artifact records
enough metadata to reproduce it: git state, machine, toolchain, and the exact
corpus fixtures (version + sha256) it was run against.

Never backfill provenance onto artifacts produced before this module existed —
missing provenance on a legacy artifact is itself evidence of when it was made.
The validator (validate_checkpoints.py) flags those as legacy, not as errors.
"""
import hashlib
import json
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

PROVENANCE_SCHEMA_VERSION = 1

# Packages whose versions materially affect benchmark results. Absence is
# recorded rather than skipped — "not_installed" explains e.g. why an -mlx
# candidate failed.
TRACKED_PACKAGES = [
    "sentence-transformers",
    "torch",
    "transformers",
    "numpy",
    "huggingface_hub",
    "mlx",
    "mlx-lm",
    "einops",
    "psutil",
]


def _run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           cwd=REPO_ROOT, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def sha256_file(path, chunk_size=1 << 20):
    """Streaming sha256 of a file, hex digest."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def _package_versions():
    from importlib import metadata
    versions = {}
    for pkg in TRACKED_PACKAGES:
        try:
            versions[pkg] = metadata.version(pkg)
        except metadata.PackageNotFoundError:
            versions[pkg] = "not_installed"
    return versions


def _corpus_fixture_info(fixtures):
    info = {}
    for name, path in fixtures.items():
        path = Path(path)
        entry = {}
        try:
            entry["path"] = str(path.relative_to(REPO_ROOT))
        except ValueError:
            entry["path"] = str(path)
        if path.exists():
            entry["sha256"] = sha256_file(path)
            try:
                with open(path) as f:
                    entry["version"] = json.load(f).get("version")
            except Exception:
                entry["version"] = None
        else:
            entry["error"] = "missing"
        info[name] = entry
    return info


def collect_provenance(corpus_fixtures=None, extra=None):
    """Capture git/machine/toolchain provenance for a benchmark artifact.

    corpus_fixtures: optional {name: path} of fixture files the run consumed;
        each is recorded with its internal version field and sha256.
    extra: optional dict merged into the result (e.g. eval binary sha256).

    git_dirty ignores untracked files: benchmark artifacts accumulating under
    Evaluation/results/ don't change code behavior, but any modified tracked
    file does — and means the run isn't reproducible from git_commit alone.
    """
    ram = _run(["sysctl", "-n", "hw.memsize"])
    prov = {
        "provenance_schema_version": PROVENANCE_SCHEMA_VERSION,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_commit": _run(["git", "rev-parse", "HEAD"]) or "unknown",
        "git_branch": _run(["git", "rev-parse", "--abbrev-ref", "HEAD"]) or "unknown",
        "git_dirty": bool(_run(["git", "status", "--porcelain", "--untracked-files=no"])),
        "device": _run(["sysctl", "-n", "machdep.cpu.brand_string"]) or platform.processor(),
        "macos_version": platform.mac_ver()[0] or None,
        "ram_gb": round(int(ram) / 2**30, 1) if ram and ram.isdigit() else None,
        "python_version": platform.python_version(),
        "packages": _package_versions(),
    }
    if corpus_fixtures:
        prov["corpus_fixtures"] = _corpus_fixture_info(corpus_fixtures)
    if extra:
        prov.update(extra)
    return prov


if __name__ == "__main__":
    print(json.dumps(collect_provenance(), indent=2))
