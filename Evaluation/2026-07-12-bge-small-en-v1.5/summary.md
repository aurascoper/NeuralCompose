# Stage 3.3 Semantic Evaluation Summary

## Benchmark history

| date/model | runtime | pooling | cold_load_ms | warm_encode_ms | embeddings_per_second |
|---|---|---|---|---|---|
| bge-small-en-v1.5 | coreml | cls | 77.31 | 60.69 | 14.12 |
| stub-hash-v1 | stub | n/a | 1.90 | 1.50 | 883.16 |

## Paraphrase pairs (expect high similarity)

| phrase A | phrase B | cosine similarity |
|---|---|---|
| start recording | begin recording | 0.9869 |
| stop recording | end recording | 0.8892 |
| speak | say it | 0.8257 |
| refine it | improve it | 0.8296 |
| begin sleep protocol | start sleep protocol | 0.9873 |

## Antonym pairs (expect low similarity — should NOT collapse with paraphrases above)

| phrase A | phrase B | cosine similarity |
|---|---|---|
| start recording | stop recording | 0.7785 |
| begin calibration | stop recording | 0.5587 |
| start dictation | stop dictation | 0.8551 |
| start command listening | stop command listening | 0.8362 |

## Command-alias cohesion

Cross-command mean similarity: **0.6133**

| command | intra-group mean similarity | gap vs. cross-command |
|---|---|---|
| beginCalibration | 0.8877 | +0.2744 |
| beginSleepProtocol | 0.8763 | +0.2629 |
| openPhaseBDebug | 0.8770 | +0.2637 |
| refine | 0.7990 | +0.1856 |
| resetComposition | 0.7932 | +0.1799 |
| speak | 0.7471 | +0.1338 |
| startCommand | 0.8625 | +0.2492 |
| startDictation | 0.9767 | +0.3633 |
| startRecording | 0.9869 | +0.3736 |
| stopCommand | 0.8707 | +0.2574 |
| stopDictation | 0.8922 | +0.2788 |
| stopRecording | 0.8892 | +0.2759 |

## Clustering metrics (over command-group-labeled embeddings)

- Silhouette score (higher is better): **0.3084**
- Davies-Bouldin index (**lower** is better): **1.0535**

## Trajectories

- `aasm-stage-transitions`: wake -> N1 -> N2 N3 -> uncertain REM
  - mean step-to-step similarity: 0.6688
  - see `trajectory_aasm-stage-transitions.png`
- `sleep-to-lucid-dream`: sleep -> deep sleep -> REM sleep -> dream -> lucid dream
  - mean step-to-step similarity: 0.7751
  - see `trajectory_sleep-to-lucid-dream.png`
