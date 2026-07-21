#!/usr/bin/env python3
"""
memory-gate.py — session-time claude-mind memory gate (Stage 2 of the
spatio-temporal grounding plan).

Reads local, opt-in artifacts and TRANSFORMS them into a manifest of claude-mind
`remember` payloads. It is OFFLINE tooling in the exact mould of
`session-seed.py`: it reads git + the local `dialectic-turns-<day>.jsonl`
telemetry (ADR-005) + `WorldModel/EXPERIMENT_LEDGER.md` + the newest SessionSeed,
and never talks to an LLM, never touches the app.

IT DOES NOT WRITE TO claude-mind. A Python script cannot call the claude-mind
MCP tool — `remember` is the session-time *agent's* capability. So this script
only emits a JSONL manifest of `{source, text, occurred_at, tags,
conversation_id}` payloads; the agent applies them via
`mcp__claude-mind__remember`. That keeps the persistent write explicit and the
manifest reviewable before anything hits the store (dry-run by default: with no
`--out`, the manifest goes to stdout and a summary to stderr).

HARD PRIVACY BOUNDARY: this is session-time only. `Sources/` must never import or
invoke it (Principle 5 / ADR-005) — the app writes only its opt-in local
telemetry and never calls claude-mind. The invariant to keep green:
  grep -rniE "claude-mind|mcp__|\\bremember\\b|\\brecall\\b" Sources/  → empty

Namespaces (`source`):
  app-dialectic  — one entry per SPOKEN dialectic turn (spoke/synthesized). Its
                   `node:<index>` tag is the SAME node-id vocabulary the Stage-1
                   3D workspace mints (turnIndex ⇒ one utterance ⇒ one node), so
                   the spatial address in the app and the temporal persistence in
                   claude-mind share one key. Silent turns minted no node → skipped.
  world-model    — one entry per EXPERIMENT_LEDGER.md milestone.
  report         — the newest SessionSeed's runtime rollup (session context).

Every payload carries a stable `key:<hash>` tag derived from
(source, conversation_id, occurred_at, text). Re-running the gate produces the
SAME key, so the agent can `recall{tags:["key:<hash>"]}` before `remember` to
apply the manifest idempotently.

Usage:
  ./Scripts/memory-gate.py dialectic [--telemetry-dir DIR] [--all-days] [--file F]
  ./Scripts/memory-gate.py ledger
  ./Scripts/memory-gate.py seed [SEED_ID]
  ./Scripts/memory-gate.py all
  # add --out manifest.jsonl to write the manifest instead of printing it.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TELEMETRY_DIR = Path.home() / "Documents" / "NeuralCompose" / "InteractionLogs"
LEDGER_PATH = REPO_ROOT / "WorldModel" / "EXPERIMENT_LEDGER.md"
SEEDS_DIR = REPO_ROOT / "docs" / "seeds"

MAX_FIELD_CHARS = 320   # keep individual ledger fields compact in a memory entry


# ── Remember payload ──────────────────────────────────────────────────────────

@dataclass
class RememberPayload:
    """One `mcp__claude-mind__remember` call, verbatim. `to_json()` is exactly the
    tool's argument object (text required; the rest optional but always set)."""
    source: str
    text: str
    occurred_at: str        # ISO8601
    tags: list[str]
    conversation_id: str

    def key(self) -> str:
        h = hashlib.sha1(
            f"{self.source}\x1f{self.conversation_id}\x1f{self.occurred_at}\x1f{self.text}".encode()
        ).hexdigest()[:10]
        return f"key:{h}"

    def to_json(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "text": self.text,
            "occurred_at": self.occurred_at,
            "tags": [*self.tags, self.key()],
            "conversation_id": self.conversation_id,
        }


def iso_at(date_str: str, offset_seconds: int = 0) -> str:
    """`YYYY-MM-DD` → ISO8601 at local-noon-UTC + `offset_seconds`. The offset lets
    turns/entries within one day carry a monotonic `occurred_at` (turn/entry index
    as seconds) so `recall_around` orders them, without inventing a wall-clock the
    telemetry never recorded."""
    try:
        base = datetime.strptime(date_str, "%Y-%m-%d").replace(hour=12, tzinfo=timezone.utc)
    except ValueError:
        base = datetime(1970, 1, 1, 12, tzinfo=timezone.utc)
    return (base + timedelta(seconds=max(0, offset_seconds))).isoformat()


def _truncate(s: str, n: int = MAX_FIELD_CHARS) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1].rstrip() + "…"


# ── app-dialectic: dialectic-turns-<day>.jsonl → per-spoken-turn memory ────────

def _dialectic_date(path: Path) -> str:
    m = re.search(r"dialectic-turns-(\d{4}-\d{2}-\d{2})\.jsonl$", path.name)
    return m.group(1) if m else "1970-01-01"


def dialectic_payloads(path: Path) -> Iterator[RememberPayload]:
    date = _dialectic_date(path)
    conv = f"dialectic-{date}"
    if not path.exists():
        return
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            outcome = str(ev.get("outcome", ""))
            role = outcome.split(":", 1)[0] if outcome else ""
            if role not in ("spoke", "synthesized"):
                continue  # a silent turn minted no workspace node → no node:<id> address
            idx = int(ev.get("index", 0))
            heard = str(ev.get("heard", "")).strip()
            spoken = str(ev.get("spokenText") or "").strip()
            if not spoken:
                continue
            parts = []
            if heard:
                parts.append(f'heard "{_truncate(heard, 160)}"')
            parts.append(f'{role} "{_truncate(spoken, 200)}"')
            ctx = []
            tension, gloss, state = ev.get("tension"), ev.get("glossScalar"), ev.get("spectralState")
            if isinstance(tension, (int, float)):
                ctx.append(f"tension {tension:.2f}")
            if isinstance(gloss, (int, float)):
                ctx.append(f"gloss {gloss:.2f}")
            if state:
                ctx.append(f"state {state}")
            text = " → ".join(parts) + (f" ({', '.join(ctx)})" if ctx else "")
            tags = [f"node:{idx}", "dialectic", role]
            if state:
                tags.append(f"state:{state}")
            yield RememberPayload(source="app-dialectic", text=text,
                                  occurred_at=iso_at(date, idx), tags=tags, conversation_id=conv)


def dialectic_files(telemetry_dir: Path, all_days: bool, explicit: Optional[Path]) -> list[Path]:
    if explicit is not None:
        return [explicit]
    hits = sorted(Path(p) for p in glob.glob(str(telemetry_dir / "dialectic-turns-*.jsonl")))
    if not hits:
        return []
    return hits if all_days else [hits[-1]]


# ── world-model: EXPERIMENT_LEDGER.md → per-milestone memory ───────────────────

_HEADER_RE = re.compile(r"^##\s+(\d+)\s+—\s+(.+?)\s*\((\d{4}-\d{2}-\d{2}),\s*commits?\s+(.+?)\)\s*$")


def _parse_bullet_fields(lines: list[str]) -> dict[str, str]:
    """`- Key: value` bullets, folding indented continuation lines into the value."""
    fields: dict[str, str] = {}
    cur: Optional[str] = None
    for ln in lines:
        m = re.match(r"^-\s+([A-Za-z][\w ]*?):\s*(.*)$", ln)
        if m:
            cur = m.group(1).strip()
            fields[cur] = m.group(2).strip()
        elif cur and ln.strip():
            fields[cur] = (fields[cur] + " " + ln.strip()).strip()
        elif not ln.strip():
            cur = None
    return fields


def ledger_payloads(path: Path = LEDGER_PATH) -> Iterator[RememberPayload]:
    if not path.exists():
        return
    text = path.read_text()
    for block in re.split(r"(?m)^(?=##\s+\d+\s+—)", text):
        lines = block.splitlines()
        if not lines:
            continue
        m = _HEADER_RE.match(lines[0])
        if not m:
            continue
        n, title, date, sha_raw = m.group(1), m.group(2).strip(), m.group(3), m.group(4).strip()
        fields = _parse_bullet_fields(lines[1:])
        bits = [f"WM ledger #{n}: {title}"]
        for key in ("Decision", "Evidence", "Next question"):
            v = fields.get(key)
            if v:
                bits.append(f"{key}: {_truncate(v)}")
        tags = ["world-model", "ledger", f"entry:{n}"]
        cat = fields.get("Category")
        if cat:
            tags.append("category:" + cat.split("|")[0].strip().lower())
        # sha_raw may be "<pending>", "abc1234", or "fa7647b + ea0afbc" — tag each
        # real hex sha, skip the <pending> placeholder (no hex match).
        for sha in re.findall(r"[0-9a-f]{7,40}", sha_raw):
            tags.append(f"commit:{sha}")
        yield RememberPayload(source="world-model", text=" | ".join(bits),
                              occurred_at=iso_at(date, int(n)), tags=tags,
                              conversation_id="world-model-ledger")


# ── report: newest SessionSeed runtime rollup ─────────────────────────────────

def _newest_seed_dir() -> Optional[Path]:
    if not SEEDS_DIR.is_dir():
        return None
    hits = sorted(SEEDS_DIR.glob("seed-*"))
    return hits[-1] if hits else None


def seed_payloads(seed_id: Optional[str], today: str) -> Iterator[RememberPayload]:
    d = (SEEDS_DIR / f"seed-{seed_id}") if seed_id else _newest_seed_dir()
    if not d or not d.is_dir():
        return
    runtime_fp = d / "runtime.json"
    if not runtime_fp.exists():
        return
    try:
        rt = json.loads(runtime_fp.read_text())
    except json.JSONDecodeError:
        return
    bits = [f"SessionSeed {d.name}"]
    if rt.get("next_experiment"):
        bits.append(f"next_experiment: {_truncate(str(rt['next_experiment']))}")
    todos = [str(t) for t in (rt.get("outstanding_todos") or [])][:5]
    if todos:
        bits.append("todos: " + "; ".join(todos))
    risks = [str(r) for r in (rt.get("known_risks") or [])][:5]
    if risks:
        bits.append("risks: " + "; ".join(risks))
    tags = ["report", "session-seed", d.name]
    style, ctx = rt.get("interaction_style"), rt.get("context_profile")
    if style:
        tags.append(f"style:{style}")
    if ctx:
        tags.append(f"context:{ctx}")
    yield RememberPayload(source="report", text=_truncate(" | ".join(bits), 900),
                          occurred_at=iso_at(today, 0), tags=tags,
                          conversation_id=f"session-seed-{d.name}")


# ── Emit ──────────────────────────────────────────────────────────────────────

def emit(payloads: list[RememberPayload], out: Optional[Path]) -> int:
    by_source: dict[str, int] = {}
    for p in payloads:
        by_source[p.source] = by_source.get(p.source, 0) + 1
    summary = ", ".join(f"{k}={v}" for k, v in sorted(by_source.items())) or "—"
    print(f"memory-gate: {len(payloads)} payload(s) [{summary}]", file=sys.stderr)
    body = "".join(json.dumps(p.to_json(), ensure_ascii=False) + "\n" for p in payloads)
    if out is not None:
        out.write_text(body)
        print(f"  → manifest written to {out}", file=sys.stderr)
        print("  Apply it session-time: for each line call mcp__claude-mind__remember(**payload).",
              file=sys.stderr)
        print("  (Optionally recall{tags:['key:<hash>']} first to stay idempotent across re-runs.)",
              file=sys.stderr)
    else:
        sys.stdout.write(body)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="memory-gate.py", add_help=True,
                                     description="Session-time claude-mind memory gate (Stage 2).")
    # --out on a shared parent so it may follow the subcommand
    # (`memory-gate.py all --out FILE`), which is the intuitive order.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out", type=Path, default=None,
                        help="write the manifest JSONL here instead of stdout")
    sub = parser.add_subparsers(dest="cmd", required=True)

    pd = sub.add_parser("dialectic", parents=[common],
                        help="dialectic-turns telemetry → app-dialectic payloads")
    pd.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)
    pd.add_argument("--all-days", action="store_true", help="all dialectic-turns files, not just newest")
    pd.add_argument("--file", type=Path, default=None, help="one explicit dialectic-turns file")

    sub.add_parser("ledger", parents=[common], help="EXPERIMENT_LEDGER.md → world-model payloads")

    ps = sub.add_parser("seed", parents=[common], help="newest SessionSeed runtime → report payload")
    ps.add_argument("seed_id", nargs="?", default=None)

    pa = sub.add_parser("all", parents=[common], help="dialectic (newest) + ledger + seed")
    pa.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)

    args = parser.parse_args(argv[1:])
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    payloads: list[RememberPayload] = []

    if args.cmd == "dialectic":
        for f in dialectic_files(args.telemetry_dir.expanduser(), args.all_days, args.file):
            payloads.extend(dialectic_payloads(f))
    elif args.cmd == "ledger":
        payloads.extend(ledger_payloads())
    elif args.cmd == "seed":
        payloads.extend(seed_payloads(args.seed_id, today))
    elif args.cmd == "all":
        for f in dialectic_files(args.telemetry_dir.expanduser(), False, None):
            payloads.extend(dialectic_payloads(f))
        payloads.extend(ledger_payloads())
        payloads.extend(seed_payloads(None, today))

    return emit(payloads, args.out)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
