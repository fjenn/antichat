#!/usr/bin/env python3
"""Fetch pinned Hugging Face model repos anonymously (M0.T01 step 10; M0.md C6; D-007).

- Every entry in tools/dev/models-m0.json is `repo@full-commit` (+ optional include globs).
- Before any download: `GET /api/models/<repo>/revision/<sha>` must return 200 with `gated == false`
  (a 401/403 or any other gated value refuses the repo).
- Files are listed with the tree API (`/api/models/<repo>/tree/<sha>?recursive=1`); every LFS file
  is verified against `lfs.oid` (sha256), every non-LFS file against its size.
- Downloads go to <models-dir>/<key>/<path> via a `.part` file with HTTP Range resume.
- Models dir: $ANTICHAT_DEV_CACHE/Models when ANTICHAT_DEV_CACHE is set, else
  ~/Library/Application Support/AntiChat-Dev/Models. No token is ever sent (anonymous only).
- Re-runs are cheap: a file whose size and sha256 match is skipped ([ok]).

Usage:
  python3 -I tools/dev/hf-fetch.py --set min [--dry-run] [--offline] [--models-dir DIR] [--key K ...]
  python3 -I tools/dev/hf-fetch.py --catalog catalog/dev-catalog.json --set T1      (M1 dev sets)
Exit codes: 0 ok, 2 refused (gated/401), 20 checksum mismatch, 3 network/other error.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import http.client
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HF = "https://huggingface.co"
UA = "AntiChat-dev-hf-fetch/0.1"


class Refused(Exception):
    pass


def http_json(url: str, with_next: bool = False):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.load(r)
                if not with_next:
                    return data
                nxt = None
                for part in (r.headers.get("Link") or "").split(","):
                    if 'rel="next"' in part:
                        nxt = part.split(";")[0].strip().strip("<>")
                return data, nxt
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise Refused(f"{url}: HTTP {e.code} (gated or private; anonymous access only, D-007)")
            if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                time.sleep(3 * (attempt + 1))
                continue
            raise
        except urllib.error.URLError:
            if attempt < 4:
                time.sleep(3 * (attempt + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def check_revision(repo: str, sha: str) -> dict:
    meta = http_json(f"{HF}/api/models/{repo}/revision/{sha}")
    gated = meta.get("gated", None)
    if gated is not False:
        raise Refused(f"{repo}@{sha}: gated={gated!r} (only gated == false is allowed)")
    if meta.get("sha") != sha:
        raise Refused(f"{repo}@{sha}: API returned sha {meta.get('sha')!r}")
    return meta


def list_tree(repo: str, sha: str) -> list[dict]:
    out, url = [], f"{HF}/api/models/{repo}/tree/{sha}?recursive=1&expand=false"
    while url:
        items, url = http_json(url, with_next=True)
        out += [it for it in items if it.get("type") == "file"]
    return out


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_blob_sha1(path: str) -> str:
    size = os.path.getsize(path)
    h = hashlib.sha1(f"blob {size}\0".encode())
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify(path: str, item: dict) -> bool:
    if not os.path.exists(path):
        return False
    lfs = item.get("lfs")
    if lfs:
        return os.path.getsize(path) == lfs["size"] and sha256_file(path) == lfs["oid"]
    return os.path.getsize(path) == item["size"] and git_blob_sha1(path) == item["oid"]


def download(repo: str, sha: str, item: dict, dest: str) -> None:
    url = f"{HF}/{repo}/resolve/{sha}/{urllib.parse.quote(item['path'])}"
    part = dest + ".part"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    total = (item.get("lfs") or {}).get("size", item["size"])
    for attempt in range(6):
        have = os.path.getsize(part) if os.path.exists(part) else 0
        if have > total:
            os.remove(part)
            have = 0
        headers = {"User-Agent": UA}
        if have:
            headers["Range"] = f"bytes={have}-"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                mode = "ab" if have and r.status == 206 else "wb"
                if mode == "ab":
                    # CR-T-15: a 206 must resume exactly at our offset, else restart the file from 0.
                    cr = r.headers.get("Content-Range") or ""
                    if not cr.startswith(f"bytes {have}-"):
                        r.close()
                        os.remove(part)
                        continue
                with open(part, mode) as f:
                    shutil.copyfileobj(r, f, length=1 << 20)
            break
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise Refused(f"{url}: HTTP {e.code}")
            if e.code == 416:
                break
            if attempt == 5:
                raise
        except (urllib.error.URLError, http.client.HTTPException, OSError):
            # OSError covers TimeoutError/ConnectionError/ssl errors; HTTPException covers a body cut
            # short (IncompleteRead), which the next attempt resumes from the .part file.
            if attempt == 5:
                raise
        time.sleep(3 * (attempt + 1))
    os.replace(part, dest)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="min")
    ap.add_argument("--key", action="append", default=[])
    ap.add_argument("--manifest", default=os.path.join(ROOT, "tools/dev/models-m0.json"))
    # M1.T02: catalog/dev-catalog.json (tools/dev/gen-dev-catalog.py) has the manifest shape (+ `catalog`).
    ap.add_argument("--catalog", dest="manifest", help="alias of --manifest for catalog/dev-catalog.json")
    ap.add_argument("--models-dir")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--offline", action="store_true")
    a = ap.parse_args()

    man = json.load(open(a.manifest))
    keys = a.key or man["sets"][a.set]
    cache = os.environ.get("ANTICHAT_DEV_CACHE")
    models_dir = a.models_dir or (os.path.join(cache, "Models") if cache else
                                  os.path.expanduser("~/Library/Application Support/AntiChat-Dev/Models"))
    os.makedirs(models_dir, exist_ok=True)
    grand = 0
    t0 = time.time()
    try:
        for key in keys:
            for spec in man["models"][key]:
                repo, sha = spec["repo"].split("@")
                if len(sha) != 40:
                    print(f"[fail] {key}: {repo}@{sha} is not a full commit SHA")
                    return 3
                kdir = os.path.join(models_dir, key, spec.get("subdir", ""))
                lockf = os.path.join(kdir, ".hf-fetch.json")
                if a.offline:
                    if not os.path.exists(lockf):
                        print(f"[fail] {key}: offline and not cached")
                        return 3
                    cached = json.load(open(lockf))
                    # The cached file list is only valid for the pin it was written for (a manifest bump must
                    # not "verify" the old revision's files offline).
                    if cached.get("repo") != repo or cached.get("commit") != sha:
                        print(f"[fail] {key}: offline and cache is for {cached.get('repo')}@{cached.get('commit')}, "
                              f"not {repo}@{sha}")
                        return 3
                    items = cached["files"]
                else:
                    check_revision(repo, sha)
                    items = list_tree(repo, sha)
                inc = spec.get("include")
                if inc:
                    items = [i for i in items if any(fnmatch.fnmatch(i["path"], g) for g in inc)]
                exc = spec.get("exclude", [])
                items = [i for i in items if not any(fnmatch.fnmatch(i["path"], g) for g in exc)]
                if not items:  # an include/exclude typo must not "verify" an empty model
                    print(f"[fail] {key}: {repo}@{sha[:7]} no files match the include/exclude globs")
                    return 3
                size = sum((i.get("lfs") or {}).get("size", i["size"]) for i in items)
                grand += size
                print(f"[..] {key}: {repo}@{sha[:7]} {len(items)} files {size/1e9:.2f} GB")
                if a.dry_run:
                    continue
                for it in items:
                    dest = os.path.normpath(os.path.join(kdir, it["path"]))
                    # Paths come from the HF tree API (or the cached .hf-fetch.json): never write outside kdir.
                    if os.path.isabs(it["path"]) or not dest.startswith(os.path.normpath(kdir) + os.sep):
                        print(f"[fail] {key}: unsafe path {it['path']!r}")
                        return 3
                    if verify(dest, it):
                        continue
                    if a.offline:
                        print(f"[fail] {key}/{it['path']}: missing offline")
                        return 3
                    download(repo, sha, it, dest)
                    if not verify(dest, it):
                        print(f"[fail] checksum {key}/{it['path']}")
                        return 20
                os.makedirs(kdir, exist_ok=True)
                json.dump({"repo": repo, "commit": sha, "files": items}, open(lockf, "w"), indent=1)
                print(f"[ok] {key}: {repo}@{sha[:7]} verified")
    except Refused as e:
        print(f"[fail] refused: {e}")
        return 2
    except Exception as e:  # network or other
        print(f"[fail] {type(e).__name__}: {e}")
        return 3
    dt = time.time() - t0
    print(f"[ok] set={a.set} total {grand/1e9:.2f} GB in {dt:.0f} s -> {models_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
