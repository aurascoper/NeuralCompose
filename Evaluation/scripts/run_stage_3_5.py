#!/usr/bin/env python3
"""Stage 3.5 offline policy evaluation runner.

Single script covering Stage 3.5's work packages (see
docs/evaluation/STAGE_3_4_3_5_DESIGN.md); --work-package selects which
pre-registered hypothesis to evaluate. Only "P" (pipeline policy
comparison, 3.5-P-pipeline-policies) is implemented so far — B/C/D/E
need new corpus construction or generation-loop confidence signals
that don't exist yet (see STAGE_3_5_READINESS.md's suggested ordering).

No production Swift code changes: this reads only frozen Stage 3.4
evidence (Evaluation/results/leaderboard.json,
Evaluation/results/embeddings/leaderboard.json) and the corpus already
used for Stage 3.4 generation eval, and writes to
Evaluation/results/stage_3_5/.

## Methodology for 3.5-P (read before trusting the output)

hypothesis_registry.json's policy_registry binds each of the 4 named
policies (Fast/Balanced/Quality/Adaptive) to BOTH an `embedding` role
and a `generator` role. Fast/Balanced/Quality bind to a single
abstract `auto:*` role each; Adaptive binds to a routing rule that
picks a role per input.

`auto:*` role resolution (no canonical spec exists for these labels —
this is a methodological choice made here, not something read out of
project docs, so it's stated explicitly):
  - fastest_available -> Pareto-frontier candidate with the best raw
    latency metric (lowest generate_time_mean / warm_encode_ms)
  - best_overall       -> Pareto-frontier candidate with the highest
    overall_score
  - best_quality       -> Pareto-frontier candidate with the highest
    norm_quality
  - mid_tier           -> Pareto-frontier candidate closest to the
    median overall_score among the Pareto set

Adaptive's routing rule is resolved against
Evaluation/corpora/generation_eval_prompts_v1.json's prompt categories
as the closest available proxy for "input type" (no corpus is labeled
with the routing rule's exact short_command/technical/uncertain/long
taxonomy):
  - category == "command-reformulation"      -> short_command
  - category == "technical-term-preservation" -> technical
  - everything else                           -> uncertain

Per policy_registry's own prose ("short commands to fast pipeline,
long/uncertain to quality pipeline"), the generator's 2-branch rule
(short_command->fastest, long->quality) is read as short_command vs.
everything-else, matching that prose exactly. The embedding rule's
"uncertain -> confidence_gated" branch has no real confidence signal
to gate on (the same gap 3.5-E is pre-registered to investigate) --
resolved here as auto:mid_tier with this caveat stated, not as an
implemented gating mechanism.

Combining an embedding leg and a generator leg into one pipeline
metric per policy: latency sums (stages run sequentially: embed, then
generate); memory sums (both models are resident in the app's process
simultaneously, matching AppContainer's actual architecture, not a
max()); quality is the unweighted mean of each leg's own norm_quality.
This is a simplification, stated here rather than left implicit.
"""

from __future__ import annotations

import argparse
import json
import statistics
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
GENERATOR_LEADERBOARD = REPO_ROOT / "Evaluation/results/leaderboard.json"
EMBEDDING_LEADERBOARD = REPO_ROOT / "Evaluation/results/embeddings/leaderboard.json"
PROMPTS_CORPUS = REPO_ROOT / "Evaluation/corpora/generation_eval_prompts_v1.json"
HYPOTHESIS_REGISTRY = REPO_ROOT / "Evaluation/corpora/hypothesis_registry.json"
DECISION_REGISTRY = REPO_ROOT / "Evaluation/reports/decision_registry.md"
RESULTS_DIR = REPO_ROOT / "Evaluation/results/stage_3_5"


def load_json(path: Path) -> Any:
    with path.open() as f:
        return json.load(f)


def pareto_candidates(leaderboard: dict) -> list[dict]:
    """The candidates whose label appears in the leaderboard's own
    pareto_frontier list — resolution only ever picks among these, never
    a dominated candidate. The generator leaderboard's frontier lists bare
    `name`s; the embedding leaderboard's frontier lists `"name (runtime)"`
    (it has both Python and mlx-swift runtimes for some models) — a
    candidate's label is built to match whichever convention this
    leaderboard uses."""
    frontier_names = set(leaderboard["pareto_frontier"])

    return [c for c in leaderboard["candidates"] if candidate_label(c) in frontier_names]


def candidate_label(c: dict) -> str:
    """Disambiguated display label. The embedding leaderboard has both a
    Python and an mlx-swift runtime for some models (e.g. all-MiniLM-L6-v2)
    with very different resolved metrics — `c["name"]` alone would silently
    collapse that distinction in the output."""
    return f"{c['name']} ({c['runtime']})" if "runtime" in c else c["name"]


def resolve_auto(role: str, pareto: list[dict], *, latency_key: str) -> dict:
    if role == "fastest_available":
        return min(pareto, key=lambda c: c[latency_key])
    if role == "best_overall":
        return max(pareto, key=lambda c: c["overall_score"])
    if role == "best_quality":
        return max(pareto, key=lambda c: c["norm_quality"])
    if role == "mid_tier":
        scores = sorted(pareto, key=lambda c: c["overall_score"])
        median_score = statistics.median(c["overall_score"] for c in scores)
        return min(scores, key=lambda c: abs(c["overall_score"] - median_score))
    raise ValueError(f"unknown auto: role {role!r}")


def categorize_prompts(prompts: list[dict]) -> dict[str, list[dict]]:
    buckets: dict[str, list[dict]] = {"short_command": [], "technical": [], "uncertain": []}
    for p in prompts:
        if p["category"] == "command-reformulation":
            buckets["short_command"].append(p)
        elif p["category"] == "technical-term-preservation":
            buckets["technical"].append(p)
        else:
            buckets["uncertain"].append(p)
    return buckets


def resolve_generator_leg(role: str, pareto: list[dict]) -> dict:
    return resolve_auto(role, pareto, latency_key="generate_time_mean")


def resolve_embedding_leg(role: str, pareto: list[dict]) -> dict:
    return resolve_auto(role, pareto, latency_key="warm_encode_ms")


def resolve_fixed_policy(policy: dict, gen_pareto: list[dict], emb_pareto: list[dict]) -> dict:
    gen_role = policy["generator"].removeprefix("auto:")
    emb_role = policy["embedding"].removeprefix("auto:")
    return {
        "generator": resolve_generator_leg(gen_role, gen_pareto),
        "embedding": resolve_embedding_leg(emb_role, emb_pareto),
    }


def resolve_adaptive_policy(
    buckets: dict[str, list[dict]], gen_pareto: list[dict], emb_pareto: list[dict]
) -> dict:
    """Category-weighted composite across Adaptive's routing branches,
    weighted by how many corpus prompts fall in each category bucket."""
    total = sum(len(v) for v in buckets.values())

    gen_short = resolve_generator_leg("fastest_available", gen_pareto)
    gen_rest = resolve_generator_leg("best_quality", gen_pareto)
    gen_weight_short = len(buckets["short_command"]) / total
    gen_weight_rest = 1.0 - gen_weight_short

    emb_short = resolve_embedding_leg("fastest_available", emb_pareto)
    emb_technical = resolve_embedding_leg("best_overall", emb_pareto)
    emb_uncertain = resolve_embedding_leg("mid_tier", emb_pareto)  # confidence_gated caveat, see module docstring
    emb_weight_short = len(buckets["short_command"]) / total
    emb_weight_technical = len(buckets["technical"]) / total
    emb_weight_uncertain = len(buckets["uncertain"]) / total

    return {
        "generator_branches": [
            {"branch": "short_command", "weight": gen_weight_short, "model": candidate_label(gen_short)},
            {"branch": "everything_else", "weight": gen_weight_rest, "model": candidate_label(gen_rest)},
        ],
        "embedding_branches": [
            {"branch": "short_command", "weight": emb_weight_short, "model": candidate_label(emb_short)},
            {"branch": "technical", "weight": emb_weight_technical, "model": candidate_label(emb_technical)},
            {"branch": "uncertain (confidence_gated -> mid_tier proxy)", "weight": emb_weight_uncertain, "model": candidate_label(emb_uncertain)},
        ],
        "generator_composite": {
            "generate_time_mean": gen_weight_short * gen_short["generate_time_mean"]
            + gen_weight_rest * gen_rest["generate_time_mean"],
            "peak_rss_mb": gen_weight_short * gen_short["peak_rss_mb"]
            + gen_weight_rest * gen_rest["peak_rss_mb"],
            "norm_quality": gen_weight_short * gen_short["norm_quality"]
            + gen_weight_rest * gen_rest["norm_quality"],
        },
        "embedding_composite": {
            "warm_encode_ms": emb_weight_short * emb_short["warm_encode_ms"]
            + emb_weight_technical * emb_technical["warm_encode_ms"]
            + emb_weight_uncertain * emb_uncertain["warm_encode_ms"],
            "peak_rss_mb": emb_weight_short * emb_short["peak_rss_mb"]
            + emb_weight_technical * emb_technical["peak_rss_mb"]
            + emb_weight_uncertain * emb_uncertain["peak_rss_mb"],
            "norm_quality": emb_weight_short * emb_short["norm_quality"]
            + emb_weight_technical * emb_technical["norm_quality"]
            + emb_weight_uncertain * emb_uncertain["norm_quality"],
        },
    }


def pipeline_metrics_from_legs(
    generator: dict, embedding: dict
) -> dict:
    """See module docstring: latency sums, memory sums, quality means."""
    return {
        "quality": (generator["norm_quality"] + embedding["norm_quality"]) / 2.0,
        "latency_s": generator["generate_time_mean"] + embedding["warm_encode_ms"] / 1000.0,
        "memory_mb": generator["peak_rss_mb"] + embedding["peak_rss_mb"],
    }


def compute_pareto_frontier(policies: dict[str, dict]) -> list[str]:
    """Pareto-optimal policy names: quality maximized, latency/memory minimized."""
    names = list(policies.keys())
    frontier = []
    for name in names:
        p = policies[name]["pipeline"]
        dominated = False
        for other_name in names:
            if other_name == name:
                continue
            o = policies[other_name]["pipeline"]
            at_least_as_good = (
                o["quality"] >= p["quality"]
                and o["latency_s"] <= p["latency_s"]
                and o["memory_mb"] <= p["memory_mb"]
            )
            strictly_better = (
                o["quality"] > p["quality"]
                or o["latency_s"] < p["latency_s"]
                or o["memory_mb"] < p["memory_mb"]
            )
            if at_least_as_good and strictly_better:
                dominated = True
                break
        if not dominated:
            frontier.append(name)
    return frontier


def evaluate_success_criterion(policies: dict[str, dict], frontier: list[str]) -> dict:
    """3.5-P success criterion: Adaptive is Pareto-optimal OR within 5% of
    the best fixed mode on every axis."""
    if "Adaptive" in frontier:
        return {"pass": True, "reason": "Adaptive is on the Pareto frontier"}

    adaptive = policies["Adaptive"]["pipeline"]
    fixed_names = [n for n in policies if n != "Adaptive"]
    best_fixed = {
        "quality": max(policies[n]["pipeline"]["quality"] for n in fixed_names),
        "latency_s": min(policies[n]["pipeline"]["latency_s"] for n in fixed_names),
        "memory_mb": min(policies[n]["pipeline"]["memory_mb"] for n in fixed_names),
    }
    within_5pct = {
        "quality": adaptive["quality"] >= best_fixed["quality"] * 0.95,
        "latency_s": adaptive["latency_s"] <= best_fixed["latency_s"] * 1.05,
        "memory_mb": adaptive["memory_mb"] <= best_fixed["memory_mb"] * 1.05,
    }
    return {
        "pass": all(within_5pct.values()),
        "reason": "Adaptive not on frontier; per-axis within-5%-of-best-fixed check",
        "best_fixed": best_fixed,
        "within_5pct": within_5pct,
    }


def run_work_package_p() -> dict:
    gen_leaderboard = load_json(GENERATOR_LEADERBOARD)
    emb_leaderboard = load_json(EMBEDDING_LEADERBOARD)
    prompts = load_json(PROMPTS_CORPUS)["prompts"]

    gen_pareto = pareto_candidates(gen_leaderboard)
    emb_pareto = pareto_candidates(emb_leaderboard)
    buckets = categorize_prompts(prompts)

    registry = load_json(HYPOTHESIS_REGISTRY)
    policy_defs = registry["policy_registry"]["policies"]

    policies: dict[str, dict] = {}
    for policy in policy_defs:
        name = policy["name"]
        if name == "Adaptive":
            resolved = resolve_adaptive_policy(buckets, gen_pareto, emb_pareto)
            pipeline = pipeline_metrics_from_legs(
                resolved["generator_composite"], resolved["embedding_composite"]
            )
            policies[name] = {"resolution": resolved, "pipeline": pipeline}
        else:
            resolved = resolve_fixed_policy(policy, gen_pareto, emb_pareto)
            pipeline = pipeline_metrics_from_legs(resolved["generator"], resolved["embedding"])
            policies[name] = {
                "resolution": {
                    "generator_model": candidate_label(resolved["generator"]),
                    "embedding_model": candidate_label(resolved["embedding"]),
                },
                "pipeline": pipeline,
            }

    frontier = compute_pareto_frontier(policies)
    verdict = evaluate_success_criterion(policies, frontier)

    return {
        "hypothesis_id": "3.5-P-pipeline-policies",
        "evaluated_at": datetime.now(timezone.utc).isoformat(),
        "prompt_category_buckets": {k: len(v) for k, v in buckets.items()},
        "policies": policies,
        "pareto_frontier": frontier,
        "success_criterion": "Adaptive mode is Pareto-optimal OR within 5% of the best fixed mode on every axis",
        "verdict": verdict,
    }


def update_hypothesis_registry(result: dict) -> None:
    registry = load_json(HYPOTHESIS_REGISTRY)
    for entry in registry["stage_3_5"]:
        if entry["id"] == "3.5-P-pipeline-policies":
            entry["status"] = "evaluated"
            entry["status_note"] = (
                f"Evaluated {result['evaluated_at']}. Verdict: "
                f"{'PASS' if result['verdict']['pass'] else 'FAIL'} — {result['verdict']['reason']}. "
                f"Pareto frontier: {result['pareto_frontier']}. See Evaluation/results/stage_3_5/pipeline_policies.json."
            )
            break
    else:
        raise ValueError("3.5-P-pipeline-policies not found in hypothesis_registry.json")
    with HYPOTHESIS_REGISTRY.open("w") as f:
        json.dump(registry, f, indent=2)
        f.write("\n")


def write_markdown_summary(result: dict, path: Path) -> None:
    lines = [
        "# Stage 3.5-P: Pipeline Policy Comparison",
        "",
        f"Evaluated: {result['evaluated_at']}",
        "",
        "**Methodology caveats** — see `run_stage_3_5.py`'s module docstring for the full "
        "reasoning: `auto:*` role resolution and Adaptive's routing-bucket assignment are "
        "methodological choices made by this script, not read from a canonical spec. The "
        "embedding routing rule's `uncertain -> confidence_gated` branch has no real confidence "
        "signal to gate on yet (same gap `3.5-E` is pre-registered to investigate) and is "
        "resolved as a `mid_tier` proxy instead.",
        "",
        f"Prompt category buckets (of {sum(result['prompt_category_buckets'].values())} corpus prompts): "
        + ", ".join(f"{k}={v}" for k, v in result["prompt_category_buckets"].items()),
        "",
        "## Resolved policies",
        "",
        "| Policy | Quality | Latency (s) | Memory (MB) |",
        "|---|---|---|---|",
    ]
    for name, data in result["policies"].items():
        p = data["pipeline"]
        lines.append(f"| {name} | {p['quality']:.4f} | {p['latency_s']:.3f} | {p['memory_mb']:.1f} |")
    lines += [
        "",
        f"**Pareto frontier:** {', '.join(result['pareto_frontier'])}",
        "",
        f"## Success criterion: {result['success_criterion']}",
        "",
        f"**Verdict: {'PASS' if result['verdict']['pass'] else 'FAIL'}** — {result['verdict']['reason']}",
        "",
    ]
    if "within_5pct" in result["verdict"]:
        lines.append("| Axis | Best fixed | Adaptive within 5%? |")
        lines.append("|---|---|---|")
        for axis, ok in result["verdict"]["within_5pct"].items():
            lines.append(f"| {axis} | {result['verdict']['best_fixed'][axis]:.4f} | {'yes' if ok else 'no'} |")
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--work-package", required=True, choices=["P"],
        help="Only P (pipeline policy comparison) is implemented so far.",
    )
    parser.add_argument(
        "--no-write", action="store_true",
        help="Print the result without writing to Evaluation/results/stage_3_5/ or updating the hypothesis registry.",
    )
    args = parser.parse_args()

    result = run_work_package_p()

    print(json.dumps(result, indent=2, default=str))

    if not args.no_write:
        RESULTS_DIR.mkdir(parents=True, exist_ok=True)
        json_path = RESULTS_DIR / "pipeline_policies.json"
        md_path = RESULTS_DIR / "pipeline_policies.md"
        with json_path.open("w") as f:
            json.dump(result, f, indent=2, default=str)
            f.write("\n")
        write_markdown_summary(result, md_path)
        update_hypothesis_registry(result)
        print(f"\nWrote {json_path}")
        print(f"Wrote {md_path}")
        print("Updated hypothesis_registry.json's 3.5-P status")


if __name__ == "__main__":
    main()
