# Stage 3.4-C: Embedding-Space Analysis

**Generated:** 2026-07-14T12:12:43.943658+00:00
**Models:** all-MiniLM-L6-v2, bge-small-en-v1.5, bge-base-en-v1.5, multilingual-e5-base, multilingual-e5-small

## Intrinsic Dimensionality (Participation Ratio)
| Model | Intrinsic Dim |
|-------|---------------|
| all-MiniLM-L6-v2 | 7.18 |
| bge-small-en-v1.5 | 6.73 |
| bge-base-en-v1.5 | 6.94 |
| multilingual-e5-base | 7.10 |
| multilingual-e5-small | 7.02 |

## Pairwise Analysis
| Pair | CKA | SVCCA | Procrustes | NN Overlap | Cluster Purity |
|------|-----|-------|------------|------------|-----------------|
| all-MiniLM-L6-v2 vs bge-small-en-v1.5 | 0.9570 | 0.9190 | 0.0250 | 0.6619 | 0.8000 |
| all-MiniLM-L6-v2 vs bge-base-en-v1.5 | 0.9647 | 0.8906 | 0.0245 | 0.7762 | 0.8000 |
| all-MiniLM-L6-v2 vs multilingual-e5-base | 0.9602 | 0.7422 | 0.0298 | 0.5750 | 0.8000 |
| all-MiniLM-L6-v2 vs multilingual-e5-small | 0.9619 | 0.8592 | 0.0242 | 0.6857 | 0.8000 |
| bge-small-en-v1.5 vs bge-base-en-v1.5 | 0.9805 | 0.8579 | 0.0124 | 0.8000 | 0.9000 |
| bge-small-en-v1.5 vs multilingual-e5-base | 0.9453 | 0.7819 | 0.0330 | 0.5238 | 0.9000 |
| bge-small-en-v1.5 vs multilingual-e5-small | 0.9655 | 0.8557 | 0.0207 | 0.6679 | 1.0000 |
| bge-base-en-v1.5 vs multilingual-e5-base | 0.9592 | 0.8650 | 0.0220 | 0.5119 | 1.0000 |
| bge-base-en-v1.5 vs multilingual-e5-small | 0.9753 | 0.9652 | 0.0210 | 0.6857 | 0.9000 |
| multilingual-e5-base vs multilingual-e5-small | 0.9818 | 0.8749 | 0.0125 | 0.6619 | 0.9000 |
