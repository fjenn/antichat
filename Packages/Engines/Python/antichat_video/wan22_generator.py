"""Wan2.2-TI2V-5B text-to-video generator for the runtime server (M5.T02 step 2; D-013 "generator written by us",
P-media-11). Same pipeline as the M0.T07 driver (`generate_wan22.py`, torch-free; removed in M5.T14), restructured for a long-lived
server: everything stays in memory and every stage reports through `sink`.

  1. umT5-XXL encode in MLX (`umt5.py`), encoder freed;            progress{stage: encode, step 0/1 → 1/1}
  2. `MLXWan22DiT` (QAD INT8) + 3-step warped DMD with UP-FV-001:  progress{stage: denoise, step k/n} + previews
     `step_callback` → previews, `pause_check` → pause / cancel between steps;
  3. TAEHV decode in chunks of latent frames (`frames.StreamingTAEHV`, exact) → RGBA8 frames in a FrameStore;
                                                                   progress{stage: decode, step frame/total}
  4. frames_ready{count, width, height, fps}.
The MLX memory limit comes from the request (the scheduler's budget share). No file is written anywhere.
"""
from __future__ import annotations

import gc
import math
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import numpy as np

from antichat_video.frames import FrameStore, StreamingTAEHV, to_rgba8_mx
from antichat_video.preview import PreviewMaker, shows_preview

Sink = Callable[[str, dict], None]
DEFAULT_STEPS = [1000, 757, 522]  # FastMetal-5B-QAD DMD (M0.T07)
COMPILE_DIT = True  # perf/t4-video: see Wan22Generator.run


class Cancelled(Exception):
    pass


@dataclass
class Control:
    """Cross-thread job control: cancel between steps / decode chunks, pause blocks between steps."""
    cancelled: threading.Event = field(default_factory=threading.Event)
    running: threading.Event = field(default_factory=lambda: _set(threading.Event()))

    def pause(self) -> None:
        self.running.clear()

    def resume(self) -> None:
        self.running.set()

    def cancel(self) -> None:
        self.cancelled.set()
        self.running.set()

    def check(self) -> None:
        while not self.running.wait(0.1):
            if self.cancelled.is_set():
                break
        if self.cancelled.is_set():
            raise Cancelled()


def _set(e: threading.Event) -> threading.Event:
    e.set()
    return e


@dataclass
class Report:
    metrics: dict[str, float] = field(default_factory=dict)


class Wan22Generator:
    def __init__(self, model_dir: Path, taehv_path: Path) -> None:
        self.model_dir = Path(model_dir)
        self.taehv_path = Path(taehv_path)

    def run(self, req: Any, sink: Sink, control: Control, store: FrameStore) -> Report:
        import mlx.core as mx

        from antichat_video import numerics, umt5
        from fastvideo.mlx_runtime.memory import cleanup_mlx
        from fastvideo.mlx_runtime.wan22 import mlx_wan22_dit_from_mlx_checkpoint
        from fastvideo.mlx_runtime.wan22_sample import sample_wan22_dmd
        from fastvideo.mlx_runtime.wan_vae import MLXTAEHVDecoder

        t0 = time.perf_counter()
        rep = Report()
        m = rep.metrics
        if req.memory_limit_bytes:
            mx.set_memory_limit(int(req.memory_limit_bytes))
        mx.reset_peak_memory()
        width, height, frames, fps = req.width, req.height, req.num_frames, req.fps
        config = __import__("json").loads((self.model_dir / "mlx_dit.json").read_text())["config"]
        in_ch = int(config["in_channels"])
        lat_t, lat_h, lat_w = (frames - 1) // 4 + 1, height // 16, width // 16
        steps = DEFAULT_STEPS[: req.steps] if req.steps < len(DEFAULT_STEPS) else DEFAULT_STEPS

        # 1. Text encoder.
        sink("progress", {"stage": "encode", "step": 0, "total": 1})
        control.check()
        t = time.perf_counter()
        enc = umt5.load_encoder(self.model_dir / "text_encoder")
        emb = umt5.encode_prompt(self.model_dir, req.prompt, encoder=enc)
        m["encode_s"] = time.perf_counter() - t
        m["te_peak_gib"] = mx.get_peak_memory() / 2**30
        del enc
        gc.collect()
        cleanup_mlx()
        ehs = mx.array(emb).astype(mx.float16)
        sink("progress", {"stage": "encode", "step": 1, "total": 1})
        control.check()

        # 2. DiT + DMD with per-step progress and previews.
        t = time.perf_counter()
        # perf/t4-video (NFR-VID1): upstream's mx.compile of the DiT forward (FastVideo `compile=True`, the
        # FASTVIDEO_MLX_COMPILE path): bit-identical latents, ≈ 1.5 s less per T4 default step (22.9 → 21.3 s on
        # M5 Max), +≈ 2 GiB denoise peak; it falls back to eager by itself if a graph does not trace.
        dit = mlx_wan22_dit_from_mlx_checkpoint(self.model_dir, compile=COMPILE_DIT)
        dec = MLXTAEHVDecoder(self.taehv_path, z_dim=in_ch)
        m["load_s"] = time.perf_counter() - t
        cos, sin = numerics.wan_rotary(config, latent_frames=lat_t, latent_height=lat_h, latent_width=lat_w)
        freqs = (mx.array(cos), mx.array(sin))
        noise = mx.array(np.random.default_rng(req.seed).standard_normal((1, in_ch, lat_t, lat_h, lat_w)).astype(np.float32)).astype(mx.float16)
        sched = numerics.wan22_dmd_schedule(steps, flow_shift=5.0)
        total = len(sched[1])
        sink("progress", {"stage": "denoise", "step": 0, "total": total})
        every = max(1, math.ceil(lat_t / 8))  # ~6–10 animated preview frames
        previews = PreviewMaker(dec, width, height, every=every, short=req.preview_short_side) if req.preview else None

        def on_step(step: int, n: int, pred_video: Any) -> None:
            sink("progress", {"stage": "denoise", "step": step, "total": n})
            if previews is None or not shows_preview(step, n, req.preview_min_fraction):
                return  # fix/t05-video: a step the helper never shows is not decoded for a preview at all
            jpegs = previews.make(pred_video, time.perf_counter() - t0)
            if jpegs is None:
                return
            pw, ph = previews.size
            if "first_preview_s" not in m:
                m["first_preview_s"] = time.perf_counter() - t0
            for i, j in enumerate(jpegs):
                sink("preview", {"frame_index": i, "frames": len(jpegs), "width": pw, "height": ph, "jpeg": j,
                                 "step": step, "total": n})

        t = time.perf_counter()
        mx.reset_peak_memory()
        latents = sample_wan22_dmd(dit, ehs, noise, freqs, dmd_denoising_steps=steps, flow_shift=5.0, seed=0,
                                   step_callback=on_step, pause_check=control.check, schedule_and_timesteps=sched)
        mx.eval(latents)
        m["denoise_s"] = time.perf_counter() - t
        m["denoise_peak_gib"] = mx.get_peak_memory() / 2**30
        del dit, ehs, noise, freqs
        gc.collect()
        cleanup_mlx()
        control.check()

        # 3. Chunked exact decode into memory.
        t = time.perf_counter()
        mx.reset_peak_memory()
        sink("progress", {"stage": "decode", "step": 0, "total": frames})
        store.clear()
        store.fps = fps

        def on_chunk(x: Any, done: int, total_lat: int) -> None:
            store.append(to_rgba8_mx(x[0]))
            sink("progress", {"stage": "decode", "step": min(store.count, frames), "total": frames})
            control.check()

        StreamingTAEHV(dec).decode(latents.astype(mx.float32).transpose(0, 2, 1, 3, 4), chunk=4, on_chunk=on_chunk)
        m["decode_s"] = time.perf_counter() - t
        m["decode_peak_gib"] = mx.get_peak_memory() / 2**30
        del latents
        gc.collect()
        cleanup_mlx()
        if previews is not None:
            m["preview_s"] = previews.spent
            m["previews_made"] = previews.made
            m["previews_skipped"] = previews.skipped
            m["previews_failed"] = previews.failed
        m["total_s"] = time.perf_counter() - t0
        m["preview_share"] = (m.get("preview_s", 0.0) / m["total_s"]) if m["total_s"] else 0.0
        sink("frames_ready", {"count": store.count, "width": store.width, "height": store.height, "fps": fps,
                              "audio_samples": 0})
        return rep
