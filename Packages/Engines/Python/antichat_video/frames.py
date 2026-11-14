"""In-memory frames of a finished job and the TAEHV streaming decoder (M5.T02 steps 2 and 4).

Frames never touch the disk: the generator decodes the latents chunk by chunk into RGBA8 numpy arrays held here,
and the server streams them out length-prefixed. `StreamingTAEHV` decodes the video in chunks of latent frames with
the exact result of FastVideo's one-shot `MLXTAEHVDecoder.decode_ntchw`: the decoder's only temporal coupling is
each MemBlock's `past` = the previous frame's input at that block, so carrying the last frame per block across
chunks reproduces the parallel pass (same as upstream TAEHV's sequential mode). It bounds the decode peak
(A-M0-T07d: 720p one-shot TAEHV peaked at 26 GiB) and gives decode progress per chunk.
"""
from __future__ import annotations

import struct
import threading
from typing import Any, Callable, Iterator

import numpy as np


class FrameStore:
    """Holds one job's RGBA8 frames (T × H × W × 4, uint8) in memory."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._frames: list[np.ndarray] = []
        self.width = 0
        self.height = 0
        self.fps = 0
        self.audio: bytes | None = None  # M5.T07: float32 LE interleaved stereo, 48 kHz

    def append(self, rgba: np.ndarray) -> None:
        assert rgba.ndim == 4 and rgba.shape[-1] == 4 and rgba.dtype == np.uint8
        with self._lock:
            for f in rgba:
                self._frames.append(np.ascontiguousarray(f))
            self.height, self.width = int(rgba.shape[1]), int(rgba.shape[2])

    @property
    def count(self) -> int:
        with self._lock:
            return len(self._frames)

    @property
    def audio_samples(self) -> int:
        return len(self.audio) // 8 if self.audio else 0

    def chunks(self, start: int, count: int) -> Iterator[bytes]:
        with self._lock:
            sel = self._frames[max(0, start): max(0, start) + max(0, count)]
        for f in sel:
            b = f.tobytes()
            yield struct.pack(">I", len(b)) + b

    def clear(self) -> None:
        with self._lock:
            self._frames.clear()
            self.audio = None


def to_rgba8(frames_t3hw01: np.ndarray) -> np.ndarray:
    """[T, 3, H, W] floats in [0, 1] → [T, H, W, 4] uint8 (alpha 255)."""
    rgb = np.clip(np.rint(frames_t3hw01 * 255.0), 0, 255).astype(np.uint8).transpose(0, 2, 3, 1)
    alpha = np.full(rgb.shape[:3] + (1,), 255, dtype=np.uint8)
    return np.concatenate([rgb, alpha], axis=-1)


def to_rgba8_mx(frames_t3hw01: Any) -> np.ndarray:
    """`to_rgba8` on the GPU (perf/t4-video: the NumPy version cost ≈ 1.7 s of host time per T4 default clip).
    Same float32 maths — `x · 255` rounded half-to-even, clipped to [0, 255] — so the bytes are identical; only uint8
    crosses to the host."""
    import mlx.core as mx

    x = frames_t3hw01.astype(mx.float32)
    rgb = mx.clip(mx.round(x * 255.0), 0, 255).astype(mx.uint8).transpose(0, 2, 3, 1)
    alpha = mx.full(rgb.shape[:3] + (1,), 255, dtype=mx.uint8)
    return np.array(mx.concatenate([rgb, alpha], axis=-1))


class StreamingTAEHV:
    """Chunked TAEHV decode with carried MemBlock state (exactly the one-shot result; see the module doc)."""

    MEM_BLOCKS = (3, 4, 5, 9, 10, 11, 15, 16, 17)

    def __init__(self, decoder: Any) -> None:
        self.dec = decoder  # fastvideo.mlx_runtime.wan_vae.MLXTAEHVDecoder (weights, patch size, trim)

    def decode(self, latents_ntchw: Any, *, chunk: int = 4, on_chunk: Callable[[Any, int, int], None]) -> None:
        """Calls `on_chunk(frames_n_t_3_h_w, done_latent_frames, total_latent_frames)` per chunk (frames in [0, 1],
        the first `frames_to_trim` output frames of the clip already removed)."""
        import mlx.core as mx

        from fastvideo.mlx_runtime.wan_vae import _mlx_conv2d, _mlx_conv2d_1x1

        d = self.dec
        w = d.weights
        n, t, c, h, wd = latents_ntchw.shape
        if c != d.latent_channels:
            raise ValueError(f"expected C={d.latent_channels}, got {c}")
        if n != 1:
            raise ValueError("one clip at a time")
        carry: dict[int, Any] = {}
        trim_left = d.frames_to_trim

        def memblock(base: int, xx: Any) -> Any:
            prev = carry.get(base)
            first = mx.zeros_like(xx[:1]) if prev is None else prev
            past = mx.concatenate([first, xx[:-1]], axis=0)
            carry[base] = xx[-1:]
            cat = mx.concatenate([xx, past], axis=1)
            hh = mx.maximum(_mlx_conv2d(cat, w[f"decoder.{base}.conv.0.weight"], w.get(f"decoder.{base}.conv.0.bias")), 0.0)
            hh = mx.maximum(_mlx_conv2d(hh, w[f"decoder.{base}.conv.2.weight"], w.get(f"decoder.{base}.conv.2.bias")), 0.0)
            hh = _mlx_conv2d(hh, w[f"decoder.{base}.conv.4.weight"], w.get(f"decoder.{base}.conv.4.bias"))
            skip_key = f"decoder.{base}.skip.weight"
            skip = _mlx_conv2d_1x1(xx, w[skip_key], None) if skip_key in w else xx
            return mx.maximum(hh + skip, 0.0)

        def upsample2(xx: Any) -> Any:
            nt, cc, hh, ww = xx.shape
            xx = mx.broadcast_to(xx.reshape(nt, cc, hh, 1, ww, 1), (nt, cc, hh, 2, ww, 2))
            return xx.reshape(nt, cc, hh * 2, ww * 2)

        def tgrow(base: int, xx: Any, stride: int) -> Any:
            wt = w[f"decoder.{base}.conv.weight"]
            out_ch = int(xx.shape[1]) * stride
            if int(wt.shape[0]) > out_ch:
                wt = wt[-out_ch:]
            y = _mlx_conv2d_1x1(xx, wt, None)
            if stride == 1:
                return y
            nt, cc, hh, ww = y.shape
            return y.reshape(nt, stride, cc // stride, hh, ww).reshape(nt * stride, cc // stride, hh, ww)

        for s in range(0, t, chunk):
            x = latents_ntchw[0, s: s + chunk]  # (T', C, H, W)
            x = mx.tanh(x / 3.0) * 3.0
            x = mx.maximum(_mlx_conv2d(x, w["decoder.1.weight"], w.get("decoder.1.bias")), 0.0)
            for b in (3, 4, 5):
                x = memblock(b, x)
            x = tgrow(7, upsample2(x), 1)
            x = _mlx_conv2d(x, w["decoder.8.weight"], w.get("decoder.8.bias"))
            for b in (9, 10, 11):
                x = memblock(b, x)
            x = tgrow(13, upsample2(x), 2)
            x = _mlx_conv2d(x, w["decoder.14.weight"], w.get("decoder.14.bias"))
            for b in (15, 16, 17):
                x = memblock(b, x)
            x = tgrow(19, upsample2(x), 2)
            x = mx.maximum(_mlx_conv2d(x, w["decoder.20.weight"], w.get("decoder.20.bias")), 0.0)
            x = _mlx_conv2d(x, w["decoder.22.weight"], w.get("decoder.22.bias"))
            if d.patch_size > 1:
                p = d.patch_size
                nt, _co, hh, ww = x.shape
                x = x.reshape(nt, d.image_channels, p, p, hh, ww).transpose(0, 1, 4, 2, 5, 3)
                x = x.reshape(nt, d.image_channels, hh * p, ww * p)
            if trim_left > 0:
                k = min(trim_left, int(x.shape[0]))
                x = x[k:]
                trim_left -= k
            x = mx.clip(x, 0.0, 1.0)
            mx.eval(x)
            for v in carry.values():
                mx.eval(v)
            on_chunk(x[None], min(s + chunk, t), t)
