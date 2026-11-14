#!/usr/bin/env python3
"""Generate the tiny-embed stub (environment.md §5; M0.T01 step 9).

Random 2-layer BERT-style encoder with 64-d output, same tokenizer as tiny-mlx-llm.
Deterministic (seed 20261030 + 1). Plumbing only (sqlite-vec/RRF), never relevance.
Run make-tiny-mlx.py first. Output: <fixtures>/stub-models/tiny-embed/

Usage: tools/.venv/bin/python -I tools/fixtures/make-tiny-embed.py [--fixtures DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil

import numpy as np
from safetensors.numpy import save_file

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SEED = 20261030 + 1
CFG = {
    "architectures": ["BertModel"],
    "model_type": "bert",
    "hidden_size": 64,
    "intermediate_size": 128,
    "num_hidden_layers": 2,
    "num_attention_heads": 4,
    "vocab_size": 512,
    "max_position_embeddings": 512,
    "type_vocab_size": 2,
    "layer_norm_eps": 1e-12,
    "hidden_act": "gelu",
    "torch_dtype": "float32",
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=os.path.join(ROOT, "fixtures"))
    a = ap.parse_args()
    src = os.path.join(a.fixtures, "stub-models/tiny-mlx-llm")
    out = os.path.join(a.fixtures, "stub-models/tiny-embed")
    os.makedirs(out, exist_ok=True)
    rng = np.random.default_rng(SEED)
    h, inter, L, V = CFG["hidden_size"], CFG["intermediate_size"], CFG["num_hidden_layers"], CFG["vocab_size"]

    def w(*shape):
        return (rng.standard_normal(shape) * 0.02).astype(np.float32)

    def z(*shape):
        return np.zeros(shape, np.float32)

    def o(*shape):
        return np.ones(shape, np.float32)

    t = {
        "embeddings.word_embeddings.weight": w(V, h),
        "embeddings.position_embeddings.weight": w(CFG["max_position_embeddings"], h),
        "embeddings.token_type_embeddings.weight": w(CFG["type_vocab_size"], h),
        "embeddings.LayerNorm.weight": o(h), "embeddings.LayerNorm.bias": z(h),
        "pooler.dense.weight": w(h, h), "pooler.dense.bias": z(h),
    }
    for i in range(L):
        p = f"encoder.layer.{i}."
        for n in ("query", "key", "value"):
            t[p + f"attention.self.{n}.weight"] = w(h, h)
            t[p + f"attention.self.{n}.bias"] = z(h)
        t[p + "attention.output.dense.weight"] = w(h, h)
        t[p + "attention.output.dense.bias"] = z(h)
        t[p + "attention.output.LayerNorm.weight"] = o(h)
        t[p + "attention.output.LayerNorm.bias"] = z(h)
        t[p + "intermediate.dense.weight"] = w(inter, h)
        t[p + "intermediate.dense.bias"] = z(inter)
        t[p + "output.dense.weight"] = w(h, inter)
        t[p + "output.dense.bias"] = z(h)
        t[p + "output.LayerNorm.weight"] = o(h)
        t[p + "output.LayerNorm.bias"] = z(h)
    save_file(t, os.path.join(out, "model.safetensors"), metadata={"format": "mlx"})
    with open(os.path.join(out, "config.json"), "w") as f:
        json.dump(CFG, f, indent=2, sort_keys=True)
    shutil.copyfile(os.path.join(src, "tokenizer.json"), os.path.join(out, "tokenizer.json"))
    with open(os.path.join(out, "tokenizer_config.json"), "w") as f:
        json.dump({"tokenizer_class": "PreTrainedTokenizerFast", "model_max_length": 512, "pad_token": "<|endoftext|>"},
                  f, indent=2, sort_keys=True)
    print(f"[ok] tiny-embed -> {out}")


if __name__ == "__main__":
    main()
