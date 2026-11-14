# SPDX-License-Identifier: Apache-2.0
"""Dense DMD sampling for MLXWan22DiT (Wan2.2 per-token timestep).

Matches the FastVideo pipeline's warped DMD schedule (``warp_denoising_step=True``,
``dmd_denoising_steps=[1000,757,522]``, ``flow_shift=5.0`` for TI2V-5B) rather
than treating raw step indices as continuous timesteps (a bug in early demos).
"""

from __future__ import annotations

from typing import TYPE_CHECKING
from collections.abc import Sequence

import numpy as np

from fastvideo.mlx_runtime.sampling import MLXDMDSchedule, dmd_step, pred_noise_to_pred_video

if TYPE_CHECKING:
    import mlx.core as mx

    from fastvideo.mlx_runtime.wan22 import MLXWan22DiT


def build_wan22_dmd_schedule(
    dmd_denoising_steps: Sequence[int] | None = None,
    *,
    flow_shift: float = 5.0,
    warp_denoising_step: bool = True,
) -> tuple[MLXDMDSchedule, list[float]]:
    """
    Build the flow-matching schedule and continuous timesteps used for Wan2.2 DMD sampling.

    Parameters:
        dmd_denoising_steps (Sequence[int] | None): Denoising step values to use; defaults to 1000, 757, and 522.
        flow_shift (float): Flow-matching shift applied when constructing the schedule.
        warp_denoising_step (bool): Whether to convert denoising steps to scheduler-warped continuous timesteps.

    Returns:
        tuple[MLXDMDSchedule, list[float]]: The DMD schedule and corresponding continuous timesteps.
    """
    import torch

    from fastvideo.models.schedulers.scheduling_flow_match_euler_discrete import FlowMatchEulerDiscreteScheduler

    steps = list(dmd_denoising_steps or [1000, 757, 522])
    scheduler = FlowMatchEulerDiscreteScheduler(shift=flow_shift)
    schedule = MLXDMDSchedule.from_torch_scheduler(scheduler)
    step_idx = torch.tensor(steps, dtype=torch.long)
    if warp_denoising_step:
        warped = torch.cat((scheduler.timesteps.cpu(), torch.tensor([0.0], dtype=torch.float32)))
        timesteps = [float(t) for t in warped[1000 - step_idx]]
    else:
        timesteps = [float(s) for s in steps]
    return schedule, timesteps


def sample_wan22_dmd(
    model: MLXWan22DiT,
    encoder_hidden_states: mx.array,
    noise_latents: mx.array,
    freqs_cis: tuple,
    *,
    dmd_denoising_steps: Sequence[int] | None = None,
    flow_shift: float = 5.0,
    warp_denoising_step: bool = True,
    seed: int = 0,
    # ANTICHAT-PATCH: UP-FV-001 per-step progress: step_callback(step, total, pred_video_latents) after each
    # sampler step (step is 1-based; pred_video is the clean-latent prediction, used for the TAEHV preview);
    # pause_check() before each step (blocks while the job is paused, raises to cancel; NFR-B3/B5, M5.T02).
    step_callback=None,
    pause_check=None,
    # ANTICHAT-PATCH-END
    # ANTICHAT-PATCH: UP-FV-002 torch-free runtime: a precomputed (schedule, timesteps) skips the torch
    # FlowMatchEulerDiscreteScheduler in build_wan22_dmd_schedule.
    schedule_and_timesteps: tuple[MLXDMDSchedule, list[float]] | None = None,
    # ANTICHAT-PATCH-END
) -> mx.array:
    """
    Generate clean video latents from noisy latents using iterative DMD denoising.

    Parameters:
        noise_latents (mx.array): Initial noisy video latents.
        freqs_cis (tuple): Rotary positional frequency tensors used by the model.
        dmd_denoising_steps (Sequence[int] | None): DMD denoising steps, or the default schedule when omitted.
        flow_shift (float): Flow-matching schedule shift.
        warp_denoising_step (bool): Whether to warp the denoising timesteps.
        seed (int): Seed for reproducible intermediate re-noising.

    Returns:
        mx.array: Denoised video latents.
    """
    import mlx.core as mx

    # ANTICHAT-PATCH: UP-FV-002 torch-free runtime (see the parameter)
    if schedule_and_timesteps is not None:
        schedule, timesteps = schedule_and_timesteps
    else:
        schedule, timesteps = build_wan22_dmd_schedule(dmd_denoising_steps,
                                                       flow_shift=flow_shift,
                                                       warp_denoising_step=warp_denoising_step)
    # ANTICHAT-PATCH-END
    # NumPy RNG so re-noise is bit-reproducible across MLX / torch A/B dumps.
    renoise_rng = np.random.default_rng(seed)
    latents = noise_latents
    batch, _c, frames, height, width = latents.shape
    pt, ph, pw = model.patch_size
    tokens = (frames // pt) * (height // ph) * (width // pw)
    last = len(timesteps) - 1
    for i, t in enumerate(timesteps):
        # ANTICHAT-PATCH: UP-FV-001 pause / cancel between steps (see the parameter)
        if pause_check is not None:
            pause_check()
        # ANTICHAT-PATCH-END
        ts = mx.full((batch, tokens), float(t), dtype=mx.float32)
        pred = model(latents.astype(mx.float16), encoder_hidden_states, ts, freqs_cis)
        ni = latents.astype(mx.float32)
        pn = pred.astype(mx.float32)
        if i < last:
            renoise = mx.array(renoise_rng.standard_normal(tuple(latents.shape)).astype(np.float32))
            latents = dmd_step(
                latents=ni,
                noise_input_latent=ni,
                pred_noise=pn,
                schedule=schedule,
                timestep=float(t),
                next_timestep=float(timesteps[i + 1]),
                noise=renoise,
            ).astype(latents.dtype)
        else:
            latents = pred_noise_to_pred_video(pn, ni, schedule.sigma_for(float(t))).astype(latents.dtype)
        mx.eval(latents)
        # ANTICHAT-PATCH: UP-FV-001 per-step progress (see the parameter)
        if step_callback is not None:
            pred_video = latents if i == last else pred_noise_to_pred_video(pn, ni, schedule.sigma_for(float(t)))
            step_callback(i + 1, len(timesteps), pred_video)
        # ANTICHAT-PATCH-END
    return latents
