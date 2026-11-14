#!/usr/bin/env python3
"""Convert the tiny-mlx-llm stub weights to GGUF (environment.md §5; M0.T01 step 9).

Uses the `gguf` package from the pinned llama.cpp submodule (Binaries/llama.cpp/gguf-py,
installed editable into tools/.venv). Same weights and tokenizer as tiny-mlx-llm.
Run make-tiny-mlx.py first. Output: <fixtures>/stub-models/tiny-gguf/tiny.gguf

Usage: tools/.venv/bin/python -I tools/fixtures/make-tiny-gguf.py [--fixtures DIR]
"""
from __future__ import annotations

import argparse
import json
import os

import gguf
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

NAME_MAP = {
    "self_attn.q_proj.weight": "attn_q.weight",
    "self_attn.k_proj.weight": "attn_k.weight",
    "self_attn.v_proj.weight": "attn_v.weight",
    "self_attn.o_proj.weight": "attn_output.weight",
    "self_attn.q_norm.weight": "attn_q_norm.weight",
    "self_attn.k_norm.weight": "attn_k_norm.weight",
    "mlp.gate_proj.weight": "ffn_gate.weight",
    "mlp.up_proj.weight": "ffn_up.weight",
    "mlp.down_proj.weight": "ffn_down.weight",
    "input_layernorm.weight": "attn_norm.weight",
    "post_attention_layernorm.weight": "ffn_norm.weight",
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=os.path.join(ROOT, "fixtures"))
    a = ap.parse_args()
    src = os.path.join(a.fixtures, "stub-models/tiny-mlx-llm")
    out_dir = os.path.join(a.fixtures, "stub-models/tiny-gguf")
    os.makedirs(out_dir, exist_ok=True)
    cfg = json.load(open(os.path.join(src, "config.json")))
    tokj = json.load(open(os.path.join(src, "tokenizer.json")))
    w = dict(np.load(os.path.join(a.fixtures, "stub-models/.work/weights.npz")))

    arch = "qwen3"
    wr = gguf.GGUFWriter(os.path.join(out_dir, "tiny.gguf"), arch)
    wr.add_name("antichat-tiny-qwen3")
    wr.add_context_length(cfg["max_position_embeddings"])
    wr.add_embedding_length(cfg["hidden_size"])
    wr.add_block_count(cfg["num_hidden_layers"])
    wr.add_feed_forward_length(cfg["intermediate_size"])
    wr.add_head_count(cfg["num_attention_heads"])
    wr.add_head_count_kv(cfg["num_key_value_heads"])
    wr.add_key_length(cfg["head_dim"])
    wr.add_value_length(cfg["head_dim"])
    wr.add_layer_norm_rms_eps(cfg["rms_norm_eps"])
    wr.add_rope_freq_base(cfg["rope_theta"])
    wr.add_file_type(gguf.LlamaFileType.ALL_F32)

    vocab = tokj["model"]["vocab"]
    added = {t["content"]: t["id"] for t in tokj.get("added_tokens", [])}
    size = cfg["vocab_size"]
    tokens = [f"[PAD{i}]" for i in range(size)]
    types = [gguf.TokenType.UNUSED] * size
    for t, i in vocab.items():
        if i < size:
            tokens[i] = t
            types[i] = gguf.TokenType.NORMAL
    for t, i in added.items():
        if i < size:
            tokens[i] = t
            types[i] = gguf.TokenType.CONTROL
    merges = [m if isinstance(m, str) else " ".join(m) for m in tokj["model"]["merges"]]
    wr.add_tokenizer_model("gpt2")
    wr.add_tokenizer_pre("qwen2")
    wr.add_token_list(tokens)
    wr.add_token_types(types)
    wr.add_token_merges(merges)
    wr.add_eos_token_id(added["<|im_end|>"])
    wr.add_pad_token_id(added["<|endoftext|>"])
    wr.add_add_bos_token(False)
    tcfg = json.load(open(os.path.join(src, "tokenizer_config.json")))
    wr.add_chat_template(tcfg["chat_template"])

    wr.add_tensor("token_embd.weight", w["model.embed_tokens.weight"])
    wr.add_tensor("output_norm.weight", w["model.norm.weight"])
    for i in range(cfg["num_hidden_layers"]):
        for k, v in NAME_MAP.items():
            wr.add_tensor(f"blk.{i}.{v}", w[f"model.layers.{i}.{k}"])

    wr.write_header_to_file()
    wr.write_kv_data_to_file()
    wr.write_tensors_to_file()
    wr.close()
    print(f"[ok] tiny-gguf -> {out_dir}/tiny.gguf")


if __name__ == "__main__":
    main()
