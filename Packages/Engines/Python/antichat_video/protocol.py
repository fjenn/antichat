"""Wire protocol of the video runtime server (M5.T02 step 4; P-media-11). Over a unix socket only; bearer token.

  GET  /health                               → {ok, version, mlx_version}
  POST /v1/video/jobs                        JobRequest → 202 {job_id}   (409 while another job runs)
  GET  /v1/video/jobs/{id}/events            SSE, `id:` = event index (Last-Event-ID resumes):
         progress{stage: encode|denoise|decode, step, total}
         preview{frame_index, width, height, jpeg_b64, step, total}   (an animated set: frame_index 0…n-1 per step)
         frames_ready{count, width, height, fps, audio_samples}       (audio_samples: 48 kHz stereo frames, 0 = silent)
         error{code}
         end{status: completed|cancelled|failed}                     (last event; the stream then closes)
  GET  /v1/video/jobs/{id}/frames?start=&count=   length-prefixed RGBA8: per frame a 4-byte big-endian length,
                                                  then width × height × 4 bytes. Memory only, never a file.
                                                  While the job runs: the frames decoded so far (decode progress
                                                  `step` = how many); after a cancel / failure: 404.
  GET  /v1/video/jobs/{id}/audio            M5.T07: the job's sound track, float32 little-endian interleaved stereo at
                                             48 kHz (404 when the job has none). Memory only, never a file.
  POST /v1/video/jobs/{id}/cancel | pause | resume | release (drop the frames from memory)
  POST /v1/shutdown
"""
from __future__ import annotations

from pydantic import BaseModel, Field

VERSION = "0.2.0"
STAGES = ("encode", "denoise", "decode")


class JobRequest(BaseModel):
    job_id: str = Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._-]+$")
    model_dir: str
    taehv_path: str | None = None  # default: <model_dir>/../vid-taehv/… is NOT guessed; the helper passes it
    prompt: str = Field(min_length=1, max_length=8000)
    negative_prompt: str | None = None  # accepted for the API shape; the 3-step DMD sampler uses no CFG
    width: int = Field(ge=64, le=1920)
    height: int = Field(ge=64, le=1920)
    num_frames: int = Field(ge=5, le=241)
    fps: int = Field(ge=1, le=60)
    steps: int = Field(default=3, ge=1, le=3)
    seed: int = 1
    memory_limit_bytes: int = Field(default=0, ge=0)
    preview: bool = True
    # fix/t05-video (VID2, NFR-F7; 0.3.4): the helper asks for previews at the gate's valid preview size (the shipped
    # ChildSafetyCheck `preview_min_side_px`; smaller previews are never shown, so it sends `preview: false` instead),
    # and only for the steps it shows (A-M5-07 `VideoPreviewPolicy`: step / total ≥ this). Defaults = the 0.3.3
    # behaviour (160 px, every step), so an older helper gets what it always got.
    preview_short_side: int = Field(default=160, ge=16, le=1920)
    preview_min_fraction: float = Field(default=0.0, ge=0.0, le=1.0)
    # M5.T07 (R-292, A-M5-04): `ltx` = LTX-2.3 distilled (ltx-2-mlx) with a 48 kHz stereo sound track; `wan22` = FastMetal.
    model_kind: str = Field(default="wan22", pattern=r"^(wan22|ltx)$")
    gemma_dir: str | None = None  # LTX text encoder (vid-ltx-te), a local directory; no hub lookup
    audio: bool = False  # keep the generated sound track (LTX only; Wan2.2 is silent)

    def shape_error(self) -> str | None:
        if self.model_kind == "ltx":
            if self.width % 64 or self.height % 64:
                return "badShape"  # two-stage: half-res latents at 32 px
            if (self.num_frames - 1) % 8:
                return "badFrames"  # LTX: 8k + 1 pixel frames
            if not self.gemma_dir:
                return "gemmaMissing"
            return None
        if self.width % 32 or self.height % 32:
            return "badShape"  # VAE 16 × patch 2
        if (self.num_frames - 1) % 4:
            return "badFrames"  # 4k + 1 pixel frames
        return None
