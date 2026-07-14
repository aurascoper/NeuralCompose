# Stage 3.4-C: Embedding-Space Analysis

**Generated:** 2026-07-14T06:42:02.823753+00:00
**Models:** all-MiniLM-L6-v2, multilingual-e5-small, bge-small-en-v1.5

## Intrinsic Dimensionality (Participation Ratio)
| Model | Intrinsic Dim |
|-------|---------------|
| all-MiniLM-L6-v2 | 7.18 |
| multilingual-e5-small | 7.02 |
| bge-small-en-v1.5 | 6.73 |

## Pairwise Analysis
| Pair | CKA | SVCCA | Procrustes | NN Overlap | Cluster Purity |
|------|-----|-------|------------|------------|-----------------|
| all-MiniLM-L6-v2 vs multilingual-e5-small | 0.9619 | 0.8592 | 0.0242 | 0.6857 | 0.8000 |
| all-MiniLM-L6-v2 vs bge-small-en-v1.5 | 0.9570 | 0.9190 | 0.0250 | 0.6619 | 0.8000 |
| multilingual-e5-small vs bge-small-en-v1.5 | 0.9655 | 0.8557 | 0.0207 | 0.6679 | 1.0000 |
