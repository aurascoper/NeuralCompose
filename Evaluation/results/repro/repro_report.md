# Reproducibility Report

**Generated:** 2026-07-14T12:13:19.930732+00:00
**Tolerances:** quality |Δ| ≤ 0.005 (absolute); perf ±20% (relative); ratio-scale metrics use the relative band
**Overall:** FAIL

Method: side-by-side controlled rerun vs canonical checkpoint — canonical evidence is never replaced.

## all-MiniLM-L6-v2 (python) — FAIL

| Metric | Canonical | Repro | Δ | Band | Status |
|--------|-----------|-------|---|------|--------|
| paraphrase_mean | 0.650781 | 0.650781 | +0 | |Δ|=0.000000 vs abs tol 0.005 | PASS |
| antonym_mean | 0.734357 | 0.734357 | +0 | |Δ|=0.000000 vs abs tol 0.005 | PASS |
| separation_ratio | 3.71033 | 3.71033 | +0 | |Δ|/canonical=0.000 vs rel tol 0.2 | PASS |
| retrieval_top1 | 0.963935 | 0.963935 | +0 | |Δ|=0.000000 vs abs tol 0.005 | PASS |
| stability_mean | 0.868034 | 0.868763 | +0.000729636 | |Δ|=0.000730 vs abs tol 0.005 | PASS |
| semantic_stability_mean | 0.919459 | 0.919459 | +2.86932e-09 | |Δ|=0.000000 vs abs tol 0.005 | PASS |
| nn_consistency | 1 | 1 | +0 | |Δ|=0.000000 vs abs tol 0.005 | PASS |
| cold_load_time | 7.57389 | 6.97389 | -0.600003 | |Δ|/canonical=0.079 vs rel tol 0.2 | PASS |
| warm_encode_time_ms | 95.432 | 34.4648 | -60.9672 | |Δ|/canonical=0.639 vs rel tol 0.2 | FAIL |
| embeddings_per_second | 1015.15 | 2538.37 | +1523.23 | |Δ|/canonical=1.500 vs rel tol 0.2 | FAIL |
| peak_rss_mb | 505.688 | 507.25 | +1.5625 | |Δ|/canonical=0.003 vs rel tol 0.2 | PASS |

## qwen2.5-0.5b — FAIL

| Metric | Canonical | Repro | Δ | Band | Status |
|--------|-----------|-------|---|------|--------|
| meaning_cosine_mean | 0.730738 | 0.744322 | +0.0135847 | |Δ|=0.013585 vs abs tol 0.005 | FAIL |
| stability | 0.962963 | 0.901235 | -0.0617284 | |Δ|=0.061728 vs abs tol 0.005 | FAIL |
| instruction_following | 0.6 | 0.4 | -0.2 | |Δ|=0.200000 vs abs tol 0.005 | FAIL |
| word_count_ratio_mean | 3.4763 | 4.21666 | +0.740365 | |Δ|/canonical=0.213 vs rel tol 0.2 | FAIL |
| cold_load_time | 2.39627 | 2.69871 | +0.302438 | |Δ|/canonical=0.126 vs rel tol 0.2 | PASS |
| peak_rss_mb | 706.906 | 702.812 | -4.09375 | |Δ|/canonical=0.006 vs rel tol 0.2 | PASS |
| generate_time_mean | 1.22807 | 1.51249 | +0.284411 | |Δ|/canonical=0.232 vs rel tol 0.2 | FAIL |
| tokens_per_second_mean | 37.5487 | 39.6261 | +2.07736 | |Δ|/canonical=0.055 vs rel tol 0.2 | PASS |
