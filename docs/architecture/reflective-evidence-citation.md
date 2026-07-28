# Citing reflective-session evidence in PR records

Status: proposed (draft PR) · 2026-07-28

NeuralCompose generates reflective/dialectic session logs (LLM dialogue
transcripts) during hypnagogic and dialectic sessions. Those logs are
private, local corpus material. This document fixes the boundary between
that material and anything that enters a pull-request record, an ADR, or a
committed artifact — so the same log is never duplicated across branches
and transcript text never becomes accidental source history.

The mechanics already exist and are the normative implementation of this
policy: `Scripts/quarantine_dialectic_corpus.py` (SHA-256 parse reports,
metadata-only event streams, 9-field disposition blocks, written to the
local `InteractionLogs/local-manifests/` directory outside the repository)
and `Scripts/review_quarantined_dialectics.py` (bounded loopback review with
whitelisted persisted keys). Raw captures never enter git; that invariant is
audited, not assumed. (The full quarantine cascade documentation ships with
its feature branch; this policy stands alone so it can land on `main`
independently.)

## Evidence classes — keep them separate

| Class | Location | Committed? |
|---|---|---|
| Raw reflective transcript (`dialectic-turns-*.jsonl`) | local/private, outside the repo | **Never** |
| Redacted session manifest (parse report, event stream, review summaries) | `local-manifests/` (local); schema definitions in-repo | Optional metadata only — no text, no embeddings |
| PR evidence summary | PR description / acceptance doc | Yes — **claim + observation + content hash + tool version only** |
| Architectural decision (ADR) | `docs/architecture/decision-log/` | Yes — independent reasoning and review |
| Training/embedding corpus | separately consented, quarantined lane | Only under its own explicit disposition |

## The citation rule

A PR record, acceptance document, or ADR may cite reflective-session
evidence **only** in this shape:

```
Claim:       <what is being asserted>
Observation: <redacted, aggregate, or structural finding — no dialogue text>
Source:      dialectic-turns-<date>.jsonl sha256=<parse-report source hash>
             parser=<PARSER_VERSION> reviewer=<REVIEWER_VERSION>
             (and/or promptHash=<generator fingerprint>)
```

- One capture = one content hash = one local manifest. PRs cite the hash;
  they never copy transcript text, and the same log is never attached to,
  or reproduced in, more than one branch.
- If a claim cannot be expressed without quoting dialogue, it does not
  belong in a PR record.

## Reflective output is not an authority

A reflective model's output is a **hypothesis generator or observation** —
never a reviewer sign-off and never normative authority. Concretely:

- **Event/labeling work (e.g. PR #44):** reflective sessions may *suggest*
  event types or failure cases; they cannot promote heuristic observations
  into labels, science-lane evidence, or clean-session credit. Promotion
  requires the pre-registered gates, not conversation.
- **Client/transport work (e.g. PR #45):** only device/client acceptance
  evidence belongs in the record. Dialogue contents and personality-analysis
  material do not belong in a transport PR.
- **Reconstructed ADRs (e.g. ADR-009 / PR #47):** a reconstruction records
  the decision as it was. Later reflective conversations postdate that
  decision and must never be folded back into it — that would convert later
  interpretation into false history. Amendments go in new, dated ADRs.

## Source-pinning for external scaffolding

Externally derived scaffolding (e.g. published alignment/evaluation work)
may inform reflective-mode *governance* — assistant-character constraints,
honesty/uncertainty behavior, evaluation design. It never silently
authorizes embedding-geometry claims, encoder promotion, runtime
architecture, training-data inclusion, or scientific labels. Any such use
must pin the exact source (paper, file, commit); an unpinned attribution is
not a source.
