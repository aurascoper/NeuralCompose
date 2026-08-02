# Proposal: mechanical integrity for EXPERIMENT_LEDGER node citations

Status: proposed · 2026-08-01 · prototype on `diag/online-target-frame-mismatch`

`docs/architecture/reflective-evidence-citation.md` already states the rule this
proposal enforces: **"an unpinned attribution is not a source."** Nothing checks
it for experiment-ledger citations. This proposes the check, reports what a
working prototype finds on the current tree, and is explicit about the part of
the problem no checker can solve.

## The incident that motivated it

Commit `8533ea8` on this branch attributed a null result to "ledger node 7 at
commit `208cbcd`", with specific figures (prediction error 4.6× lower, rollout
norm ratio 1.20 → 0.98, control 0/35).

Neither half of that citation resolves:

- **Node 7** in every pushed ledger is *"Transform A/B, arm 2 audit:
  'standardize' is the baseline, not a treatment"*, which contains none of those
  numbers.
- **`208cbcd`** is not on the remote and appears in no branch.

The figures were reported in-session from an unpushed run. They may be entirely
correct. But as committed they were unverifiable, and nothing in CI noticed.

## Two gaps, not one

The obvious reading — "extend `check_adr_references.py` to scan
`EXPERIMENT_LEDGER.md`" — **would not have caught this**, and it is worth being
precise about why.

| gap | where the citation lives | catchable by a file scanner? |
|---|---|---|
| A | files in the tree (docs, source comments, the ledger itself) | yes |
| B | **git commit messages** | **no** — a commit message is not a file in the tree |

`check_adr_references.py` scans `HARD_ROOTS` and `ADVISORY_ROOTS`. A commit
message is never in either. The motivating defect was gap B.

There was also a plain coverage hole in gap A, now closed: `HARD_ROOTS` was
`Sources`, `Tests`, `Scripts`, `docs/architecture`, and `ADVISORY_ROOTS` is
`README.md`, `docs/reviews`, `Evaluation/reports`. **`WorldModel/` was in
neither**, so the entire experiment lane — including the ledger — was unscanned
even for ADR references, despite citing ADR-005 and ADR-006 in eight places
(`README.md`, `EEG_INTEGRATION_DESIGN.md`, `export_coreml.py`).

`WorldModel/` is now in `HARD_ROOTS`. Normative rather than advisory, because
ADR-006 is *jepa-transition-capture*, which that directory implements. Adding it
produces **zero findings** on the current tree — all eight references are
canonical and both ADRs exist — so the gate stays green.

That zero was checked for vacuity rather than trusted. A probe file placed under
`WorldModel/`, citing one nonexistent three-digit ADR number and one malformed
two-digit one, yields **0 findings without** the root and **2 with** it
(`ADR_REFERENCE_MISSING`, `ADR_REFERENCE_MALFORMED`), so the new coverage
demonstrably scans. Probe removed; tree clean. The 16 tests in
`Tests/eval/test_adr_references.py` still pass.

(The literal tokens are deliberately not reproduced here. Writing them into a
document under `docs/architecture` — itself a `HARD_ROOTS` entry — makes the
checker flag this file, which is exactly what happened on the first attempt at
this paragraph and is why `HARD_SCAN_EXCLUSIONS` exists for the checker's own
source. A prose description costs nothing and keeps this document scanned.)

## What is proposed

`Scripts/check_ledger_references.py` — a sibling of `check_adr_references.py`,
deliberately structured to match it (same `Finding` shape, same mode/severity
split, same GitHub-annotation rendering) so the two can be reviewed together and
later merged into one entry point.

Five checks:

1. Every node heading is canonical: `## <n> — <title> (<date>, commit <sha>)`.
2. No node number is defined twice in one ledger.
3. Every bare `node N` resolves to a node in the **same** ledger.
4. A reference to another numbering space must name it — `dialectic node 33` —
   because a bare number silently borrows this ledger's namespace.
5. Every pinned commit SHA resolves in this repository. `<pending>` is allowed;
   an unresolvable SHA is not.

Plus `--commit-message FILE`, which applies checks 3–5 to a commit message.
That is the gap-B path, suitable for a `commit-msg` hook or a CI pass over a
PR's commits.

## What the prototype finds, run on this tree

**Tree scan** — 12 findings, all the same defect:

```
WorldModel/EXPERIMENT_LEDGER.md:147,181,183,185,190,194,195,206,207,208,233,234
  [LEDGER_NODE_REFERENCE_MISSING] bare 'node 33' does not resolve in this ledger
```

Node 33 is a dialectic-session node from a different numbering space. It is
referenced 13 times and qualified as *"dialectic node 33"* exactly once, at
line 149 — which the checker correctly does **not** flag. So the ledger already
half-observes the rule; the checker just makes the other twelve explicit. Every
one is a one-word fix.

**Commit-message scan** — run against the two commits on this branch:

```
$ ... --commit-message <8533ea8>   ->  PASS (0 warnings)
$ ... --commit-message <5925bfa>   ->  FAIL (2 errors)
    [COMMIT_SHA_UNRESOLVABLE] message cites commit 208cbcd, which does not
    resolve in this repository (unpushed or mistyped?)
```

## It catches half of what happened. Say so.

This is the part that matters most, and overstating it here would repeat the
original error.

| half of the defect | mechanically detectable? |
|---|---|
| pinned `208cbcd`, which does not exist | **yes** — check 5 catches it |
| cited "node 7", which exists but does not contain the claimed numbers | **no** |

The second half is a semantic claim about content. `8533ea8` passes the checker
cleanly, because node 7 is a real node and nothing in a citation reveals that
the numbers attributed to it are not in it. **Only human review catches that.**

What the check does buy is narrower and still worth having: a citation can no
longer point at a commit that does not exist, and the moment the numbers *are*
pushed the pin becomes verifiable. It converts "unverifiable" into "wrong or
right", which is the precondition for review to work at all.

## A design decision worth recording

The first draft treated any word before `node` that was not on a denylist of
English connectives as a namespace qualifier. On the real ledger that produced
**9 false positives out of 18 findings** — `if node 33`, `refutes node 12`,
`across node 7`, `strengthening node 33`.

A denylist of English words cannot be completed. The prototype uses an
**allowlist** (`dialectic`, `session`, `reflective`); anything else is treated
as prose and the citation resolves as bare. That trades a missed qualifier for
zero noise, which is the right direction: a checker that cries wolf gets
disabled, and then catches nothing at all.

## Proposed adoption

1. Land advisory-only, not wired into CI. Warnings, exit 0.
2. Fix the twelve `node 33` references (one word each), then flip to `--mode hard`
   in `.github/workflows/ci.yml` beside the existing ADR line.
3. ~~Add `WorldModel/` to `check_adr_references.py`'s roots.~~ **Done** — zero
   findings, non-vacuity probed, existing tests pass. This is the one part of
   this proposal that is not advisory: it changes what an existing required gate
   covers, so it is a reasonable thing to split into its own PR if you would
   rather land it independently of the prototype.
4. Gap B needs a decision (below) before it can be enforced.

## Open questions for review

- **Where does gap B run?** A local `commit-msg` hook is unenforceable on a
  shared repo; a CI pass over a PR's commits is enforceable but can only fail
  *after* the commit exists. Neither is obviously right.
- **Should an unresolvable SHA be an error or a warning?** A legitimate workflow
  writes the ledger entry before pushing. Warning-on-branch and error-on-`main`
  may be the honest split.
- **Namespace syntax.** `dialectic node 33` is prose. A stricter
  `[dialectic#33]` would be unambiguous but is a bigger edit to existing text.
- **Merge or keep separate?** Two checkers share most of their machinery. One
  entry point with `--check {adr,ledger,all}` may be better than two scripts.

## Non-claims

This proposal does not claim the node 7 figures are wrong — only that as
committed they were unverifiable. It does not claim mechanical checking replaces
review; it explicitly cannot catch the content half of the defect it was written
in response to. And it changes no experimental result, no objective, and no
control claim.
