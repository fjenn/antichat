"""NFR-VID3 memory miss (2026-11-08 re-run, run 5 step 1): a cancelled job's arrays must be gone before the allocator
cache is cleared. A cancel raises `Cancelled` out of the sampler, so the job's tensors live on in the traceback frames;
if anything in them sits in a reference cycle, only a collection frees it, and buffers freed after `mx.clear_cache()`
go back into MLX's cache, which the helper sees as footprint for the whole window (the next job's `gc.collect()` was
what finally released them). `run_job` now drops the generator, collects, then clears the cache on every terminal path.
"""
from __future__ import annotations

import gc
import weakref
from types import SimpleNamespace

from antichat_video import server
from antichat_video.wan22_generator import Cancelled


class _Big:
    """Stands in for a job tensor: kept in a reference cycle, as module trees and closures can be."""

    def __init__(self) -> None:
        self.me = self


def _run(monkeypatch, outcome: str):
    refs: list[weakref.ref] = []
    cleared_with_alive: list[bool] = []

    class Gen:
        def run(self, req, emit, control, store):
            big = _Big()
            refs.append(weakref.ref(big))
            self.big = big  # the generator holds it too (dit / decoder on the instance)
            if outcome == "cancel":
                control.cancel()
                control.check()
            if outcome == "fail":
                raise RuntimeError("boom")
            return SimpleNamespace(metrics={})

    import mlx.core as mx

    real_clear = mx.clear_cache

    def clear_cache():
        cleared_with_alive.append(refs[0]() is not None)
        real_clear()

    monkeypatch.setattr(server, "make_generator", lambda kind, req: Gen())
    # pytest's log capture keeps every record (and a failure's traceback with it); the runtime's stderr handler does not.
    monkeypatch.setattr(server, "log", SimpleNamespace(exception=lambda *a, **k: None))
    monkeypatch.setattr(mx, "clear_cache", clear_cache)
    job = server.Job(SimpleNamespace(job_id="j"))
    was = gc.isenabled()
    gc.disable()  # deterministic: no automatic collection may rescue a missing one
    try:
        server.run_job(server.State("scripted"), job)
    finally:
        if was:
            gc.enable()
    return job, cleared_with_alive


def test_cancelled_job_arrays_are_freed_before_the_cache_is_cleared(monkeypatch):
    job, cleared_with_alive = _run(monkeypatch, "cancel")
    assert job.status == "cancelled"
    assert cleared_with_alive == [False], "a cancelled job's arrays were still alive when the cache was cleared"


def test_failed_job_arrays_are_freed_before_the_cache_is_cleared(monkeypatch):
    job, cleared_with_alive = _run(monkeypatch, "fail")
    assert job.status == "failed"
    assert cleared_with_alive == [False]


def test_completed_job_arrays_are_freed_before_the_cache_is_cleared(monkeypatch):
    job, cleared_with_alive = _run(monkeypatch, "ok")
    assert job.status == "completed"
    assert cleared_with_alive == [False]
