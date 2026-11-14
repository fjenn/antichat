#!/usr/bin/env python3
"""Print the DMG window layout from a .DS_Store as JSON (M10.T02 AT-225; release venv: ds_store package).
Usage: build/release-venv/bin/python -I tools/release/dsstore-read.py <mounted volume>/.DS_Store
Output: {"icons": {name: [x, y]}, "window": [x, y, w, h] | null, "icon_size": n | null, "background": kind | null,
         "background_bookmark": "/abs/path" | null, "background_bookmark_volume": "/Volumes/…" | null,
         "background_alias": "/path/in/volume" | null}
background kind 2 = picture. The bookmark (`pBBk`, what Finder resolves) path is read from the filesystem root, as
CoreFoundation does; the alias (`icvp.backgroundImageAlias`, legacy) target is relative to its volume.
"""
from __future__ import annotations

import json
import plistlib
import re
import sys

from ds_store import DSStore
from mac_alias import Alias, Bookmark


def main() -> int:
    icons: dict[str, list[int]] = {}
    window = icon_size = background = bookmark = bookmark_volume = alias = None
    with DSStore.open(sys.argv[1], "r") as d:
        for e in d:
            if e.code == b"Iloc":
                icons[e.filename] = [int(e.value[0]), int(e.value[1])]
            elif e.filename == "." and e.code == b"bwsp":
                v = e.value if isinstance(e.value, dict) else plistlib.loads(e.value)
                nums = [int(n) for n in re.findall(r"-?\d+", v.get("WindowBounds", ""))]
                if len(nums) == 4:
                    window = nums
            elif e.filename == "." and e.code == b"icvp":
                v = e.value if isinstance(e.value, dict) else plistlib.loads(e.value)
                icon_size = int(v.get("iconSize", 0)) or None
                background = v.get("backgroundType")
                if v.get("backgroundImageAlias"):
                    a = Alias.from_bytes(v["backgroundImageAlias"])
                    alias = a.target.posix_path.decode() if isinstance(a.target.posix_path, bytes) else a.target.posix_path
            elif e.filename == "." and e.code == b"pBBk":
                bm = e.value if isinstance(e.value, Bookmark) else Bookmark.from_bytes(bytes(e.value))
                toc = bm.tocs[0][1]
                bookmark = "/" + "/".join(str(c) for c in toc.get(0x1004, []))
                bookmark_volume = str(toc.get(0x2002)) if toc.get(0x2002) is not None else None
    print(json.dumps({"icons": icons, "window": window, "icon_size": icon_size, "background": background,
                      "background_bookmark": bookmark, "background_bookmark_volume": bookmark_volume,
                      "background_alias": alias}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
