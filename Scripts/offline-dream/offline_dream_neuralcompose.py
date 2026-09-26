#!/usr/bin/env python3
"""Offline (no network) daily report for NeuralCompose.

Runs only the parts of the /dream cycle (~/.claude/commands/dream.md) that
require NO live model call:
  - Phase 1C.1-1C.4: latest night dir, overnight-review.py, consume-session.py
  - Phase 1C.7: memory-gate.py manifest + idempotent ingest into claude-mind-mcp
    (local CoreML embeddings, local SQLite -- verified no network dependency)

Explicitly SKIPPED, and this is a real capability gap, not hidden: Phase 2
(2A NREM clustering, 2B entity-graph consolidation, 2C TTL/forgetting, 2D REM
abstraction) requires an LLM to read memory text and make judgment calls --
there is no offline substitute for that. Run the real `/dream neuralcompose`
(live, requires network + Claude subscription) periodically by hand or via a
network-available scheduled job if that phase is wanted; this script does not
attempt to approximate it, and it never calls `forget`.
"""
import hashlib
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
NC_DIR = HOME / "Developer" / "NeuralCompose"
REC_DIR = HOME / "Documents" / "NeuralCompose" / "Recordings"
LOG_DIR = HOME / "Documents" / "NeuralCompose" / "InteractionLogs"
REPORT_PATH = LOG_DIR / "offline-dream-report.jsonl"
MCP_BIN = HOME / "Developer" / "claude-mind-mcp" / ".build" / "release" / "claude-mind-mcp"


def run(cmd, cwd=None, timeout=120):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except Exception as e:
        return 1, "", str(e)


def latest_night_dir():
    if not REC_DIR.exists():
        return None
    nights = sorted(REC_DIR.glob("night-*"), reverse=True)
    return nights[0] if nights else None


def phase_1c():
    out = {"phase": "1C", "night_dir": None, "engineering_qa": None, "physiology": None, "errors": []}
    night = latest_night_dir()
    if night is None:
        out["errors"].append("no night-* directory found under Recordings/")
        return out
    out["night_dir"] = str(night)

    venv_py = NC_DIR / "venv" / "bin" / "python3"
    if not venv_py.exists():
        out["errors"].append(f"venv python not found at {venv_py}")
        return out

    rc, so, se = run([str(venv_py), "Scripts/overnight-review.py", "--night-dir", str(night)], cwd=NC_DIR)
    out["engineering_qa"] = {"rc": rc, "stdout_tail": so[-2000:], "stderr_tail": se[-500:] if rc else None}

    csvs = sorted(night.glob("*.csv"), key=lambda p: p.stat().st_size, reverse=True)
    protocols = sorted(night.glob("protocol-*.json"), reverse=True)
    if csvs and protocols:
        rc2, so2, se2 = run(
            [str(venv_py), "Scripts/consume-session.py", str(csvs[0]), "--protocol", str(protocols[0])],
            cwd=NC_DIR, timeout=300,
        )
        out["physiology"] = {"rc": rc2, "stdout_tail": so2[-2000:], "stderr_tail": se2[-500:] if rc2 else None,
                              "eeg_csv": str(csvs[0]), "protocol": str(protocols[0])}
    else:
        out["errors"].append("no EEG csv + protocol pair found in night dir")
    return out


def mcp_call(method_name, args, timeout=30):
    """Speak MCP JSON-RPC to the local claude-mind-mcp binary. Local CoreML
    embeddings + local SQLite store -- no network call, verified 2026-08-07."""
    proc = subprocess.Popen([str(MCP_BIN)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        proc.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                       "clientInfo": {"name": "offline-dream-report", "version": "1.0"}},
        }) + "\n")
        proc.stdin.flush()
        proc.stdout.readline()
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}) + "\n")
        proc.stdin.flush()
        time.sleep(0.2)
        proc.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": method_name, "arguments": args},
        }) + "\n")
        proc.stdin.flush()
        line = proc.stdout.readline()
        return json.loads(line) if line else None
    finally:
        try:
            proc.stdin.close()
        except Exception:
            pass
        time.sleep(0.3)
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()


def phase_1c7_memory_gate():
    out = {"phase": "1C.7", "manifest_lines": 0, "new_entries": 0, "already_present": 0, "errors": []}
    gate_script = NC_DIR / "Scripts" / "memory-gate.py"
    if not gate_script.exists():
        out["errors"].append(f"memory-gate.py not found at {gate_script}")
        return out
    if not MCP_BIN.exists():
        out["errors"].append(f"claude-mind-mcp binary not found at {MCP_BIN}")
        return out

    venv_py = NC_DIR / "venv" / "bin" / "python3"
    py = str(venv_py) if venv_py.exists() else "python3"
    manifest_path = Path("/tmp/offline-dream-memory-gate.jsonl")
    rc, so, se = run([py, str(gate_script), "all", "--out", str(manifest_path)], cwd=NC_DIR, timeout=120)
    if rc != 0 or not manifest_path.exists():
        out["errors"].append(f"memory-gate.py failed rc={rc}: {se[-500:]}")
        return out

    lines = [l for l in manifest_path.read_text().splitlines() if l.strip()]
    out["manifest_lines"] = len(lines)

    for line in lines:
        try:
            payload = json.loads(line)
        except Exception as e:
            out["errors"].append(f"bad manifest line: {e}")
            continue
        tags = payload.get("tags", [])
        key_tag = next((t for t in tags if t.startswith("key:")), None)
        if key_tag is None:
            # derive one deterministically if the gate didn't include it
            h = hashlib.sha256(payload.get("text", "").encode()).hexdigest()[:16]
            key_tag = f"key:{h}"
            tags = list(tags) + [key_tag]
            payload["tags"] = tags

        recall_resp = mcp_call("recall", {"query": payload.get("text", "")[:200], "tags": [key_tag], "k": 1})
        hits = []
        try:
            content = recall_resp["result"]["content"][0]["text"]
            hits = json.loads(content).get("hits", [])
        except Exception as e:
            out["errors"].append(f"recall parse error: {e}")

        if hits:
            out["already_present"] += 1
            continue

        remember_args = {k: v for k, v in payload.items() if k in
                          ("text", "source", "conversation_id", "occurred_at", "tags", "metadata")}
        remember_resp = mcp_call("remember", remember_args)
        if remember_resp and not remember_resp.get("result", {}).get("isError"):
            out["new_entries"] += 1
        else:
            out["errors"].append(f"remember failed for key {key_tag}: {remember_resp}")

    return out


def main():
    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "script": "offline_dream_neuralcompose.py",
        "network_calls_made": False,
        "note": "Phase 2 (clustering/consolidation/forgetting/abstraction) intentionally skipped -- requires live model judgment, not available offline. No forget() calls ever issued by this script.",
    }
    report["phase_1c"] = phase_1c()
    report["phase_1c7"] = phase_1c7_memory_gate()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    with open(REPORT_PATH, "a") as f:
        f.write(json.dumps(report) + "\n")

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
