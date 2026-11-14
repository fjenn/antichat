"""LTX-2.3 text-to-video WITH a sound track for the runtime server (M5.T07; R-292; A-M5-04: the engine is
ltx-2-mlx@895201d, vendored into the runtime, with the pinned MLX weights `vid-ltx` = dgrauet/ltx-2.3-mlx-q4@f306259
distilled-1.1 and the text encoder `vid-ltx-te` = mlx-community/gemma-3-12b-it-4bit@86cc6a8, D-016). Same server
protocol as `wan22_generator.py`; everything stays in memory, nothing is written:

  1. Gemma 3 encode + stage 1 (half resolution, 8 distilled steps) + x2 latent upscale + stage 2 (3 steps), the
     upstream `DistilledPipeline.generate_two_stage`;          progress{stage: encode 0/1 → 1/1, denoise k/11}
  2. audio latent → audio VAE + vocoder (+ BWE) → 48 kHz stereo waveform → `store.audio` (float32 interleaved);
  3. video latent → the pipeline's VAE decoder (`tiled_decode`, auto-tiled to the memory budget) → RGBA8 frames in a
     FrameStore;                                                progress{stage: decode frame/total}
  4. frames_ready{count, width, height, fps, audio_samples}.
No step previews: LTX's stepwise previews need the VAE decoder resident through denoising; the plan card shows progress
only (A-M5-04 note; VideoPreviewPolicy would hide most of them anyway). Cancel/pause between denoise steps and decode
chunks (`control.check`). The upstream ffmpeg mux path is never called.
"""
from __future__ import annotations

import gc
import time
from pathlib import Path
from typing import Any

import numpy as np

from antichat_video.frames import FrameStore
from antichat_video.wan22_generator import Control, Report

Sink = Any
STAGE1_STEPS = 8
STAGE2_STEPS = 3


class LtxGenerator:
    def __init__(self, model_dir: Path, gemma_dir: Path) -> None:
        self.model_dir = Path(model_dir)
        self.gemma_dir = Path(gemma_dir)

    def run(self, req: Any, sink: Sink, control: Control, store: FrameStore) -> Report:
        import mlx.core as mx
        from ltx_core_mlx.model.video_vae.video_vae import _compute_decode_tiling
        from ltx_pipelines_mlx.distilled import DistilledPipeline

        t0 = time.perf_counter()
        rep = Report()
        m = rep.metrics
        if req.memory_limit_bytes:
            mx.set_memory_limit(int(req.memory_limit_bytes))
        mx.reset_peak_memory()
        total = STAGE1_STEPS + STAGE2_STEPS
        state = {"step": 0, "encoded": False}

        def on_step(*_a: Any, **_k: Any) -> None:
            if not state["encoded"]:
                state["encoded"] = True
            state["step"] += 1
            sink("progress", {"stage": "denoise", "step": min(state["step"], total), "total": total})
            control.check()

        class Pipeline(DistilledPipeline):
            def _run_denoise_loop(self, *, on_step=None, **kw):  # type: ignore[override]
                inner = on_step

                def hook(*a: Any, **k: Any) -> Any:
                    r = inner(*a, **k) if inner is not None else None
                    on_step_outer(*a, **k)
                    return r

                return super()._run_denoise_loop(on_step=hook, **kw)

        on_step_outer = on_step
        sink("progress", {"stage": "encode", "step": 0, "total": 1})
        control.check()
        pipe = Pipeline(str(self.model_dir), gemma_model_id=str(self.gemma_dir), low_memory=True)
        pipe.verbose = False
        t = time.perf_counter()
        sink("progress", {"stage": "encode", "step": 1, "total": 1})
        sink("progress", {"stage": "denoise", "step": 0, "total": total})
        video_lat, audio_lat = pipe.generate_two_stage(req.prompt, height=req.height, width=req.width,
                                                       num_frames=req.num_frames, frame_rate=float(req.fps),
                                                       seed=int(req.seed), stage1_steps=STAGE1_STEPS,
                                                       stage2_steps=STAGE2_STEPS)
        mx.eval(video_lat, audio_lat)
        m["generate_s"] = time.perf_counter() - t
        m["denoise_peak_gib"] = mx.get_peak_memory() / 2**30
        pipe.dit = None
        pipe._loaded = False
        gc.collect()
        mx.clear_cache()
        control.check()

        # Sound track (kept only when asked; the DiT made it jointly either way).
        store.clear()
        store.fps = req.fps
        if req.audio:
            t = time.perf_counter()
            wave = pipe.audio_decoder_block(audio_lat)  # (B?, 2, N) float in [-1, 1] at 48 kHz
            mx.eval(wave)
            w = np.array(wave.astype(mx.float32))
            w = w.reshape(-1, w.shape[-1]) if w.ndim > 2 else w
            if w.shape[0] == 1:
                w = np.repeat(w, 2, axis=0)
            w = np.clip(w[:2], -1.0, 1.0)
            n_target = int(round(req.num_frames / req.fps * 48_000))
            w = w[:, :n_target] if w.shape[1] >= n_target else np.pad(w, ((0, 0), (0, n_target - w.shape[1])))
            store.audio = np.ascontiguousarray(w.T.astype("<f4")).tobytes()
            m["audio_s"] = time.perf_counter() - t
            pipe.audio_decoder_block.free()
            del wave
            gc.collect()
        del audio_lat
        control.check()

        # Video frames, in memory.
        t = time.perf_counter()
        mx.reset_peak_memory()
        sink("progress", {"stage": "decode", "step": 0, "total": req.num_frames})
        decoder = pipe.video_decoder_block.load()
        tiling = _compute_decode_tiling(video_lat.shape, frame_rate=float(req.fps))
        for chunk in decoder.tiled_decode(video_lat, tiling):  # (B, 3, T, H, W) in [-1, 1]
            arr = np.array(chunk[0].astype(mx.float32)).transpose(1, 0, 2, 3)  # T, 3, H, W
            rgb = np.clip(np.rint((arr + 1.0) * 127.5), 0, 255).astype(np.uint8).transpose(0, 2, 3, 1)
            alpha = np.full(rgb.shape[:3] + (1,), 255, dtype=np.uint8)
            room = req.num_frames - store.count
            if room > 0:
                store.append(np.concatenate([rgb, alpha], axis=-1)[:room])
            sink("progress", {"stage": "decode", "step": min(store.count, req.num_frames), "total": req.num_frames})
            control.check()
        m["decode_s"] = time.perf_counter() - t
        m["decode_peak_gib"] = mx.get_peak_memory() / 2**30
        pipe.video_decoder_block.free()
        del video_lat, pipe
        gc.collect()
        mx.clear_cache()
        m["total_s"] = time.perf_counter() - t0
        sink("frames_ready", {"count": store.count, "width": store.width, "height": store.height, "fps": req.fps,
                              "audio_samples": store.audio_samples})
        return rep
