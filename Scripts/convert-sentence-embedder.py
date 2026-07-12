#!/usr/bin/env python3
"""
convert-sentence-embedder.py — Convert a HuggingFace sentence-embedding
model (BGE/E5/MiniLM-family) to Core ML for `CoreMLSentenceEmbedder.swift`.

Generalized per-model (not "convert-bge.py") because the conversion path is
the same for every WordPiece/BERT-family sentence encoder on the shortlist
(docs/research/embedding-model-survey.md) — only `--model` changes. This is
script reuse, not a registry: nothing at runtime chooses between backends.

Conversion path: direct PyTorch trace -> Core ML (`ct.convert(traced_model,
convert_to="mlprogram")`), not the ONNX-intermediate path the original
survey assumed. Requires coremltools==8.0 specifically — see the version
history comment on `trace_model()` below for the three real, distinct
conversion bugs this sidesteps in coremltools 9.0.

Input: a HuggingFace model id, e.g. BAAI/bge-small-en-v1.5

Output: <output-dir>/ containing three co-located artifacts, all read by
  CoreMLSentenceEmbedder.swift:
    model.mlpackage   — the converted encoder (last_hidden_state output)
    tokenizer.json    — the model's own canonical tokenizer (not hand-derived;
                        parsed at runtime by WordPieceTokenizer.swift)
    metadata.json     — {model, revision, pooling, dimension, tokenizer,
                        converted_with}; `pooling` is decided by the
                        self-verification step below, never hardcoded.
                        Also carries download/environment provenance
                        (huggingface_model, revision, download_date,
                        coremltools/transformers/sentence_transformers/python
                        versions) so the conversion is reproducible later —
                        CoreMLSentenceEmbedder.swift ignores these extra
                        fields, they're historical record only.

I/O contract (must match CoreMLSentenceEmbedder.swift):
  input  "input_ids":         Int32 MLMultiArray of shape [1, max_seq_len]
  input  "attention_mask":    Int32 MLMultiArray of shape [1, max_seq_len]
  output "last_hidden_state": Float32 MLMultiArray of shape [1, max_seq_len, dimension]

Usage:
  ./Scripts/convert-sentence-embedder.py --model BAAI/bge-small-en-v1.5
  ./Scripts/convert-sentence-embedder.py --model BAAI/bge-small-en-v1.5 \\
      --output-dir Models/BGE-small-en-v1.5 --revision main
  ./Scripts/convert-sentence-embedder.py --model BAAI/bge-small-en-v1.5 --skip-verify
"""

import argparse
import json
import platform
import sys
from datetime import datetime, timezone
from pathlib import Path

import coremltools as ct
import numpy as np
import sentence_transformers
import torch
import transformers
from transformers import AutoModel, AutoTokenizer

MAX_SEQUENCE_LENGTH = 512
VERIFY_SENTENCE = "Deep sleep restores the body and mind."
# Any residual asymmetry between CLS and mean pooling on a converted model is
# expected to be small; a near-zero match against *both* signals a broken
# conversion rather than an ambiguous pooling choice.
MIN_PLAUSIBLE_SIMILARITY = 0.5
# Above this, the winning pooling strategy is a high-confidence match (an
# ONNX->Core ML conversion should reproduce the reference near bit-for-bit,
# modulo fp16/ANE rounding) — below it but still above MIN_PLAUSIBLE_SIMILARITY,
# the conversion is plausible but worth a manual look before trusting it.
HIGH_CONFIDENCE_SIMILARITY = 0.999


class MeanPoolingWrapper(torch.nn.Module):
    """Wraps a HF encoder so the traced graph has a single tensor output
    (`last_hidden_state`) rather than a whole `BaseModelOutput` — coremltools'
    torch frontend wants a plain graph output, not a HF model-output object."""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        return self.model(input_ids=input_ids, attention_mask=attention_mask).last_hidden_state


def cls_pool(hidden_states: np.ndarray) -> np.ndarray:
    return hidden_states[:, 0, :]


def mean_pool(hidden_states: np.ndarray, attention_mask: np.ndarray) -> np.ndarray:
    mask = attention_mask[:, :, None].astype(np.float32)
    summed = (hidden_states * mask).sum(axis=1)
    counts = np.clip(mask.sum(axis=1), a_min=1e-9, a_max=None)
    return summed / counts


def l2_normalize(vectors: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(vectors, axis=-1, keepdims=True)
    norms = np.clip(norms, a_min=1e-9, a_max=None)
    return vectors / norms


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    a = l2_normalize(a)
    b = l2_normalize(b)
    return float((a * b).sum(axis=-1)[0])


def trace_model(wrapped_model: torch.nn.Module, tokenizer) -> torch.jit.ScriptModule:
    """`torch.jit.trace` with fixed-shape example inputs.

    Conversion history (kept as a comment because each failure was a real,
    version-specific coremltools gap, not a config mistake — a future
    contributor hitting one of these again shouldn't re-derive this):
      1. coremltools 9.x dropped `source="onnx"` from `ct.convert()` entirely
         (only "auto"/"tensorflow"/"pytorch"/"milinternal" remain) — ruled
         out the ONNX-intermediate path the original survey assumed.
      2. `torch.jit.trace` + coremltools 9.0 hit a real bug: an `int()` op
         inside the embeddings module traced into a non-scalar MIL constant
         ("TypeError: only 0-dimensional arrays can be converted to Python
         scalars"), reproduced identically across transformers 4.40.2 and
         5.13.1 — not a transformers-version issue.
      3. `torch.export.export(strict=False).run_decompositions({})` (the
         "modern" path) got past that, but coremltools 9.0's EXIR/FX
         frontend doesn't implement the `alias` op at all
         ("NotImplementedError: Unsupported fx node alias, kind alias") —
         a structural gap in that specific frontend, not a config issue.
      4. Downgrading to coremltools==8.0 and going back to `torch.jit.trace`
         (this function) resolved it — 8.0's older, more heavily-exercised
         JIT frontend doesn't have the 9.0 regression from (2).
    """
    encoded = tokenizer(
        VERIFY_SENTENCE,
        return_tensors="pt",
        padding="max_length",
        truncation=True,
        max_length=MAX_SEQUENCE_LENGTH,
    )
    with torch.no_grad():
        traced = torch.jit.trace(wrapped_model, (encoded["input_ids"], encoded["attention_mask"]))
    return traced


def convert_to_coreml(traced_model: torch.jit.ScriptModule, mlpackage_path: Path) -> ct.models.MLModel:
    mlmodel = ct.convert(
        traced_model,
        convert_to="mlprogram",
        # BERT's extended attention mask uses float32's finfo.min (~-3.4e38)
        # to zero out padding positions in softmax. Core ML's default FP16
        # compute precision can't represent that — it silently overflows
        # during cast ("RuntimeWarning: overflow encountered in cast"),
        # corrupting attention over padding (most of the fixed 512-token
        # sequence for a short sentence) and dropping the self-verification
        # cosine similarity to ~0.65 instead of the expected ~0.999+. FP32
        # avoids the overflow entirely.
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_SEQUENCE_LENGTH), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, MAX_SEQUENCE_LENGTH), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="last_hidden_state")],
    )
    mlmodel.save(str(mlpackage_path))
    return mlmodel


def self_verify(model, tokenizer, mlmodel: ct.models.MLModel) -> str:
    """Runs the original PyTorch model and the converted Core ML model on the
    same fixed test sentence, compares both pooling strategies, and returns
    whichever ('cls' or 'mean') is the closer match. Raises if neither is a
    plausible match — that indicates the conversion itself is broken, not
    just an ambiguous pooling choice."""
    encoded = tokenizer(
        VERIFY_SENTENCE,
        return_tensors="pt",
        padding="max_length",
        truncation=True,
        max_length=MAX_SEQUENCE_LENGTH,
    )
    with torch.no_grad():
        reference_hidden = model(**encoded).last_hidden_state.numpy()
    attention_mask_np = encoded["attention_mask"].numpy()

    reference_cls = cls_pool(reference_hidden)
    reference_mean = mean_pool(reference_hidden, attention_mask_np)

    coreml_inputs = {
        "input_ids": encoded["input_ids"].numpy().astype(np.int32),
        "attention_mask": attention_mask_np.astype(np.int32),
    }
    coreml_output = mlmodel.predict(coreml_inputs)
    coreml_hidden = coreml_output["last_hidden_state"]

    coreml_cls = cls_pool(coreml_hidden)
    coreml_mean = mean_pool(coreml_hidden, attention_mask_np)

    cls_similarity = cosine_similarity(reference_cls, coreml_cls)
    mean_similarity = cosine_similarity(reference_mean, coreml_mean)

    print(f"  cls similarity:  {cls_similarity:.6f}")
    print(f"  mean similarity: {mean_similarity:.6f}")

    if cls_similarity < MIN_PLAUSIBLE_SIMILARITY and mean_similarity < MIN_PLAUSIBLE_SIMILARITY:
        raise RuntimeError(
            "Neither pooling strategy plausibly matches the reference model — "
            "the conversion itself is likely broken (check the traced model's inputs/outputs)."
        )

    winning_pooling = "cls" if cls_similarity >= mean_similarity else "mean"
    winning_similarity = max(cls_similarity, mean_similarity)
    if winning_similarity >= HIGH_CONFIDENCE_SIMILARITY:
        print(f"  -> high-confidence match ({winning_pooling}, {winning_similarity:.6f} >= {HIGH_CONFIDENCE_SIMILARITY})")
    else:
        print(
            f"  -> plausible but not exact match ({winning_pooling}, {winning_similarity:.6f} < "
            f"{HIGH_CONFIDENCE_SIMILARITY}) — worth a manual look (fp16/ANE rounding is expected, "
            "but confirm it's not a masked conversion bug) before trusting downstream fixtures"
        )
    return winning_pooling


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True, help="HuggingFace model id, e.g. BAAI/bge-small-en-v1.5")
    parser.add_argument("--revision", default="main", help="Pinned model revision (default: main)")
    parser.add_argument("--output-dir", default=None, help="Defaults to Models/<model-name>")
    parser.add_argument("--skip-verify", action="store_true", help="Skip self-verification (not recommended)")
    args = parser.parse_args()

    output_dir = Path(args.output_dir) if args.output_dir else Path("Models") / args.model.split("/")[-1]
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {args.model}@{args.revision} ...")
    tokenizer = AutoTokenizer.from_pretrained(args.model, revision=args.revision)
    # eager attention: the default SDPA path in recent transformers versions
    # uses shape-dependent Python branching that traces into ops coremltools'
    # torch frontend can't convert (int() on a non-scalar tensor). Eager
    # attention is the simple, unconditional matmul path BERT-family models
    # have always traced cleanly with.
    model = AutoModel.from_pretrained(args.model, revision=args.revision, attn_implementation="eager")
    model.eval()

    dimension = model.config.hidden_size

    print("Saving tokenizer (tokenizer.json is the canonical artifact Swift parses) ...")
    tokenizer.save_pretrained(str(output_dir))
    if not (output_dir / "tokenizer.json").exists():
        print("error: tokenizer.save_pretrained() did not produce tokenizer.json", file=sys.stderr)
        return 1

    print("Tracing PyTorch model ...")
    traced_model = trace_model(MeanPoolingWrapper(model), tokenizer)

    mlpackage_path = output_dir / "model.mlpackage"
    print(f"Converting traced model -> Core ML ({mlpackage_path}) ...")
    mlmodel = convert_to_coreml(traced_model, mlpackage_path)

    if args.skip_verify:
        print("Skipping self-verification (--skip-verify); assuming CLS pooling.")
        pooling = "cls"
    else:
        print("Self-verifying pooling strategy against the original PyTorch model ...")
        pooling = self_verify(model, tokenizer, mlmodel)
        print(f"  -> resolved pooling: {pooling}")

    metadata = {
        "model": args.model,
        "revision": args.revision,
        "pooling": pooling,
        "dimension": dimension,
        "tokenizer": "tokenizer.json",
        "converted_with": f"coremltools {ct.__version__}",
        # Provenance for reproducing this conversion later — not read by
        # CoreMLSentenceEmbedder.swift, historical record only.
        "huggingface_model": args.model,
        "download_date": datetime.now(timezone.utc).isoformat(),
        "coremltools_version": ct.__version__,
        "transformers_version": transformers.__version__,
        "sentence_transformers_version": sentence_transformers.__version__,
        "python_version": platform.python_version(),
    }
    metadata_path = output_dir / "metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Wrote {metadata_path}")

    print(f"Done. {output_dir} is ready for CoreMLSentenceEmbedder(modelDirectory:).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
