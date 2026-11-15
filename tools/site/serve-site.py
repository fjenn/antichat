#!/usr/bin/env python3
"""Local stand-in for the static host (M10.T05: the hosting check and the Playwright CSP check). `python3 -I`;
stdlib only. Serves a built site (`make site` → site/dist) on 127.0.0.1 the way the Vercel static host does:
  - the response headers of `<dist>/vercel.json` (`headers[].source` patterns; written by post-build.py), so the
    CSP the browser enforces is the one that deploys;
  - `/a/b/` and `/a/b` → `a/b/index.html`; unknown paths → `404.html` with status 404 (no SPA fallback);
  - content types as the host sends them (`.xml` application/xml, `.json` application/json, `.txt` text/plain,
    `.wasm` application/wasm for Pagefind, `.sig`/Pagefind indexes application/octet-stream);
  - no cookies, no logging of request bodies. Never binds anything but loopback: local tests only, nothing is published.
Watchdog: the server exits on its own when its parent dies (re-parented), so a killed test run leaves no server behind.
Usage: serve-site.py [--dist site/dist] [--port 0] [--port-file FILE]
  --port 0 picks a free port; the chosen URL is printed ("serve-site: http://127.0.0.1:<port>/") and written to
  --port-file when given. `serve(dist, port)` is the in-process form hosting-check.py uses."""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TYPES = {".html": "text/html; charset=utf-8", ".xml": "application/xml", ".json": "application/json; charset=utf-8",
         ".txt": "text/plain; charset=utf-8", ".js": "application/javascript; charset=utf-8",
         ".mjs": "application/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".wasm": "application/wasm",
         ".png": "image/png", ".webp": "image/webp", ".svg": "image/svg+xml", ".ico": "image/x-icon",
         ".jpg": "image/jpeg", ".woff2": "font/woff2", ".dmg": "application/x-apple-diskimage",
         ".zip": "application/zip"}


def content_type(path: Path) -> str:
    return TYPES.get(path.suffix.lower(), "application/octet-stream")


def source_regex(source: str) -> re.Pattern[str]:
    """vercel.json `source` (path-to-regexp). The site uses plain regex groups such as `/(.*)`; `:name` segments
    become one-segment wildcards and `:name*` any suffix."""
    rx = re.sub(r":[A-Za-z_]\w*\*", ".*", source)
    rx = re.sub(r":[A-Za-z_]\w*", "[^/]+", rx)
    return re.compile("^" + rx + "$")


def load_headers(dist: Path) -> list[tuple[re.Pattern[str], list[tuple[str, str]]]]:
    cfg_path = dist / "vercel.json"
    if not cfg_path.exists():
        return []
    cfg = json.loads(cfg_path.read_text())
    return [(source_regex(h["source"]), [(x["key"], x["value"]) for x in h["headers"]]) for h in cfg.get("headers", [])]


def resolve(dist: Path, url_path: str) -> Path | None:
    rel = urllib.parse.unquote(url_path.split("?", 1)[0].split("#", 1)[0]).lstrip("/")
    target = (dist / rel).resolve()
    if dist not in target.parents and target != dist:
        return None
    if target.is_dir():
        target = target / "index.html"
    return target if target.is_file() and target.name != "vercel.json" else None


def make_handler(dist: Path):
    rules = load_headers(dist)

    class Handler(BaseHTTPRequestHandler):
        server_version = "serve-site"
        sys_version = ""

        def _send(self, head_only: bool) -> None:
            path = self.path.split("?", 1)[0]
            f = resolve(dist, path)
            status = 200
            if f is None:
                status, f = 404, dist / "404.html"
            body = f.read_bytes() if f.exists() else b"not found"
            self.send_response(status)
            self.send_header("Content-Type", content_type(f) if f.exists() else "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            for rx, headers in rules:
                if rx.match(path):
                    for k, v in headers:
                        self.send_header(k, v)
            self.end_headers()
            if not head_only:
                self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            self._send(False)

        def do_HEAD(self) -> None:  # noqa: N802
            self._send(True)

        def log_message(self, fmt: str, *args) -> None:
            pass

    return Handler


def serve(dist: Path, port: int = 0) -> tuple[ThreadingHTTPServer, str]:
    """Start in a daemon thread; returns (server, base URL). Call server.shutdown() when done."""
    srv = ThreadingHTTPServer(("127.0.0.1", port), make_handler(dist.resolve()))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", default="site/dist")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--port-file")
    a = ap.parse_args()
    dist = Path(a.dist).resolve()
    if not (dist / "index.html").exists():
        print(f"serve-site: {dist} has no index.html (run make site)", file=sys.stderr)
        return 2
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(dist))
    parent = os.getppid()

    def watchdog() -> None:
        while os.getppid() == parent:
            time.sleep(1)
        os._exit(0)

    threading.Thread(target=watchdog, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/"
    if a.port_file:
        Path(a.port_file).write_text(url + "\n")
    print(f"serve-site: {url} → {dist}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
