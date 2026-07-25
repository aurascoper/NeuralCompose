# Fine-Tuned Model Handoff — Reproducible Training Specification

## Status: BASELINE — No Fine-Tuned Artifact Found

The Pixel 8a currently runs the stock Qwen2.5-0.5B-Instruct Q4_K_M model.
No LoRA adapter, no merged weights, no fine-tuning has been performed.

## What a Fine-Tune Would Improve

Role adherence: keeping the output in the assigned role (coherence vs displacement).
Brevity: 1-3 sentences without bloat.
Spoken register: conversational, not written/academic.

## What a Fine-Tune Must NOT Do

The fine-tuned model must NEVER:
- Output tension numbers, synthesis decisions, or selection scores
- Select its own winner
- Act as a judge or arbiter
- Collapse both roles into one voice

The dialectical gates (energies, tensions, softmax, synthesis) remain outside the fine-tune.

## Role-Output Schema

```
coherence-seeker output:
  - 1-3 short sentences
  - stays close to the heard claim
  - makes it clearer, concrete, precise
  - does not introduce a new position
  - spoken register (no preamble, no "Sure:", no role description)

displacement-seeker output:
  - 1-3 short sentences
  - opens a genuinely different angle
  - surfaces a counter-position or overlooked assumption
  - does not restate, agree, or reconcile
  - spoken register (same constraints)
```

## Held-Out Behavioral Evaluation Set

See `eval_cases.jsonl` for 6 cases (3 coherence, 3 displacement) with expected characteristics.

Scoring rubric:
- Role adherence: does the output match the role's objective? (0-1)
- Brevity: is it 1-3 sentences? (0 or 1)
- Register: is it spoken, not written? (0 or 1)
- No preamble: does it avoid "Sure:", "Here is", role descriptions? (0 or 1)

A fine-tuned model must score >0.8 on role adherence and >0.9 on brevity,
measured on this held-out set.

## Adapter Integration (when an artifact exists)

1. If a GGUF LoRA exists:
   - Launch llama-server with `--lora /path/to/adapter.gguf`
   - Hash both base and adapter
   - Record in model manifest with `finetune_status: "adapter"`

2. If a HuggingFace PEFT adapter exists:
   - Do NOT improvise a conversion in the app
   - Use `llama.cpp/convert_lora_to_gguf.py` to convert
   - Test adapter-on vs adapter-off on the held-out eval set
   - Record source hash

3. If merged weights exist:
   - Hash the merged GGUF
   - Replace the base model path in the server config
   - Record with `finetune_status: "merged"`

## Exact Integration Command (GGUF LoRA)

```bash
~/llama.cpp/build/bin/llama-server \
  --model ~/models/qwen2.5-0.5b-instruct-q4_k_m.gguf \
  --lora ~/models/dialectic-adapter.gguf \
  --host 127.0.0.1 \
  --port 8081 \
  --ctx-size 512 \
  --threads 2
```

## What NOT to Do on the Pixel

- Do not attempt sustained fine-tuning on the Pixel 8a
- Do not improvise adapter conversion in the app
- Do not mark the fine-tuned-model acceptance criterion complete until verified by hash