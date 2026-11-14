"""Shared helpers for the video runtime tests (M5.T02). Run inside the runtime:

  build/runtimes/video-runtime/bin/video-runtime-launcher --pytest Packages/Engines/Python/tests
  (ANTICHAT_VIDEO_TEST_SITE=build/runtimes/video-test-site; `make runtime-video-test` sets it up and runs this)

`@pytest.mark.realModels` tests need ANTICHAT_REAL_MODELS=1 and the dev models (vid-5b, vid-taehv) and are GPU
jobs: run them under ~/AntiChat-tools/gpu-run.sh shared --.
"""
from __future__ import annotations

import http.client
import json
import os
import secrets
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[4]
MODELS = Path(os.environ.get("ANTICHAT_DEV_MODELS", Path.home() / "Library/Application Support/AntiChat-Dev/Models"))


def pytest_configure(config):
    config.addinivalue_line("markers", "realModels: needs the dev video models and the GPU (ANTICHAT_REAL_MODELS=1)")


def pytest_collection_modifyitems(config, items):
    if os.environ.get("ANTICHAT_REAL_MODELS") == "1":
        return
    skip = pytest.mark.skip(reason="realModels: set ANTICHAT_REAL_MODELS=1")
    for it in items:
        if "realModels" in it.keywords:
            it.add_marker(skip)


class UHTTP(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float = 30):
        super().__init__("localhost", timeout=timeout)
        self.uds = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.uds)
        self.sock = s


class Client:
    def __init__(self, uds: str, token: str):
        self.uds, self.token = uds, token

    def req(self, method: str, path: str, body=None, token: str | None = None, headers=None, timeout=30):
        c = UHTTP(self.uds, timeout)
        h = {"Authorization": f"Bearer {self.token if token is None else token}"}
        h.update(headers or {})
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
        c.request(method, path, body=data, headers=h)
        r = c.getresponse()
        out = r.read()
        c.close()
        return r.status, out, dict(r.getheaders())

    def json(self, method, path, body=None, **kw):
        st, out, _ = self.req(method, path, body, **kw)
        return st, (json.loads(out) if out else None)

    def events(self, job: str, last_id: int | None = None, timeout=600):
        """All SSE events of a job up to `end`: [(id, kind, data)]."""
        c = UHTTP(self.uds, timeout)
        h = {"Authorization": f"Bearer {self.token}"}
        if last_id is not None:
            h["Last-Event-ID"] = str(last_id)
        c.request("GET", f"/v1/video/jobs/{job}/events", headers=h)
        r = c.getresponse()
        assert r.status == 200, r.status
        out, cur = [], {}
        while True:
            line = r.readline()  # decoded (chunked) body, not the raw socket
            if not line:
                break
            line = line.decode().rstrip("\r\n")
            if line.startswith(":"):
                continue
            if not line:
                if cur:
                    out.append((int(cur["id"]), cur["event"], json.loads(cur["data"])))
                    if cur["event"] == "end":
                        break
                cur = {}
                continue
            k, _, v = line.partition(": ")
            cur[k] = v
        c.close()
        return out


class Server:
    def __init__(self, tmp: Path, generator: str = "scripted"):
        import tempfile
        self.dir = Path(tempfile.mkdtemp(prefix="acv-", dir="/tmp"))  # AF_UNIX paths are ≤ 104 bytes; 0700
        self.uds = str(self.dir / "v.sock")
        self.token = secrets.token_hex(16)
        self.home = tmp / "home"
        self.home.mkdir()
        self.tmpdir = tmp / "tmp"
        self.tmpdir.mkdir()
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "TMPDIR": str(self.tmpdir),
               "ANTICHAT_VIDEO_TOKEN": self.token}
        self.proc = subprocess.Popen([sys.executable, "-I", "-B", "-m", "antichat_video.server", "--uds", self.uds,
                                      "--generator", generator], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 30
        while not os.path.exists(self.uds):
            if self.proc.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"server did not start: {self.proc.stderr.read().decode()[-2000:]}")
            time.sleep(0.05)
        self.client = Client(self.uds, self.token)

    def stop(self):
        try:
            self.client.json("POST", "/v1/shutdown", timeout=5)
        except Exception:
            pass
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)


@pytest.fixture
def server(tmp_path):
    s = Server(tmp_path)
    yield s
    s.stop()


def job_body(job_id="j1", **kw):
    b = {"job_id": job_id, "model_dir": str(MODELS / "vid-5b"),
         "taehv_path": str(MODELS / "vid-taehv/taew2_2.safetensors"),
         "prompt": "Ocean waves rolling onto a sandy beach under a clear blue sky", "width": 832, "height": 480,
         "num_frames": 33, "fps": 24, "steps": 3, "seed": 3}
    b.update(kw)
    return b


def tree_snapshot(*roots: Path) -> set[str]:
    out = set()
    for r in roots:
        for p in Path(r).rglob("*"):
            out.add(str(p))
    return out
