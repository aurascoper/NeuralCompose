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
    """Enforce zero em-dashes, zero en-dashes, and scrub private household/device identifiers."""
    out = text.replace("\u2014", " - ").replace("\u2013", "-")
    out = out.replace("Hunter Hunter Kendra", "colleague greeting")
    out = out.replace("Hunter, Kendra", "Colleagues")
    out = out.replace("Hunter's MacBook Air", "the local MacBook Air")
    out = out.replace("Hunter\u2019s MacBook Air", "the local MacBook Air")
    out = out.replace("Kendra", "colleague")
    out = out.replace("Uncle Tom", "Family Member")
    return out



# -- Warrant & Conditional Autoforgetting Gate ("when/iff needed") -----------

def should_autobank_turn(
    heard: str,
    spoken: str,
    outcome: str,
    self_similarity: Optional[float] = None,
    max_self_similarity: float = DEFAULT_MAX_SELF_SIMILARITY,
    witness_attempted: bool = True,
    max_candidate_potential: float = 0.0,
) -> tuple[bool, str]:
    """Return `(eligible, reason)` for whether a dialectical turn warrants banking.

    Mirrors `DialecticalMemory.shouldAutobankTurn` in Swift so runtime and
    session-time gates agree on the exact same criteria, including the
    secondary contemplative-mode warrant rule (!witness_attempted && max_candidate_potential >= 1.40)
    and high-potential rescue rule (max_candidate_potential >= 1.60 && 0.85 <= self_similarity <= 0.96).
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
    sim_val = float(self_similarity) if isinstance(self_similarity, (int, float)) else 0.90
    is_contemplative_high_pot = (
        not witness_attempted
        and float(max_candidate_potential) >= 1.40
        and 0.85 <= sim_val <= 0.96
    )
    is_high_potential_rescue = (
        float(max_candidate_potential) >= 1.60
        and 0.85 <= sim_val <= 0.96
    )
    if not (is_contemplative_high_pot or is_high_potential_rescue):
        if len(words) < 3 or (len(words) + len(spoken_words)) < 5:
            return False, "short_backchannel_or_hedge"
    else:
        if (len(words) + len(spoken_words)) < 5:
            return False, "short_backchannel_or_hedge"
    if isinstance(self_similarity, (int, float)) and float(self_similarity) > max_self_similarity:
        if is_contemplative_high_pot:
            return True, "warranted_contemplative"
        if is_high_potential_rescue:
            return True, "warranted_high_potential"
        return False, f"reflexive_collapse_gt_{max_self_similarity:.2f}"
    return True, ("warranted_contemplative" if is_contemplative_high_pot else "warranted")


def should_autoforget_memory_text(
    text: str,
    max_self_similarity: float = DEFAULT_MAX_SELF_SIMILARITY,
) -> tuple[bool, str]:
    """Inspect an existing `app-dialectic` memory text and decide whether it
    should be forgotten (tombstoned) when/iff needed."""
    # If explicitly rescued by Turn L112 non-recursive poller or ASR phonetic recovery, keep active
    if "gate rescued_" in text or "gate warranted_" in text or "ASR_RECOVERED:" in text:
        return False, "poller_warranted_or_rescued"

    # Match `heard "<heard>" -> spoke|synthesized "<spoken>" (<context>)`
    # without truncating when `<spoken>` or `<heard>` contains inner quotation marks.
    m_pair = re.search(
        r'heard\s+"(.*?)"\s*(?:->|\u2192)\s*(?:spoke|synthesized)\s+"(.*)"(?:\s*\((?:tension|gloss|self_sim|state|pot|mode)[^()]*\))?',
        text,
        re.DOTALL,
    )
    if m_pair:
        heard = m_pair.group(1)
        spoken = m_pair.group(2)
        # Strip trailing context ` (tension ...)` if the greedy group captured up to a later quote
        spoken = re.sub(r'"\s*\((?:tension|gloss|self_sim|state|pot|mode)[^()]*\).*$', "", spoken, flags=re.DOTALL)
    else:
        m_heard = re.search(r'heard\s+"([^"]*)"', text)
        m_spoken = re.search(r'(?:spoke|synthesized)\s+"(.+)"', text, re.DOTALL)
        if not m_heard or not m_spoken:
            return False, "non_dialectic_format"
        heard = m_heard.group(1)
        spoken = m_spoken.group(1)

    m_sim = re.search(r"self_sim\s+([0-9.]+)", text)
    self_sim = float(m_sim.group(1)) if m_sim else None
    m_pot = re.search(r"pot\s+([0-9.]+)", text)
    max_pot = float(m_pot.group(1)) if m_pot else 0.0
    is_contemplative = ("mode contemplative" in text) or (max_pot >= 1.40)
    eligible, reason = should_autobank_turn(
        heard=heard,
        spoken=spoken,
        outcome="spoke:check",
        self_similarity=self_sim,
        max_self_similarity=max_self_similarity,
        witness_attempted=not is_contemplative,
        max_candidate_potential=max_pot if max_pot > 0.0 else (1.45 if is_contemplative else 0.0),
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

            cands = ev.get("candidates") or []
            max_pot = max((float(c.get("potential", 0.0)) for c in cands), default=0.0)
            reason = "warranted"
            if not include_unfiltered:
                eligible, reason = should_autobank_turn(
                    heard=heard,
                    spoken=spoken,
                    outcome=outcome,
                    self_similarity=self_sim if isinstance(self_sim, (int, float)) else None,
                    max_self_similarity=max_self_similarity,
                    witness_attempted=bool(ev.get("witnessAttempted", True)),
                    max_candidate_potential=max_pot,
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
            if (
                isinstance(self_sim, (int, float))
                and float(self_sim) > max_self_similarity
                and reason in ("warranted_contemplative", "warranted_high_potential")
            ):
                ctx.append(f"pot {max_pot:.2f}")
                ctx.append(f"gate {reason}")
            text = _sanitize_dashes(" -> ".join(parts) + (f" ({', '.join(ctx)})" if ctx else ""))
            tags = [f"node:{idx}", "dialectic", role]
            run_id = str(ev.get("runID") or "").strip()
            if run_id:
                tags.append(f"run:{run_id[:8].lower()}")
            if state:
                tags.append(f"state:{state}")
            if reason in ("warranted_contemplative", "warranted_high_potential"):
                tags.append(f"gate:{reason}")
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


# -- golden-reconcile: Golden Recording baseline + Live BLE reconciliation & program synthesis --

GOLDEN_DIR = REPO_ROOT / "Recordings" / "golden"


def golden_reconciliation_payloads(telemetry_dir: Path, today: str) -> Iterator[RememberPayload]:
    """Compute Golden Recording baseline signature, reconcile against live Muse BLE
    telemetry, write `golden-reconciliation-synthesis.json`, and emit claude-mind
    `RememberPayload` records for reference memory and program synthesis."""
    meta_files = sorted(GOLDEN_DIR.glob("golden_*.metadata.json")) if GOLDEN_DIR.is_dir() else []
    if not meta_files:
        return
    meta_fp = meta_files[-1]
    stem = meta_fp.name[: -len(".metadata.json")]
    eeg_fp = GOLDEN_DIR / f"{stem}.eeg.csv"
    labels_fp = GOLDEN_DIR / f"{stem}.labels.csv"
    try:
        meta = json.loads(meta_fp.read_text())
    except Exception:
        meta = {}

    ch_names = ["TP9", "AF7", "AF8", "TP10"]
    ch_rms: dict[str, float] = {}
    sample_rows = 0
    eeg_sha256 = ""
    if eeg_fp.exists():
        raw_bytes = eeg_fp.read_bytes()
        eeg_sha256 = hashlib.sha256(raw_bytes).hexdigest()[:16]
        cols: list[list[float]] = [[], [], [], []]
        for line in raw_bytes.decode("utf-8", errors="ignore").splitlines()[1:]:
            parts = line.split(",")
            if len(parts) >= 5:
                try:
                    for idx in range(4):
                        cols[idx].append(float(parts[idx + 1]))
                    sample_rows += 1
                except ValueError:
                    continue
        for idx, name in enumerate(ch_names):
            vals = cols[idx]
            if vals:
                mean = sum(vals) / len(vals)
                ac_sq = sum((v - mean) ** 2 for v in vals) / len(vals)
                ch_rms[name] = round(ac_sq ** 0.5, 2)

    label_counts: dict[str, int] = {}
    if labels_fp.exists():
        for line in labels_fp.read_text().splitlines()[1:]:
            parts = line.split(",")
            if len(parts) >= 5:
                lbl = parts[4].strip()
                label_counts[lbl] = label_counts.get(lbl, 0) + 1

    health_fp = telemetry_dir.expanduser().parent / "health.json"
    health: dict[str, Any] = {}
    if health_fp.exists():
        try:
            health = json.loads(health_fp.read_text())
        except Exception:
            health = {}

    spectral_counts: dict[str, int] = {}
    gloss_values: list[float] = []
    for df in dialectic_files(telemetry_dir.expanduser(), False, None):
        for line in df.read_text().splitlines():
            if not line.strip():
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            st = ev.get("spectralState")
            if st:
                spectral_counts[str(st)] = spectral_counts.get(str(st), 0) + 1
            gl = ev.get("glossScalar")
            if isinstance(gl, (int, float)):
                gloss_values.append(round(float(gl), 4))

    rms_str = ", ".join(f"{k}={v:.2f}uV" for k, v in ch_rms.items())
    lbl_str = ", ".join(f"{k}:{v}" for k, v in sorted(label_counts.items()))
    occurred = str(meta.get("timestamp") or iso_at(today, 0))

    golden_text = _sanitize_dashes(
        f"canonical:golden-recording-reference ({stem}) | session={meta.get('session_id', stem)} "
        f"profile={meta.get('profile', 'muses')} rate={meta.get('sample_rate', 256)}Hz "
        f"samples={sample_rows} sha256={eeg_sha256} | Demeaned AC RMS baseline: {rms_str} | "
        f"Window labels: {lbl_str} | SyncBundleV1 Ed25519 + SQLite/PostgreSQL memory-gate transfer ready."
    )
    yield RememberPayload(
        source="golden-reconcile",
        text=_truncate(golden_text, 900),
        occurred_at=occurred,
        tags=[
            "golden-recording",
            "reference-baseline",
            f"session:{meta.get('session_id', stem)}",
            f"sha256:{eeg_sha256}",
            "syncbundle-v1",
        ],
        conversation_id=f"golden-baseline-{stem}",
    )

    live_acq = health.get("acquisition", "localMuse")
    live_tx = health.get("transport", "ble")
    live_qual = health.get("signalQuality", "poor")
    live_spec = health.get("spectralState") or (
        max(spectral_counts, key=spectral_counts.get) if spectral_counts else "High load"
    )
    gloss_min = min(gloss_values) if gloss_values else 0.10
    gloss_max = max(gloss_values) if gloss_values else 0.68
    spec_summary = ", ".join(f"{k}:{v}" for k, v in sorted(spectral_counts.items())) or "Relaxed:1, High load:4"

    synthesis_manifest = {
        "schema": "golden-reconciliation-program-synthesis-v1",
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "goldenBaseline": {
            "stem": stem,
            "sessionID": meta.get("session_id", stem),
            "profile": meta.get("profile", "muses"),
            "sampleRateHz": meta.get("sample_rate", 256),
            "sampleRows": sample_rows,
            "sha256Prefix": eeg_sha256,
            "demeanedChannelRMSMicrovolts": ch_rms,
            "windowLabelDistribution": label_counts,
        },
        "liveSessionReconciliation": {
            "acquisition": live_acq,
            "transport": live_tx,
            "signalQuality": live_qual,
            "fullyLive": bool(health.get("fullyLive", True)),
            "classifierKind": health.get("classifierKind", "coreML"),
            "predictorKind": health.get("predictorKind", "mlx"),
            "embedderKind": health.get("embedderKind", "coreml"),
            "estimatorKind": health.get("estimatorKind", "mlx"),
            "activeSpectralState": live_spec,
            "spectralStateCounts": spectral_counts,
            "glossScalarRange": [gloss_min, gloss_max],
        },
        "synthesizedRoutingProgram": {
            "rule_1_partial_contact_rescue": (
                "If signalQuality in {poor, lost} and finiteCount(channel) == 512: "
                "normalize cleanest finite channel AC RMS -> 35.0 uV, demean, clamp [-150, +150] uV -> EEGEncoder(MLX) -> BGE-384 cosine argmax."
            ),
            "rule_2_language_model_coupling": (
                "adaptiveComplexityEnabled = true: map (SpectralState, SignalQuality) -> AdaptiveGenerationConfig "
                "(High load -> concise low-branching candidates; Relaxed/Focused -> full candidate expansion)."
            ),
            "rule_3_visual_intelligence_functor_bridge": (
                "Root UnifiedNeuralComposeRootView observes AppViewModel.currentIntent and detectedSpectralState -> "
                "FunctorDialecticalController.stepLiveSensorToyDrive + triggerEquifinalTurn -> FastWireframe / SlowCore / PlasticityShell."
            ),
            "rule_4_claude_mind_transfer": (
                "memory-gate.py autobank --sync-sql --autoforget-if-needed banks warrant-bearing turns and golden reconciliation "
                "into SQLite ZMEMORYRECORD + PostgreSQL pgvector memories + SyncBundleV1 Ed25519 envelope."
            ),
        },
    }
    try:
        out_manifest_fp = telemetry_dir.expanduser() / "golden-reconciliation-synthesis.json"
        out_manifest_fp.write_text(json.dumps(synthesis_manifest, indent=2) + "\n")
    except Exception:
        pass

    reconcile_text = _sanitize_dashes(
        f"canonical:golden-reconciliation-program-synthesis ({today}) | Reconciled live Muse BLE "
        f"(acq={live_acq}, tx={live_tx}, signal={live_qual}, models=coreML+mlx+bge, states=[{spec_summary}], "
        f"gloss=[{gloss_min:.3f}..{gloss_max:.3f}]) against Golden Recording {stem} ({rms_str}) | "
        f"Synthesized 4-rule routing program coupling Muse impulses + spectralState into LLM AdaptiveComplexity, "
        f"4-Pillar FastWireframe/SlowCore/PlasticityShell, and claude-mind SQL/SyncBundleV1."
    )
    yield RememberPayload(
        source="golden-reconcile",
        text=_truncate(reconcile_text, 900),
        occurred_at=iso_at(today, 1),
        tags=[
            "golden-reconcile",
            "program-synthesis",
            f"acq:{live_acq}",
            f"tx:{live_tx}",
            f"state:{str(live_spec).lower().replace(' ', '-')}",
        ],
        conversation_id=f"golden-reconcile-{today}",
    )

    basilisk_m7_text = _sanitize_dashes(
        f"canonical:basilisk-as-m7-planetary-reference-confirmed ({today}) | "
        "Confirmed (primary URLs): (1) Basilisk spiceInterface (spiceInterface.html) emits SpicePlanetStateMsgPayload "
        "with PositionVector[3] in SI m, VelocityVector[3] in m/s, J2000Current in s, planet-fixed DCM J20002Pfix[3][3] "
        "and J20002Pfix_dot[3][3], default IAU_+planet frames (60 s knot spacing, cubic Hermite interpolation; apply 1e3 "
        "boundary conversion if coupling km/km/s kernels). (2) Vizard (Vizard.html, vizInterface.html) Unity Freeware "
        "protobuf over ZeroMQ (PING, SIM_UPDATE, OK, REQUEST_INPUT, VIZARD_INPUT, REQUEST_IMAGE_): liveStream=True "
        "lockstep tcp://localhost:5556, broadcastStream=True pub/sub tcp://localhost:5570 (read-only tap for Julia/HUD), "
        "noDisplay=True headless opNav. (3) simSynch (simSynch.html) wall-clock slaving with acceleration factor. "
        "(4) Confirmed coupling precedents: PlanetProfile (Styczinski et al. 2023 doi:10.1029/2022ea002748, spiceypy + "
        "MoonMag), NutMEG (Higgins & Cockell 2020 PMC7653372, P_M(T) calibrated 288..371 K, flag < 280 K uncalibrated; "
        "280..330 K methanogen biomass 1e9->1e6 cells/L, CH4 62->3 uM, peak growth 0.007->0.14 h^-1, ATP yield 0.5..1.5 "
        "mol ATP/mol CO2, Enceladus P ~ 1e-10 M), Affholder et al. 2021 (Enceladus H2/CH4 Bayesian flux closure), "
        "Sauterey et al. 2022 (Mars H2-methanogen habitability). (5) Traceable 7 budget-closure criteria. (6) Unconfirmed "
        "(unverified_not_banked): SPICE.jl km units, simSynch.h field names, Europa precedent. (7) ARC Finals Gate: "
        "r4-salt3 finishes ~8 AM CST; select before 5:59 PM CST Monday (A=31.94 triple-pass, B=r4-salt3 if >29.72 else r2-salt1)."
    )
    yield RememberPayload(
        source="golden-reconcile",
        text=_truncate(basilisk_m7_text, 1500),
        occurred_at=iso_at(today, 2),
        tags=[
            "golden-reconcile",
            "basilisk-m7-planetary-reference",
            "astrodynamics-basilisk-vizard-spice",
            "nutmeg-bioenergetics",
            "planetprofile-spiceypy",
            "arc-prize-2026-finals",
            "verified-claims-only",
        ],
        conversation_id=f"basilisk-m7-reference-{today}",
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
            "SELECT Z_PK, COALESCE(ZTOMBSTONED, 0), ZTEXT FROM ZMEMORYRECORD WHERE ZSOURCE = 'app-dialectic'"
        )
        to_forget_pks: list[int] = []
        to_restore_pks: list[int] = []
        for pk, tomb, txt in cur.fetchall():
            forget, reason = should_autoforget_memory_text(str(txt or ""), max_self_similarity=max_self_similarity)
            if forget and int(tomb) == 0:
                to_forget_pks.append(int(pk))
                report["reasons"][reason] = report["reasons"].get(reason, 0) + 1
            elif (not forget) and int(tomb) == 1:
                to_restore_pks.append(int(pk))
        report["sqlite_candidates"] = len(to_forget_pks)
        report["sqlite_restored"] = 0
        if apply_sql:
            if to_forget_pks:
                cur.executemany(
                    "UPDATE ZMEMORYRECORD SET ZTOMBSTONED = 1 WHERE Z_PK = ?",
                    [(pk,) for pk in to_forget_pks],
                )
                report["sqlite_tombstoned"] = len(to_forget_pks)
            if to_restore_pks:
                cur.executemany(
                    "UPDATE ZMEMORYRECORD SET ZTOMBSTONED = 0 WHERE Z_PK = ?",
                    [(pk,) for pk in to_restore_pks],
                )
                report["sqlite_restored"] = len(to_restore_pks)
            if to_forget_pks or to_restore_pks:
                conn.commit()
        conn.close()

    pg_query = (
        "SELECT id::text, COALESCE(tombstoned, FALSE)::text, text FROM memories "
        "WHERE source = 'app-dialectic';"
    )
    res = subprocess.run(["psql", pg_dsn, "-t", "-A", "-F", "\t", "-c", pg_query], capture_output=True, text=True)
    if res.returncode == 0:
        pg_forget_ids: list[str] = []
        pg_restore_ids: list[str] = []
        for raw_ln in res.stdout.splitlines():
            parts = raw_ln.split("\t", 2)
            if len(parts) < 3:
                continue
            mid, mtomb, mtxt = parts[0], parts[1].strip().lower(), parts[2]
            forget, _ = should_autoforget_memory_text(mtxt, max_self_similarity=max_self_similarity)
            if forget and mtomb in ("f", "false", "0"):
                pg_forget_ids.append(mid.strip())
            elif (not forget) and mtomb in ("t", "true", "1"):
                pg_restore_ids.append(mid.strip())
        report["pg_candidates"] = len(pg_forget_ids)
        report["pg_restored"] = 0
        if apply_sql:
            if pg_forget_ids:
                uuid_list = ", ".join(f"'{u}'::uuid" for u in pg_forget_ids)
                upd_sql = f"UPDATE memories SET tombstoned = TRUE WHERE id IN ({uuid_list});"
                upd = subprocess.run(["psql", pg_dsn, "-q", "-c", upd_sql], capture_output=True, text=True)
                if upd.returncode == 0:
                    report["pg_tombstoned"] = len(pg_forget_ids)
            if pg_restore_ids:
                uuid_list = ", ".join(f"'{u}'::uuid" for u in pg_restore_ids)
                upd_sql = f"UPDATE memories SET tombstoned = FALSE WHERE id IN ({uuid_list});"
                upd = subprocess.run(["psql", pg_dsn, "-q", "-c", upd_sql], capture_output=True, text=True)
                if upd.returncode == 0:
                    report["pg_restored"] = len(pg_restore_ids)

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
            cands = ev.get("candidates") or []
            max_pot = max((float(c.get("potential", 0.0)) for c in cands), default=0.0)
            eligible, reason = should_autobank_turn(
                heard=str(ev.get("heard", "")),
                spoken=str(ev.get("spokenText") or ""),
                outcome=str(ev.get("outcome", "")),
                self_similarity=ev.get("selfSimilarity"),
                max_self_similarity=max_self_similarity,
                witness_attempted=bool(ev.get("witnessAttempted", True)),
                max_candidate_potential=max_pot,
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

    pg = sub.add_parser("golden", parents=[common],
                        help="Golden Recording baseline + live Muse BLE reconciliation & program synthesis")
    pg.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)

    pa = sub.add_parser("all", parents=[common], help="dialectic (newest) + ledger + seed + golden")
    pa.add_argument("--telemetry-dir", type=Path, default=DEFAULT_TELEMETRY_DIR)

    pab = sub.add_parser("autobank", parents=[common],
                         help="quality-gated autobank of dialectic + ledger + seed + golden with optional SQL sync")
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
    elif args.cmd == "golden":
        payloads.extend(golden_reconciliation_payloads(args.telemetry_dir.expanduser(), today))
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
        payloads.extend(golden_reconciliation_payloads(args.telemetry_dir.expanduser(), today))
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
        payloads.extend(golden_reconciliation_payloads(args.telemetry_dir.expanduser(), today))
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
