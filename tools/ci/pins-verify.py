#!/usr/bin/env python3
"""Verify lockfiles against tools/ci/pins.json (M0.T01 step 3; environment.md §2).

Checks Package.resolved (root + ChildSafetyCheck), .gitmodules + `git submodule status`,
Vendor/vendir.lock.yml (when present) and tools/toolchain.lock (when present).
Prints `name expected actual` for each mismatch and exits 1 on any. Run with `python3 -I`.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_resolved(path: str) -> dict[str, dict]:
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return {}
    data = json.load(open(full))
    out = {}
    for pin in data.get("pins", []):
        out[pin["identity"].lower()] = {
            "location": pin.get("location", ""),
            "revision": pin.get("state", {}).get("revision"),
            "version": pin.get("state", {}).get("version"),
        }
    return out


def norm_url(u: str) -> str:
    u = u.lower().rstrip("/")
    return u[:-4] if u.endswith(".git") else u


def main() -> int:
    pins = json.load(open(os.path.join(ROOT, "tools/ci/pins.json")))
    errors: list[tuple[str, str, str]] = []
    ok: list[str] = []

    root_resolved = load_resolved("Package.resolved")
    if not root_resolved:
        errors.append(("Package.resolved", "present", "missing"))
    locks: dict[str, dict] = {}

    for name, want in pins["swiftpm"].items():
        # Pins of separate packages name their lockfile (ChildSafetyCheck, Benchmarks; M1.T02).
        lf = want.get("lockfile")
        lock = locks.setdefault(lf, load_resolved(lf)) if lf else root_resolved
        got = lock.get(name)
        if got is None:
            if want.get("when") == "present":
                continue
            errors.append((name, "pinned in lockfile", "absent"))
            continue
        if norm_url(got["location"]) != norm_url(want["url"]):
            errors.append((f"{name}.url", want["url"], got["location"]))
        if "revision" in want and got["revision"] != want["revision"]:
            errors.append((f"{name}.revision", want["revision"], str(got["revision"])))
        if "revision_prefix" in want and not str(got["revision"]).startswith(want["revision_prefix"]):
            errors.append((f"{name}.revision", want["revision_prefix"] + "…", str(got["revision"])))
        if "exact" in want and got["version"] != want["exact"]:
            errors.append((f"{name}.version", want["exact"], str(got["version"])))
        if "commit" in want and got["revision"] != want["commit"]:
            errors.append((f"{name}.commit", want["commit"], str(got["revision"])))
        ok.append(name)

    # Submodules: .gitmodules URL + recorded gitlink SHA.
    gm = os.path.join(ROOT, ".gitmodules")
    gm_text = open(gm).read() if os.path.exists(gm) else ""
    try:
        status = subprocess.run(["git", "-C", ROOT, "submodule", "status"], capture_output=True, text=True, check=True).stdout
    except subprocess.CalledProcessError as e:
        status = ""
        errors.append(("git submodule status", "exit 0", f"exit {e.returncode}"))
    sub_sha = {}
    for line in status.splitlines():
        m = re.match(r"^[ +\-U]?([0-9a-f]{40}) (\S+)", line)
        if m:
            sub_sha[m.group(2)] = (m.group(1), line[0])
    for path, want in pins["submodules"].items():
        entries = {}
        for b in re.finditer(r'\[submodule "[^"]*"\]\s*\n((?:[ \t]+\S.*\n?)+)', gm_text):
            kv = dict(re.findall(r"^\s*(\w+)\s*=\s*(\S+)", b.group(1), re.M))
            if "path" in kv:
                entries[kv["path"]] = kv.get("url", "")
        if path not in entries:
            errors.append((f"{path}", "in .gitmodules", "absent"))
            continue
        url = entries[path]
        if "url" in want and norm_url(url) != norm_url(want["url"]):
            errors.append((f"{path}.url", want["url"], url))
        if "url_suffix" in want and not url.endswith(want["url_suffix"]):
            errors.append((f"{path}.url", "*" + want["url_suffix"], url))
        sha, flag = sub_sha.get(path, (None, None))
        if sha is None:
            errors.append((f"{path}.commit", want["commit"], "no gitlink"))
        elif want["commit"] != "any" and sha != want["commit"]:
            errors.append((f"{path}.commit", want["commit"], sha))
        elif flag == "+":
            errors.append((f"{path}.checkout", "matches gitlink", "checked-out commit differs (+)"))
        else:
            ok.append(path)

    # Vendir lock (when present).
    vl = os.path.join(ROOT, "Vendor/vendir.lock.yml")
    if os.path.exists(vl):
        text = open(vl).read()
        for name, want in pins.get("vendir", {}).items():
            if want["commit"] not in text:
                errors.append((f"vendir.{name}", want["commit"], "not in vendir.lock.yml"))
            else:
                ok.append(f"vendir.{name}")

    # Toolchain lock (when present).
    tl = os.path.join(ROOT, "tools/toolchain.lock")
    if os.path.exists(tl):
        text = open(tl).read()
        for tool, ver in pins.get("toolchain", {}).items():
            m = re.search(rf"^{re.escape(tool)}=(\S+)", text, re.M) or re.search(rf"\b{re.escape(tool)}=(\S+)", text)
            if not m or m.group(1) != ver:
                errors.append((f"toolchain.{tool}", ver, m.group(1) if m else "absent"))
            else:
                ok.append(f"toolchain.{tool}")

    for e in errors:
        print(" ".join(e))
    print(f"pins-verify: {len(ok)} ok, {len(errors)} mismatch(es)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
