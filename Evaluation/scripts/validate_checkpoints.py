#!/usr/bin/env python3
"""
Benchmark artifact validator — schema, provenance, and aggregate traceability.

Guards against the failure classes that have actually occurred in this
project:
  - orphaned aggregate values (leaderboard cited MiniLM at 1980 emb/s while
    the on-disk checkpoint said 1015 and the source JSON of the 1980 run was
    lost — see Evaluation/reports/throughput_discrepancy.md)
  - silent schema drift between harness versions
  - artifacts with no provenance (cannot be traced to a commit/machine)
  - corpus fixtures mutated after results were produced

Checks:
  1. Corpus integrity  — corpora/*.json against MANIFEST.sha256 (if frozen)
  2. Embedding checkpoints — results/embeddings/<model>/<runtime>/benchmark.json
  3. Generation checkpoints — results/candidates/<name>/{raw.json, metadata.json}
  4. Aggregate traceability — every leaderboard row re-derivable (1e-6) from
     its on-disk checkpoint via the same extract_metrics() the pipeline uses

Levels: FAIL (exit 1) — evidence is wrong or untraceable.
        WARN (exit 0, FAIL under --strict) — legacy/pre-provenance artifacts,
        unfrozen corpora, in-progress candidates.

Usage:
  python3 Evaluation/scripts/validate_checkpoints.py [--strict] [--json PATH]
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from provenance import sha256_file

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
CORPORA_DIR = EVAL_DIR / "corpora"
RESULTS_DIR = EVAL_DIR / "results"
EMBEDDINGS_DIR = RESULTS_DIR / "embeddings"
CANDIDATES_DIR = RESULTS_DIR / "candidates"
MANIFEST_PATH = CORPORA_DIR / "MANIFEST.sha256"

FLOAT_TOLERANCE = 1e-6

# Runtimes benchmarked by the Python pipeline (full metric schema) vs the
# Swift EmbeddingBench eval-layout emission (RQ1 consistency evidence only —
# no quality/stability blocks, by design; see EvalCheckpointWriter.swift).
FULL_SCHEMA_RUNTIMES = {"python", "mlx"}
RQ1_ONLY_RUNTIMES = {"coreml", "mlx-swift"}

EMBEDDING_BASE_FIELDS = ["model_name", "repo_id", "runtime", "timestamp", "status"]
EMBEDDING_EVALUATED_FIELDS = [
    "dimension", "cold_load_time", "warm_encode_time_ms",
    "embeddings_per_second", "peak_rss_mb",
]
EMBEDDING_EVALUATED_NESTED = [
    ("stability", "overall", "mean"),
    ("stability", "overall", "std"),
    ("stability", "overall", "n"),
    ("paraphrase_pairs", "mean"),
    ("antonym_pairs", "mean"),
    ("command_groups", "separation_ratio"),
    ("retrieval", "mean_top1_similarity"),
]
EMBEDDING_EVALUATED_BLOCKS = ["nn_consistency", "neighborhood_stability", "embedding_sample"]
RQ1_EVALUATED_FIELDS = ["dimension", "cold_load_time", "embeddings_per_second"]

PROVENANCE_FIELDS = ["git_commit", "git_branch", "device", "macos_version",
                     "python_version", "packages"]

GENERATION_PROVENANCE_FIELDS = ["candidates_fixture_version", "prompts_fixture_version",
                                "device", "git_commit", "macos_version"]

# Leaderboard columns that must re-derive exactly from the checkpoint.
# norm_* and overall_score are normalization-set-dependent and are excluded.
EMBEDDING_TRACE_FIELDS = [
    "dimension", "model_size_mb", "cold_load_time", "warm_encode_ms",
    "embeddings_per_second", "peak_rss_mb", "stability_mean", "quality_score",
    "paraphrase_mean", "antonym_mean", "separation_ratio", "retrieval_top1",
    "nn_consistency",
]
GENERATION_TRACE_FIELDS = [
    "cold_load_time", "warm_load_time", "peak_rss_mb", "generate_time_mean",
    "tokens_per_second_mean", "word_count_ratio_mean", "meaning_cosine_mean",
    "stability", "instruction_following",
]


class Report:
    def __init__(self, strict=False):
        self.strict = strict
        self.findings = []

    def fail(self, category, path, message):
        self.findings.append({"level": "FAIL", "category": category,
                              "path": str(path), "message": message})

    def warn(self, category, path, message):
        level = "FAIL" if self.strict else "WARN"
        self.findings.append({"level": level, "category": category,
                              "path": str(path), "message": message})

    def info(self, category, path, message):
        self.findings.append({"level": "INFO", "category": category,
                              "path": str(path), "message": message})

    @property
    def n_fail(self):
        return sum(1 for f in self.findings if f["level"] == "FAIL")

    @property
    def n_warn(self):
        return sum(1 for f in self.findings if f["level"] == "WARN")


def _get_nested(data, keys):
    cur = data
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def _load_json(path, report, category):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        report.fail(category, path, f"unparseable JSON: {e}")
        return None


def rel(path):
    try:
        return Path(path).relative_to(REPO_ROOT)
    except ValueError:
        return path


# ---------------------------------------------------------------------------
# 1. Corpus integrity
# ---------------------------------------------------------------------------

def check_corpora(report):
    if not MANIFEST_PATH.exists():
        report.warn("corpus-freeze", MANIFEST_PATH,
                    "corpora not frozen yet (no MANIFEST.sha256) — run "
                    "freeze_corpora.py at Gate C")
        return
    for line in MANIFEST_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            expected, name = line.split(None, 1)
            name = name.lstrip("*")
        except ValueError:
            report.fail("corpus-integrity", MANIFEST_PATH, f"malformed line: {line!r}")
            continue
        path = CORPORA_DIR / name
        if not path.exists():
            report.fail("corpus-integrity", path, "manifested corpus file missing")
            continue
        actual = sha256_file(path)
        if actual != expected:
            report.fail("corpus-integrity", path,
                        f"sha256 mismatch — corpora are versioned-immutable; "
                        f"expected {expected[:12]}…, got {actual[:12]}…")


# ---------------------------------------------------------------------------
# 2. Embedding checkpoints
# ---------------------------------------------------------------------------

def check_embedding_checkpoints(report):
    if not EMBEDDINGS_DIR.exists():
        report.fail("embedding-checkpoints", EMBEDDINGS_DIR, "directory missing")
        return
    for model_dir in sorted(EMBEDDINGS_DIR.iterdir()):
        if not model_dir.is_dir() or model_dir.name == "plots":
            continue
        runtime_dirs = [d for d in model_dir.iterdir() if d.is_dir()]
        has_any_benchmark = False
        for rt_dir in sorted(runtime_dirs):
            bench_path = rt_dir / "benchmark.json"
            archived = list(rt_dir.glob("benchmark.failed-*.json"))
            if archived:
                report.info("embedding-checkpoints", rt_dir,
                            f"{len(archived)} archived failed attempt(s) preserved")
            if not bench_path.exists():
                continue
            has_any_benchmark = True
            bench = _load_json(bench_path, report, "embedding-checkpoints")
            if bench is None:
                continue
            for field in EMBEDDING_BASE_FIELDS:
                if field not in bench:
                    report.fail("schema", bench_path, f"missing required field: {field}")
            runtime = bench.get("runtime")
            if runtime and runtime != rt_dir.name:
                report.fail("schema", bench_path,
                            f"runtime field {runtime!r} != directory {rt_dir.name!r}")
            status = str(bench.get("status", ""))
            if status == "evaluated":
                if runtime in RQ1_ONLY_RUNTIMES:
                    required = RQ1_EVALUATED_FIELDS + ["embedding_sample"]
                    for field in required:
                        if field not in bench:
                            report.fail("schema", bench_path,
                                        f"missing field for RQ1 checkpoint: {field}")
                else:
                    for field in EMBEDDING_EVALUATED_FIELDS:
                        if field not in bench:
                            report.fail("schema", bench_path, f"missing field: {field}")
                    for keys in EMBEDDING_EVALUATED_NESTED:
                        if _get_nested(bench, keys) is None:
                            report.fail("schema", bench_path,
                                        f"missing nested field: {'.'.join(keys)}")
                    for block in EMBEDDING_EVALUATED_BLOCKS:
                        if block not in bench:
                            report.fail("schema", bench_path, f"missing block: {block}")
                sample = bench.get("embedding_sample")
                if isinstance(sample, dict):
                    texts = sample.get("texts", [])
                    embs = sample.get("embeddings", [])
                    if len(texts) != len(embs):
                        report.fail("schema", bench_path,
                                    f"embedding_sample length mismatch: "
                                    f"{len(texts)} texts vs {len(embs)} embeddings")
            elif status.startswith("failed"):
                if "failure_class" not in bench:
                    report.warn("schema", bench_path,
                                "failed checkpoint lacks failure_class (pre-classification artifact)")
            # Provenance
            prov = bench.get("provenance")
            if prov is None:
                report.warn("provenance", bench_path,
                            "pre-provenance legacy artifact (no provenance block)")
            else:
                for field in PROVENANCE_FIELDS:
                    if field not in prov:
                        report.fail("provenance", bench_path,
                                    f"provenance missing field: {field}")
        meta_path = model_dir / "metadata.json"
        if not meta_path.exists():
            if has_any_benchmark:
                # Legacy condition: early runs didn't write metadata and it
                # cannot be honestly backfilled. New runs always write it.
                report.warn("embedding-checkpoints", model_dir,
                            "benchmark.json present but metadata.json missing "
                            "(legacy artifact)")
            else:
                report.warn("embedding-checkpoints", model_dir,
                            "no benchmark.json and no metadata.json — in-progress "
                            "or aborted candidate")
        elif _load_json(meta_path, report, "embedding-checkpoints") is None:
            pass


# ---------------------------------------------------------------------------
# 3. Generation checkpoints
# ---------------------------------------------------------------------------

def check_generation_checkpoints(report):
    if not CANDIDATES_DIR.exists():
        report.fail("generation-checkpoints", CANDIDATES_DIR, "directory missing")
        return
    for cand_dir in sorted(CANDIDATES_DIR.iterdir()):
        if not cand_dir.is_dir():
            continue
        meta_path = cand_dir / "metadata.json"
        raw_path = cand_dir / "raw.json"
        meta = None
        if not meta_path.exists():
            report.fail("generation-checkpoints", cand_dir, "metadata.json missing")
        else:
            meta = _load_json(meta_path, report, "generation-checkpoints")
            if meta is not None and "provenance" not in meta:
                report.warn("provenance", meta_path,
                            "pre-provenance legacy metadata (no provenance block)")
        if not raw_path.exists():
            error = (meta or {}).get("error")
            if not error:
                report.warn("generation-checkpoints", cand_dir,
                            "no raw.json and no recorded error — in-progress or "
                            "silently aborted candidate")
            else:
                report.info("generation-checkpoints", cand_dir,
                            f"terminal failure recorded: {error}")
            continue
        raw = _load_json(raw_path, report, "generation-checkpoints")
        if raw is None:
            continue
        if "schema_version" not in raw:
            report.fail("schema", raw_path, "missing schema_version")
        prov = raw.get("provenance")
        if prov is None:
            report.fail("provenance", raw_path,
                        "raw.json has no provenance block (GenerationEval always "
                        "writes one — artifact predates it or was hand-edited)")
        else:
            for field in GENERATION_PROVENANCE_FIELDS:
                if field not in prov:
                    report.fail("provenance", raw_path,
                                f"provenance missing field: {field}")
        cands = raw.get("candidates", [])
        if not cands:
            report.fail("schema", raw_path, "empty candidates array")
            continue
        c = cands[0]
        if c.get("status") == "evaluated" and not c.get("prompts"):
            report.fail("schema", raw_path, "evaluated candidate has no prompts")


# ---------------------------------------------------------------------------
# 4. Aggregate traceability
# ---------------------------------------------------------------------------

def _compare_traced(report, lb_path, entry, extracted, fields, checkpoint_path):
    for field in fields:
        stored = entry.get(field)
        derived = extracted.get(field)
        if stored is None and derived is None:
            continue
        if stored is None or derived is None:
            report.fail("traceability", lb_path,
                        f"{entry.get('name')}: field {field} stored={stored!r} "
                        f"vs re-derived={derived!r} from {rel(checkpoint_path)}")
            continue
        if isinstance(stored, (int, float)) and isinstance(derived, (int, float)):
            if abs(float(stored) - float(derived)) > FLOAT_TOLERANCE:
                report.fail("traceability", lb_path,
                            f"{entry.get('name')} [{field}]: leaderboard says "
                            f"{stored} but checkpoint {rel(checkpoint_path)} "
                            f"re-derives {derived} — orphaned aggregate value")
        elif stored != derived:
            report.fail("traceability", lb_path,
                        f"{entry.get('name')} [{field}]: {stored!r} != {derived!r}")


def check_embedding_traceability(report):
    lb_path = EMBEDDINGS_DIR / "leaderboard.json"
    if not lb_path.exists():
        report.warn("traceability", lb_path, "embedding leaderboard missing")
        return
    lb = _load_json(lb_path, report, "traceability")
    if lb is None:
        return
    from embedding_streaming_benchmark import extract_metrics
    for entry in lb.get("candidates", []):
        name, runtime = entry.get("name"), entry.get("runtime")
        bench_path = EMBEDDINGS_DIR / name / runtime / "benchmark.json"
        if not bench_path.exists():
            report.fail("traceability", lb_path,
                        f"{name} ({runtime}): leaderboard entry has NO on-disk "
                        f"checkpoint — value cannot be traced to evidence")
            continue
        bench = _load_json(bench_path, report, "traceability")
        if bench is None:
            continue
        extracted = extract_metrics(bench)
        if extracted is None:
            report.fail("traceability", lb_path,
                        f"{name} ({runtime}): checkpoint status is not 'evaluated' "
                        f"but a leaderboard entry exists")
            continue
        _compare_traced(report, lb_path, entry, extracted,
                        EMBEDDING_TRACE_FIELDS, bench_path)


def check_generation_traceability(report):
    lb_path = RESULTS_DIR / "leaderboard.json"
    if not lb_path.exists():
        report.warn("traceability", lb_path, "generation leaderboard missing")
        return
    lb = _load_json(lb_path, report, "traceability")
    if lb is None:
        return
    from streaming_benchmark import extract_metrics
    for entry in lb.get("candidates", []):
        name = entry.get("name")
        raw_path = CANDIDATES_DIR / name / "raw.json"
        if not raw_path.exists():
            report.fail("traceability", lb_path,
                        f"{name}: leaderboard entry has NO on-disk checkpoint")
            continue
        raw = _load_json(raw_path, report, "traceability")
        if raw is None:
            continue
        extracted = extract_metrics(raw)
        if extracted is None:
            report.fail("traceability", lb_path,
                        f"{name}: checkpoint is not 'evaluated' but a "
                        f"leaderboard entry exists")
            continue
        _compare_traced(report, lb_path, entry, extracted,
                        GENERATION_TRACE_FIELDS, raw_path)


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Validate benchmark artifacts")
    parser.add_argument("--strict", action="store_true",
                        help="Treat warnings (legacy provenance, unfrozen "
                             "corpora) as failures — post-freeze mode")
    parser.add_argument("--json", default=None, metavar="PATH",
                        help="Also write a machine-readable report")
    args = parser.parse_args()

    report = Report(strict=args.strict)
    check_corpora(report)
    check_embedding_checkpoints(report)
    check_generation_checkpoints(report)
    check_embedding_traceability(report)
    check_generation_traceability(report)

    by_level = {"FAIL": [], "WARN": [], "INFO": []}
    for f in report.findings:
        by_level[f["level"]].append(f)

    print("=== NeuralCompose benchmark artifact validation ===\n")
    for level in ("FAIL", "WARN", "INFO"):
        for f in by_level[level]:
            print(f"[{level}] {f['category']}: {rel(f['path'])}")
            print(f"       {f['message']}")
    print(f"\n{report.n_fail} failure(s), {report.n_warn} warning(s), "
          f"{len(by_level['INFO'])} note(s)"
          + (" [--strict: warnings escalated]" if args.strict else ""))

    if args.json:
        payload = {
            "status": "fail" if report.n_fail else "pass",
            "strict": args.strict,
            "n_fail": report.n_fail,
            "n_warn": report.n_warn,
            "findings": report.findings,
        }
        with open(args.json, "w") as f:
            json.dump(payload, f, indent=2)
        print(f"JSON report: {args.json}")

    sys.exit(1 if report.n_fail else 0)


if __name__ == "__main__":
    main()
