"""AntiChat File tools runtime: per-process setup, imported by `site` before any user code (M6.T15 step 4).

Lives in `<runtime>/antichat/` (on PYTHONPATH, set by the FileTools XPC launcher, M6.T17). It
  - points matplotlib at the headless `Agg` backend and a config/cache dir inside the chat's scratch folder;
  - offers `save_open_figures()`, the figure auto-save hook the REPL calls after every run (PNG into `out/`);
  - installs an audit hook that refuses process creation (fork/exec/spawn/system/Popen) and, unless the
    network variant of the service started us (ANTICHAT_FILETOOLS_NETWORK=1), outgoing sockets and DNS.

The hook is defence in depth only. The boundary is the kernel: the App Sandbox of AntiChatFileTools.xpc (no
network entitlement, no file access outside its container + the read-only runtime) plus the rlimits and the
watchdog of the service (M6.T17/T18). The security suite proves the kernel boundary with ctypes calls that
bypass this hook.
"""
import errno
import os
import sys

_SCRATCH = os.environ.get("ANTICHAT_SCRATCH") or os.getcwd()
OUT_DIR = os.path.join(_SCRATCH, "out")
os.environ["MPLBACKEND"] = "Agg"
os.environ.setdefault("MPLCONFIGDIR", os.path.join(_SCRATCH, "tmp", "matplotlib"))

_NETWORK = os.environ.get("ANTICHAT_FILETOOLS_NETWORK") == "1"
_PROCESS_EVENTS = frozenset({
    "os.fork", "os.forkpty", "os.posix_spawn", "os.spawn", "os.exec", "os.system", "os.startfile",
    "subprocess.Popen", "pty.spawn",
})
_NETWORK_EVENTS = frozenset({
    "socket.connect", "socket.sendto", "socket.sendmsg", "socket.getaddrinfo", "socket.gethostbyname",
    "socket.gethostbyaddr", "socket.getnameinfo",
})


def _refuse(event: str, what: str) -> None:
    raise PermissionError(errno.EPERM, f"{what} ({event})")


def _audit(event: str, args: tuple) -> None:
    if event in _PROCESS_EVENTS:
        _refuse(event, "Starting another process is not allowed in the File tools sandbox")
    if not _NETWORK and event in _NETWORK_EVENTS:
        _refuse(event, "Network is off for code")
    if event == "os.kill" and args and args[0] not in (0, os.getpid()):
        _refuse(event, "Signalling another process is not allowed in the File tools sandbox")


sys.addaudithook(_audit)


def save_open_figures(prefix: str = "figure") -> list:
    """Save every open matplotlib figure as `out/<prefix>-<n>.png` and close it; returns the file names.
    Never imports matplotlib itself (a run that did not use it pays nothing)."""
    plt = sys.modules.get("matplotlib.pyplot")
    if plt is None:
        return []
    os.makedirs(OUT_DIR, exist_ok=True)
    saved = []
    for num in list(plt.get_fignums()):
        fig = plt.figure(num)
        n = 1
        while os.path.exists(os.path.join(OUT_DIR, f"{prefix}-{n}.png")):
            n += 1
        name = f"{prefix}-{n}.png"
        fig.savefig(os.path.join(OUT_DIR, name), dpi=144, bbox_inches="tight")
        plt.close(fig)
        saved.append(name)
    return saved
