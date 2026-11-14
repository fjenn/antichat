"""The video runtime server (M5.T02 step 4; P-media-11, D-013): a FastAPI app on uvicorn over a unix socket.

  video-runtime-launcher --uds <dir>/video-<pid>.sock --token-env ANTICHAT_VIDEO_TOKEN [--generator wan22|scripted]

Never a TCP listener. Every request needs `Authorization: Bearer <token>` (the token comes from the environment
variable named by --token-env, set by the helper; random per launch). One job at a time (a second POST while one
runs → 409 `busy`). The job runs on a worker thread; its events are kept in memory (SSE resumes from
Last-Event-ID) and its frames live in a FrameStore until the next job, `release`, or shutdown. Nothing is written
to disk: no frame, preview or video file, and no bytecode (-B). `--generator scripted` is the test double (gradient
frames, real event flow, no model) used by the runtime's pytest suite and the helper's process tests.
See `protocol.py` for the API.
"""
# (no `from __future__ import annotations`: FastAPI resolves the endpoint annotations, imported in create_app)

import argparse
import asyncio
import base64
import gc
import json
import logging
import os
import secrets
import socket
import sys
import threading
import time
from pathlib import Path
from typing import Any

log = logging.getLogger("antichat_video.server")


class Job:
    def __init__(self, req: Any) -> None:
        from antichat_video.frames import FrameStore
        from antichat_video.wan22_generator import Control

        self.req = req
        self.id = req.job_id
        self.events: list[tuple[str, dict]] = []
        self.lock = threading.Lock()
        self.control = Control()
        self.store = FrameStore()
        self.status = "running"  # running | completed | cancelled | failed
        self.metrics: dict[str, float] = {}
        self.thread: threading.Thread | None = None

    def emit(self, kind: str, data: dict) -> None:
        if kind == "preview":
            data = dict(data)
            data["jpeg_b64"] = base64.b64encode(data.pop("jpeg")).decode("ascii")
        with self.lock:
            self.events.append((kind, data))

    def snapshot(self, start: int) -> list[tuple[int, str, dict]]:
        with self.lock:
            return [(i, k, d) for i, (k, d) in enumerate(self.events) if i >= start]


class State:
    def __init__(self, generator: str) -> None:
        self.generator = generator
        self.job: Job | None = None
        self.lock = threading.Lock()
        self.server: Any = None


def make_generator(kind: str, req: Any):
    if kind == "scripted":
        from antichat_video.scripted import ScriptedGenerator
        return ScriptedGenerator()
    if getattr(req, "model_kind", "wan22") == "ltx":
        from antichat_video.ltx_generator import LtxGenerator
        return LtxGenerator(Path(req.model_dir), Path(req.gemma_dir))
    from antichat_video.wan22_generator import Wan22Generator
    if not req.taehv_path:
        raise ValueError("taehvMissing")
    return Wan22Generator(Path(req.model_dir), Path(req.taehv_path))


def run_job(state: State, job: Job) -> None:
    from antichat_video.wan22_generator import Cancelled

    gen = None
    try:
        gen = make_generator(state.generator, job.req)
        rep = gen.run(job.req, job.emit, job.control, job.store)
        job.metrics = rep.metrics
        job.status = "completed"
    except Cancelled:
        job.store.clear()
        job.status = "cancelled"
    except Exception as e:  # reported as an error event; the job fails, the server stays up
        log.exception("job %s failed", job.id)
        job.store.clear()
        code = str(e) if str(e) in ("taehvMissing",) else type(e).__name__
        job.emit("error", {"code": code})
        job.status = "failed"
    finally:
        # NFR-VID3 (2026-11-08 miss, +390 MB held after a step-1 cancel): a cancel or failure leaves the job's arrays in
        # the traceback frames and the generator, some in reference cycles. Drop the generator, collect, wait for the
        # GPU, and only then clear the allocator cache; buffers freed after `clear_cache` would stay in MLX's cache.
        gen = None
        gc.collect()
        try:
            import mlx.core as mx
            mx.synchronize()
            mx.clear_cache()
        except Exception:
            pass
        job.emit("end", {"status": job.status, "metrics": {k: round(float(v), 4) for k, v in job.metrics.items()}})


def create_app(state: State, token: str):
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse, Response, StreamingResponse

    from antichat_video.protocol import VERSION, JobRequest

    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def auth(request: Request, call_next):
        got = request.headers.get("authorization", "")
        if not secrets.compare_digest(got, f"Bearer {token}"):
            return JSONResponse({"error": "unauthorized"}, status_code=401)
        return await call_next(request)

    def current(job_id: str) -> Job | None:
        j = state.job
        return j if j is not None and j.id == job_id else None

    @app.get("/health")
    async def health():
        try:
            import mlx.core as mx
            mv = mx.__version__
        except Exception:  # scripted generator in a plain interpreter
            mv = None
        return {"ok": True, "version": VERSION, "mlx_version": mv, "generator": state.generator}

    @app.post("/v1/video/jobs", status_code=202)
    async def submit(req: JobRequest):
        bad = req.shape_error()
        if bad:
            return JSONResponse({"error": bad}, status_code=400)
        with state.lock:
            if state.job is not None and state.job.status == "running":
                return JSONResponse({"error": "busy"}, status_code=409)
            if state.job is not None:
                state.job.store.clear()
            job = Job(req)
            state.job = job
            job.thread = threading.Thread(target=run_job, args=(state, job), name=f"job-{job.id}", daemon=True)
            job.thread.start()
        return {"job_id": job.id}

    @app.get("/v1/video/jobs/{job_id}/events")
    async def events(job_id: str, request: Request):
        job = current(job_id)
        if job is None:
            return JSONResponse({"error": "noJob"}, status_code=404)
        last = request.headers.get("last-event-id")
        start = int(last) + 1 if last and last.isdigit() else 0

        async def stream():
            nonlocal start
            idle = 0.0
            while True:
                batch = job.snapshot(start)
                for i, kind, data in batch:
                    start = i + 1
                    yield f"id: {i}\nevent: {kind}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n"
                    if kind == "end":
                        return
                if not batch:
                    idle += 0.05
                    if idle >= 10:
                        idle = 0.0
                        yield ": keepalive\n\n"
                    else:
                        await asyncio.sleep(0.05)
                else:
                    idle = 0.0
                if await request.is_disconnected():
                    return

        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-store"})

    @app.get("/v1/video/jobs/{job_id}/frames")
    async def frames(job_id: str, start: int = 0, count: int = 1 << 30):
        job = current(job_id)
        # perf/t4-video: while the job runs, the frames decoded so far are served too (the helper checks the sampled
        # ones during the decode; nothing is shown or written before its verdict). Cancelled / failed jobs: none.
        if job is None or job.status not in ("completed", "running"):
            return JSONResponse({"error": "noFrames"}, status_code=404)
        body = b"".join(job.store.chunks(start, count))
        return Response(body, media_type="application/octet-stream",
                        headers={"X-Frame-Width": str(job.store.width), "X-Frame-Height": str(job.store.height),
                                 "X-Frame-Count": str(job.store.count)})

    @app.get("/v1/video/jobs/{job_id}/audio")
    async def audio(job_id: str):
        job = current(job_id)
        if job is None or job.status != "completed" or not job.store.audio:
            return JSONResponse({"error": "noAudio"}, status_code=404)
        return Response(job.store.audio, media_type="application/octet-stream",
                        headers={"X-Audio-Rate": "48000", "X-Audio-Channels": "2"})

    def control(job_id: str, action: str):
        job = current(job_id)
        if job is None:
            return JSONResponse({"error": "noJob"}, status_code=404)
        getattr(job.control, action)()
        return {"ok": True, "status": job.status}

    @app.post("/v1/video/jobs/{job_id}/cancel")
    async def cancel(job_id: str):
        return control(job_id, "cancel")

    @app.post("/v1/video/jobs/{job_id}/pause")
    async def pause(job_id: str):
        return control(job_id, "pause")

    @app.post("/v1/video/jobs/{job_id}/resume")
    async def resume(job_id: str):
        return control(job_id, "resume")

    @app.post("/v1/video/jobs/{job_id}/release")
    async def release(job_id: str):
        job = current(job_id)
        if job is None:
            return JSONResponse({"error": "noJob"}, status_code=404)
        job.store.clear()
        return {"ok": True}

    @app.post("/v1/shutdown")
    async def shutdown():
        j = state.job
        if j is not None:
            j.control.cancel()
        if state.server is not None:
            state.server.should_exit = True
        return {"ok": True}

    return app


def bind_uds(path: str) -> socket.socket:
    """Binds the unix socket ourselves (0600 before listen) and hands it to uvicorn."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)
    try:
        s.bind(path)
    finally:
        os.umask(old)
    os.chmod(path, 0o600)
    s.listen(16)
    return s


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--uds", required=True)
    ap.add_argument("--token-env", default="ANTICHAT_VIDEO_TOKEN")
    ap.add_argument("--generator", default="wan22", choices=["wan22", "scripted"])
    ap.add_argument("--log-level", default="warning")
    a = ap.parse_args(argv)
    token = os.environ.get(a.token_env, "")
    if len(token) < 16:
        print(f"video runtime: {a.token_env} missing or too short", file=sys.stderr)
        return 64
    logging.basicConfig(level=a.log_level.upper(), stream=sys.stderr, format="%(name)s %(levelname)s %(message)s")
    import uvicorn

    state = State(a.generator)
    app = create_app(state, token)
    sock = bind_uds(a.uds)
    config = uvicorn.Config(app, log_level=a.log_level, access_log=False, lifespan="off",
                            timeout_graceful_shutdown=0.3)  # SIGTERM = the helper's cancel escalation (NFR-VID3 ≤ 2 s)
    server = uvicorn.Server(config)
    state.server = server
    t0 = time.monotonic()
    print(json.dumps({"event": "listening", "uds": a.uds, "pid": os.getpid()}), flush=True)
    try:
        server.run(sockets=[sock])
    finally:
        try:
            os.unlink(a.uds)
        except OSError:
            pass
    log.info("server exit after %.1f s", time.monotonic() - t0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
