#!/usr/bin/env python3
"""
memory-report.py — assemble a cross-session research report from claude-mind
recall hits (Stage 3b of the spatio-temporal grounding plan).

Like the memory gate, this is an OFFLINE FORMATTER: a Python script cannot call
the claude-mind MCP, so the session-time AGENT performs the `recall`s (by
`source`, time window, and `node:`/`entry:` tags — plus `recall_around` for
temporal context) and pipes the union of hit objects here. This script groups,
orders, and renders them into a markdown report grounded in the PERSISTED and
/dream-CONSOLIDATED memory, rather than re-deriving anything from the repo.

Input: a JSON array of claude-mind hit objects (or an object with a `hits`
array), from --hits FILE or stdin. Each hit is used loosely: `text`, `source`,
`occurred_at`, `tags`, `id`, and optionally `combined_score`. Unknown fields are
ignored; missing fields degrade gracefully.

Output: markdown to --out FILE or stdout. Sections, in order:
  1. WorldModel research trajectory   (source: world-model, ordered by entry:<n>)
  2. Consolidated principles          (tags: consolidated / principle:* — from /dream)
  3. Grounded dialogue                (source: app-dialectic, by conversation then node)
  4. Session context                  (source: report — SessionSeed rollups)
  5. Spatial index                    (node:<id> → the turns anchored there)

Usage:
  # agent recalls, unions the `hits` arrays into hits.json, then:
  python3 Scripts/memory-report.py --hits hits.json --out research-report.md
  # or:  cat hits.json | python3 Scripts/memory-report.py
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from typing import Any, Optional


def _tag_value(tags: list[str], prefix: str) -> Optional[str]:
    for t in tags:
        if t.startswith(prefix):
            return t[len(prefix):]
    return None


def _load_hits(raw: str) -> list[dict[str, Any]]:
    data = json.loads(raw)
    if isinstance(data, dict):
        data = data.get("hits", [])
    hits: list[dict[str, Any]] = []
    seen: set[str] = set()
    for h in data:
        if not isinstance(h, dict) or not h.get("text"):
            continue
        hid = str(h.get("id", ""))
        if hid and hid in seen:   # union of several recalls may overlap
            continue
        if hid:
            seen.add(hid)
        hits.append(h)
    return hits


def _by_source(hits: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    g: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for h in hits:
        g[str(h.get("source", "unknown"))].append(h)
    return g


def _occurred(h: dict[str, Any]) -> str:
    return str(h.get("occurred_at") or h.get("occurredAt") or h.get("created_at") or "")


def _tags(h: dict[str, Any]) -> list[str]:
    t = h.get("tags") or []
    return [str(x) for x in t]


def _render_world_model(hits: list[dict[str, Any]], out: list[str]) -> None:
    if not hits:
        return
    out.append("## WorldModel research trajectory")
    out.append("")
    out.append("_The Integrate → Benchmark → Optimize → Stop arc, in ledger order "
               "(`source: world-model`)._")
    out.append("")

    def entry_key(h: dict[str, Any]) -> tuple[int, str]:
        e = _tag_value(_tags(h), "entry:")
        return (int(e) if e and e.isdigit() else 9999, _occurred(h))

    for h in sorted(hits, key=entry_key):
        e = _tag_value(_tags(h), "entry:")
        cat = _tag_value(_tags(h), "category:")
        commits = [t[len("commit:"):] for t in _tags(h) if t.startswith("commit:")]
        head = f"- **#{e}**" if e else "-"
        if cat:
            head += f" _({cat})_"
        out.append(f"{head} {h['text']}")
        if commits:
            out.append(f"    - commits: {', '.join(commits)}")
    out.append("")


def _render_principles(hits: list[dict[str, Any]], out: list[str]) -> None:
    if not hits:
        return
    out.append("## Consolidated principles")
    out.append("")
    out.append("_Cross-session abstractions the `/dream` consolidation phases (2A/2B/2D) wrote "
               "over the persisted memory — not present in any single session._")
    out.append("")
    for h in sorted(hits, key=_occurred):
        principle = next((t[len("principle:"):] for t in _tags(h) if t.startswith("principle:")), None)
        label = f"**{principle}** — " if principle else ""
        out.append(f"- {label}{h['text']}")
    out.append("")


def _render_dialogue(hits: list[dict[str, Any]], out: list[str]) -> None:
    if not hits:
        return
    out.append("## Grounded dialogue")
    out.append("")
    out.append("_Spoken dialectic turns, each anchored to a 3D-workspace concept node "
               "(`node:<turnIndex>` — the same address the in-app workspace lit as the word "
               "was voiced)._")
    out.append("")
    by_conv: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for h in hits:
        by_conv[str(h.get("conversation_id") or h.get("conversationID") or "—")].append(h)
    for conv in sorted(by_conv):
        out.append(f"### {conv}")
        for h in sorted(by_conv[conv], key=_occurred):
            node = _tag_value(_tags(h), "node:")
            state = _tag_value(_tags(h), "state:")
            addr = f"[node:{node}]" if node is not None else "[·]"
            suffix = f"  _(EEG: {state})_" if state else ""
            out.append(f"- **{addr}** {h['text']}{suffix}")
        out.append("")


def _render_report(hits: list[dict[str, Any]], out: list[str]) -> None:
    if not hits:
        return
    out.append("## Session context")
    out.append("")
    for h in sorted(hits, key=_occurred):
        out.append(f"- {h['text']}")
    out.append("")


def _render_spatial_index(dialogue: list[dict[str, Any]], out: list[str]) -> None:
    if not dialogue:
        return
    idx: dict[int, list[str]] = defaultdict(list)
    for h in dialogue:
        node = _tag_value(_tags(h), "node:")
        if node is not None and node.lstrip("-").isdigit():
            snippet = " ".join(str(h["text"]).split())[:80]
            idx[int(node)].append(snippet)
    if not idx:
        return
    out.append("## Spatial index (node addresses)")
    out.append("")
    out.append("_Each `node:<id>` is a workspace concept-node position; recall "
               "`tags:[\"node:<id>\"]` to pull what was said there._")
    out.append("")
    for node in sorted(idx):
        out.append(f"- **node:{node}** ({len(idx[node])}) — {idx[node][0]}…")
    out.append("")


def build_report(hits: list[dict[str, Any]]) -> str:
    g = _by_source(hits)
    sources = sorted(g)
    occurreds = sorted(o for o in (_occurred(h) for h in hits) if o)
    span = f"{occurreds[0][:10]} → {occurreds[-1][:10]}" if occurreds else "n/a"

    out: list[str] = []
    out.append("# NeuralCompose — Cross-Session Research Report")
    out.append("")
    out.append(f"_Assembled from {len(hits)} claude-mind memory entries across "
               f"{len(sources)} source(s) [{', '.join(sources)}], span {span}. Grounded in the "
               f"persisted + `/dream`-consolidated store, not re-derived from the repo._")
    out.append("")

    _render_world_model(g.get("world-model", []), out)
    principles = [h for h in hits if any(t == "consolidated" or t.startswith("principle:")
                                         for t in _tags(h))]
    _render_principles(principles, out)
    dialogue = g.get("app-dialectic", [])
    _render_dialogue(dialogue, out)
    _render_report(g.get("report", []), out)
    _render_spatial_index(dialogue, out)

    return "\n".join(out).rstrip() + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="memory-report.py",
                                     description="Format claude-mind recall hits into a report.")
    parser.add_argument("--hits", type=str, default=None,
                        help="JSON file of recall hits (array, or {hits:[...]}). Default: stdin.")
    parser.add_argument("--out", type=str, default=None, help="write markdown here (default: stdout)")
    args = parser.parse_args(argv[1:])

    raw = open(args.hits).read() if args.hits else sys.stdin.read()
    if not raw.strip():
        print("memory-report: no input hits", file=sys.stderr)
        return 2
    hits = _load_hits(raw)
    report = build_report(hits)
    if args.out:
        with open(args.out, "w") as fh:
            fh.write(report)
        print(f"memory-report: {len(hits)} entries → {args.out}", file=sys.stderr)
    else:
        sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
