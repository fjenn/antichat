"""Scripted generator (M5.T02 test double; `--generator scripted`): the real event flow with no model.

Emits encode → denoise steps (with an animated preview per step) → decode chunks → frames_ready, honouring
pause / cancel between steps exactly like the Wan2.2 generator, and fills the FrameStore with gradient frames.
Request fields steer it: `prompt` containing "preview-raise" makes every preview raise (must not fail the job);
"step-delay=<s>" sets the per-step delay (default 0.05 s); "decode-delay=<s>" sleeps before each 16-frame decode chunk.
"""
from __future__ import annotations

import io
import re
import time
from typing import Any

import numpy as np

from antichat_video.preview import preview_size, shows_preview


class ScriptedGenerator:
    def run(self, req: Any, sink, control, store):
        from antichat_video.wan22_generator import Report

        m = re.search(r"step-delay=([0-9.]+)", req.prompt)
        delay = float(m.group(1)) if m else 0.05
        raise_preview = "preview-raise" in req.prompt
        t0 = time.perf_counter()
        rep = Report()
        sink("progress", {"stage": "encode", "step": 0, "total": 1})
        control.check()
        sink("progress", {"stage": "encode", "step": 1, "total": 1})
        total = req.steps
        failed = 0
        sink("progress", {"stage": "denoise", "step": 0, "total": total})
        for step in range(1, total + 1):
            control.check()
            time.sleep(delay)
            sink("progress", {"stage": "denoise", "step": step, "total": total})
            if req.preview and shows_preview(step, total, req.preview_min_fraction):
                try:
                    if raise_preview:
                        raise RuntimeError("scripted preview failure")
                    jpegs = self._previews(req, step)
                    pw, ph = preview_size(req.width, req.height, req.preview_short_side)
                    for i, j in enumerate(jpegs):
                        sink("preview", {"frame_index": i, "frames": len(jpegs), "width": pw, "height": ph,
                                         "jpeg": j, "step": step, "total": total})
                except Exception:
                    failed += 1
        control.check()
        store.clear()
        store.fps = req.fps
        n = req.num_frames
        sink("progress", {"stage": "decode", "step": 0, "total": n})
        dm = re.search(r"decode-delay=([0-9.]+)", req.prompt)
        decode_delay = float(dm.group(1)) if dm else 0.0
        for s in range(0, n, 16):
            k = min(16, n - s)
            if decode_delay:
                time.sleep(decode_delay)
            store.append(self._frames(req, s, k))
            sink("progress", {"stage": "decode", "step": store.count, "total": n})
            control.check()
        if getattr(req, "audio", False):
            # M5.T07 test double: a 440 Hz tone, 48 kHz stereo float32, exactly the clip's duration.
            n_s = int(round(store.count / req.fps * 48_000))
            t = np.arange(n_s, dtype=np.float32) / 48_000
            tone = (0.2 * np.sin(2 * np.pi * 440 * t)).astype("<f4")
            store.audio = np.stack([tone, tone], axis=1).tobytes()
        rep.metrics.update({"total_s": time.perf_counter() - t0, "previews_failed": failed})
        sink("frames_ready", {"count": store.count, "width": store.width, "height": store.height, "fps": req.fps,
                              "audio_samples": store.audio_samples})
        return rep

    @staticmethod
    def _frames(req: Any, start: int, k: int) -> np.ndarray:
        h, w = req.height, req.width
        y = np.linspace(0, 255, h, dtype=np.float32)[:, None]
        x = np.linspace(0, 255, w, dtype=np.float32)[None, :]
        out = np.empty((k, h, w, 4), dtype=np.uint8)
        for i in range(k):
            phase = (start + i) * 4
            out[i, ..., 0] = ((x + phase) % 256).astype(np.uint8)
            out[i, ..., 1] = ((y + phase) % 256).astype(np.uint8)
            out[i, ..., 2] = 128
            out[i, ..., 3] = 255
        return out

    @staticmethod
    def _previews(req: Any, step: int) -> list[bytes]:
        from PIL import Image

        pw, ph = preview_size(req.width, req.height, req.preview_short_side)
        out = []
        for i in range(6):
            arr = np.full((ph, pw, 3), (40 * step + 10 * i) % 256, dtype=np.uint8)
            buf = io.BytesIO()
            Image.fromarray(arr).save(buf, format="JPEG", quality=70)
            out.append(buf.getvalue())
        return out
