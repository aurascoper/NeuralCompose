#!/usr/bin/env python3
"""
memory-gate.py - session-time claude-mind memory gate, autobank, and
conditional autoforgetting ("when/iff needed") (Stage 2 of the spatio-temporal
grounding plan).

Reads local, opt-in artifacts and TRANSFORMS them into a manifest of claude-mind
`remember` payloads, with optional session-time autobanking and conditional
autoforgetting ("when/iff needed"). It is OFFLINE tooling in the exact mould of
`session-seed.py`: it reads git + the local `dialectic-turns-<day>.jsonl`
telemetry (ADR-005) + `WorldModel/EXPERIMENT_LEDGER.md` + the newest SessionSeed,
and never talks to an LLM, never touches the running app.

HARD PRIVACY BOUNDARY: this is session-time only. `Sources/` must never import or
invoke it (Principle 5 / ADR-005) - the app writes only its opt-in local
telemetry and never calls claude-mind. The invariant to keep green:
  grep -rniE "claude-mind|mcp__|\\bremember\\b|\\brecall\\b" Sources/ -> empty

Namespaces (`source`):
  app-dialectic  - one entry per warrant-bearing SPOKEN dialectic turn
                   (spoke/synthesized) passing `should_autobank_turn`. Its
                   `node:<index>` and `run:<runID[:8]>` tags match the Stage-1
                   3D workspace node vocabulary. Silent turns, single-token
                   stutters, short backchannels (< 3 words), routine control/
                   transit phrases, and unmitigated reflexive collapse
                   (selfSimilarity > 0.92) are filtered out by default and can
                   be conditionally tombstoned via `autoforget`.
  world-model    - one entry per EXPERIMENT_LEDGER.md milestone.
  report         - the newest SessionSeed's runtime rollup (session context).

Every payload carries a stable `key:<hash>` tag derived from
(source, conversation_id, occurred_at, text). Re-running the gate produces the
SAME key, so the agent or `--sync-sql` pass can check `key:<hash>` before
inserting to apply the manifest idempotently.

Usage:
  ./Scripts/memory-gate.py dialectic [--telemetry-dir DIR] [--all-days] [--file F] [--include-unfiltered]
  ./Scripts/memory-gate.py ledger
  ./Scripts/memory-gate.py seed [SEED_ID]
  ./Scripts/memory-gate.py all [--include-unfiltered]
  ./Scripts/memory-gate.py autobank [--telemetry-dir DIR] [--all-days] [--file F] [--sync-sql] [--autoforget-if-needed]
  ./Scripts/memory-gate.py autoforget [--telemetry-dir DIR] [--apply-sql] [--compact-logs]
  # add --out manifest.jsonl to write the manifest instead of printing it.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TELEMETRY_DIR = Path.home() / "Documents" / "NeuralCompose" / "InteractionLogs"
DEFAULT_SQLITE_DB = Path.home() / "Library" / "Application Support" / "claude-mind" / "memory.sqlite"
DEFAULT_PG_DSN = os.environ.get(
    "CLAUDE_MIND_PG_DSN",
    "postgresql://aurascoper@127.0.0.1:5432/claude_mind_codex_local_20261014",
)
LEDGER_PATH = REPO_ROOT / "WorldModel" / "EXPERIMENT_LEDGER.md"
SEEDS_DIR = REPO_ROOT / "docs" / "seeds"

MAX_FIELD_CHARS = 320   # keep individual ledger fields compact in a memory entry
COREDATA_EPOCH_OFFSET = 978307200.0  # 2001-01-01T00:00:00Z
DEFAULT_MAX_SELF_SIMILARITY = 0.92
REFLEXIVE_COLLAPSE_WARN_THRESHOLD = 0.85

TRANSIENT_CONTROL_OR_TRANSIT_PHRASES = (
    "turn off",
    "turn it off",
    "switch off",
    "forget that",
    "clear memory",
    "reset memory",
    "clear history",
    "reset history",
    "ok i should be good",
    "okay i should be good",
    "i'll be down in a second",
    "be down in a second",
    "be right back",
    "hold on a second",
)


def _sanitize_dashes(text: str) -> str:
    """Enforce zero em-dashes and zero en-dashes across all emitted payloads."""
    return text.replace("\u2014", " - ").replace("\u2013", "-")


# -- Warrant & Conditional Autoforgetting Gate ("when/iff needed") -----------

def should_autobank_turn(
    heard: str,
    spoken: str,
    outcome: str,
    self_similarity: Optional[float] = None,
    max_self_similarity: float = DEFAULT_MAX_SELF_SIMILARITY,
) -> tuple[bool, str]:
    """Return `(eligible, reason)` for whether a dialectical turn warrants banking.

    Mirrors `DialecticalMemory.shouldAutobankTurn` in Swift so runtime and
    session-time gates agree on the exact same criteria.
    """
    role = outcome.split(":", 1)[0] if outcome else ""
    if role not in ("spoke", "synthesized"):
        return False, "silent_turn"
    clean_spoken = (spoken or "").strip()
    if not clean_spoken:
        return False, "empty_spoken"
    spoken_words = [re.sub(r"^[^\w]+|[^\w]+$", "", w) for w in clean_spoken.lower().split()]
    spoken_words = [w for w in spoken_words if w]
    clean_heard = (heard or "").strip()
    lowered = re.sub(r"^[^\w]+|[^\w]+$", "", clean_heard.lower())
    words = [re.sub(r"^[^\w]+|[^\w]+$", "", w) for w in lowered.split()]
    words = [w for w in words if w]
    if not words:
        return False, "short_backchannel_or_hedge"
    for phrase in TRANSIENT_CONTROL_OR_TRANSIT_PHRASES:
        if lowered == phrase or lowered.startswith(phrase + " ") or phrase in lowered:
            return False, "transient_control_or_transit"
    if len(words) >= 2 and len(set(words)) == 1:
        return False, "single_token_stutter"
    if len(words) < 3 or (len(words) + len(spoken_words)) < 5:
        return False, "short_backchannel_or_hedge"
    if isinstance(self_similarity, (int, float)) and float(self_similarity) > max_self_similarity:
        return False, f"reflexive_collapse_gt_{max_self_similarity:.2f}"
    return True, "warranted"


def should_autoforget_memory_text(
    text: str,
    max_self_similarity: float = DEFAULT_MAX_SELF_SIMILARITY,
) -> tuple[bool, str]:
    """Inspect an existing `app-dialectic` memory text and decide whether it
    should be forgotten (tombstoned) when/iff needed."""
    m_heard = re.search(r'heard\s+"([^"]*)"', text)
    m_Spoken = re.search(r'(?:spoke|synthesized)\s+"([^"]*)"', text)
    if not m_heard or not m_Spoken:
        return False, "non_dialectic_format"
    heard = m_heard.group(1)
    spoken = m_Spoken.group(1)
    m_sim = re.search(r"self_sim\s+([0-9.]+)", text)
    self_sim = float(m_sim.group(1)) if m_sim else None
    eligible, reason = should_autobank_turn(
        heard=heard,
        spoken=spoken,
        outcome="spoke:check",
        self_similarity=self_sim,
        max_self_similarity=max_self_similarity,
    )
    return (not eligible), reason


# -- Remember payload --------------------------------------------------------

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
        clean_text = _sanitize_dashes(self.text)
        h = hashlib.sha1(
            f"{self.source}\x1f{self.conversation_id}\x1f{self.occurred_at}\x1f{clean_text}".encode()
        ).hexdigest()[:10]
        return f"key:{h}"

    def to_json(self) -> dict[str, Any]:
        clean_text = _sanitize_dashes(self.text)
        k = self.key()
        tag_list = list(self.tags)
        if k not in tag_list:
            tag_list.append(k)
        return {
            "source": self.source,
            "text": clean_text,
            "occurred_at": self.occurred_at,
            "tags": tag_list,
            "conversation_id": self.conversation_id,
        }


def iso_at(date_str: str, offset_seconds: int = 0) -> str:
    """`YYYY-MM-DD` -> ISO8601 at local-noon-UTC + `offset_seconds`. The offset lets
    turns/entries within one day carry a monotonic `occurred_at` (turn/entry index
    as seconds) so `recall_around` orders them, without inventing a wall-clock the
    telemetry never recorded."""
    try:
        base = datetime.strptime(date_str, "%Y-%m-%d").replace(hour=12, tzinfo=timezone.utc)
    except ValueError:
        base = datetime(1970, 1, 1, 12, tzinfo=timezone.utc)
    return (base + timedelta(seconds=max(0, offset_seconds))).isoformat()


def _truncate(s: str, n: int = MAX_FIELD_CHARS) -> str:
    s = _sanitize_dashes(" ".join(s.split()))
    return s if len(s) <= n else s[: n - 1].rstrip() + "..."


# -- app-dialectic: dialectic-turns-<day>.jsonl -> per-spoken-turn memory ----

def _dialectic_date(path: Path) -> str:
    m = re.search(r"dialectic-turns-(\d{4}-\d{2}-\d{2})\.jsonl$", path.name)
    return m.group(1) if m else "1970-01-01"


def dialectic_payloads(
    path: Path,
    include_unfiltered: bool = False,
    max_self_similarity: float = DEFAULT_MAX_SELF_SIMILARITY,
) -> Iterator[RememberPayload]:
    date = _dialectic_date(path)
    conv = f"dialectic-{date}"
    if not path.exists():
        return
    with path.open() as fh:
        for line_ordinal, line in enumerate(fh):
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
                continue  # a silent turn minted no workspace node -> no node:<id> address
            idx = int(ev.get("index", 0))
            heard = str(ev.get("heard", "")).strip()
            spoken = str(ev.get("spokenText") or "").strip()
            self_sim = ev.get("selfSimilarity")
            if not spoken:
                continue

            if not include_unfiltered:
                eligible, _ = should_autobank_turn(
                    heard=heard,
                    spoken=spoken,
                    outcome=outcome,
                    self_similarity=self_sim if isinstance(self_sim, (int, float)) else None,
                    max_self_similarity=max_self_similarity,
                )
                if not eligible:
                    continue

            parts = []
            if heard:
                parts.append(f'heard "{_truncate(heard, 160)}"')
            parts.append(f'{role} "{_truncate(spoken, 200)}"')
            ctx = []
            tension = ev.get("tension")
            gloss = ev.get("glossScalar")
            state = ev.get("spectralState")
            if isinstance(tension, (int, float)):
                ctx.append(f"tension {tension:.2f}")
            if isinstance(gloss, (int, float)):
                ctx.append(f"gloss {gloss:.2f}")
            if isinstance(self_sim, (int, float)):
                ctx.append(f"self_sim {self_sim:.2f}")
            if state:
                ctx.append(f"state {state}")
            text = _sanitize_dashes(" -> ".join(parts) + (f" ({', '.join(ctx)})" if ctx else ""))
            tags = [f"node:{idx}", "dialectic", role]
            run_id = str(ev.get("runID") or "").strip()
            if run_id:
                tags.append(f"run:{run_id[:8].lower()}")
            if state:
                tags.append(f"state:{state}")
            recorded_at = str(ev.get("recordedAt") or "").strip()
            occurred = recorded_at if recorded_at else iso_at(date, line_ordinal)
            yield RememberPayload(
                source="app-dialectic",
                text=text,
                occurred_at=occurred,
                tags=tags,
                conversation_id=conv,
            )


def dialectic_files(telemetry_dir: Path, all_days: bool, explicit: Optional[Path]) -> list[Path]:
    if explicit is not None:
        return [explicit]
    hits = sorted(Path(p) for p in glob.glob(str(telemetry_dir / "dialectic-turns-*.jsonl")))
    if not hits:
        return []
    return hits if all_days else [hits[-1]]


# -- world-model: EXPERIMENT_LEDGER.md -> per-milestone memory ---------------

_HEADER_RE = re.compile(r"^##\s+(\d+)\s+(?:\u2014|-)\s+(.+?)\s*\((\d{4}-\d{2}-\d{2}),\s*commits?\s+(.+?)\)\s*$")


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
    for block in re.split(r"(?m)^(?=##\s+\d+\s+(?:\u2014|-))", text):
        lines = block.splitlines()
        if not lines:
            continue
        m = _HEADER_RE.match(lines[0])
        if not m:
            continue
        n, title, date, sha_raw = m.group(1), _sanitize_dashes(m.group(2).strip()), m.group(3), m.group(4).strip()
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
        for sha in re.findall(r"[0-9a-f]{7,40}", sha_raw):
            tags.append(f"commit:{sha}")
        yield RememberPayload(
            source="world-model",
            text=_sanitize_dashes(" | ".join(bits)),
            occurred_at=iso_at(date, int(n)),
            tags=tags,
            conversation_id="world-model-ledger",
        )


# -- report: newest SessionSeed runtime rollup -------------------------------

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
    todos = [_sanitize_dashes(str(t)) for t in (rt.get("outstanding_todos") or [])][:5]
    if todos:
        bits.append("todos: " + "; ".join(todos))
    risks = [_sanitize_dashes(str(r)) for r in (rt.get("known_risks") or [])][:5]
    if risks:
        bits.append("risks: " + "; ".join(risks))
    tags = ["report", "session-seed", d.name]
    style, ctx = rt.get("interaction_style"), rt.get("context_profile")
    if style:
        tags.append(f"style:{style}")
    if ctx:
        tags.append(f"context:{ctx}")
    yield RememberPayload(
        source="report",
        text=_truncate(" | ".join(bits), 900),
        occurred_at=iso_at(today, 0),
        tags=tags,
        conversation_id=f"session-seed-{d.name}",
    )


# -- Session-time SQL Autobank & Conditional Autoforgetting ------------------

def _parse_iso_to_epoch(iso_str: str) -> float:
    try:
        s = iso_str.replace("Z", "+00:00")
        return datetime.fromisoformat(s).timestamp()
    except Exception:
        return datetime.now(timezone.utc).timestamp()


def sync_payloads_to_sql(
    payloads: list[RememberPayload],
    sqlite_path: Path = DEFAULT_SQLITE_DB,
    pg_dsn: str = DEFAULT_PG_DSN,
) -> dict[str, int]:
    """Idempotently bank `RememberPayload` entries into SQLite `ZMEMORYRECORD`
    and PostgreSQL `memories` + `tags` + `memory_tags` keyed by `key:<hash>`."""
    stats = {"sqlite_inserted": 0, "sqlite_skipped": 0, "pg_inserted": 0, "pg_skipped": 0}
    if not payloads:
        return stats

    if sqlite_path.exists():
        conn = sqlite3.connect(str(sqlite_path))
        cur = conn.cursor()
        cur.execute("SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'MemoryRecord'")
        mem_ent_row = cur.fetchone()
        mem_ent = int(mem_ent_row[0]) if mem_ent_row else 3
        cur.execute("SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'TagRecord'")
        tag_ent_row = cur.fetchone()
        tag_ent = int(tag_ent_row[0]) if tag_ent_row else 11

        for p in payloads:
            key_tag = p.key()
            cur.execute(
                """
                SELECT m.Z_PK
                FROM ZMEMORYRECORD m
                JOIN Z_3TAGS mt ON mt.Z_3MEMORIES = m.Z_PK
                JOIN ZTAGRECORD t ON t.Z_PK = mt.Z_11TAGS
                WHERE t.ZNAME = ?
                LIMIT 1
                """,
                (key_tag,),
            )
            if cur.fetchone() is not None:
                stats["sqlite_skipped"] += 1
                continue

            cur.execute("SELECT COALESCE(MAX(Z_PK), 0) + 1 FROM ZMEMORYRECORD")
            mem_pk = int(cur.fetchone()[0])
            now_cd = datetime.now(timezone.utc).timestamp() - COREDATA_EPOCH_OFFSET
            occ_cd = _parse_iso_to_epoch(p.occurred_at) - COREDATA_EPOCH_OFFSET
            mem_uuid = uuid.uuid5(uuid.NAMESPACE_URL, f"neuralcompose:{key_tag}").bytes
            clean_text = _sanitize_dashes(p.text)

            cur.execute(
                """
                INSERT INTO ZMEMORYRECORD (
                    Z_PK, Z_ENT, Z_OPT, ZTOMBSTONED,
                    ZCREATEDAT, ZOCCURREDAT, ZSENTIMENT,
                    ZCONVERSATIONID, ZLANGUAGE, ZSOURCE, ZTEXT, ZID
                ) VALUES (?, ?, 1, 0, ?, ?, 0.0, ?, 'en', ?, ?, ?)
                """,
                (mem_pk, mem_ent, now_cd, occ_cd, p.conversation_id, p.source, clean_text, mem_uuid),
            )
            cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = 'MemoryRecord' AND Z_MAX < ?", (mem_pk, mem_pk))

            all_tags = list(dict.fromkeys([*p.tags, key_tag]))
            for t_name in all_tags:
                cur.execute("SELECT Z_PK FROM ZTAGRECORD WHERE ZNAME = ?", (t_name,))
                t_row = cur.fetchone()
                if t_row is not None:
                    tag_pk = int(t_row[0])
                else:
                    cur.execute("SELECT COALESCE(MAX(Z_PK), 0) + 1 FROM ZTAGRECORD")
                    tag_pk = int(cur.fetchone()[0])
                    tag_uuid = uuid.uuid5(uuid.NAMESPACE_URL, f"neuralcompose:tag:{t_name}").bytes
                    cur.execute(
                        "INSERT INTO ZTAGRECORD (Z_PK, Z_ENT, Z_OPT, ZNAME, ZID) VALUES (?, ?, 1, ?, ?)",
                        (tag_pk, tag_ent, t_name, tag_uuid),
                    )
                    cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = 'TagRecord' AND Z_MAX < ?", (tag_pk, tag_pk))
                cur.execute(
                    "INSERT OR IGNORE INTO Z_3TAGS (Z_3MEMORIES, Z_11TAGS) VALUES (?, ?)",
                    (mem_pk, tag_pk),
                )
            stats["sqlite_inserted"] += 1

        conn.commit()
        conn.close()

    # Sync to PostgreSQL when psql is available
    for p in payloads:
        key_tag = p.key()
        mem_uuid_str = str(uuid.uuid5(uuid.NAMESPACE_URL, f"neuralcompose:{key_tag}"))
        clean_text = _sanitize_dashes(p.text).replace("'", "''")
        conv_sql = p.conversation_id.replace("'", "''")
        src_sql = p.source.replace("'", "''")
        occ_sql = p.occurred_at.replace("'", "''")
        all_tags = list(dict.fromkeys([*p.tags, key_tag]))

        check_sql = f"SELECT COUNT(*) FROM memories WHERE id = '{mem_uuid_str}'::uuid;"
        chk = subprocess.run(
            ["psql", pg_dsn, "-t", "-A", "-c", check_sql],
            capture_output=True,
            text=True,
        )
        if chk.returncode != 0:
            break
        if chk.stdout.strip() not in ("0", ""):
            stats["pg_skipped"] += 1
            continue

        tag_sql_parts = []
        for t_name in all_tags:
            t_esc = t_name.replace("'", "''")
            tag_uuid_str = str(uuid.uuid5(uuid.NAMESPACE_URL, f"neuralcompose:tag:{t_name}"))
            tag_sql_parts.append(
                f"INSERT INTO tags (id, name) VALUES ('{tag_uuid_str}'::uuid, '{t_esc}') ON CONFLICT (name) DO NOTHING;\n"
                f"INSERT INTO memory_tags (memory_id, tag_id) "
                f"SELECT '{mem_uuid_str}'::uuid, id FROM tags WHERE name = '{t_esc}' ON CONFLICT DO NOTHING;"
            )

        insert_sql = (
            "BEGIN;\n"
            f"INSERT INTO memories (id, text, created_at, occurred_at, source, conversation_id, language, sentiment, metadata, tombstoned) "
            f"VALUES ('{mem_uuid_str}'::uuid, '{clean_text}', NOW(), '{occ_sql}'::timestamptz, '{src_sql}', '{conv_sql}', 'en', 0.0, '{{\"x\":0.0,\"y\":0.0,\"z\":0.0}}'::jsonb, FALSE) "
            "ON CONFLICT (id) DO NOTHING;\n"
            + "\n".join(tag_sql_parts)
            + "\nCOMMIT;"
        )
        ins = subprocess.run(["psql", pg_dsn, "-q", "-c", insert_sql], capture_output=True, text=True)
        if ins.returncode == 0:
            stats["pg_inserted"] += 1

    return stats


def autoforget_sql_and_logs(
    telemetry_dir: Path = DEFAULT_TELEMETRY_DIR,
    sqlite_path: Path = DEFAULT_SQLITE_DB,
    pg_dsn: str = DEFAULT_PG_DSN,
    apply_sql: bool = False,
    compact_logs: bool = False,
    max_self_similarity: float = DEFAULT_MAX_SELF_SIMILARITY,
) -> dict[str, Any]:
    """Conditional autoforgetting ("when/iff needed"):
    1. Scans `app-dialectic` rows in SQLite and PostgreSQL for stutters, short
       backchannels, routine transit/control phrases, or reflexive collapse
       (`self_sim > max_self_similarity`), tombstoning them iff `apply_sql=True`.
    2. Scans `dialectic-turns-*.jsonl` in `telemetry_dir` and writes filtered
       `dialectic-autobank-<day>.jsonl` manifests (and compacts the primary log
       with `.bak` backup iff `compact_logs=True`).
    """
    report: dict[str, Any] = {
        "sqlite_candidates": 0,
        "sqlite_tombstoned": 0,
        "pg_candidates": 0,
        "pg_tombstoned": 0,
        "files_inspected": 0,
        "turns_evaluated": 0,
        "turns_autobanked": 0,
        "turns_forgotten": 0,
        "reasons": {},
    }

    if sqlite_path.exists():
        conn = sqlite3.connect(str(sqlite_path))
        cur = conn.cursor()
        cur.execute(
            "SELECT Z_PK, ZTEXT FROM ZMEMORYRECORD WHERE ZSOURCE = 'app-dialectic' AND COALESCE(ZTOMBSTONED, 0) = 0"
        )
        to_forget_pks: list[int] = []
        for pk, txt in cur.fetchall():
            forget, reason = should_autoforget_memory_text(str(txt or ""), max_self_similarity=max_self_similarity)
            if forget:
                to_forget_pks.append(int(pk))
                report["reasons"][reason] = report["reasons"].get(reason, 0) + 1
        report["sqlite_candidates"] = len(to_forget_pks)
        if apply_sql and to_forget_pks:
            cur.executemany(
                "UPDATE ZMEMORYRECORD SET ZTOMBSTONED = 1 WHERE Z_PK = ?",
                [(pk,) for pk in to_forget_pks],
            )
            conn.commit()
            report["sqlite_tombstoned"] = len(to_forget_pks)
        conn.close()

    pg_query = (
        "SELECT id::text, text FROM memories "
        "WHERE source = 'app-dialectic' AND COALESCE(tombstoned, FALSE) = FALSE;"
    )
    res = subprocess.run(["psql", pg_dsn, "-t", "-A", "-F", "\t", "-c", pg_query], capture_output=True, text=True)
    if res.returncode == 0:
        pg_forget_ids: list[str] = []
        for raw_ln in res.stdout.splitlines():
            if "\t" not in raw_ln:
                continue
            mid, mtxt = raw_ln.split("\t", 1)
            forget, _ = should_autoforget_memory_text(mtxt, max_self_similarity=max_self_similarity)
            if forget:
                pg_forget_ids.append(mid.strip())
        report["pg_candidates"] = len(pg_forget_ids)
        if apply_sql and pg_forget_ids:
            uuid_list = ", ".join(f"'{u}'::uuid" for u in pg_forget_ids)
            upd_sql = f"UPDATE memories SET tombstoned = TRUE WHERE id IN ({uuid_list});"
            upd = subprocess.run(["psql", pg_dsn, "-q", "-c", upd_sql], capture_output=True, text=True)
            if upd.returncode == 0:
                report["pg_tombstoned"] = len(pg_forget_ids)

    for fp in dialectic_files(telemetry_dir.expanduser(), all_days=True, explicit=None):
        report["files_inspected"] += 1
        date_str = _dialectic_date(fp)
        kept_lines: list[str] = []
        raw_lines = [ln for ln in fp.read_text().splitlines() if ln.strip()]
        file_forgotten = 0
        for ln in raw_lines:
            try:
                ev = json.loads(ln)
            except json.JSONDecodeError:
                continue
            report["turns_evaluated"] += 1
            eligible, reason = should_autobank_turn(
                heard=str(ev.get("heard", "")),
                spoken=str(ev.get("spokenText") or ""),
                outcome=str(ev.get("outcome", "")),
                self_similarity=ev.get("selfSimilarity"),
                max_self_similarity=max_self_similarity,
            )
            if eligible:
                kept_lines.append(_sanitize_dashes(ln))
                report["turns_autobanked"] += 1
            else:
                file_forgotten += 1
                report["turns_forgotten"] += 1
                report["reasons"][reason] = report["reasons"].get(reason, 0) + 1

        if kept_lines:
            autobank_fp = fp.parent / f"dialectic-autobank-{date_str}.jsonl"
            autobank_fp.write_text("\n".join(kept_lines) + "\n")

        if compact_logs and file_forgotten > 0 and raw_lines:
            bak_fp = fp.parent / f"{fp.name}.bak"
            if not bak_fp.exists():
                bak_fp.write_text("\n".join(raw_lines) + "\n")
            fp.write_text(("\n".join(kept_lines) + "\n") if kept_lines else "")

    return report


# -- Emit --------------------------------------------------------------------

def emit(payloads: list[RememberPayload], out: Optional[Path]) -> int:
    by_source: dict[str, int] = {}
    for p in payloads:
        by_source[p.source] = by_source.get(p.source, 0) + 1
    summary = ", ".join(f"{k}={v}" for k, v in sorted(by_source.items())) or "none"
    print(f"memory-gate: {len(payloads)} payload(s) [{summary}]", file=sys.stderr)
    body = "".join(json.dumps(p.to_json(), ensure_ascii=False) + "\n" for p in payloads)
    if out is not None:
        out.write_text(body)
        print(f"  -> manifest written to {out}", file=sys.stderr)
        print("  Apply it session-time: for each line call mcp__claude-mind__remember(**payload).",
              file=sys.stderr)
        print("  (Optionally recall{tags:['key:<hash>']} first to stay idempotent across re-runs.)",
              file=sys.stderr)
    else:
        sys.stdout.write(body)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="memory-gate.py",
        add_help=True,
        description="Session-time claude-mind memory gate, autobank, and conditional autoforgetting (Stage 2).",
    )
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out", type=Path, default=None,
                        help="write the manifest JSONL here instead of stdout")
    common.add_argument("--include-unfiltered", action="store_true",
                        help="disable warrant/collapse filtering on dialectic turns")
    common.add_argument("--max-self-similarity", type=float, default=DEFAULT_MAX_SELF_SIMILARITY,
                        help="maximum selfSimilarity allowed for autobanking (default: 0.92)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    pd = sub.add_parser("dialectic", parents=[common],
                        help="dialectic-turns telemetry -> app-dialectic payloads")
    pd.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)
    pd.add_argument("--all-days", action="store_true", help="all dialectic-turns files, not just newest")
    pd.add_argument("--file", type=Path, default=None, help="one explicit dialectic-turns file")

    sub.add_parser("ledger", parents=[common], help="EXPERIMENT_LEDGER.md -> world-model payloads")

    ps = sub.add_parser("seed", parents=[common], help="newest SessionSeed runtime -> report payload")
    ps.add_argument("seed_id", nargs="?", default=None)

    pa = sub.add_parser("all", parents=[common], help="dialectic (newest) + ledger + seed")
    pa.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)

    pab = sub.add_parser("autobank", parents=[common],
                         help="quality-gated autobank of dialectic + ledger + seed with optional SQL sync")
    pab.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)
    pab.add_argument("--all-days", action="store_true", help="all dialectic-turns files, not just newest")
    pab.add_argument("--file", type=Path, default=None, help="one explicit dialectic-turns file")
    pab.add_argument("--sync-sql", action="store_true",
                     help="idempotently bank payloads into SQLite ZMEMORYRECORD and PostgreSQL memories")
    pab.add_argument("--autoforget-if-needed", action="store_true",
                     help="also run conditional autoforgetting on noisy/collapsed turns")

    paf = sub.add_parser("autoforget", parents=[common],
                         help="conditional autoforgetting ('when/iff needed') for SQL stores and interaction logs")
    paf.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)
    paf.add_argument("--apply-sql", action="store_true",
                     help="tombstone noisy/collapsed app-dialectic rows in SQLite and PostgreSQL")
    paf.add_argument("--compact-logs", action="store_true",
                     help="compact dialectic-turns-*.jsonl files in place (preserving .bak backup)")

    args = parser.parse_args(argv[1:])
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    payloads: list[RememberPayload] = []

    if args.cmd == "dialectic":
        for f in dialectic_files(args.telemetry_dir.expanduser(), args.all_days, args.file):
            payloads.extend(
                dialectic_payloads(
                    f,
                    include_unfiltered=args.include_unfiltered,
                    max_self_similarity=args.max_self_similarity,
                )
            )
    elif args.cmd == "ledger":
        payloads.extend(ledger_payloads())
    elif args.cmd == "seed":
        payloads.extend(seed_payloads(args.seed_id, today))
    elif args.cmd == "all":
        for f in dialectic_files(args.telemetry_dir.expanduser(), False, None):
            payloads.extend(
                dialectic_payloads(
                    f,
                    include_unfiltered=args.include_unfiltered,
                    max_self_similarity=args.max_self_similarity,
                )
            )
        payloads.extend(ledger_payloads())
        payloads.extend(seed_payloads(None, today))
    elif args.cmd == "autobank":
        for f in dialectic_files(args.telemetry_dir.expanduser(), args.all_days, args.file):
            payloads.extend(
                dialectic_payloads(
                    f,
                    include_unfiltered=args.include_unfiltered,
                    max_self_similarity=args.max_self_similarity,
                )
            )
        payloads.extend(ledger_payloads())
        payloads.extend(seed_payloads(None, today))
        if args.autoforget_if_needed:
            af_report = autoforget_sql_and_logs(
                telemetry_dir=args.telemetry_dir,
                apply_sql=args.sync_sql,
                compact_logs=False,
                max_self_similarity=args.max_self_similarity,
            )
            print(f"memory-gate autoforget: {json.dumps(af_report)}", file=sys.stderr)
        if args.sync_sql:
            sql_stats = sync_payloads_to_sql(payloads)
            print(f"memory-gate sync-sql: {json.dumps(sql_stats)}", file=sys.stderr)
    elif args.cmd == "autoforget":
        af_report = autoforget_sql_and_logs(
            telemetry_dir=args.telemetry_dir,
            apply_sql=args.apply_sql,
            compact_logs=args.compact_logs,
            max_self_similarity=args.max_self_similarity,
        )
        print(json.dumps(af_report, indent=2))
        return 0

    return emit(payloads, args.out)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
