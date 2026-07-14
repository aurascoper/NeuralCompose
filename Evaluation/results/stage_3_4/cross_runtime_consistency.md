# Stage 3.4-A: Cross-Runtime Embedding Consistency

**Generated:** 2026-07-14T12:12:17.122820+00:00
**Comparisons:** 4

| Model | Runtime A | Runtime B | Mean Cosine | Min | Max | Std | Drift? | Latency Δ |
|-------|-----------|-----------|-------------|-----|-----|-----|--------|-----------|
| all-MiniLM-L6-v2 | python | mlx-swift | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no | +7.55s |
| bge-small-en-v1.5 | python | mlx-swift | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no | +7.28s |
| bge-small-en-v1.5 | python | coreml | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no | +7.24s |
| bge-small-en-v1.5 | mlx-swift | coreml | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no | -0.04s |
