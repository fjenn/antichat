"""Parity of the torch-free video driver against the torch originals (M0.T07; A-M0-T07a). Dev-only: needs a
venv with torch + transformers + diffusers + mlx (never the shipped runtime). GPU job: run under the lock.

  lockf /tmp/antichat-gpu.lock <devvenv>/bin/python -I Packages/Engines/Python/tests/test_parity.py \
      --model <vid-5b dir> --taehv-pth <taew2_2.pth> --taehv <taew2_2.safetensors> [--skip-te] [--out parity.json]

Checks
  1. tokenizer: sentencepiece + </s> == transformers T5TokenizerFast(tokenizer/) ids + mask (padding 512);
  2. schedule: numerics.wan22_dmd_schedule == FastVideo `build_wan22_dmd_schedule` math on diffusers'
     FlowMatchEulerDiscreteScheduler(shift=5) (FastVideo's scheduler is a copy of it, static shift);
  3. RoPE: numerics.wan_rotary == upstream `get_nd_rotary_pos_embed` (source extracted from the pristine
     Vendor/.upstream copy of fastvideo/layers/rotary_embedding.py and run with torch);
  4. umT5: MLX bf16 encoder vs transformers UMT5EncoderModel fp32 (CPU) on the valid tokens: cosine ≥ 0.999;
  5. TAEHV: every tensor of madebyollin/taehv@fa579a9 `safetensors/taew2_2.safetensors` (the file the runtime loads,
     UP-FV-002) == torch.load(taew2_2.pth) (the checkpoint FastVideo pins), exact after .float().
"""
from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path

import numpy as np

sys.dont_write_bytecode = True  # never write .pyc into Vendor/ (allow-list check)
HERE = Path(__file__).resolve()
ROOT = HERE.parents[4]
sys.path[:0] = [str(HERE.parents[1]), str(ROOT / "Vendor/FastVideo@d9e6c3e")]
PROMPTS = [
    "A calm mountain lake at sunrise, mist drifting over the water, pine trees on the shore",
    "A red vintage bicycle leaning against an old stone wall, autumn leaves on the cobblestones",
    "Ocean waves rolling onto a sandy beach under a clear blue sky, slow camera pan",
]


def upstream_rope():
    import torch

    src = (ROOT / "Vendor/.upstream/FastVideo@d9e6c3e/fastvideo/layers/rotary_embedding.py").read_text()
    tree = ast.parse(src)
    want = {"_to_tuple", "get_meshgrid_nd", "get_1d_rotary_pos_embed", "get_nd_rotary_pos_embed"}
    body = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in want]
    ns = {"torch": torch, "Any": object}
    exec(compile(ast.Module(body=body, type_ignores=[]), "rotary_embedding.py", "exec"), ns)
    return ns["get_nd_rotary_pos_embed"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--taehv-pth", type=Path, required=True)
    ap.add_argument("--taehv", type=Path, required=True)
    ap.add_argument("--skip-te", action="store_true")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()
    import torch

    from antichat_video import numerics, umt5
    res: dict[str, object] = {}

    # 1. tokenizer
    from transformers import AutoTokenizer

    hf = AutoTokenizer.from_pretrained(a.model / "tokenizer", local_files_only=True)
    tok = umt5.Tokenizer(a.model / "tokenizer")
    ok = True
    for p in PROMPTS:
        t = hf([p], padding="max_length", max_length=512, truncation=True, add_special_tokens=True,
               return_attention_mask=True, return_tensors="np")
        ids, mask = tok(p, 512)
        ok &= bool((t.input_ids == ids).all() and (t.attention_mask == mask).all())
    res["tokenizer_equal"] = ok

    # 2. schedule
    from diffusers import FlowMatchEulerDiscreteScheduler

    s = FlowMatchEulerDiscreteScheduler(shift=5.0)
    steps = torch.tensor([1000, 757, 522], dtype=torch.long)
    warped = torch.cat((s.timesteps.cpu(), torch.tensor([0.0], dtype=torch.float32)))
    ref_ts = [float(t) for t in warped[1000 - steps]]
    sched, ts = numerics.wan22_dmd_schedule([1000, 757, 522], flow_shift=5.0)
    res["schedule_timesteps"] = {"ours": ts, "torch": ref_ts}
    res["schedule_equal"] = (ts == ref_ts and np.array_equal(sched.sigmas, s.sigmas.double().numpy())
                             and np.array_equal(sched.timesteps, s.timesteps.double().numpy()))

    # 3. RoPE (480p: latent 19×30×52, patch 1×2×2)
    cfg = json.loads((a.model / "mlx_dit.json").read_text())["config"]
    get_nd = upstream_rope()
    hd = int(cfg["attention_head_dim"])
    dims = [hd - 4 * (hd // 6), 2 * (hd // 6), 2 * (hd // 6)]
    rc, rs = get_nd(dims, (19, 15, 26), theta=10000, dtype=torch.float32, use_real=True)
    oc, os_ = numerics.wan_rotary(cfg, latent_frames=19, latent_height=30, latent_width=52)
    res["rope_max_abs_diff"] = float(max(np.abs(rc.numpy() - oc).max(), np.abs(rs.numpy() - os_).max()))
    res["rope_ok"] = res["rope_max_abs_diff"] <= 1e-5

    # 5. TAEHV conversion
    from safetensors.numpy import load_file

    ref = {k: v.float().numpy() for k, v in torch.load(a.taehv_pth, map_location="cpu", weights_only=True).items()}
    ours = load_file(str(a.taehv))
    res["taehv_tensors"] = len(ref)
    res["taehv_equal"] = set(ref) == set(ours) and all(np.array_equal(ref[k], ours[k].astype(np.float32)) for k in ref)

    # 4. umT5 (slow: fp32 torch reference on CPU)
    if not a.skip_te:
        import mlx.core as mx
        from transformers import UMT5EncoderModel

        p = PROMPTS[0]
        ids, mask = tok(p, 512)
        n = int(mask.sum())
        ours_e = umt5.encode_prompt(a.model, p)[0, :n]
        mx.clear_cache()
        te = UMT5EncoderModel.from_pretrained(a.model / "text_encoder", torch_dtype=torch.float32, local_files_only=True).eval()
        with torch.no_grad():
            ref_e = te(torch.from_numpy(ids.astype(np.int64)), torch.from_numpy(mask.astype(np.int64))).last_hidden_state[0, :n].numpy()
        cos = (ours_e * ref_e).sum(-1) / (np.linalg.norm(ours_e, axis=-1) * np.linalg.norm(ref_e, axis=-1))
        res["umt5_tokens"] = n
        res["umt5_cosine_min"] = float(cos.min())
        res["umt5_cosine_mean"] = float(cos.mean())
        res["umt5_rel_l2"] = float(np.linalg.norm(ours_e - ref_e) / np.linalg.norm(ref_e))
        res["umt5_ok"] = res["umt5_cosine_min"] >= 0.999
    keys = [k for k in res if k.endswith(("_ok", "_equal"))]
    res["pass"] = all(bool(res[k]) for k in keys)
    print(json.dumps(res, indent=1))
    if a.out:
        a.out.parent.mkdir(parents=True, exist_ok=True)
        a.out.write_text(json.dumps(res, indent=1) + "\n")
    return 0 if res["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
