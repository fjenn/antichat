"""NumPy ports of the torch-only pieces of FastVideo's Wan2.2 MLX path (M0.T07; A-M0-T07a).

- `wan22_dmd_schedule`: FastVideo@d9e6c3e `fastvideo/mlx_runtime/wan22_sample.py:24-55`
  (`build_wan22_dmd_schedule`) over `fastvideo/models/schedulers/scheduling_flow_match_euler_discrete.py:141-150`
  (`FlowMatchEulerDiscreteScheduler.__init__`, static shift): float32 `timesteps = linspace(1, 1000, 1000)[::-1]`,
  `sigmas = shift·s / (1 + (shift − 1)·s)`, `timesteps = sigmas · 1000`; warped DMD steps index
  `cat(timesteps, [0])[1000 − step]`.
- `wan_rotary`: `examples/inference/basic/mlx_wan_prompt_to_video.py:318-345` (`make_rotary_embeddings`) over
  `fastvideo/layers/rotary_embedding.py:245-465` (`get_meshgrid_nd`, `get_1d_rotary_pos_embed`,
  `get_nd_rotary_pos_embed`; `use_real=True`, theta 10000, no rescale/interpolation, no sharding).
Both are float32 like the torch code; `tests/test_parity.py` compares them with the torch originals.
"""
from __future__ import annotations

from collections.abc import Sequence

import numpy as np


def flow_match_schedule(shift: float, num_train_timesteps: int = 1000) -> tuple[np.ndarray, np.ndarray]:
    t = np.linspace(1, num_train_timesteps, num_train_timesteps, dtype=np.float32)[::-1].copy()
    s = t / np.float32(num_train_timesteps)
    s = (np.float32(shift) * s / (np.float32(1) + np.float32(shift - 1) * s)).astype(np.float32)
    return s, (s * np.float32(num_train_timesteps)).astype(np.float32)


def wan22_dmd_schedule(dmd_denoising_steps: Sequence[int] | None = None, *, flow_shift: float = 5.0,
                       warp_denoising_step: bool = True):
    """Returns `(MLXDMDSchedule, timesteps)` exactly as `build_wan22_dmd_schedule` without torch."""
    from fastvideo.mlx_runtime.sampling import MLXDMDSchedule

    steps = list(dmd_denoising_steps or [1000, 757, 522])
    sigmas, timesteps = flow_match_schedule(flow_shift)
    schedule = MLXDMDSchedule(sigmas=sigmas.astype(np.float64), timesteps=timesteps.astype(np.float64))
    if warp_denoising_step:
        warped = np.concatenate([timesteps, np.zeros(1, dtype=np.float32)])
        ts = [float(warped[1000 - s]) for s in steps]
    else:
        ts = [float(s) for s in steps]
    return schedule, ts


def _rope_1d(dim: int, pos: np.ndarray, theta: float) -> tuple[np.ndarray, np.ndarray]:
    exps = np.arange(0, dim, 2, dtype=np.float32)[: dim // 2] / np.float32(dim)
    freqs = (np.float32(1.0) / (np.float32(theta) ** exps)).astype(np.float32)
    f = np.outer(pos.astype(np.float32), freqs).astype(np.float32)
    return np.repeat(np.cos(f), 2, axis=-1), np.repeat(np.sin(f), 2, axis=-1)


def wan_rotary(config: dict, *, latent_frames: int, latent_height: int, latent_width: int, theta: float = 10000.0):
    """`(cos, sin)` float32 `[tokens, head_dim]` for the DiT (same values as `make_rotary_embeddings`)."""
    head_dim = int(config["attention_head_dim"])
    pt, ph, pw = tuple(config["patch_size"])
    sizes = (latent_frames // pt, latent_height // ph, latent_width // pw)
    dims = [head_dim - 4 * (head_dim // 6), 2 * (head_dim // 6), 2 * (head_dim // 6)]
    axes = [np.linspace(0, n, n + 1, dtype=np.float32)[:n] for n in sizes]
    grid = np.stack(np.meshgrid(*axes, indexing="ij"), axis=0)
    cos, sin = zip(*[_rope_1d(dims[i], grid[i].reshape(-1), theta) for i in range(3)])
    return np.concatenate(cos, axis=1), np.concatenate(sin, axis=1)
