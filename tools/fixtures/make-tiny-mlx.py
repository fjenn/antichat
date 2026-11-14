#!/usr/bin/env python3
"""Generate the tiny-mlx-llm stub (environment.md §5; M0.T01 step 9).

Qwen3 architecture (mlx-swift-lm `qwen3`), 2 layers, hidden 64, 4 heads (2 KV), vocab 512.
Byte-level BPE trained with `tokenizers` on fixtures/docs/text/emoji-rtl.md + a frozen copy-deck snapshot
(tools/fixtures/corpus/tiny-mlx-copy-deck.md, CR-P-10).
Deterministic: numpy seed 20261030, single-threaded tokenizer training.
Plumbing only: random weights, never used for quality or speed.

Usage: tools/.venv/bin/python -I tools/fixtures/make-tiny-mlx.py [--fixtures DIR]
Writes <fixtures>/stub-models/tiny-mlx-llm/{config.json, model.safetensors, tokenizer.json,
tokenizer_config.json, generation_config.json} and <fixtures>/stub-models/.work/weights.npz (shared
with make-tiny-gguf.py).
"""
from __future__ import annotations

import argparse
import json
import os

os.environ.setdefault("RAYON_NUM_THREADS", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

import numpy as np  # noqa: E402
from safetensors.numpy import save_file  # noqa: E402
from tokenizers import Tokenizer, decoders, models, pre_tokenizers, trainers  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# CR-P-10 (M1.T03): a frozen snapshot of copy-deck.md at d2f09850 (the deck the committed stub models were trained
# on), not the living deck, which every UI task edits; keeps the tokenizer byte-reproducible.
CORPUS_DECK = os.path.join(ROOT, "tools/fixtures/corpus/tiny-mlx-copy-deck.md")
SEED = 20261030
SPECIAL = ["<|endoftext|>", "<|im_start|>", "<|im_end|>", "<tool_call>", "</tool_call>", "<think>", "</think>"]
CFG = {
    "architectures": ["Qwen3ForCausalLM"],
    "model_type": "qwen3",
    "hidden_size": 64,
    "intermediate_size": 128,
    "num_hidden_layers": 2,
    "num_attention_heads": 4,
    "num_key_value_heads": 2,
    "head_dim": 16,
    "vocab_size": 512,
    "max_position_embeddings": 2048,
    "rms_norm_eps": 1e-6,
    "rope_theta": 1000000.0,
    "tie_word_embeddings": True,
    "hidden_act": "silu",
    "torch_dtype": "float32",
    "bos_token_id": None,
    "eos_token_id": 2,
}
CHAT_TEMPLATE = (
    "{%- if tools %}<|im_start|>system\n# Tools\n<tools>\n{%- for tool in tools %}{{ tool | tojson }}\n{%- endfor %}"
    "</tools>\nFor each function call, return a json object inside <tool_call></tool_call> tags.<|im_end|>\n{%- endif %}"
    "{%- for message in messages %}"
    "{%- if message.role == 'assistant' and message.tool_calls %}<|im_start|>assistant\n"
    "{%- for tc in message.tool_calls %}<tool_call>\n{\"name\": \"{{ tc.function.name }}\", \"arguments\": "
    "{{ tc.function.arguments | tojson }}}\n</tool_call>{%- endfor %}<|im_end|>\n"
    "{%- else %}<|im_start|>{{ message.role }}\n{{ message.content }}<|im_end|>\n{%- endif %}"
    "{%- endfor %}{%- if add_generation_prompt %}<|im_start|>assistant\n{%- endif %}"
)


def train_tokenizer(fixtures: str) -> Tokenizer:
    texts = []
    for p in [os.path.join(fixtures, "docs/text/emoji-rtl.md"),
              CORPUS_DECK]:
        with open(p, encoding="utf-8") as f:
            texts.append(f.read())
    tok = Tokenizer(models.BPE(unk_token=None))
    tok.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tok.decoder = decoders.ByteLevel()
    trainer = trainers.BpeTrainer(vocab_size=CFG["vocab_size"], special_tokens=SPECIAL, show_progress=False,
                                  initial_alphabet=pre_tokenizers.ByteLevel.alphabet(), min_frequency=2)
    tok.train_from_iterator(texts, trainer=trainer)
    return tok


def weights(rng: np.random.Generator) -> dict[str, np.ndarray]:
    h, inter, L = CFG["hidden_size"], CFG["intermediate_size"], CFG["num_hidden_layers"]
    nh, nkv, hd, V = CFG["num_attention_heads"], CFG["num_key_value_heads"], CFG["head_dim"], CFG["vocab_size"]

    def w(*shape):
        return (rng.standard_normal(shape) * 0.02).astype(np.float32)

    t = {"model.embed_tokens.weight": w(V, h), "model.norm.weight": np.ones(h, np.float32)}
    for i in range(L):
        p = f"model.layers.{i}."
        t[p + "self_attn.q_proj.weight"] = w(nh * hd, h)
        t[p + "self_attn.k_proj.weight"] = w(nkv * hd, h)
        t[p + "self_attn.v_proj.weight"] = w(nkv * hd, h)
        t[p + "self_attn.o_proj.weight"] = w(h, nh * hd)
        t[p + "self_attn.q_norm.weight"] = np.ones(hd, np.float32)
        t[p + "self_attn.k_norm.weight"] = np.ones(hd, np.float32)
        t[p + "mlp.gate_proj.weight"] = w(inter, h)
        t[p + "mlp.up_proj.weight"] = w(inter, h)
        t[p + "mlp.down_proj.weight"] = w(h, inter)
        t[p + "input_layernorm.weight"] = np.ones(h, np.float32)
        t[p + "post_attention_layernorm.weight"] = np.ones(h, np.float32)
    return t


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=os.path.join(ROOT, "fixtures"))
    a = ap.parse_args()
    out = os.path.join(a.fixtures, "stub-models/tiny-mlx-llm")
    os.makedirs(out, exist_ok=True)

    tok = train_tokenizer(a.fixtures)
    tok.save(os.path.join(out, "tokenizer.json"), pretty=False)
    eos = tok.token_to_id("<|im_end|>")
    cfg = dict(CFG, eos_token_id=eos)
    with open(os.path.join(out, "config.json"), "w") as f:
        json.dump(cfg, f, indent=2, sort_keys=True)
    with open(os.path.join(out, "tokenizer_config.json"), "w") as f:
        json.dump({"tokenizer_class": "Qwen2Tokenizer", "model_max_length": 2048, "eos_token": "<|im_end|>",
                   "pad_token": "<|endoftext|>", "bos_token": None, "unk_token": None, "add_prefix_space": False,
                   "chat_template": CHAT_TEMPLATE,
                   "added_tokens_decoder": {str(tok.token_to_id(s)): {"content": s, "special": True} for s in SPECIAL}},
                  f, indent=2, sort_keys=True)
    with open(os.path.join(out, "generation_config.json"), "w") as f:
        json.dump({"eos_token_id": eos, "do_sample": False}, f, indent=2, sort_keys=True)

    t = weights(np.random.default_rng(SEED))
    save_file(t, os.path.join(out, "model.safetensors"), metadata={"format": "mlx"})
    os.makedirs(os.path.join(a.fixtures, "stub-models/.work"), exist_ok=True)
    np.savez(os.path.join(a.fixtures, "stub-models/.work/weights.npz"), **t)
    print(f"[ok] tiny-mlx-llm -> {out}")


if __name__ == "__main__":
    main()
