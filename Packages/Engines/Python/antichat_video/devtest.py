"""`video-runtime-launcher --pytest PATHS…` (M5.T02 task check; dev builds only). Runs pytest inside the runtime's
own interpreter. pytest is not part of the runtime: it comes from a separate `--target` install named by
ANTICHAT_VIDEO_TEST_SITE (`make runtime-video-testsite`), appended after the runtime's site-packages so the
runtime's pinned packages always win. No cache or bytecode is written (-B, -p no:cacheprovider).
"""
from __future__ import annotations

import os
import sys


def main(argv: list[str]) -> int:
    site = os.environ.get("ANTICHAT_VIDEO_TEST_SITE")
    if not site or not os.path.isdir(site):
        print("devtest: set ANTICHAT_VIDEO_TEST_SITE to a pytest --target install", file=sys.stderr)
        return 64
    sys.path.append(site)
    import pytest

    return int(pytest.main(["-p", "no:cacheprovider", "-q", *argv]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
