#!/usr/bin/env python3
"""
session-seed.py — Typed loader + runtime-seed assembler for the co-development
session-seed system (see docs/seeds/README.md).

A *session seed* is the compressed, versioned artifact that carries project state
from one Opus (architect) session to the next, instead of re-summarising raw
chat transcripts. Each seed snapshot (seed-NNN/) has three parts that evolve at
DIFFERENT rates, kept separate so implementation churn never contaminates
architectural reasoning:

  architecture.json  — modules, invariants, public API seams   (slow)
  research.json      — open hypotheses, accepted/rejected decisions, questions  (medium)
  runtime.json       — todos, failures, telemetry, benchmarks, next experiment  (fast)

Each part carries its own `content_version`, bumped only when that part changes,
so one monotonic snapshot id (001, 002, …) still gives one auditable chain while
the three parts move independently.

This script is OFFLINE tooling: it reads git + the local dialectic-turns
telemetry and (re)assembles the *runtime* seed. It never talks to an LLM, never
touches the app. Architecture/research seeds are authored by hand and only
validated here.

Schema (mirrors the JSON):
  SeedPart (common):
    seed_id: str            # "001"
    part: "architecture" | "research" | "runtime"
    content_version: int

  Runtime extras:
    interaction_style, context_profile: str
    outstanding_todos, current_failures, known_risks: list[str]
    next_experiment: str
    generated_from: {git: {...}, telemetry: {...}}   # filled by `refresh`

Usage:
  ./Scripts/session-seed.py show 001            # print a one-screen summary
  ./Scripts/session-seed.py refresh 001         # re-assemble runtime.json from
                                                #   live git + newest telemetry
  ./Scripts/session-seed.py telemetry           # just print the telemetry rollup
"""

from __future__ import annotations

import glob
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
SEEDS_DIR = REPO_ROOT / "docs" / "seeds"
DEFAULT_TELEMETRY_DIR = Path.home() / "Documents" / "NeuralCompose" / "InteractionLogs"

PARTS = ("architecture", "research", "runtime")


# ── Telemetry rollup ──────────────────────────────────────────────────────────

# selfSimilarity above this (normalized cosine, [0,1]) flags the reflexive failure
# mode — replies collapsing onto their own centroid (WITNESS.md).
REFLEXIVE_COLLAPSE_THRESHOLD = 0.85


@dataclass
class TelemetryRollup:
    """A compact summary of one dialectic-turns-<day>.jsonl file. `gloss_variance`
    is the load-bearing signal: > 0 across turns means live EEG actually reached
    the SpectralGloss; ~0 (a single distinct value, typically the neutral 0.5)
    means the run was text-only (stub estimator / synthetic stream)."""
    source_file: Optional[str] = None
    turns: int = 0
    outcomes: dict[str, int] = field(default_factory=dict)   # spoke / silent / synthesized
    mean_tension: Optional[float] = None
    gloss_mean: Optional[float] = None
    gloss_variance: Optional[float] = None
    gloss_distinct: int = 0
    live_eeg_influence: bool = False   # gloss_variance > epsilon
    # Reflective-rung introspection (see Sources/BCICore/Dialectic/WITNESS.md).
    witness_turns: int = 0                          # turns where the Witness fired
    mean_witness_distance: Optional[float] = None   # reflective metric: "how much was avoided"
    mean_self_similarity: Optional[float] = None    # reflexive metric: collapse toward the reply centroid
    reflective_active: bool = False                 # witness_turns > 0 — this run ran the Witness
    reflexive_collapse_warn: bool = False           # mean_self_similarity > threshold

    def to_json(self) -> dict[str, Any]:
        return {
            "source_file": self.source_file,
            "turns": self.turns,
            "outcomes": self.outcomes,
            "mean_tension": _round(self.mean_tension),
            "gloss_mean": _round(self.gloss_mean),
            "gloss_variance": _round(self.gloss_variance, 6),
            "gloss_distinct_values": self.gloss_distinct,
            "live_eeg_influence": self.live_eeg_influence,
            "witness_turns": self.witness_turns,
            "mean_witness_distance": _round(self.mean_witness_distance),
            "mean_self_similarity": _round(self.mean_self_similarity),
            "reflective_active": self.reflective_active,
            "reflexive_collapse_warn": self.reflexive_collapse_warn,
        }


def _round(x: Optional[float], ndigits: int = 4) -> Optional[float]:
    return round(x, ndigits) if isinstance(x, (int, float)) else None


def newest_telemetry_file(telemetry_dir: Path) -> Optional[Path]:
    hits = sorted(glob.glob(str(telemetry_dir / "dialectic-turns-*.jsonl")))
    return Path(hits[-1]) if hits else None


def roll_up_telemetry(path: Optional[Path]) -> TelemetryRollup:
    if path is None or not path.exists():
        return TelemetryRollup()
    turns = 0
    outcomes: dict[str, int] = {"spoke": 0, "silent": 0, "synthesized": 0}
    tensions: list[float] = []
    glosses: list[float] = []
    witness_turns = 0
    witness_distances: list[float] = []
    self_sims: list[float] = []
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            turns += 1
            outcome = str(ev.get("outcome", ""))
            key = outcome.split(":", 1)[0] if outcome else ""
            if key in outcomes:
                outcomes[key] += 1
            else:
                outcomes[key] = outcomes.get(key, 0) + 1
            if isinstance(ev.get("tension"), (int, float)):
                tensions.append(float(ev["tension"]))
            if isinstance(ev.get("glossScalar"), (int, float)):
                glosses.append(float(ev["glossScalar"]))
            if isinstance(ev.get("witnessFinding"), str) and ev["witnessFinding"].strip():
                witness_turns += 1
            if isinstance(ev.get("witnessDistance"), (int, float)):
                witness_distances.append(float(ev["witnessDistance"]))
            if isinstance(ev.get("selfSimilarity"), (int, float)):
                self_sims.append(float(ev["selfSimilarity"]))

    roll = TelemetryRollup(source_file=str(path), turns=turns, outcomes=outcomes)
    if tensions:
        roll.mean_tension = sum(tensions) / len(tensions)
    if glosses:
        mean = sum(glosses) / len(glosses)
        var = sum((g - mean) ** 2 for g in glosses) / len(glosses)
        roll.gloss_mean = mean
        roll.gloss_variance = var
        roll.gloss_distinct = len(set(round(g, 4) for g in glosses))
        roll.live_eeg_influence = var > 1e-6
    # Reflective-rung introspection rollup (WITNESS.md). reflective_active
    # distinguishes a Reflective run (Witness fired) from Focused (0 witness turns);
    # reflexive_collapse_warn flags replies collapsing onto their own centroid.
    roll.witness_turns = witness_turns
    if witness_distances:
        roll.mean_witness_distance = sum(witness_distances) / len(witness_distances)
    if self_sims:
        roll.mean_self_similarity = sum(self_sims) / len(self_sims)
    roll.reflective_active = witness_turns > 0
    roll.reflexive_collapse_warn = (roll.mean_self_similarity or 0.0) > REFLEXIVE_COLLAPSE_THRESHOLD
    return roll


# ── Git state ─────────────────────────────────────────────────────────────────

def git_state() -> dict[str, Any]:
    def run(*args: str) -> str:
        try:
            return subprocess.run(
                ["git", *args], cwd=REPO_ROOT, capture_output=True, text=True, check=True
            ).stdout.strip()
        except Exception:
            return ""
    return {
        "branch": run("rev-parse", "--abbrev-ref", "HEAD"),
        "head": run("rev-parse", "--short", "HEAD"),
        "head_subject": run("log", "-1", "--pretty=%s"),
        "recent": [l for l in run("log", "-8", "--pretty=%h %s").splitlines() if l],
        "dirty_tracked": bool(run("status", "--porcelain=v1", "--untracked-files=no")),
    }


# ── Seed model ────────────────────────────────────────────────────────────────

@dataclass
class SessionSeed:
    seed_id: str
    architecture: dict[str, Any]
    research: dict[str, Any]
    runtime: dict[str, Any]

    @property
    def dir(self) -> Path:
        return SEEDS_DIR / f"seed-{self.seed_id}"

    @classmethod
    def load(cls, seed_id: str) -> "SessionSeed":
        d = SEEDS_DIR / f"seed-{seed_id}"
        if not d.is_dir():
            raise FileNotFoundError(f"no seed at {d}")
        parts = {}
        for p in PARTS:
            fp = d / f"{p}.json"
            parts[p] = json.loads(fp.read_text()) if fp.exists() else {}
        return cls(seed_id, parts["architecture"], parts["research"], parts["runtime"])

    def refresh_runtime(self, telemetry_dir: Path) -> TelemetryRollup:
        """Fold live git + newest-telemetry rollup into runtime.json, preserving
        every hand-authored field. Bumps runtime `content_version`."""
        roll = roll_up_telemetry(newest_telemetry_file(telemetry_dir))
        self.runtime.setdefault("seed_id", self.seed_id)
        self.runtime.setdefault("part", "runtime")
        self.runtime["content_version"] = int(self.runtime.get("content_version", 0)) + 1
        self.runtime["generated_from"] = {"git": git_state(), "telemetry": roll.to_json()}
        (self.dir / "runtime.json").write_text(json.dumps(self.runtime, indent=2) + "\n")
        return roll


# ── CLI ───────────────────────────────────────────────────────────────────────

def _fmt_outcomes(o: dict[str, int]) -> str:
    return ", ".join(f"{k}={v}" for k, v in o.items()) if o else "—"


def cmd_show(seed_id: str) -> int:
    seed = SessionSeed.load(seed_id)
    a, r, rt = seed.architecture, seed.research, seed.runtime
    print(f"seed-{seed_id}")
    print(f"  architecture  v{a.get('content_version','?')}  "
          f"arch={a.get('architecture_version','?')} field={a.get('field_version','?')} "
          f"modules={len(a.get('modules', []))} invariants={len(a.get('invariants', []))}")
    print(f"  research      v{r.get('content_version','?')}  "
          f"hypotheses={len(r.get('open_hypotheses', []))} "
          f"accepted={len(r.get('accepted_decisions', []))} "
          f"rejected={len(r.get('rejected_decisions', []))} "
          f"open_questions={len(r.get('pending_questions', []))}")
    tel = (rt.get("generated_from") or {}).get("telemetry") or {}
    print(f"  runtime       v{rt.get('content_version','?')}  "
          f"style={rt.get('interaction_style','?')}/{rt.get('context_profile','?')} "
          f"todos={len(rt.get('outstanding_todos', []))} risks={len(rt.get('known_risks', []))}")
    print(f"    next_experiment: {rt.get('next_experiment','—')}")
    if tel:
        print(f"    telemetry: turns={tel.get('turns',0)} "
              f"[{_fmt_outcomes(tel.get('outcomes', {}))}] "
              f"live_eeg_influence={tel.get('live_eeg_influence')} "
              f"(gloss var={tel.get('gloss_variance')})")
    return 0


def cmd_refresh(seed_id: str, telemetry_dir: Path) -> int:
    seed = SessionSeed.load(seed_id)
    roll = seed.refresh_runtime(telemetry_dir)
    where = roll.source_file or "(no telemetry file found)"
    print(f"refreshed seed-{seed_id} runtime.json → v{seed.runtime['content_version']}")
    print(f"  telemetry: {where}")
    print(f"    turns={roll.turns} [{_fmt_outcomes(roll.outcomes)}] "
          f"mean_tension={_round(roll.mean_tension)} "
          f"live_eeg_influence={roll.live_eeg_influence} (gloss var={_round(roll.gloss_variance, 6)})")
    print(f"    reflective_active={roll.reflective_active} (witness_turns={roll.witness_turns}, "
          f"mean_witness_distance={_round(roll.mean_witness_distance)}) "
          f"self_similarity={_round(roll.mean_self_similarity)}")
    if roll.turns and not roll.live_eeg_influence:
        print("  ⚠️ gloss variance ~0 — run was text-only (stub estimator or synthetic stream), "
              "no live-EEG bias reached the dialogue.")
    if roll.reflexive_collapse_warn:
        print(f"  ⚠️ reflexive collapse — mean self-similarity {_round(roll.mean_self_similarity)} > "
              f"{REFLEXIVE_COLLAPSE_THRESHOLD}; replies are converging onto their own centroid.")
    return 0


def cmd_telemetry(telemetry_dir: Path) -> int:
    roll = roll_up_telemetry(newest_telemetry_file(telemetry_dir))
    print(json.dumps(roll.to_json(), indent=2))
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    telemetry_dir = DEFAULT_TELEMETRY_DIR
    if cmd == "show" and len(argv) >= 3:
        return cmd_show(argv[2])
    if cmd == "refresh" and len(argv) >= 3:
        if len(argv) >= 4:
            telemetry_dir = Path(argv[3]).expanduser()
        return cmd_refresh(argv[2], telemetry_dir)
    if cmd == "telemetry":
        if len(argv) >= 3:
            telemetry_dir = Path(argv[2]).expanduser()
        return cmd_telemetry(telemetry_dir)
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
