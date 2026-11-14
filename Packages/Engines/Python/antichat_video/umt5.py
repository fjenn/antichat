"""umT5-XXL text encoder in MLX for Wan2.2 (M0.T07; torch-free replacement of FastVideo's `encode_prompt`).

Model code ported from Blaizzy/mlx-video@87db56a51758fefb748a359b90a5283bb8ba4837
`mlx_video/models/wan_2/text_encoder.py` (MIT, Prince Canuma): T5 RMS norm, per-layer relative position bias
(umT5: `shared_pos=False`), unscaled attention with an fp32 softmax, gated-GELU (tanh) feed-forward.
Changes: weights load directly from the Hugging Face `UMT5EncoderModel` safetensors shards of vid-5b
(`text_encoder/model-0000x-of-00003.safetensors`, key map below) instead of a converted file; tokenizer =
sentencepiece on `tokenizer/spiece.model` + `</s>` (the T5TokenizerFast behaviour for plain prompts).

Prompt-embedding post-processing follows FastVideo@d9e6c3e
`examples/inference/basic/mlx_wan_prompt_to_video.py:147-201` (`encode_prompt`): pad to 512 tokens, run with
the attention mask, keep the first `seq_len` rows and zero the rest. Parity with the torch reference is
checked by `tests/test_parity.py` (dev-only, needs torch + transformers outside the runtime).
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np


class T5LayerNorm(nn.Module):
    def __init__(self, dim: int, eps: float = 1e-6):
        super().__init__()
        self.eps = eps
        self.weight = mx.ones((dim,))

    def __call__(self, x: mx.array) -> mx.array:
        return mx.fast.rms_norm(x, self.weight, self.eps)


class T5RelativeEmbedding(nn.Module):
    def __init__(self, num_buckets: int, num_heads: int, bidirectional: bool = True, max_dist: int = 128):
        super().__init__()
        self.num_buckets = num_buckets
        self.num_heads = num_heads
        self.bidirectional = bidirectional
        self.max_dist = max_dist
        self.embedding = nn.Embedding(num_buckets, num_heads)

    def _bucket(self, rel_pos: mx.array) -> mx.array:
        if self.bidirectional:
            num_buckets = self.num_buckets // 2
            buckets = (rel_pos > 0).astype(mx.int32) * num_buckets
            rel_pos = mx.abs(rel_pos)
        else:
            num_buckets = self.num_buckets
            buckets = mx.zeros_like(rel_pos, dtype=mx.int32)
            rel_pos = mx.maximum(-rel_pos, mx.zeros_like(rel_pos))
        max_exact = num_buckets // 2
        is_small = rel_pos < max_exact
        # max(·, 1) keeps log() finite on the small branch (that branch is discarded by `where`).
        rel_f = mx.maximum(rel_pos, 1).astype(mx.float32)
        large = max_exact + (mx.log(rel_f / max_exact) / math.log(self.max_dist / max_exact)
                             * (num_buckets - max_exact)).astype(mx.int32)
        large = mx.minimum(large, mx.full(large.shape, num_buckets - 1, dtype=mx.int32))
        return buckets + mx.where(is_small, rel_pos.astype(mx.int32), large)

    def __call__(self, lq: int, lk: int) -> mx.array:
        rel = mx.arange(lk)[None, :] - mx.arange(lq)[:, None]
        emb = self.embedding(self._bucket(rel))  # [lq, lk, heads]
        return emb.transpose(2, 0, 1)[None]  # [1, heads, lq, lk]


class T5Attention(nn.Module):
    def __init__(self, dim: int, dim_attn: int, num_heads: int):
        super().__init__()
        self.num_heads = num_heads
        self.head_dim = dim_attn // num_heads
        self.q = nn.Linear(dim, dim_attn, bias=False)
        self.k = nn.Linear(dim, dim_attn, bias=False)
        self.v = nn.Linear(dim, dim_attn, bias=False)
        self.o = nn.Linear(dim_attn, dim, bias=False)

    def __call__(self, x: mx.array, mask: mx.array | None, pos_bias: mx.array | None) -> mx.array:
        b, n, c = x.shape[0], self.num_heads, self.head_dim
        q = self.q(x).reshape(b, -1, n, c).transpose(0, 2, 1, 3)
        k = self.k(x).reshape(b, -1, n, c).transpose(0, 2, 1, 3)
        v = self.v(x).reshape(b, -1, n, c).transpose(0, 2, 1, 3)
        attn = q.astype(mx.float32) @ k.astype(mx.float32).transpose(0, 1, 3, 2)  # T5: no 1/sqrt(d)
        if pos_bias is not None:
            attn = attn + pos_bias.astype(mx.float32)
        if mask is not None:
            attn = attn + mx.where(mask[:, None, None, :] == 0, -3.389e38, 0.0).astype(mx.float32)
        attn = mx.softmax(attn, axis=-1).astype(q.dtype)
        out = (attn @ v).transpose(0, 2, 1, 3).reshape(b, -1, n * c)
        return self.o(out)


class T5FeedForward(nn.Module):
    def __init__(self, dim: int, dim_ffn: int):
        super().__init__()
        self.gate_proj = nn.Linear(dim, dim_ffn, bias=False)  # HF wi_0 (through gelu_new)
        self.fc1 = nn.Linear(dim, dim_ffn, bias=False)  # HF wi_1
        self.fc2 = nn.Linear(dim_ffn, dim, bias=False)  # HF wo
        self.act = nn.GELU(approx="tanh")

    def __call__(self, x: mx.array) -> mx.array:
        return self.fc2(self.fc1(x) * self.act(self.gate_proj(x)))


class T5Block(nn.Module):
    def __init__(self, dim, dim_attn, dim_ffn, num_heads, num_buckets, max_dist, eps):
        super().__init__()
        self.norm1 = T5LayerNorm(dim, eps)
        self.attn = T5Attention(dim, dim_attn, num_heads)
        self.norm2 = T5LayerNorm(dim, eps)
        self.ffn = T5FeedForward(dim, dim_ffn)
        self.pos_embedding = T5RelativeEmbedding(num_buckets, num_heads, True, max_dist)

    def __call__(self, x: mx.array, mask: mx.array | None) -> mx.array:
        e = self.pos_embedding(x.shape[1], x.shape[1])
        x = x + self.attn(self.norm1(x), mask, e)
        return x + self.ffn(self.norm2(x))


class UMT5Encoder(nn.Module):
    def __init__(self, cfg: dict):
        super().__init__()
        dim, heads = int(cfg["d_model"]), int(cfg["num_heads"])
        dim_attn = heads * int(cfg["d_kv"])
        self.token_embedding = nn.Embedding(int(cfg["vocab_size"]), dim)
        self.blocks = [T5Block(dim, dim_attn, int(cfg["d_ff"]), heads, int(cfg["relative_attention_num_buckets"]),
                               int(cfg.get("relative_attention_max_distance", 128)), float(cfg["layer_norm_epsilon"]))
                       for _ in range(int(cfg["num_layers"]))]
        self.norm = T5LayerNorm(dim, float(cfg["layer_norm_epsilon"]))

    def __call__(self, ids: mx.array, mask: mx.array | None = None) -> mx.array:
        x = self.token_embedding(ids)
        for blk in self.blocks:
            x = blk(x, mask)
        return self.norm(x)


def hf_key_map(num_layers: int) -> dict[str, str]:
    """HF `UMT5EncoderModel` safetensors key → this module's parameter path."""
    m = {"shared.weight": "token_embedding.weight", "encoder.final_layer_norm.weight": "norm.weight"}
    for i in range(num_layers):
        h, o = f"encoder.block.{i}.layer", f"blocks.{i}"
        m.update({
            f"{h}.0.SelfAttention.q.weight": f"{o}.attn.q.weight",
            f"{h}.0.SelfAttention.k.weight": f"{o}.attn.k.weight",
            f"{h}.0.SelfAttention.v.weight": f"{o}.attn.v.weight",
            f"{h}.0.SelfAttention.o.weight": f"{o}.attn.o.weight",
            f"{h}.0.SelfAttention.relative_attention_bias.weight": f"{o}.pos_embedding.embedding.weight",
            f"{h}.0.layer_norm.weight": f"{o}.norm1.weight",
            f"{h}.1.DenseReluDense.wi_0.weight": f"{o}.ffn.gate_proj.weight",
            f"{h}.1.DenseReluDense.wi_1.weight": f"{o}.ffn.fc1.weight",
            f"{h}.1.DenseReluDense.wo.weight": f"{o}.ffn.fc2.weight",
            f"{h}.1.layer_norm.weight": f"{o}.norm2.weight",
        })
    return m


def load_encoder(text_encoder_dir: Path, dtype=mx.bfloat16) -> UMT5Encoder:
    cfg = json.loads((text_encoder_dir / "config.json").read_text())
    if cfg.get("model_type") != "umt5":
        raise ValueError(f"expected a umt5 text encoder, got {cfg.get('model_type')}")
    model = UMT5Encoder(cfg)
    kmap = hf_key_map(int(cfg["num_layers"]))
    weights: list[tuple[str, mx.array]] = []
    seen: set[str] = set()
    for shard in sorted(text_encoder_dir.glob("*.safetensors")):
        for k, v in mx.load(str(shard)).items():
            if k == "encoder.embed_tokens.weight" and "shared.weight" in seen:
                continue  # tied copy of shared.weight in some exports
            if k not in kmap:
                raise ValueError(f"unexpected text-encoder tensor {k}")
            name = "shared.weight" if k == "encoder.embed_tokens.weight" else k
            seen.add(name)
            weights.append((kmap[name], v.astype(dtype)))
    missing = set(kmap) - seen
    if missing:
        raise ValueError(f"missing text-encoder tensors: {sorted(missing)[:5]} …")
    model.load_weights(weights, strict=True)
    mx.eval(model.parameters())
    return model


class Tokenizer:
    """sentencepiece `spiece.model` + `</s>`; pad id 0 (T5TokenizerFast for plain-text prompts)."""

    def __init__(self, tokenizer_dir: Path):
        import sentencepiece as spm

        self.sp = spm.SentencePieceProcessor(model_file=str(tokenizer_dir / "spiece.model"))
        self.eos_id, self.pad_id = 1, 0

    def __call__(self, text: str, max_length: int) -> tuple[np.ndarray, np.ndarray]:
        ids = self.sp.encode(text, out_type=int)[: max_length - 1] + [self.eos_id]
        n = len(ids)
        arr = np.full((1, max_length), self.pad_id, dtype=np.int32)
        arr[0, :n] = ids
        mask = np.zeros((1, max_length), dtype=np.int32)
        mask[0, :n] = 1
        return arr, mask


def encode_prompt(model_root: Path, prompt: str, *, max_sequence_length: int = 512,
                  encoder: UMT5Encoder | None = None) -> np.ndarray:
    """Returns float32 `[1, max_sequence_length, 4096]` prompt embeddings (padding rows zeroed)."""
    tok = Tokenizer(model_root / "tokenizer")
    ids, mask = tok(prompt, max_sequence_length)
    enc = encoder or load_encoder(model_root / "text_encoder")
    out = enc(mx.array(ids), mx.array(mask))
    out = out.astype(mx.float32)
    mx.eval(out)
    emb = np.array(out)
    seq_len = int(mask.sum())
    emb[:, seq_len:] = 0.0
    return emb
