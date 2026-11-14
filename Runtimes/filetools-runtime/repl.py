"""AntiChat File tools REPL (M6.T15 step 4): one persistent interpreter per chat, driven by AntiChatFileTools.xpc.

Protocol: JSON lines. The service writes one request per line to our stdin and reads one reply per line from
our stdout:
    in   {"id": "<str>", "code": "<python source>"}
    out  {"id": "<str>", "stdout": "...", "stderr": "...", "error": null | {"type", "message", "traceback",
          "errno"}, "files": ["<names in out/ created or changed by this run>"], "stdout_truncated": bool}
The first line we write is {"ready": true, "python": "<version>", "pid": <pid>}.

Globals persist across requests (one namespace per process). Captured stdout and stderr are capped at 64 KB
each. File descriptors 1 and 2 are re-pointed at capture files in `tmp/`, so output written by C code (or by
`os.write(1, …)`) can never corrupt the protocol stream; the protocol uses private duplicates of 0 and 1.
If the service dies we exit too (reparenting check), so no interpreter outlives its watchdog.
CPU: the service sets the hard RLIMIT_CPU (the interpreter's lifetime budget, also the bound for anything it
forks); before every run we lower the soft limit to "CPU used so far + ANTICHAT_RUN_CPU_SECONDS" (default 60), so
one run gets at most 60 s of CPU (SIGXCPU) on top of the service's 60 s wall-clock watchdog (M6.T18).
"""
import ast
import io
import json
import linecache
import math
import os
import resource
import sys
import threading
import time
import traceback

CAP = 64 * 1024
SCRATCH = os.environ.get("ANTICHAT_SCRATCH") or os.getcwd()
OUT = os.path.join(SCRATCH, "out")
TMP = os.path.join(SCRATCH, "tmp")


class CappedWriter(io.TextIOBase):
    def __init__(self, cap: int = CAP):
        self.parts, self.size, self.cap, self.truncated = [], 0, cap, False

    def writable(self) -> bool:
        return True

    def write(self, s) -> int:
        s = str(s)
        room = self.cap - self.size
        if room > 0:
            piece = s[:room]
            self.parts.append(piece)
            self.size += len(piece)
        if len(s) > max(room, 0):
            self.truncated = True
        return len(s)

    def getvalue(self) -> str:
        return "".join(self.parts)


def _snapshot() -> dict:
    files = {}
    for root, _dirs, names in os.walk(OUT):
        for n in names:
            p = os.path.join(root, n)
            try:
                st = os.stat(p)
            except OSError:
                continue
            files[os.path.relpath(p, OUT)] = (st.st_size, st.st_mtime_ns)
    return files


def _read_capped(path: str) -> str:
    try:
        with open(path, "rb") as f:
            data = f.read(CAP)
        with open(path, "wb"):
            pass  # truncate for the next run (fd 1/2 are O_APPEND, so writes continue at the new end)
        return data.decode("utf-8", "replace")
    except OSError:
        return ""


def _watch_parent(parent: int) -> None:
    while True:
        if os.getppid() != parent:
            os._exit(70)
        time.sleep(0.5)


def arm_cpu_limit() -> None:
    per_run = int(os.environ.get("ANTICHAT_RUN_CPU_SECONDS", "60"))
    ru = resource.getrusage(resource.RUSAGE_SELF)
    _soft, hard = resource.getrlimit(resource.RLIMIT_CPU)
    soft = math.ceil(ru.ru_utime + ru.ru_stime) + per_run
    if hard != resource.RLIM_INFINITY:
        soft = min(soft, hard)
    resource.setrlimit(resource.RLIMIT_CPU, (soft, hard))


def run_cell(namespace: dict, cell_id: str, code: str):
    filename = f"<cell {cell_id}>"
    linecache.cache[filename] = (len(code), None, code.splitlines(True), filename)
    tree = ast.parse(code, filename, "exec")
    last = None
    if tree.body and isinstance(tree.body[-1], ast.Expr):
        last = ast.Expression(tree.body.pop().value)
    exec(compile(tree, filename, "exec"), namespace)
    if last is not None:
        value = eval(compile(last, filename, "eval"), namespace)
        if value is not None:
            namespace["_"] = value
            print(repr(value))


def main() -> int:
    import sitecustomize  # noqa: F401  (already imported by site; explicit so a missing hook fails loudly)

    os.makedirs(OUT, exist_ok=True)
    os.makedirs(TMP, exist_ok=True)
    proto_in = os.fdopen(os.dup(0), "r", encoding="utf-8", newline="\n")
    proto_out = os.fdopen(os.dup(1), "w", encoding="utf-8", newline="\n", buffering=1)
    null = os.open(os.devnull, os.O_RDONLY)
    os.dup2(null, 0)
    os.close(null)
    fd_logs = []
    for fd in (1, 2):
        path = os.path.join(TMP, f".fd{fd}.log")
        h = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_APPEND, 0o600)
        os.dup2(h, fd)
        os.close(h)
        fd_logs.append(path)
    threading.Thread(target=_watch_parent, args=(os.getppid(),), daemon=True).start()

    namespace = {"__name__": "__main__", "__builtins__": __builtins__}
    real_stdout, real_stderr = sys.stdout, sys.stderr
    proto_out.write(json.dumps({"ready": True, "python": sys.version.split()[0], "pid": os.getpid()}) + "\n")
    for line in proto_in:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            cell_id, code = str(req["id"]), str(req["code"])
        except (ValueError, KeyError, TypeError) as e:
            proto_out.write(json.dumps({"id": None, "error": {"type": "ProtocolError", "message": str(e)}}) + "\n")
            continue
        before = _snapshot()
        arm_cpu_limit()
        out, err = CappedWriter(), CappedWriter()
        sys.stdout, sys.stderr = out, err
        error = None
        try:
            run_cell(namespace, cell_id, code)
        except BaseException as e:  # noqa: BLE001  (SystemExit/KeyboardInterrupt are user errors here too)
            error = {
                "type": type(e).__name__,
                "message": str(e),
                "traceback": "".join(traceback.format_exception(e)),
                "errno": getattr(e, "errno", None),
            }
        finally:
            sys.stdout, sys.stderr = real_stdout, real_stderr
        try:
            import sitecustomize as sc
            sc.save_open_figures()
        except Exception as e:  # noqa: BLE001
            err.write(f"\n[figure save failed: {e}]\n")
        for writer, path in ((out, fd_logs[0]), (err, fd_logs[1])):
            extra = _read_capped(path)
            if extra:
                writer.write(extra)
        after = _snapshot()
        files = sorted(k for k, v in after.items() if before.get(k) != v)
        reply = {"id": cell_id, "stdout": out.getvalue(), "stderr": err.getvalue(), "error": error,
                 "files": files, "stdout_truncated": out.truncated}
        proto_out.write(json.dumps(reply) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
