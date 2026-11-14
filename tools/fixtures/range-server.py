#!/usr/bin/env python3
"""M2.T08 (AT-NFR-D6, AT-204, AT-220 part 2): a loopback HTTP/1.1 file server with Range + If-Range for the
download tests. Run with `python3 -I`. Prints `PORT <n>` on stdout once listening.

URL → file: `/<anything>/resolve/<commit>/<path>` serves `<root>/<path>` (Hugging Face's layout); any other path
serves `<root>/<path>`; `--literal` always serves `<root>/<URL path>` (a mirror of many repos). ETag = `"<size>-<mtime_ns>"`; `If-Range` with another ETag gets the whole file (200).

Faults (each path argument matches the URL path's suffix):
  --fail-after <bytes>   once the server has sent that many body bytes in total, every open response stops at
                         once — a network loss at that byte boundary: each socket's send buffer drains, then FIN, so
                         nothing counted is still in flight — and new connections are refused for --down-for
                         seconds; then the server serves normally again (one-shot)
  --slow <kbps>          per-response throttle (kilobytes per second)
  --404 <path>           answer 404 (repeatable); --410 <path> likewise
  --corrupt <path>       flip the byte at offset size/2 in every response that covers it (repeatable);
                         --corrupt-times <n> stops after n corrupted responses (default: always)
  --log <file>           one JSON line per response: {ts, path, range, status, sent, active, max_active,
                         max_active_path} (`active` = simultaneous responses when it started, all paths)

Lifetime: the server exits on its own when the process that started it goes away (it is re-parented: getppid()
changes), so a test process that crashes, times out or never runs its deinit leaves no orphan behind.
Every way out is a plain exit(0): SIGTERM/SIGINT/SIGHUP are handled (os._exit(0)), parent death is os._exit(0), and
the server never raises a crashing signal (SIGSEGV/SIGABRT/SIGBUS make macOS write a "Python quit unexpectedly" report).
"""
import argparse, json, os, re, signal, socket, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ARGS = None
LOCK = threading.Lock()
SO_NWRITE = getattr(socket, "SO_NWRITE", 0x1024)  # Darwin: bytes still in the socket's send buffer
STATE = {"sent": 0, "tripped": False, "down_until": 0.0, "active": 0, "max_active": 0, "corrupted": 0,
         "per_path_active": {}, "per_path_max": {}}
GEN = [0]  # bumped when the --fail-after trip fires; responses of an older generation abort


def log(rec):
    if not ARGS.log:
        return
    with LOCK, open(ARGS.log, "a") as f:
        f.write(json.dumps(rec) + "\n")


def matches(path, patterns):
    return any(path.endswith(p) for p in patterns or [])


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def resolve(self):
        p = self.path.split("?", 1)[0]
        m = None if ARGS.literal else re.search(r"/resolve/[^/]+/(.+)$", p)
        rel = m.group(1) if m else p.lstrip("/")
        full = os.path.realpath(os.path.join(ARGS.root, rel))
        if not full.startswith(os.path.realpath(ARGS.root) + os.sep) or not os.path.isfile(full):
            return p, None
        return p, full

    def do_HEAD(self):
        self.serve(head=True)

    def do_GET(self):
        self.serve(head=False)

    def cut(self):
        # The --fail-after network loss: close the response short WITHOUT discarding what is already in flight. A reset
        # (RST) throws away the bytes sitting unread in the socket buffers, and how many those are depends on how far the
        # client lags (a loaded host: several MB), which made the measured over-fetch (bytes sent - file size) a function
        # of host load. FIN after the last byte: the client has every byte the server counted, then sees a truncated body.
        # Before the FIN, wait (bounded) until this socket's send buffer is empty — every byte counted has been sent
        # and acknowledged — so the loss falls on a byte boundary with nothing in flight, however far a loaded client
        # lags (bytes still queued at the cut were what made the over-fetch track host load, AT-NFR-D6 2026-11-08).
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                if self.connection.getsockopt(socket.SOL_SOCKET, SO_NWRITE) == 0:
                    break
            except OSError:
                break
            time.sleep(0.005)
        try:
            self.connection.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        self.close_connection = True

    def reset(self):
        # shutdown() acts on the socket at once even while rfile/wfile still hold it (close() alone would wait
        # for them, and the client would sit on a half-sent body until its timeout).
        for step in (lambda: self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)),
                     lambda: self.connection.shutdown(socket.SHUT_RDWR), lambda: self.connection.close()):
            try:
                step()
            except OSError:
                pass
        self.close_connection = True

    def serve(self, head):
        path, full = self.resolve()
        if time.monotonic() < STATE["down_until"]:
            self.reset()
            return
        if matches(path, ARGS.e404) or matches(path, ARGS.e410) or full is None:
            code = 410 if matches(path, ARGS.e410) else 404
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()
            log({"ts": time.time(), "path": path, "range": self.headers.get("Range"), "status": code, "sent": 0})
            return
        st = os.stat(full)
        size, etag = st.st_size, f'"{st.st_size}-{st.st_mtime_ns}"'
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if_range = self.headers.get("If-Range")
        if rng and (if_range is None or if_range == etag):
            m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
            if not m or (m.group(1) == "" and m.group(2) == ""):
                self.send_response(416); self.send_header("Content-Length", "0"); self.end_headers(); return
            if m.group(1) == "":
                start, end = max(0, size - int(m.group(2))), size - 1
            else:
                start = int(m.group(1))
                end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", etag)
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head:
            return
        corrupt_at = size // 2 if matches(path, ARGS.corrupt) and start <= size // 2 <= end else None
        if corrupt_at is not None:
            with LOCK:
                if ARGS.corrupt_times is not None and STATE["corrupted"] >= ARGS.corrupt_times:
                    corrupt_at = None
                else:
                    STATE["corrupted"] += 1
        with LOCK:
            STATE["active"] += 1
            active = STATE["active"]
            STATE["max_active"] = max(STATE["max_active"], active)
            pa = STATE["per_path_active"].get(path, 0) + 1
            STATE["per_path_active"][path] = pa
            STATE["per_path_max"][path] = max(STATE["per_path_max"].get(path, 0), pa)
            gen = GEN[0]
        sent, aborted = 0, False
        try:
            with open(full, "rb") as f:
                f.seek(start)
                pos = start
                block = 256 * 1024 if not ARGS.slow else max(1024, ARGS.slow * 1024 // 20)
                while pos <= end:
                    if GEN[0] != gen:
                        aborted = True
                        break
                    n = min(block, end - pos + 1)
                    if ARGS.fail_after is not None:
                        with LOCK:
                            if not STATE["tripped"] and STATE["sent"] + n >= ARGS.fail_after:
                                n = max(0, ARGS.fail_after - STATE["sent"])
                                STATE["tripped"] = True
                                STATE["down_until"] = time.monotonic() + ARGS.down_for
                                GEN[0] += 1
                    data = bytearray(f.read(n))
                    if corrupt_at is not None and pos <= corrupt_at < pos + len(data):
                        data[corrupt_at - pos] ^= 0xFF
                    if data:
                        self.wfile.write(data)
                    sent += len(data)
                    pos += len(data)
                    with LOCK:
                        STATE["sent"] += len(data)
                    if GEN[0] != gen:
                        aborted = True
                        break
                    if ARGS.slow:
                        time.sleep(len(data) / (ARGS.slow * 1024))
        except (BrokenPipeError, ConnectionResetError, OSError):
            aborted = True
        finally:
            with LOCK:
                STATE["active"] -= 1
                STATE["per_path_active"][path] -= 1
                rec = {"ts": time.time(), "path": path, "range": rng, "status": status, "sent": sent, "active": active,
                       "max_active": STATE["max_active"], "max_active_path": STATE["per_path_max"][path],
                       "aborted": aborted}
            log(rec)
            if aborted:
                (self.cut if GEN[0] != gen else self.reset)()


def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--log")
    ap.add_argument("--fail-after", type=int)
    ap.add_argument("--down-for", type=float, default=0.5)
    ap.add_argument("--slow", type=int, help="kilobytes per second per response")
    ap.add_argument("--404", dest="e404", action="append")
    ap.add_argument("--410", dest="e410", action="append")
    ap.add_argument("--corrupt", action="append")
    ap.add_argument("--corrupt-times", type=int)
    ap.add_argument("--literal", action="store_true", help="serve <root>/<URL path> as is (a multi-repo mirror, M10.T09)")
    ap.add_argument("--run-token", help="test-run tag (tools/ci/range-server-leftovers.sh); unused by the server")
    ARGS = ap.parse_args()
    ThreadingHTTPServer.daemon_threads = True
    ThreadingHTTPServer.request_queue_size = 64
    srv = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    parent = os.getppid()

    def watch_parent():
        while True:
            time.sleep(0.25)
            ppid = os.getppid()
            if ppid != parent or ppid == 1:  # the spawning test process died (re-parented to launchd): never outlive it
                os._exit(0)

    def bye(*_):
        os._exit(0)  # a clean exit, never a crash report

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, bye)
    threading.Thread(target=watch_parent, daemon=True).start()
    print(f"PORT {srv.server_address[1]}", flush=True)
    try:
        srv.serve_forever(poll_interval=0.05)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
