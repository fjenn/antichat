"""Video runtime server + generator tests (M5.T02 step 5; R-041, NFR-VID2, D-006 "no disk writes before the gate").

Scripted-generator tests run anywhere the runtime runs. `realModels` tests run the Wan2.2 generator on vid-5b at
the T3 cap (GPU: under gpu-run.sh shared).
"""
from __future__ import annotations

import base64
import io
import os
import struct
import subprocess
import time

import numpy as np
import pytest

from conftest import MODELS, ROOT, Server, job_body, tree_snapshot


def frames_of(server, job, count, w, h):
    st, body, hdr = server.client.req("GET", f"/v1/video/jobs/{job}/frames?start=0&count={count}")
    assert st == 200
    out, off = [], 0
    while off < len(body):
        (n,) = struct.unpack(">I", body[off: off + 4])
        out.append(body[off + 4: off + 4 + n])
        off += 4 + n
    assert all(len(f) == w * h * 4 for f in out)
    return out


def kinds(evs, kind):
    return [d for _, k, d in evs if k == kind]


def test_token_required_and_health(server):
    st, _ = server.client.json("GET", "/health", token="wrong")
    assert st == 401
    st, h = server.client.json("GET", "/health")
    assert st == 200 and h["ok"] and h["version"]


def test_scripted_job_events_previews_and_frames(server):
    st, r = server.client.json("POST", "/v1/video/jobs", job_body(num_frames=49))
    assert st == 202 and r["job_id"] == "j1"
    evs = server.client.events("j1")
    prog = kinds(evs, "progress")
    den = [p for p in prog if p["stage"] == "denoise" and p["step"] > 0]
    assert [p["step"] for p in den] == [1, 2, 3]  # one progress event per sampler step
    dec = [p["step"] for p in prog if p["stage"] == "decode"]
    assert dec == sorted(dec) and dec[-1] == 49  # decode progress monotonic, ends at the frame count
    pv = kinds(evs, "preview")
    assert pv and all(min(p["width"], p["height"]) >= 160 for p in pv)
    assert abs(pv[0]["width"] / pv[0]["height"] - 832 / 480) < 0.02  # target aspect
    from PIL import Image
    im = Image.open(io.BytesIO(base64.b64decode(pv[0]["jpeg_b64"])))
    assert im.format == "JPEG"
    ready = kinds(evs, "frames_ready")[0]
    assert ready == {"count": 49, "width": 832, "height": 480, "fps": 24, "audio_samples": 0}
    st, _, _ = server.client.req("GET", "/v1/video/jobs/j1/audio")
    assert st == 404  # Wan2.2 / no "Sound on": no audio endpoint payload
    assert kinds(evs, "end")[0]["status"] == "completed"
    assert len(frames_of(server, "j1", 49, 832, 480)) == 49
    # SSE resume: from id k on, exactly the tail.
    tail = server.client.events("j1", last_id=evs[2][0])
    assert [e[0] for e in tail] == [e[0] for e in evs[3:]]


def test_scripted_sound_track_is_served_in_memory(server):
    # M5.T07: `audio: true` → frames_ready carries the 48 kHz stereo sample count; GET …/audio serves float32 LE pairs
    # whose length is the clip duration × 48 kHz.
    st, _ = server.client.json("POST", "/v1/video/jobs", job_body(num_frames=49, audio=True))
    assert st == 202
    evs = server.client.events("j1")
    ready = kinds(evs, "frames_ready")[0]
    assert ready["audio_samples"] == round(49 / 24 * 48_000)
    st, body, hdr = server.client.req("GET", "/v1/video/jobs/j1/audio")
    assert st == 200 and len(body) == ready["audio_samples"] * 8
    pcm = np.frombuffer(body, dtype="<f4").reshape(-1, 2)
    assert 0.1 < np.abs(pcm).max() <= 1.0


def test_previews_at_the_requested_size_only_for_shown_steps(server):
    # fix/t05-video (VID2, 0.3.4): the helper asks for the gate's valid preview size (512 px short side) and only the
    # steps it shows (step / total ≥ 0.75 → step 3 of 3); frames and progress are unchanged.
    st, _ = server.client.json("POST", "/v1/video/jobs", job_body(width=1280, height=704, num_frames=17,
                                                                  preview_short_side=512, preview_min_fraction=0.75))
    assert st == 202
    evs = server.client.events("j1")
    den = [p["step"] for p in kinds(evs, "progress") if p["stage"] == "denoise" and p["step"] > 0]
    assert den == [1, 2, 3]
    pv = kinds(evs, "preview")
    assert pv and {p["step"] for p in pv} == {3}
    assert all(min(p["width"], p["height"]) == 512 for p in pv)
    from PIL import Image
    im = Image.open(io.BytesIO(base64.b64decode(pv[0]["jpeg_b64"])))
    assert min(im.size) == 512
    assert kinds(evs, "end")[0]["status"] == "completed"


def test_preview_size_helpers():
    from antichat_video.preview import preview_size, shows_preview, spatial_stride
    assert preview_size(832, 480) == (277, 160)  # the 0.3.3 default
    assert preview_size(1280, 704, 512) == (931, 512)
    assert preview_size(832, 480, 512) == (832, 480)  # never upscaled (the helper sends `preview: false` there)
    assert spatial_stride(30, 160) == 3 and spatial_stride(44, 512) == 1
    assert [shows_preview(k, 3, 0.75) for k in (0, 1, 2, 3)] == [False, False, False, True]
    assert [k for k in range(1, 21) if shows_preview(k, 20, 0.75)] == list(range(15, 21))
    assert all(shows_preview(k, 3, 0.0) for k in (1, 2, 3))
    # fix/t05-video-t4 (VID2): the helper's 2/3 rule shows steps 2 and 3 of the 3-step DMD, 14-20 of 20.
    assert [shows_preview(k, 3, 2.0 / 3.0) for k in (0, 1, 2, 3)] == [False, False, True, True]
    assert [k for k in range(1, 21) if shows_preview(k, 20, 2.0 / 3.0)] == list(range(14, 21))


def test_preview_exception_does_not_fail_the_job(server):
    server.client.json("POST", "/v1/video/jobs", job_body(prompt="waves preview-raise"))
    evs = server.client.events("j1")
    assert not kinds(evs, "preview")
    assert kinds(evs, "end")[0]["status"] == "completed"


def test_gpu_rgba8_conversion_is_byte_identical_to_numpy():
    # perf/t4-video: frames.to_rgba8_mx (GPU) must give exactly to_rgba8's bytes, ties (k + 0.5) / 255 and
    # out-of-range values included.
    import mlx.core as mx

    from antichat_video.frames import to_rgba8, to_rgba8_mx

    rng = np.random.default_rng(3)
    x = rng.uniform(-0.1, 1.1, size=(5, 3, 48, 64)).astype(np.float32)
    ties = ((np.arange(48 * 64, dtype=np.float32) % 256) + 0.5) / np.float32(255)
    x[0, 0] = ties.reshape(48, 64)
    x[1, 1, :2] = [[0.0] * 64, [1.0] * 64]
    a, b = to_rgba8(x), to_rgba8_mx(mx.array(x))
    assert a.dtype == b.dtype == np.uint8 and a.shape == b.shape == (5, 48, 64, 4)
    assert np.array_equal(a, b)


def test_frames_decoded_so_far_are_served_while_the_job_runs(server):
    # perf/t4-video: the helper pulls frames during the decode (its check runs meanwhile); a pull returns only the
    # frames already in the store, and they are the final frames.
    server.client.json("POST", "/v1/video/jobs", job_body(num_frames=49, prompt="waves decode-delay=0.4"))
    deadline = time.time() + 20
    partial = None
    while time.time() < deadline:
        got = frames_of(server, "j1", 49, 832, 480)
        if 0 < len(got) < 49:
            partial = got
            break
        time.sleep(0.05)
    assert partial, "no partial pull while decoding"
    evs = server.client.events("j1")
    assert kinds(evs, "end")[0]["status"] == "completed"
    full = frames_of(server, "j1", 49, 832, 480)
    assert len(full) == 49 and full[: len(partial)] == partial


def test_cancel_stops_between_steps_and_drops_frames(server):
    server.client.json("POST", "/v1/video/jobs", job_body(prompt="waves step-delay=1.0"))
    time.sleep(1.3)  # inside step 2
    st, _ = server.client.json("POST", "/v1/video/jobs/j1/cancel")
    assert st == 200
    evs = server.client.events("j1")
    steps = [p["step"] for p in kinds(evs, "progress") if p["stage"] == "denoise"]
    assert max(steps) < 3 and not kinds(evs, "frames_ready")
    assert kinds(evs, "end")[0]["status"] == "cancelled"
    st, _, _ = server.client.req("GET", "/v1/video/jobs/j1/frames")
    assert st == 404


def test_pause_blocks_then_resume_finishes(server):
    server.client.json("POST", "/v1/video/jobs", job_body(prompt="waves step-delay=0.3"))
    server.client.json("POST", "/v1/video/jobs/j1/pause")
    time.sleep(1.5)
    st, ev = server.client.json("POST", "/v1/video/jobs/j1/resume")
    assert st == 200
    evs = server.client.events("j1")
    assert kinds(evs, "end")[0]["status"] == "completed"


def test_second_job_while_running_is_busy_and_bad_shape_rejected(server):
    server.client.json("POST", "/v1/video/jobs", job_body(prompt="waves step-delay=0.5"))
    st, r = server.client.json("POST", "/v1/video/jobs", job_body(job_id="j2"))
    assert st == 409 and r["error"] == "busy"
    server.client.events("j1")
    st, r = server.client.json("POST", "/v1/video/jobs", job_body(job_id="j3", width=830))
    assert st == 400 and r["error"] == "badShape"


def test_no_file_written_during_a_job_and_no_tcp_listener(server):
    runtime = ROOT / "build/runtimes/video-runtime"
    roots = [server.home, server.tmpdir] + ([runtime] if runtime.exists() else [])
    before = tree_snapshot(*roots)
    server.client.json("POST", "/v1/video/jobs", job_body())
    server.client.events("j1")
    after = tree_snapshot(*roots)
    assert after == before, sorted(after ^ before)[:10]
    out = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(server.proc.pid), "-i"], capture_output=True, text=True)
    assert out.stdout.strip() == "", out.stdout


def test_streaming_decode_equals_one_shot_decode():
    """frames.StreamingTAEHV (chunked, carried MemBlock state) == FastVideo's one-shot decode, bit for bit-ish."""
    taehv = MODELS / "vid-taehv/taew2_2.safetensors"
    if not taehv.exists():
        pytest.skip("vid-taehv not downloaded")
    import mlx.core as mx
    from fastvideo.mlx_runtime.wan_vae import MLXTAEHVDecoder
    from antichat_video.frames import StreamingTAEHV

    dec = MLXTAEHVDecoder(taehv, z_dim=48)
    lat = mx.array(np.random.default_rng(0).standard_normal((1, 9, 48, 8, 12)).astype(np.float32))
    ref = np.array(dec.decode_ntchw(lat))
    parts = []
    StreamingTAEHV(dec).decode(lat, chunk=4, on_chunk=lambda x, d, t: parts.append(np.array(x)))
    got = np.concatenate(parts, axis=1)
    assert got.shape == ref.shape == (1, 33, 3, 128, 192)
    assert float(np.abs(got - ref).max()) < 1e-4


def test_preview_frame_indices_match_the_one_shot_choice():
    # fix/t05-video-t4: the chunked preview decode keeps exactly the frames the 0.3.4 one-shot path picked
    # (np.linspace over the trimmed output, one per decoded latent frame).
    from antichat_video.preview import preview_frame_indices
    for t_lat in range(1, 12):
        t_out = 4 * t_lat - 3
        ref = np.linspace(0, t_out - 1, num=t_lat).round().astype(int).tolist()
        assert preview_frame_indices(t_lat, 3) == ref
    assert preview_frame_indices(8, 3) == [0, 4, 8, 12, 16, 20, 24, 28]  # T4: 121 f, every 4th latent frame


def test_chunked_preview_decode_equals_one_shot_and_bounds_the_peak():
    """fix/t05-video-t4: PreviewMaker's chunked decode gives the one-shot decode's preview frames (up to float
    rounding), with a smaller MLX peak (the T4 one-shot preview decode ran the whole TAEHV graph at full resolution beside the DiT)."""
    taehv = MODELS / "vid-taehv/taew2_2.safetensors"
    if not taehv.exists():
        pytest.skip("vid-taehv not downloaded")
    import mlx.core as mx
    from fastvideo.mlx_runtime.wan_vae import MLXTAEHVDecoder
    from antichat_video.preview import decode_preview_frames, preview_frame_indices

    dec = MLXTAEHVDecoder(taehv, z_dim=48)
    # The T4 preview's latents: 8 latent frames (every 4th of 31) at full 704 × 1280 resolution (≈ 10 GiB one-shot).
    lat = mx.array(np.random.default_rng(1).standard_normal((1, 8, 48, 44, 80)).astype(np.float32))
    mx.eval(lat)
    mx.clear_cache()
    mx.reset_peak_memory()
    ref_all = dec.decode_ntchw(lat)
    mx.eval(ref_all)
    one_shot_peak = mx.get_peak_memory()
    ref = np.array(ref_all[0])[preview_frame_indices(8, dec.frames_to_trim)]
    del ref_all
    mx.clear_cache()
    mx.reset_peak_memory()
    got = np.stack(decode_preview_frames(dec, lat))
    chunked_peak = mx.get_peak_memory()
    assert got.shape == ref.shape == (8, 3, 704, 1280)
    # Not bit-exact: the per-chunk convolutions round differently from the 8-frame batch (measured at 352 × 640:
    # mean |d| ≤ 7e-4, ≤ 6 of 255 on ≤ 0.2 % of pixels; one chunk of 8 is bit-identical). The clip's decode is chunked too.
    d = np.abs(got - ref)
    u8 = np.abs(np.rint(got * 255).astype(int) - np.rint(ref * 255).astype(int))
    assert float(d.mean()) < 1e-3 and float(d.max()) < 0.05, (float(d.mean()), float(d.max()))
    assert float((u8 > 1).mean()) < 0.01
    one = np.stack(decode_preview_frames(dec, lat, chunk=8))
    assert np.array_equal(one, ref), "a single chunk is the one-shot decode"
    assert chunked_peak < one_shot_peak / 2, (chunked_peak, one_shot_peak)


@pytest.mark.realModels
def test_real_wan22_job_progress_previews_share_and_no_writes(tmp_path):
    s = Server(tmp_path, generator="wan22")
    try:
        roots = [s.home, s.tmpdir, ROOT / "build/runtimes/video-runtime"]
        before = tree_snapshot(*roots)
        st, _ = s.client.json("POST", "/v1/video/jobs", job_body(num_frames=73, memory_limit_bytes=36_000_000_000))
        assert st == 202
        evs = s.client.events("j1", timeout=900)
        end = kinds(evs, "end")[0]
        assert end["status"] == "completed", evs[-3:]
        den = [p["step"] for p in kinds(evs, "progress") if p["stage"] == "denoise" and p["step"] > 0]
        assert den == [1, 2, 3]
        dec = [p["step"] for p in kinds(evs, "progress") if p["stage"] == "decode"]
        assert dec == sorted(dec) and dec[-1] == 73
        pv = kinds(evs, "preview")
        assert pv and all(min(p["width"], p["height"]) >= 160 for p in pv)
        m = end["metrics"]
        assert m["preview_share"] <= 0.10, m
        frames = frames_of(s, "j1", 73, 832, 480)
        assert len(frames) == 73
        a = np.frombuffer(frames[36], dtype=np.uint8).reshape(480, 832, 4)
        assert a[..., :3].std() > 5  # not a flat frame
        assert tree_snapshot(*roots) == before
        print("real wan22 metrics:", m)
    finally:
        s.stop()


@pytest.mark.realModels
def test_real_cancel_stops_between_steps(tmp_path):
    s = Server(tmp_path, generator="wan22")
    try:
        s.client.json("POST", "/v1/video/jobs", job_body(num_frames=73, memory_limit_bytes=36_000_000_000))
        time.sleep(6)  # encode + about one DiT step on S4
        t0 = time.monotonic()
        s.client.json("POST", "/v1/video/jobs/j1/cancel")
        evs = s.client.events("j1", timeout=300)
        assert kinds(evs, "end")[0]["status"] == "cancelled"
        assert not kinds(evs, "frames_ready")
        print(f"cancel → end {time.monotonic() - t0:.2f} s")
    finally:
        s.stop()
