"""Step previews (M5.T02 step 3; R-041 AC4, NFR-VID2). TAEHV weights are pinned (`vid-taehv`), so previews are a
real decode of the step's clean-latent prediction (no latent projection; A-M5-02 not needed).

Per step: every n-th latent frame of the prediction (n chosen for ~6–10 frames) is decoded with TAEHV from spatially
strided latents (output short side ≥ the requested short side, default 160 px), resized to the target aspect with that
short side, and JPEG-encoded at q = 70 → an animated preview of ~5–10 frames. fix/t05-video (VID2): the helper asks for
the gate's valid preview size (512 px), because a smaller preview is never shown (only the shown steps are made).
Time box: total preview work stays ≤ 10 % of the job; a preview is skipped when the running share already exceeds
8 %. Any preview exception is logged and swallowed (a preview never fails the job). Bytes stay in memory: the
helper's MediaJobRunner checks each one with ChildSafetyCheck before anything is shown or written (D-006).

fix/t05-video-t4 (0.3.5): a 512-px T4 preview decodes at full resolution (stride 1). One-shot over its 8 latent frames
(0.3.4) the TAEHV graph ran at 1280 x 704 x 29 frames beside the resident DiT: 10.0 GiB MLX peak and 22.2 GiB left in
MLX's buffer cache until the end of the denoise (measured at T4 shape) = the +19 GB of helper + runtime footprint at T4
(27-28 -> 46.7-46.9 GB; 720p 81 f +20 GB; 480p, no previews, unchanged). Now: MLX's buffer cache is dropped first (the
DiT's cached step buffers, reallocated by the next step), then `frames.StreamingTAEHV` decodes one latent frame at a
time and only the output frames the preview uses reach the host; its buffers are dropped again before the next step:
2.8 GiB peak, 0.8-0.9 s per preview with the JPEGs (one-shot: 10.0-10.4 GiB peak, 16-22 GiB cache after). Frames = the one-shot decode up to float rounding of the per-chunk convolutions (at 352 x 640: mean |d| 3e-4,
max 5 of 255 on 0.02 % of pixels, below the JPEG q 70 step); the clip itself is decoded in chunks the same way.
"""
from __future__ import annotations

import io
import logging
import time
from typing import Any

import numpy as np

log = logging.getLogger("antichat_video.preview")

MIN_SHORT_SIDE = 160
PREVIEW_CHUNK = 1  # latent frames per preview decode chunk (bounds the decode's working set, fix/t05-video-t4)
SKIP_SHARE = 0.08
JPEG_QUALITY = 70


def preview_size(width: int, height: int, short: int = MIN_SHORT_SIDE) -> tuple[int, int]:
    """Target-aspect size with the short side = `short` (never upscaled past the source)."""
    if min(width, height) <= short:
        return width, height
    if width <= height:
        return short, max(short, round(height * short / width))
    return max(short, round(width * short / height)), short


def shows_preview(step: int, total: int, min_fraction: float) -> bool:
    """The helper's `VideoPreviewPolicy.shows` (A-M5-07): step k of n is shown iff k / n ≥ `min_fraction`."""
    return total > 0 and step > 0 and step / total >= min_fraction - 1e-9


def spatial_stride(lat_short: int, short: int = MIN_SHORT_SIDE) -> int:
    """The largest latent stride whose decode (TAEHV upsamples 16×) still has a short side ≥ `short` (1 = full res)."""
    f = max(1, (16 * lat_short) // short)
    while f > 1 and 16 * -(-lat_short // f) < short:
        f -= 1
    return f


def preview_frame_indices(t_lat: int, trim: int, growth: int = 4) -> list[int]:
    """Which decoded frames make the animated preview: one per decoded latent frame, evenly over the decoder's output
    (TAEHV expands time `growth`x and trims the first `trim` frames). Same choice as the 0.3.4 one-shot path."""
    n_out = growth * t_lat
    if n_out > trim:
        n_out -= trim
    return [int(i) for i in np.linspace(0, n_out - 1, num=max(1, t_lat)).round().astype(int)]


def decode_preview_frames(decoder: Any, x_ntchw: Any, *, chunk: int = PREVIEW_CHUNK) -> list[np.ndarray]:
    """The preview's frames ([3, H, W] float32 in [0, 1], host) of latents `x_ntchw` ([1, T', C, H, W] float32),
    decoded in chunks of `chunk` latent frames with carried MemBlock state (= the one-shot decode's frames)."""
    from antichat_video.frames import StreamingTAEHV

    t_lat = int(x_ntchw.shape[1])
    want = preview_frame_indices(t_lat, int(decoder.frames_to_trim))
    picked: dict[int, np.ndarray] = {}
    pos = 0

    def on_chunk(x: Any, _done: int, _total: int) -> None:
        nonlocal pos
        k = int(x.shape[1])
        for i in want:
            if pos <= i < pos + k and i not in picked:
                picked[i] = np.array(x[0, i - pos])
        pos += k

    StreamingTAEHV(decoder).decode(x_ntchw, chunk=max(1, chunk), on_chunk=on_chunk)
    if any(i not in picked for i in want):
        raise RuntimeError(f"preview decode gave {pos} frames, wanted indices up to {max(want)}")
    return [picked[i] for i in want]


class PreviewMaker:
    def __init__(self, decoder: Any, width: int, height: int, *, every: int = 4, short: int = MIN_SHORT_SIDE) -> None:
        self.decoder = decoder
        self.short = short
        self.size = preview_size(width, height, short)
        self.every = every
        self.spent = 0.0
        self.skipped = 0
        self.failed = 0
        self.made = 0

    def share(self, job_elapsed: float) -> float:
        return self.spent / job_elapsed if job_elapsed > 0 else 0.0

    def make(self, pred_video: Any, job_elapsed: float) -> list[bytes] | None:
        """JPEG frames for one step, or None when skipped (time box) or failed (logged, swallowed)."""
        if job_elapsed > 0 and self.share(job_elapsed) > SKIP_SHARE:
            self.skipped += 1
            return None
        t0 = time.perf_counter()
        try:
            return self._make(pred_video)
        except Exception as e:  # a preview failure never fails the job
            self.failed += 1
            log.warning("preview failed: %s: %s", type(e).__name__, e)
            return None
        finally:
            self.spent += time.perf_counter() - t0

    def _make(self, pred_video: Any) -> list[bytes]:
        import mlx.core as mx
        from PIL import Image

        # Every `every`-th latent frame, and spatially strided so the decode is already near the preview size (the
        # decoder upsamples 16×): a 480p preview at 160 px decodes 1/9 of the pixels (short side 16 × ceil(30 / 3) =
        # 160); a 704p preview at 512 px decodes at full resolution (stride 2 would give 352 px).
        lat_short = int(min(pred_video.shape[3], pred_video.shape[4]))
        f = spatial_stride(lat_short, self.short)
        sub = pred_video[:, :, :: self.every, ::f, ::f]  # N C T' H' W
        x = sub.astype(mx.float32).transpose(0, 2, 1, 3, 4)  # N T' C H W
        # fix/t05-video-t4: MLX's freed-buffer cache (the DiT step's buffers) goes first, so the preview's buffers do not
        # stack on it; then a chunked decode (as the clip's own); only the frames the preview uses reach the host. One
        # output frame per decoded latent frame (TAEHV expands time 4× after the first, trimmed by 3), as before.
        mx.eval(x)
        mx.clear_cache()
        frames = decode_preview_frames(self.decoder, x)
        del x, sub
        mx.clear_cache()  # and the preview's own buffers go before the next DiT step allocates
        out = []
        for fr in frames:
            img = np.clip(np.rint(fr.transpose(1, 2, 0) * 255.0), 0, 255).astype(np.uint8)
            im = Image.fromarray(img).resize(self.size, Image.BILINEAR)
            buf = io.BytesIO()
            im.save(buf, format="JPEG", quality=JPEG_QUALITY)
            out.append(buf.getvalue())
        self.made += 1
        return out
