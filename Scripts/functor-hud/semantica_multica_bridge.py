#!/usr/bin/env python3
"""
semantica_multica_bridge.py
Drop-In Local Bridge Pairing Multica (Chronological Hash-Chained Ledger)
with Semantica (Causal ContextGraph, Hybrid Precedents, & PolicyEngine).

Supports all 5 `/semantica:decision` console verbs for Tab 1 & Tab 2:
  - record     : Ingests verified Multica turn into AgentContext & ContextGraph
  - query      : Queries recorded decision nodes and homology signatures
  - precedents : Runs hybrid structural + semantic precedent search (0.5 / 0.5)
  - influence  : Traces multi-hop INFLUENCED causal lineage around a decision_id
  - explain    : Runs PolicyEngine conflict & 4-defect-axis audit + causal summary

Epistemic Boundary: [MODEL ILLUSTRATION - RUNG_4_MODEL]
Strictly zero em-dashes and zero en-dashes.
"""

from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional

os.environ["SEMANTICA_DISABLE_PROGRESS"] = "1"

from semantica.context import AgentContext, ContextGraph
from semantica.context.decision_query import DecisionQuery
from semantica.context.policy_engine import PolicyEngine


DEFAULT_MULTICA_JSONL = Path("/Users/aurascoper/.gemini/antigravity/scratch/multica_channel.jsonl")


class SemanticaMulticaBridge:
    def __init__(self) -> None:
        self.ctx = AgentContext(decision_tracking=True, advanced_analytics=True)
        self.graph = ContextGraph(advanced_analytics=True)
        self.query_engine = DecisionQuery(self.ctx, self.graph)
        self.policy_engine = PolicyEngine()
        self.last_decision_id: Optional[str] = None
        self.seq_to_decision_id: Dict[int, str] = {}

    @staticmethod
    def _normalize_event(raw_event: Dict[str, Any]) -> Dict[str, Any]:
        """
        Accepts either snake_case (`seq_id`, `p_coord`) or camelCase (`seqId`, `p`)
        lines from `multica_channel.jsonl`.
        """
        seq_id = int(raw_event.get("seq_id", raw_event.get("seqId", 1)))
        modality = str(raw_event.get("modality", raw_event.get("source", "text")))
        verdict = str(raw_event.get("verdict", "Accepted"))
        p_vec = list(raw_event.get("p_coord", raw_event.get("p", [0.0, 0.0, 0.5])))
        while len(p_vec) < 3:
            p_vec.append(0.0)
        beta_0 = int(raw_event.get("beta_0", raw_event.get("beta0", 1)))
        beta_1 = int(raw_event.get("beta_1", raw_event.get("beta1", 4)))
        d_m = float(raw_event.get("d_mahalanobis", raw_event.get("mahalanobisD", 1.0)))
        theta_1 = float(raw_event.get("theta_1_deg", raw_event.get("theta1Deg", 18.0)))
        prev_hash = str(raw_event.get("prev_hash", raw_event.get("prevHash", "0000000000000000")))
        curr_hash = str(raw_event.get("curr_hash", raw_event.get("currHash", "0000000000000000")))
        wbr_mode = str(raw_event.get("wbr_mode", raw_event.get("wbrMode", "Focus")))
        mic_locked = bool(raw_event.get("hardware_mic_locked", modality == "hardware_mic" and "Incomplete" in verdict))
        return {
            "seq_id": seq_id,
            "modality": modality,
            "verdict": verdict,
            "p_coord": [float(p_vec[0]), float(p_vec[1]), float(p_vec[2])],
            "beta_0": beta_0,
            "beta_1": beta_1,
            "d_mahalanobis": d_m,
            "theta_1_deg": theta_1,
            "prev_hash": prev_hash,
            "curr_hash": curr_hash,
            "wbr_mode": wbr_mode,
            "hardware_mic_locked": mic_locked,
            "utterance": str(raw_event.get("utterance", raw_event.get("inputUtterance", ""))),
            "chosen_pole": str(raw_event.get("chosen_pole", raw_event.get("outcomeLabel", "synthesis"))),
        }

    def publish_dialectical_turn(self, multica_event: dict) -> str:
        """
        Ingests a verified Multica turn (text | commit | synthetic | hardware_mic)
        into Semantica's causal ContextGraph without external network calls.
        """
        ev = self._normalize_event(multica_event)
        seq_id = ev["seq_id"]
        modality = ev["modality"]
        verdict = ev["verdict"]  # "Accepted" | "Rejected" | "Incomplete"
        p_vec = ev["p_coord"]    # [z_valence, z_arousal, z_binding]
        beta_0 = ev["beta_0"]
        beta_1 = ev["beta_1"]
        d_m = ev["d_mahalanobis"]
        theta_1 = ev["theta_1_deg"]

        scenario_str = (
            f"Modality={modality} | p=({p_vec[0]:.3f},{p_vec[1]:.3f},{p_vec[2]:.3f}) "
            f"| Homology=(beta0:{beta_0}, beta1:{beta_1})"
        )
        reasoning_str = (
            f"Mahalanobis D_M={d_m:.3f}, 3D Tilt theta_1={theta_1:.1f} deg, "
            f"PrevHash={ev['prev_hash'][:12]}"
        )

        policy_report = self.policy_engine.enforce_decision_policy(ev)

        decision_id = self.ctx.record_decision(
            category=f"dialectical_turn_{modality}",
            scenario=scenario_str,
            reasoning=reasoning_str,
            outcome=verdict,
            metadata={
                "seq_id": seq_id,
                "p_coord": p_vec,
                "beta_0": beta_0,
                "beta_1": beta_1,
                "d_mahalanobis": d_m,
                "theta_1_deg": theta_1,
                "wbr_mode": ev["wbr_mode"],
                "prev_hash": ev["prev_hash"],
                "curr_hash": ev["curr_hash"],
                "policy_report": policy_report,
            },
        )

        self.graph.add_node(
            f"turn_{seq_id}",
            "DialecticalTurn",
            decision_id=decision_id,
            modality=modality,
            verdict=verdict,
            beta_0=beta_0,
            beta_1=beta_1,
            d_mahalanobis=d_m,
            theta_1_deg=theta_1,
            p_coord=p_vec,
            wbr_mode=ev["wbr_mode"],
        )
        self.graph.add_node(
            decision_id,
            "DecisionNode",
            seq_id=seq_id,
            modality=modality,
            verdict=verdict,
            beta_0=beta_0,
            beta_1=beta_1,
            d_mahalanobis=d_m,
            theta_1_deg=theta_1,
            p_coord=p_vec,
        )

        if self.last_decision_id is not None:
            self.graph.add_causal_relationship(
                self.last_decision_id,
                decision_id,
                relationship_type="INFLUENCED",
            )
        self.last_decision_id = decision_id
        self.seq_to_decision_id[seq_id] = decision_id
        return decision_id

    def trace_turn_lineage(self, decision_id: str, max_steps: int = 5) -> Dict[str, Any]:
        return self.graph.trace_decision_chain(decision_id, max_steps=max_steps)

    def load_multica_jsonl(self, jsonl_path: Path = DEFAULT_MULTICA_JSONL) -> int:
        if not jsonl_path.exists():
            return 0
        count = 0
        for line in jsonl_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            raw = json.loads(line)
            self.publish_dialectical_turn(raw)
            count += 1
        return count

    def execute_verb(
        self,
        verb: str,
        seq_id: Optional[int] = None,
        decision_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        target_id = decision_id
        if target_id is None and seq_id is not None:
            target_id = self.seq_to_decision_id.get(seq_id)
        if target_id is None:
            target_id = self.last_decision_id or "dec_000_none"

        dec = self.ctx.decisions.get(target_id, {})
        meta = dec.get("metadata", {})

        if verb == "record":
            return {
                "verb": "record",
                "status": "OK",
                "decision_id": target_id,
                "total_decisions": len(self.ctx.decision_order),
                "total_causal_edges": len(self.graph.edges),
                "summary": f"Recorded {len(self.ctx.decision_order)} Semantica DecisionNodes with {len(self.graph.edges)} INFLUENCED edges.",
            }
        elif verb == "query":
            return {
                "verb": "query",
                "status": "OK",
                "decision_id": target_id,
                "category": dec.get("category", "unknown"),
                "outcome": dec.get("outcome", "unknown"),
                "scenario": dec.get("scenario", ""),
                "reasoning": dec.get("reasoning", ""),
                "summary": f"Query[{target_id}]: {dec.get('outcome', 'N/A')} | {dec.get('scenario', '')}",
            }
        elif verb == "precedents":
            precs = self.query_engine.find_precedents_advanced(
                query_scenario=dec.get("scenario", "Modality=text"),
                p_coord=meta.get("p_coord", [0.0, 0.0, 0.5]),
                beta_0=int(meta.get("beta_0", 1)),
                beta_1=int(meta.get("beta_1", 4)),
                similarity_weights={"semantic": 0.5, "structural": 0.5},
                top_k=3,
            )
            top_str = ", ".join(
                f"{p['decision_id']}(hyb={p['hybrid_score']:.2f}, b1={p['beta_1']})"
                for p in precs
            )
            return {
                "verb": "precedents",
                "status": "OK",
                "decision_id": target_id,
                "precedents": precs,
                "summary": f"Hybrid Precedents (0.5 sem + 0.5 struct): {top_str}",
            }
        elif verb == "influence":
            lineage = self.trace_turn_lineage(target_id, max_steps=5)
            chain_str = " -> ".join(lineage["chain_ids"])
            return {
                "verb": "influence",
                "status": "OK",
                "decision_id": target_id,
                "lineage": lineage,
                "summary": f"INFLUENCED Chain ({lineage['total_hops']} hops): {chain_str}",
            }
        else:  # explain
            policy_rep = meta.get("policy_report", {})
            lineage = self.trace_turn_lineage(target_id, max_steps=5)
            axes = policy_rep.get("defect_axes", {})
            axes_str = " ".join(f"{k}:{v}" for k, v in axes.items())
            return {
                "verb": "explain",
                "status": "OK",
                "decision_id": target_id,
                "policy_report": policy_rep,
                "lineage": lineage,
                "summary": f"Explain[{target_id}]: Verdict={dec.get('outcome', 'N/A')} | Axes=[{axes_str}] | Chain={' -> '.join(lineage['chain_ids'])}",
            }


def main() -> None:
    parser = argparse.ArgumentParser(description="Semantica + Multica Local Bridge")
    parser.add_argument("--jsonl", type=str, default=str(DEFAULT_MULTICA_JSONL))
    parser.add_argument(
        "--verb",
        type=str,
        choices=["record", "query", "precedents", "influence", "explain"],
        default="explain",
    )
    parser.add_argument("--seq-id", type=int, default=None)
    parser.add_argument("--decision-id", type=str, default=None)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    bridge = SemanticaMulticaBridge()
    if args.self_test:
        sample_events = [
            {
                "seq_id": 1,
                "modality": "text",
                "verdict": "Accepted(text_coherence)",
                "p_coord": [0.38, 0.24, 0.86],
                "beta_0": 1,
                "beta_1": 4,
                "d_mahalanobis": 1.12,
                "theta_1_deg": 14.2,
                "prev_hash": "0000000000000000",
                "curr_hash": "a1b2c3d4e5f60001",
                "wbr_mode": "Focus",
            },
            {
                "seq_id": 2,
                "modality": "commit",
                "verdict": "Accepted(commit_synthesized)",
                "p_coord": [0.51, 0.62, 0.79],
                "beta_0": 1,
                "beta_1": 7,
                "d_mahalanobis": 1.84,
                "theta_1_deg": 28.6,
                "prev_hash": "a1b2c3d4e5f60001",
                "curr_hash": "b2c3d4e5f6a10002",
                "wbr_mode": "Frustration",
            },
            {
                "seq_id": 3,
                "modality": "hardware_mic",
                "verdict": "Incomplete(hardware_mic_locked)",
                "p_coord": [0.0, 0.0, 0.0],
                "beta_0": 1,
                "beta_1": 7,
                "d_mahalanobis": 1.84,
                "theta_1_deg": 28.6,
                "prev_hash": "b2c3d4e5f6a10002",
                "curr_hash": "c3d4e5f6a1b20003",
                "wbr_mode": "Frustration",
                "hardware_mic_locked": True,
            },
        ]
        ids = [bridge.publish_dialectical_turn(ev) for ev in sample_events]
        lineage = bridge.trace_turn_lineage(ids[1], max_steps=5)
        assert len(lineage["chain_ids"]) == 3, f"Expected 3-node chain, got {lineage['chain_ids']}"
        out = {
            "status": "PASS",
            "decisions_recorded": len(ids),
            "decision_ids": ids,
            "lineage": lineage,
            "precedents": bridge.execute_verb("precedents", decision_id=ids[1])["precedents"],
            "explain_locked_mic": bridge.execute_verb("explain", decision_id=ids[2]),
        }
        print(json.dumps(out))
        return

    loaded = bridge.load_multica_jsonl(Path(args.jsonl))
    if loaded == 0:
        bridge.publish_dialectical_turn({
            "seq_id": 1,
            "modality": "synthetic",
            "verdict": "Accepted(seed_turn)",
            "p_coord": [0.42, 0.35, 0.88],
            "beta_0": 1,
            "beta_1": 6,
            "d_mahalanobis": 1.45,
            "theta_1_deg": 22.4,
            "prev_hash": "0000000000000000",
            "curr_hash": "f00seed000000001",
            "wbr_mode": "Frustration",
        })
    res = bridge.execute_verb(args.verb, seq_id=args.seq_id, decision_id=args.decision_id)
    print(json.dumps(res))


if __name__ == "__main__":
    main()
