#!/usr/bin/env python3
"""Make the DMG window's background picture resolvable by Finder (M10 VQ: the dev DMG opened on a plain white window).

dmgbuild 1.6.5 stores the background as `pBBk` (a CFURL bookmark built by mac_alias `Bookmark.for_file`) next to the
legacy `icvp.backgroundImageAlias`. mac_alias writes the bookmark's path (0x1004) and CNID path (0x1005) *relative to
the volume* (`['.background.tiff']`), while CoreFoundation reads them from the filesystem root
(`['Volumes', 'AntiChat', '.background.tiff']`, as `NSURL.bookmarkData` writes them). Finder (macOS 26) resolves the
bookmark to `/.background.tiff` on the startup disk, finds nothing and draws no picture; the alias is not used as a
fallback. The layout, icon positions and window size are unaffected, which is why the static checks passed.

This rewrites the bookmark's path to start at the volume's mount path (`/Volumes/<volume name>`, where Finder mounts
an opened DMG) and changes nothing else. Idempotent. No host-specific data is added except the CNID of /Volumes on the
build Mac (path resolution comes first; the CNID only matters if the path fails).

Usage (release venv: ds_store, mac_alias): fix-background-bookmark.py <mounted read-write volume>/.DS_Store
"""
from __future__ import annotations

import os
import sys

from ds_store import DSStore


def main() -> int:
    path = sys.argv[1]
    with DSStore.open(path, "r+") as d:
        bm = d["."]["pBBk"]
        toc = bm.tocs[0][1]
        vol_comps = [c for c in str(toc[0x2002]).split("/") if c]  # '/Volumes/AntiChat' → ['Volumes', 'AntiChat']
        names = list(toc[0x1004])
        if names[: len(vol_comps)] == vol_comps:
            print(f"bookmark already absolute: /{'/'.join(names)}")
            return 0
        cnids = list(toc[0x1005])
        prefix_cnids = [os.stat("/" + "/".join(vol_comps[:i + 1])).st_ino for i in range(len(vol_comps) - 1)] + [2]
        toc[0x1004] = vol_comps + names
        toc[0x1005] = prefix_cnids + cnids
        d["."]["pBBk"] = bm
    print(f"bookmark path: /{'/'.join(vol_comps + names)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
