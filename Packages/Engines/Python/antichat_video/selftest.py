"""`video-runtime-launcher --selftest` (M5.T01 acceptance check): the runtime imports what a job needs, offline.

Imports MLX (and asks for Metal), the vendored FastVideo Wan2.2 MLX modules, our generator and the server stack;
asserts torch was not pulled in (A-M0-T07a) and that the interpreter runs isolated. Prints one JSON line, exit 0.
"""
from __future__ import annotations

import json
import sys


def main() -> int:
    import mlx.core as mx
    import numpy
    import fastvideo.mlx_runtime.wan22  # noqa: F401
    import fastvideo.mlx_runtime.wan22_sample  # noqa: F401
    import antichat_video.wan22_generator  # noqa: F401
    import antichat_video.server  # noqa: F401
    import fastapi
    import uvicorn

    problems = []
    if "torch" in sys.modules:
        problems.append("torch imported")
    if not sys.flags.isolated:
        problems.append("not isolated (-I)")
    if not sys.flags.dont_write_bytecode:
        problems.append("bytecode writes on")
    out = {
        "ok": not problems, "python": sys.version.split()[0], "mlx": mx.__version__, "numpy": numpy.__version__,
        "fastapi": fastapi.__version__, "uvicorn": uvicorn.__version__, "metal": bool(mx.metal.is_available()),
        "problems": problems,
    }
    print(json.dumps(out), flush=True)
    return 0 if not problems else 1


if __name__ == "__main__":
    sys.exit(main())
