#!/usr/bin/env python3
"""
Embedding stability benchmark — variant generation + cosine stability measurement.

NeuralCompose consumes noisy speech-recognition output. This module generates
deterministic variants of each test utterance (ASR substitutions, typos,
hesitation, filler pauses, punctuation, capitalization) and measures cosine
similarity between the original embedding and every variant.

This is a FIRST-CLASS evaluation metric, not a secondary check.

Variant generation is DETERMINISTIC (rule-based, not random) for reproducibility.
"""
import json
import math
import re
from pathlib import Path
from typing import List, Dict, Tuple, Any

import numpy as np


# ---------------------------------------------------------------------------
# Variant generators — each is a pure function: str -> str
# ---------------------------------------------------------------------------

def asr_variant(text: str) -> str:
    """Simulate common ASR substitutions."""
    subs = {
        "recording": "reccording",
        "calibration": "calibrations",
        "dictation": "diction",
        "composition": "composition",  # ASR usually gets this right
        "protocol": "protocols",
        "aloud": "a loud",
        "speak": "speek",
        "refine": "define",
        "clear": "cleer",
        "sleep": "sleeve",
    }
    result = text
    for correct, asr_err in subs.items():
        result = re.sub(r'\b' + re.escape(correct) + r'\b', asr_err, result, flags=re.IGNORECASE)
    return result


def typo_variant(text: str) -> str:
    """Introduce realistic typos — dropped letters, transpositions."""
    # Deterministic per-word transformations
    words = text.split()
    result = []
    for i, word in enumerate(words):
        if len(word) <= 2:
            result.append(word)
            continue
        # Every 3rd word: drop a letter from the middle
        if i % 3 == 1 and len(word) > 4:
            mid = len(word) // 2
            result.append(word[:mid] + word[mid+1:])
        # Every 5th word: transpose two adjacent letters
        elif i % 5 == 2 and len(word) > 3:
            pos = len(word) // 3
            chars = list(word)
            chars[pos], chars[pos+1] = chars[pos+1], chars[pos]
            result.append(''.join(chars))
        else:
            result.append(word)
    return ' '.join(result)


def hesitation_variant(text: str) -> str:
    """Prefix with hesitation words."""
    hesitations = ["um", "uh", "er", "hmm"]
    # Pick based on text length to be deterministic
    idx = len(text) % len(hesitations)
    prefix = hesitations[idx]
    # Some texts get a longer prefix
    if len(text) % 3 == 0:
        prefix = f"{prefix} let me think"
    return f"{prefix} {text}"


def filler_variant(text: str) -> str:
    """Add filler words around the text."""
    fillers = ["like", "you know", "just", "okay", "so", "well"]
    # Wrap with fillers deterministically based on text hash
    h = hash(text) % 4
    if h == 0:
        return f"like {text} you know"
    elif h == 1:
        return f"just {text} okay"
    elif h == 2:
        return f"so {text} then"
    else:
        return f"well {text} I guess"


def punctuation_variant(text: str) -> str:
    """Vary punctuation — add or remove commas, periods, question marks."""
    # Remove existing punctuation, then add based on text properties
    cleaned = re.sub(r'[,.!?;:]', '', text)
    words = cleaned.split()
    if len(words) > 4:
        # Add a comma after the 3rd word
        words.insert(3, ',')
        result = ' '.join(words)
        # Fix spacing around comma
        result = result.replace(' , ', ', ')
        return result + '.'
    elif len(words) > 2:
        return cleaned + '?'
    else:
        return cleaned + '!'


def capitalization_variant(text: str) -> str:
    """Vary capitalization — all lower, title case, or mixed."""
    h = hash(text) % 3
    if h == 0:
        return text.lower()
    elif h == 1:
        return text.title()
    else:
        # Capitalize every other word
        words = text.split()
        return ' '.join(
            w.upper() if i % 2 == 0 else w.lower()
            for i, w in enumerate(words)
        )


def no_punctuation_variant(text: str) -> str:
    """Strip all punctuation."""
    return re.sub(r'[,.!?;:]', '', text)


def doubled_word_variant(text: str) -> str:
    """Simulate ASR word-doubling stutter."""
    words = text.split()
    if not words:
        return text
    # Double the first word
    return f"{words[0]} {words[0]} {' '.join(words[1:])}"


# ---------------------------------------------------------------------------
# Semantic-preserving transforms — test semantic robustness, not noise
# robustness. These change wording while preserving meaning.
# ---------------------------------------------------------------------------

# Deterministic synonym map for common command verbs
_SYNONYM_MAP = {
    "start": "begin",
    "begin": "start",
    "stop": "halt",
    "end": "cease",
    "clear": "erase",
    "reset": "restart",
    "refine": "polish",
    "improve": "enhance",
    "speak": " vocalize",
    "read": "recite",
    "save": "store",
    "delete": "remove",
    "open": "launch",
    "close": "shut",
    "turn on": "enable",
    "turn off": "disable",
    "increase": "raise",
    "decrease": "lower",
    "change": "switch",
    "adjust": "modify",
}


def politeness_variant(text: str) -> str:
    """Add a politeness marker."""
    return f"please {text}"


def question_variant(text: str) -> str:
    """Convert imperative to question form."""
    return f"could you {text}?"


def synonym_variant(text: str) -> str:
    """Substitute command verbs with synonyms."""
    result = text
    for original, synonym in _SYNONYM_MAP.items():
        result = re.sub(r'\b' + re.escape(original) + r'\b', synonym, result, flags=re.IGNORECASE)
    return result


def drop_article_variant(text: str) -> str:
    """Drop articles (the, a, an)."""
    return re.sub(r'\b(?:the|a|an)\b\s*', '', text, flags=re.IGNORECASE)


def demonstrative_variant(text: str) -> str:
    """Replace 'the' with 'that'."""
    return re.sub(r'\bthe\b', 'that', text, flags=re.IGNORECASE)


def pluralize_variant(text: str) -> str:
    """Naive pluralization/singularization of last noun."""
    words = text.split()
    if not words:
        return text
    last = words[-1]
    if last.endswith('s') and not last.endswith('ss'):
        # Singularize
        words[-1] = last[:-1]
    elif last.endswith('y') and len(last) > 2:
        words[-1] = last[:-1] + 'ies'
    else:
        words[-1] = last + 's'
    return ' '.join(words)


def contraction_variant(text: str) -> str:
    """Expand contractions or contract expanded forms."""
    contractions = {
        "don't": "do not",
        "do not": "don't",
        "can't": "cannot",
        "won't": "will not",
        "I'm": "I am",
        "I am": "I'm",
    }
    result = text
    for contracted, expanded in contractions.items():
        if contracted in result:
            result = result.replace(contracted, expanded)
            break  # Only apply one to stay deterministic
    return result


# Semantic-preserving variant generators, in stable order
SEMANTIC_VARIANT_GENERATORS = [
    ("politeness", politeness_variant),
    ("question", question_variant),
    ("synonym", synonym_variant),
    ("drop_article", drop_article_variant),
    ("demonstrative", demonstrative_variant),
    ("pluralize", pluralize_variant),
    ("contraction", contraction_variant),
]


def generate_semantic_variants(text: str) -> Dict[str, str]:
    """Generate all semantic-preserving variants for a single text."""
    return {name: gen(text) for name, gen in SEMANTIC_VARIANT_GENERATORS}


# All variant generators, in stable order
VARIANT_GENERATORS = [
    ("asr", asr_variant),
    ("typo", typo_variant),
    ("hesitation", hesitation_variant),
    ("filler", filler_variant),
    ("punctuation", punctuation_variant),
    ("capitalization", capitalization_variant),
    ("no_punctuation", no_punctuation_variant),
    ("doubled_word", doubled_word_variant),
]


def generate_variants(text: str) -> Dict[str, str]:
    """Generate all variants for a single text. Returns {variant_type: variant_text}."""
    return {name: gen(text) for name, gen in VARIANT_GENERATORS}


# ---------------------------------------------------------------------------
# Stability measurement
# ---------------------------------------------------------------------------

def cosine_sim(a, b) -> float:
    """Cosine similarity between two vectors (lists or np arrays)."""
    a = np.array(a, dtype=np.float32)
    b = np.array(b, dtype=np.float32)
    dot = float(np.dot(a, b))
    na = float(np.linalg.norm(a))
    nb = float(np.linalg.norm(b))
    if na < 1e-9 or nb < 1e-9:
        return 0.0
    return dot / (na * nb)


def measure_stability(
    embedder_fn,
    test_texts: List[str],
) -> Dict[str, Any]:
    """
    Measure embedding stability across text variants.

    Computes TWO classes of stability:
    1. Noise stability: cosine(original, noise_variant) for ASR/typo/hesitation/etc.
    2. Semantic stability: cosine(original, semantic_variant) for politeness/question/synonym/etc.

    Args:
        embedder_fn: callable that takes List[str] -> List[List[float]] (embeddings)
        test_texts: list of original utterances to test

    Returns:
        {
            "per_text": [...],
            "per_variant_type": {...},      # noise variants
            "per_semantic_type": {...},      # semantic variants
            "overall": {...},               # noise stability stats
            "semantic_overall": {...},      # semantic stability stats
        }
    """
    # Build the full text list: for each original, generate all variants
    all_texts = []
    text_variant_map = []  # (original_index, variant_type, variant_text)

    for i, text in enumerate(test_texts):
        all_texts.append(text)  # original first
        text_variant_map.append((i, "original", text))
        variants = generate_variants(text)
        for vtype, vtext in variants.items():
            all_texts.append(vtext)
            text_variant_map.append((i, vtype, vtext))
        # Also generate semantic variants
        sem_variants = generate_semantic_variants(text)
        for vtype, vtext in sem_variants.items():
            all_texts.append(vtext)
            text_variant_map.append((i, f"semantic_{vtype}", vtext))

    # Embed all at once (batch is more efficient and consistent)
    all_embeddings = embedder_fn(all_texts)

    # Map embeddings back
    original_emb = {}  # original_index -> embedding
    variant_embs = {}  # (original_index, variant_type) -> embedding

    for (orig_idx, vtype, _), emb in zip(text_variant_map, all_embeddings):
        if vtype == "original":
            original_emb[orig_idx] = emb
        else:
            variant_embs[(orig_idx, vtype)] = emb

    # Compute per-text results
    per_text = []
    all_cosines_by_type = {name: [] for name, _ in VARIANT_GENERATORS}
    all_cosines_by_semantic = {f"semantic_{name}": [] for name, _ in SEMANTIC_VARIANT_GENERATORS}
    all_cosines = []
    all_semantic_cosines = []

    for i, text in enumerate(test_texts):
        orig = original_emb[i]
        text_result = {"text": text, "variants": {}, "semantic_variants": {}}
        for vtype, _ in VARIANT_GENERATORS:
            vemb = variant_embs.get((i, vtype))
            if vemb is not None:
                sim = cosine_sim(orig, vemb)
                text_result["variants"][vtype] = {
                    "variant_text": generate_variants(text)[vtype],
                    "cosine_similarity": sim,
                }
                all_cosines_by_type[vtype].append(sim)
                all_cosines.append(sim)
        for vtype, _ in SEMANTIC_VARIANT_GENERATORS:
            key = f"semantic_{vtype}"
            vemb = variant_embs.get((i, key))
            if vemb is not None:
                sim = cosine_sim(orig, vemb)
                text_result["semantic_variants"][vtype] = {
                    "variant_text": generate_semantic_variants(text)[vtype],
                    "cosine_similarity": sim,
                }
                all_cosines_by_semantic[key].append(sim)
                all_semantic_cosines.append(sim)
        per_text.append(text_result)

    # Per-variant-type aggregation (noise)
    per_variant_type = {}
    for vtype, cosines in all_cosines_by_type.items():
        if cosines:
            arr = np.array(cosines)
            per_variant_type[vtype] = {
                "mean": float(arr.mean()),
                "median": float(np.median(arr)),
                "std": float(arr.std()),
                "variance": float(arr.var()),
                "min": float(arr.min()),
                "max": float(arr.max()),
                "ci_95_lo": float(np.percentile(arr, 2.5)),
                "ci_95_hi": float(np.percentile(arr, 97.5)),
                "n": len(cosines),
            }

    # Per-semantic-type aggregation
    per_semantic_type = {}
    for vtype, cosines in all_cosines_by_semantic.items():
        if cosines:
            arr = np.array(cosines)
            per_semantic_type[vtype] = {
                "mean": float(arr.mean()),
                "median": float(np.median(arr)),
                "std": float(arr.std()),
                "variance": float(arr.var()),
                "min": float(arr.min()),
                "max": float(arr.max()),
                "ci_95_lo": float(np.percentile(arr, 2.5)),
                "ci_95_hi": float(np.percentile(arr, 97.5)),
                "n": len(cosines),
            }

    # Overall noise stability
    overall = {}
    if all_cosines:
        arr = np.array(all_cosines)
        overall = {
            "mean": float(arr.mean()),
            "median": float(np.median(arr)),
            "std": float(arr.std()),
            "variance": float(arr.var()),
            "min": float(arr.min()),
            "max": float(arr.max()),
            "ci_95_lo": float(np.percentile(arr, 2.5)),
            "ci_95_hi": float(np.percentile(arr, 97.5)),
            "n": len(all_cosines),
        }

    # Overall semantic stability
    semantic_overall = {}
    if all_semantic_cosines:
        arr = np.array(all_semantic_cosines)
        semantic_overall = {
            "mean": float(arr.mean()),
            "median": float(np.median(arr)),
            "std": float(arr.std()),
            "variance": float(arr.var()),
            "min": float(arr.min()),
            "max": float(arr.max()),
            "ci_95_lo": float(np.percentile(arr, 2.5)),
            "ci_95_hi": float(np.percentile(arr, 97.5)),
            "n": len(all_semantic_cosines),
        }

    return {
        "per_text": per_text,
        "per_variant_type": per_variant_type,
        "per_semantic_type": per_semantic_type,
        "overall": overall,
        "semantic_overall": semantic_overall,
    }