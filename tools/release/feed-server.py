#!/usr/bin/env python3
"""Local static host for the update tests (M10.T03; M10.md "Hosting and accounts": the local form). `python3 -I`.

Serves --root (default build/serve: site/public + build/release/*.dmg + build/updates/dev/*) over HTTP and logs
every request line with all headers as one JSON object per line to --log (AT-NFR-PR5 evidence; pr5-check.py reads
it). Binds 127.0.0.1 by default; the Tart VM needs --bind 0.0.0.0 (host NAT gateway 192.168.64.1). Never used to
publish anything: local tests only.
Usage: feed-server.py [--root DIR] [--bind ADDR] [--port 8765] [--log FILE]
"""
from __future__ import annotations

import argparse
import functools
import json
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(SimpleHTTPRequestHandler):
    log_file: Path | None = None

    def _record(self) -> None:
        if self.log_file:
            entry = {"ts": time.time(), "client": self.client_address[0], "method": self.command,
                     "path": self.path, "version": self.request_version, "headers": dict(self.headers.items())}
            with self.log_file.open("a") as f:
                f.write(json.dumps(entry) + "\n")

    def do_GET(self) -> None:  # noqa: N802
        self._record()
        super().do_GET()

    def do_HEAD(self) -> None:  # noqa: N802
        self._record()
        super().do_HEAD()

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("feed-server: " + (fmt % args) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="build/serve")
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--log", default="build/serve/requests.log")
    a = ap.parse_args()
    root = Path(a.root).resolve()
    log = Path(a.log).resolve()
    log.parent.mkdir(parents=True, exist_ok=True)
    Handler.log_file = log
    srv = ThreadingHTTPServer((a.bind, a.port), functools.partial(Handler, directory=str(root)))
    print(f"feed-server: http://{a.bind}:{a.port}/ → {root} (log {log})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
