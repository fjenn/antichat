"""M5.T07 real leg (R-292, AT-292): LTX-2.3 distilled (vid-ltx + vid-ltx-te) through the runtime server, T3 cap.
@realModels, GPU (gpu-run.sh shared; free memory >= vid-ltx + vid-ltx-te + 20 GB). Benign prompt (Q-012).
Checks: 11 denoise progress events, frames + a 48 kHz stereo track whose length is duration x 48 kHz +- 1 frame, no
file written anywhere during the job.
"""
from __future__ import annotations

import numpy as np
import pytest

from conftest import MODELS, ROOT, Server, job_body, tree_snapshot
from test_generator import frames_of, kinds


@pytest.mark.realModels
def test_real_ltx_job_has_a_sound_track_of_the_clip_length(tmp_path):
    s = Server(tmp_path, generator="wan22")
    try:
        roots = [s.home, s.tmpdir, ROOT / "build/runtimes/video-runtime"]
        before = tree_snapshot(*roots)
        body = job_body(prompt="Ocean waves rolling onto a sandy beach, seagulls calling, wind", num_frames=97, width=768,
                        height=512, memory_limit_bytes=36_000_000_000, model_kind="ltx", audio=True, preview=False,
                        model_dir=str(MODELS / "vid-ltx"), gemma_dir=str(MODELS / "vid-ltx-te"), taehv_path=None)
        st, r = s.client.json("POST", "/v1/video/jobs", body)
        assert st == 202, r
        evs = s.client.events("j1", timeout=3600)
        end = kinds(evs, "end")[0]
        assert end["status"] == "completed", evs[-3:]
        den = [p["step"] for p in kinds(evs, "progress") if p["stage"] == "denoise" and p["step"] > 0]
        assert den == list(range(1, 12))
        ready = kinds(evs, "frames_ready")[0]
        assert ready["count"] == 97 and ready["fps"] == 24
        expected = 97 / 24 * 48_000
        assert abs(ready["audio_samples"] - expected) <= 48_000 / 24, ready  # +- 1 frame
        st, pcm, _ = s.client.req("GET", "/v1/video/jobs/j1/audio")
        assert st == 200 and len(pcm) == ready["audio_samples"] * 8
        a = np.frombuffer(pcm, dtype="<f4").reshape(-1, 2)
        assert np.isfinite(a).all() and np.abs(a).max() <= 1.0 and a.std() > 1e-4  # not silent
        frames = frames_of(s, "j1", 97, ready["width"], ready["height"])
        assert len(frames) == 97
        assert tree_snapshot(*roots) == before
        print("real ltx metrics:", end["metrics"])
    finally:
        s.stop()
