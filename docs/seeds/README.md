# Session seeds — the co-development loop's memory

A **session seed** is the compressed, versioned artifact that carries project
state from one Opus (architect) session to the next — instead of recursively
summarising arbitrary chat transcripts. The next session begins with

```
Seed N  +  the current repository  +  the evaluation logs
```

which is far more stable and auditable than an ever-shrinking summary of a
conversation.

## The co-development loop

Two agents, clear roles:

| Agent | Role |
|---|---|
| **Opus** | architect / theorist / specification writer |
| **Sonnet 5** | runtime generator (`ClaudeCLIGenerator`) **and** the day-to-day implementation agent embedded in the repo |

```
spec → Sonnet implements → tests → telemetry → review → (next seed) → repeat
```

Opus periodically revisits the architecture using a small set of versioned seeds
rather than the full transcript; Sonnet executes against the spec. The seeds are
the hand-off.

## Three parts, evolving at different rates

Each snapshot `seed-NNN/` holds three files, kept **separate on purpose** so that
fast-moving implementation detail never contaminates slow architectural
reasoning:

| File | Contents | Rate |
|---|---|---|
| `architecture.json` | modules, invariants, public API seams, architecture/field versions | slow |
| `research.json` | open hypotheses, accepted/rejected decisions, pending questions, experiments | medium |
| `runtime.json` | outstanding todos, current failures, known risks, benchmarks, telemetry rollup, next experiment | fast |
| `SEED.md` | a one-page human-readable render of all three | — |

One monotonic snapshot id (`001`, `002`, …) gives a single auditable chain, while
each file's own `content_version` bumps only when *that* part changes — so the
three parts can move independently without losing the chain.

## Tooling

`Scripts/session-seed.py` is the typed loader + runtime-seed assembler (offline;
never touches an LLM or the app):

```sh
./Scripts/session-seed.py show 001        # one-screen summary of a seed
./Scripts/session-seed.py refresh 001     # re-assemble runtime.json from live
                                          #   git state + newest dialectic-turns
                                          #   telemetry (bumps its content_version)
./Scripts/session-seed.py telemetry       # just print the telemetry rollup
```

`architecture.json` and `research.json` are authored by hand (the architect's
judgement) and only validated by the tool. `runtime.json`'s `generated_from`
block is machine-assembled by `refresh`; its hand-authored fields (todos, risks,
next experiment) are preserved across refreshes.

The telemetry rollup's load-bearing field is **`live_eeg_influence`**
(`gloss_variance > 0`): it distinguishes a genuine live-EEG session, where the
`SpectralGloss` actually varied the dialogue, from a text-only run where the
gloss sat at the neutral 0.5.

## The mode-progression ladder (context for `next_experiment`)

Seeds track where we are on the ladder. Sleep modes are gated behind
characterizing the waking dynamics first — see
[`ADR-008`](../architecture/decision-log/ADR-008-opus-sonnet-codev-loop.md).

```
Mirror → Focused+Dialectical → Reflective → Contemplative
       → [GATE: waking dynamics characterized] → Wind-down → Hypnagogic → Dream
```

## Starting a new snapshot

Copy the previous seed dir to `seed-<next>/`, bump the `content_version` of only
the parts you changed, revise them, then `refresh` the runtime part. The old
snapshot stays immutable as the audit trail.
