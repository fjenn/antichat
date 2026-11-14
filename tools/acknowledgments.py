#!/usr/bin/env python3
"""tools/acknowledgments.py — licence inventory (S-7; M0.T12 step 6; G-061 early slice).

Run: python3 -I tools/acknowledgments.py [--offline] [--runtime DIR] [--out ACKNOWLEDGMENTS.md] [--json FILE]

Reads, in this order:
  1. Package.resolved: every SwiftPM pin → GitHub licence API (`/repos/{o}/{r}/license?ref=<revision>`, anonymous)
     plus the licence file at that revision from raw.githubusercontent.com (the text that ships), and NOTICE /
     NOTICE.txt / NOTICE.md at that revision (Apache-2.0 §4(d) duty).
  2. Vendor/VENDORED.json + Vendor/donors.json: every vendored/test row must carry a licence, equal to its donor's
     declared licence and to the licence detected in the donor's copied LICENSE; every other file under Vendor/
     must belong to a donor directory (pristine `.upstream` copies) or be AntiChat metadata.
  3. Binaries/ submodules (llama.cpp, sd.cpp) at the gitlink SHA: the local checkout's LICENSE if present, else raw.
  4. Ported code: every `Ported from <owner>/<repo>@<sha>` / `ported from …@…` header in App/, Packages/, tools/,
     Runtimes/ → that repo's licence at that SHA.
  5. Design references without copied code (Jan, Atomic Chat, Hob): licence recorded, "no NOTICE needed" stated.
  6. Models: every catalog pin (catalog/models.yaml `license`) and every dev pin of tools/dev/models-m0.json
     (DEV_MODEL_LICENSE_RECORDS for the non-catalog ones), all offline; `--verify-models` compares them with the
     Hugging Face card (`/api/models/<repo>/revision/<sha>` `cardData.license`).
  7. Video runtime (optional, --runtime DIR = an unzipped video-runtime): python-build-standalone + every
     installed distribution's METADATA licence.

Writes ACKNOWLEDGMENTS.md (generated; do not edit) and a machine summary (--json). Exit 1 if any licence is
UNKNOWN, a vendored row lacks a licence, or a declared/detected licence disagrees.
HTTP results are cached in build/acknowledgments/cache.json; --offline uses only the cache.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE_PATH = ROOT / "build" / "acknowledgments" / "cache.json"
UA = {"User-Agent": "AntiChat-acknowledgments/1 (M0.T12)", "Accept": "application/vnd.github+json"}
# Raw GitHub URLs are case-sensitive: sindresorhus packages (Defaults, KeyboardShortcuts) ship a lowercase `license`.
LICENSE_NAMES = ["LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "LICENSE-MIT", "COPYING", "License.txt", "license.txt",
                 "license"]
NOTICE_NAMES = ["NOTICE", "NOTICE.txt", "NOTICE.md"]
# Design references (PRD packet: selection.md §3/§9 S-7; patches cite these SHAs). No code copied.
DESIGN_REFS = [
    ("janhq/jan", "42bc7d2df1", "design/behaviour reference (downloads, vector DB, mlx-server); no code copied"),
    ("AtomicBot-ai/atomic-chat-core", "6c7e9e8", "design reference (sd.cpp image/video arbiter, lost-job recovery); no code copied"),
    ("FrigadeHQ/hob", "d02efe9ce330004955b2e5e11053d2faa2e0ca54", "design reference (files in/out, metasearch, uninstall flow); no code copied"),
]
# Model repos whose card carries neither `license` nor `base_model`: the upstream they were converted from,
# matched by name (the mlx-community README at the pin has no text), pinned to the upstream revision checked.
MODEL_UPSTREAM = {
    "mlx-community/gemma-4-12B-it-4bit": "google/gemma-4-12B-it@707f0a3b8a3c7ad586ed01e27eafbad8a27dd0f7",
}
# Embedded code whose own files carry no licence header the detector reads (sd.cpp thirdparty/zip.{h,c} has only the
# MIT warranty paragraph). Reviewed 2026-10-30: upstream kuba--/zip LICENSE.txt (git blob a29f3653df3fb9ec1e509fe8ce86231bef25b6cf,
# GitHub API spdx_id MIT) is the MIT licence. Pinned to the sha256 of the vendored files at sdcpp e239e4b0: a changed file
# drops the override and the scan falls back to detection / the network lookup, so a re-vendor is re-reviewed.
EMBEDDED_LICENSE_OVERRIDES = {
    "sdcpp/thirdparty/kuba-zip": {
        "license": "MIT",
        "source": "https://github.com/kuba--/zip/blob/master/LICENSE.txt (blob a29f3653df3fb9ec1e509fe8ce86231bef25b6cf; reviewed override)",
        "sha256": {
            "zip.c": "4c6de45d7ffbebadd70f468f5892ff380cea6d997e6deb910b65c04654e74d90",
            "zip.h": "8ede649cf053c54c5fd86c7311122db3afe990f1a102ffaf3b2a0aa5c575708d",
        },
    },
}
PORTED_RE = re.compile(r"[Pp]orted from ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-f]{7,40})")
SKIP_DIRS = {".build", "build", "node_modules", ".venv", "__pycache__", "Vendor", ".git"}


# ---------------------------------------------------------------- HTTP with cache
class Fetcher:
    def __init__(self, offline: bool, cache_path: Path = CACHE_PATH):
        self.offline = offline
        self.cache_path = cache_path
        self.cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
        self.api_blocked = False

    def get(self, url: str, api: bool = False) -> tuple[int, str]:
        if url in self.cache:
            c = self.cache[url]
            return c["status"], c["body"]
        if self.offline or (api and self.api_blocked):
            return 0, ""
        req = urllib.request.Request(url, headers=UA if api else {"User-Agent": UA["User-Agent"]})
        status, body = 0, ""
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    status, body = r.status, r.read().decode("utf-8", "replace")
                break
            except urllib.error.HTTPError as e:
                status, body = e.code, e.read().decode("utf-8", "replace")
                if api and e.code in (403, 429) and "rate limit" in body.lower():
                    self.api_blocked = True  # anonymous quota (60/h): fall back to licence-text detection
                    return status, body
                break
            except (urllib.error.URLError, TimeoutError):
                time.sleep(1 + attempt)
        if status in (200, 404):
            self.cache[url] = {"status": status, "body": body, "fetched": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        return status, body

    def save(self):
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        self.cache_path.write_text(json.dumps(self.cache, indent=1, sort_keys=True))


# ---------------------------------------------------------------- licence-text detection
def detect(text: str) -> str:
    t = re.sub(r"\s+", " ", text)
    found = []
    if re.search(r"Apache License,? Version 2\.0", t, re.I) or "www.apache.org/licenses/LICENSE-2.0" in t:
        found.append("Apache-2.0")
    if "Permission is hereby granted, free of charge" in t or re.search(r"^\W*MIT License\W*$", text, re.M):
        found.append("MIT")
    if "Redistribution and use in source and binary forms" in t:
        if re.search(r"Neither the name|names of its contributors may be used", t, re.I):
            found.append("BSD-3-Clause")
        else:
            found.append("BSD-2-Clause")
    if "SIL Open Font License" in t and re.search(r"Version 1\.1", t):
        found.append("OFL-1.1")
    if "Boost Software License" in t:
        found.append("BSL-1.0")
    if "Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee" in t:
        found.append("ISC")
    if "GNU AFFERO GENERAL PUBLIC LICENSE" in t:
        found.append("AGPL-3.0")
    elif "GNU LESSER GENERAL PUBLIC LICENSE" in t:
        found.append("LGPL")
    elif "GNU GENERAL PUBLIC LICENSE" in t:
        found.append("GPL")
    if "This is free and unencumbered software released into the public domain" in t:
        found.append("Unlicense")
    if "zlib License" in t or "This software is provided 'as-is', without any express or implied warranty" in t:
        found.append("Zlib")
    m = re.search(r"SPDX-License-Identifier:\s*([A-Za-z0-9.+-]+(?:\s+(?:OR|AND)\s+[A-Za-z0-9.+-]+)*)", t)
    if m and not found:
        found.append(m.group(1))
    if not found and re.search(r"\bpublic domain\b", t, re.I):
        found.append("Public-Domain")
    if "PYTHON SOFTWARE FOUNDATION LICENSE" in t:
        found.append("PSF-2.0")
    # Apache text with an appended MIT block (e.g. a licence transition) → both
    return " AND ".join(dict.fromkeys(found)) if found else "UNKNOWN"


def gh_parts(url: str) -> str:
    m = re.match(r"https://github\.com/([^/]+)/(.+?)(?:\.git)?/?$", url)
    return f"{m.group(1)}/{m.group(2)}" if m else ""


def github_component(f: Fetcher, slug: str, ref: str, local_dir: Path | None = None) -> dict:
    out = {"repo": slug, "ref": ref, "api_spdx": None, "license_file": None, "detected": "UNKNOWN", "text": "", "notice": None}
    st, body = f.get(f"https://api.github.com/repos/{slug}/license?ref={ref}", api=True)
    if st == 200:
        try:
            j = json.loads(body)
            out["api_spdx"] = (j.get("license") or {}).get("spdx_id")
            out["license_file"] = j.get("path")
            if j.get("content"):
                out["text"] = base64.b64decode(j["content"]).decode("utf-8", "replace")
        except (ValueError, KeyError):
            pass
    elif st == 404:
        out["api_spdx"] = "none (404)"
    if local_dir and local_dir.is_dir() and not out["text"]:
        for n in LICENSE_NAMES:
            if (local_dir / n).is_file():
                out["text"], out["license_file"] = (local_dir / n).read_text(errors="replace"), n
                break
    if not out["text"]:
        for n in LICENSE_NAMES:
            st, body = f.get(f"https://raw.githubusercontent.com/{slug}/{ref}/{n}")
            if st == 200 and body.strip():
                out["text"], out["license_file"] = body, n
                break
    out["detected"] = detect(out["text"]) if out["text"] else "UNKNOWN"
    if out["detected"] == "UNKNOWN":
        # No licence file: npm packages declare it in package.json (e.g. atomic-chat-core, "MIT per package.json").
        st, body = f.get(f"https://raw.githubusercontent.com/{slug}/{ref}/package.json")
        if st == 200:
            try:
                lic = json.loads(body).get("license")
            except ValueError:
                lic = None
            if isinstance(lic, str) and lic.strip():
                out["detected"], out["license_file"] = lic.strip(), "package.json (license field; no LICENSE file)"
    for n in NOTICE_NAMES:
        if local_dir and (local_dir / n).is_file():
            out["notice"] = {"file": n, "text": (local_dir / n).read_text(errors="replace")}
            break
        st, body = f.get(f"https://raw.githubusercontent.com/{slug}/{ref}/{n}")
        if st == 200 and body.strip():
            out["notice"] = {"file": n, "text": body}
            break
    return out


def resolved_license(c: dict) -> tuple[str, str]:
    """(licence, note). The detected text wins over a missing/NOASSERTION API answer; disagreement is flagged."""
    api, det = c.get("api_spdx"), c.get("detected", "UNKNOWN")
    if api and api not in ("NOASSERTION", "none (404)", "NONE"):
        if det != "UNKNOWN" and api not in det.split(" AND "):
            return det, f"GitHub API says {api}, licence text reads {det}; the text is authoritative"
        return api, ""
    if det != "UNKNOWN":
        return det, f"GitHub API: {api or 'not queried (rate limit/offline)'}; licence from the text of {c.get('license_file')}"
    return "UNKNOWN", f"GitHub API: {api}; no licence file found"


# ---------------------------------------------------------------- sources
def swiftpm_checkout(location: str, ref: str) -> Path | None:
    """The package's SwiftPM checkout (`.build/checkouts/<repo>`) when it is at the pinned revision: its licence
    file is read locally, so --offline needs no cached raw URL for a newly added pin."""
    d = ROOT / ".build" / "checkouts" / re.sub(r"\.git$", "", location.rstrip("/").rsplit("/", 1)[-1])
    if not d.is_dir():
        return None
    try:
        head = subprocess.run(["git", "-C", str(d), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return d if head == ref else None


def swiftpm(f: Fetcher) -> list[dict]:
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    rows = []
    for p in pins:
        slug = gh_parts(p["location"])
        ref = p["state"]["revision"]
        c = github_component(f, slug, ref, swiftpm_checkout(p["location"], ref))
        lic, note = resolved_license(c)
        rows.append({"kind": "swiftpm", "name": p["identity"], "version": p["state"].get("version") or p["state"].get("branch") or "revision",
                     "ref": ref[:7], **c, "license": lic, "note": note})
    return rows


def vendored(errors: list[str], f: "Fetcher | None" = None) -> tuple[list[dict], dict]:
    donors = json.loads((ROOT / "Vendor/donors.json").read_text())
    vj = json.loads((ROOT / "Vendor/VENDORED.json").read_text())
    summary = {}
    for name, d in donors.items():
        short = d["ref"][:7]
        lic_path = ROOT / "Vendor" / f"{name}@{short}" / "LICENSE"
        text = lic_path.read_text(errors="replace") if lic_path.exists() else ""
        det = detect(text) if text else "UNKNOWN"
        if not text:
            errors.append(f"Vendor/{name}@{short}/LICENSE missing")
        elif d["license"] not in det.split(" AND "):
            errors.append(f"donor {name}: declared {d['license']} but LICENSE reads {det}")
        notice = None
        slug = gh_parts(d["repo"])
        for n in NOTICE_NAMES if f and slug else []:
            st, body = f.get(f"https://raw.githubusercontent.com/{slug}/{d['ref']}/{n}")
            if st == 200 and body.strip():
                notice = {"file": n, "text": body}
                break
        summary[name] = {"repo": d["repo"], "ref": d["ref"], "license": d["license"], "detected": det, "text": text,
                         "license_file": str(lic_path.relative_to(ROOT)), "rows": 0, "modes": {}, "notice": notice}
    # M1.T09: npm dist files (Vendor/js, `make vendor-js`): one donor per package, licence copied from the tarball.
    js_manifest = ROOT / "Vendor/js/vendored-js.json"
    for e in (json.loads(js_manifest.read_text())["files"] if js_manifest.exists() else []):
        name = f"npm:{e['package']}"
        if name in summary:
            continue
        lic_path = ROOT / e.get("license_file", f"Vendor/js/licenses/{e['package']}.LICENSE")
        text = lic_path.read_text(errors="replace") if lic_path.exists() else ""
        det = detect(text) if text else "UNKNOWN"
        if not text:
            errors.append(f"{lic_path.relative_to(ROOT)} missing (run make vendor-js)")
        elif e["license"] not in det.split(" AND "):
            errors.append(f"{name}: declared {e['license']} but LICENSE reads {det}")
        summary[name] = {"repo": e["resolved"], "ref": e["version"], "license": e["license"], "detected": det,
                         "text": text, "license_file": str(lic_path.relative_to(ROOT)), "rows": 0, "modes": {},
                         "notice": None}
    # M6.T09: Noto fonts (Vendor/fonts, `make vendor-fonts`): one donor per font repo, licence fetched at the pin.
    fonts_manifest = ROOT / "Vendor/fonts/vendored-fonts.json"
    for e in (json.loads(fonts_manifest.read_text())["files"] if fonts_manifest.exists() else []):
        name = f"fonts:{e['repo']}"
        if name in summary:
            continue
        lic_path = ROOT / e["license_file"]
        text = lic_path.read_text(errors="replace") if lic_path.exists() else ""
        det = detect(text) if text else "UNKNOWN"
        if not text:
            errors.append(f"{lic_path.relative_to(ROOT)} missing (run make vendor-fonts)")
        elif e["license"] not in det.split(" AND "):
            errors.append(f"{name}: declared {e['license']} but LICENSE reads {det}")
        summary[name] = {"repo": f"https://github.com/{e['repo']}", "ref": e["sha"],
                         "license": e["license"], "detected": det, "text": text,
                         "license_file": str(lic_path.relative_to(ROOT)), "rows": 0, "modes": {}, "notice": None}
    for row in vj["files"]:
        lic = row.get("license")
        if not lic:
            errors.append(f"VENDORED.json row without licence: {row['local_path']}")
            continue
        dn = row["donor"]
        if dn not in summary:
            errors.append(f"VENDORED.json row with unknown donor {dn}: {row['local_path']}")
            continue
        if lic != summary[dn]["license"]:
            errors.append(f"VENDORED.json {row['local_path']}: {lic} != donor licence {summary[dn]['license']}")
        summary[dn]["rows"] += 1
        summary[dn]["modes"][row["mode"]] = summary[dn]["modes"].get(row["mode"], 0) + 1
    # every other file under Vendor/ must sit in a donor directory (pristine .upstream copies, LICENSE, ORIGIN)
    listed = {r["local_path"] for r in vj["files"]}
    donor_dirs = [f"Vendor/{n}@{d['ref'][:7]}/" for n, d in donors.items()] + [f"Vendor/.upstream/{n}@{d['ref'][:7]}/" for n, d in donors.items()]
    uncovered, covered_extra = [], 0
    for p in sorted((ROOT / "Vendor").rglob("*")):
        if not p.is_file() or p.name == ".DS_Store":
            continue
        rel = str(p.relative_to(ROOT))
        if rel in listed:
            continue
        if any(rel.startswith(dd) for dd in donor_dirs):
            covered_extra += 1
            continue
        if p.parent == ROOT / "Vendor":
            continue  # AntiChat metadata (allow-lists, donors.json, VENDORED.json, vendir.*, UPSTREAM_PATCHES.md)
        if p.parent == ROOT / "Vendor/js" or p.parent == ROOT / "Vendor/js/licenses":
            continue  # M1.T09 npm metadata (package.json, lockfile, vendored-js.json) and copied licences
        if p.parent == ROOT / "Vendor/fonts" or p.parent == ROOT / "Vendor/fonts/licenses":
            continue  # M6.T09 font manifest and copied OFL texts
        if p.suffix == ".patch" and p.parent.parent == ROOT / "Vendor/patches":
            continue  # M4.T05: AntiChat's UP-* patches on a pinned Binaries/ submodule (the submodule's own licence row covers it)
        uncovered.append(rel)
    for u in uncovered:
        errors.append(f"Vendor file outside any donor directory (no licence): {u}")
    return [summary[k] | {"name": k} for k in summary], {"rows": len(vj["files"]), "donor_dir_extra_files": covered_extra, "uncovered": uncovered}


def submodules(f: Fetcher, gitlinks: dict[str, str], src_root: Path | None = None) -> list[dict]:
    """Binaries/ submodules: the licence file of the local checkout (this tree's, else `src_root`'s: a worktree has
    no submodule checkout), else the network / cache."""
    rows = []
    mods = re.findall(r'\[submodule "([^"]+)"\]\s*path = (\S+)\s*url = (\S+)', (ROOT / ".gitmodules").read_text())
    for name, path, url in mods:
        if not path.startswith("Binaries/"):
            continue
        sha = gitlinks.get(path) or json.loads((ROOT / "Binaries/checksums.json").read_text()).get(
            {"Binaries/llama.cpp": "llama-server", "Binaries/sdcpp": "sd-server"}.get(path, ""), {}).get("submodule_sha", "")
        local = ROOT / path
        if not any((local / n).is_file() for n in LICENSE_NAMES) and src_root is not None:
            local = src_root / Path(path).name
        c = github_component(f, gh_parts(url), sha, local)
        lic, note = resolved_license(c)
        rows.append({"kind": "binary", "name": path, "version": sha[:7], **c, "license": lic, "note": note})
    return rows


def embedded(src_root: Path, f: "Fetcher | None" = None) -> list[dict]:
    """Third-party code compiled into llama-server / sd-server / sd-cli (llama.cpp vendor/, sd.cpp thirdparty/).
    Needs a checkout of the submodules (the worktree may not have one: --binaries-src)."""
    rows = []
    for sub, folder in (("llama.cpp", "vendor"), ("sdcpp", "thirdparty")):
        base = src_root / sub / folder
        if not base.is_dir():
            continue
        groups: dict[str, list[Path]] = {}
        for p in sorted(base.iterdir()):
            if p.name in ("CMakeLists.txt", "README.md") or p.name.startswith("."):
                continue
            key = re.sub(r"\.(h|c|hpp|cpp)$", "", p.name) if p.is_file() else p.name
            key = {"zip": "kuba-zip", "LICENSE.darts_clone.txt": "darts", "stb_image_resize": "stb", "stb_image_write": "stb", "stb_image": "stb"}.get(key, key)
            groups.setdefault(key, []).append(p)
        for key, paths in groups.items():
            files = [q for p in paths for q in ([p] if p.is_file() else sorted(p.rglob("*"))) if q.is_file()]
            lic_files = [q for q in files if re.match(r"(?i)(licen[cs]e|copying)", q.name)]
            texts = [q.read_text(errors="replace") for q in lic_files]
            if not texts:
                for q in files:
                    if q.suffix in (".h", ".c", ".hpp", ".cpp"):
                        t = q.read_text(errors="replace")
                        texts.append(t[:5000] + "\n" + t[-8000:])
            det = " AND ".join(dict.fromkeys(d for d in (detect(t) for t in texts) if d != "UNKNOWN")) or "UNKNOWN"
            src = ", ".join(str(q.relative_to(src_root)) for q in (lic_files or files)[:3])
            name = f"{sub}/{folder}/{key}"
            ov = EMBEDDED_LICENSE_OVERRIDES.get(name)
            if det == "UNKNOWN" and ov and {q.name: hashlib.sha256(q.read_bytes()).hexdigest() for q in files} == ov["sha256"]:
                det, src = ov["license"], ov["source"]
            readme = base / "README.md"
            if det == "UNKNOWN" and f and readme.is_file():
                # sd.cpp thirdparty/README.md: "- ZIP Library from: https://github.com/kuba--/zip / LICENSE: <url>"
                m = re.search(r"from:\s*https://github\.com/([^/\s]+/[^/\s]+)\s*\n\s*LICENSE:\s*(\S+)", readme.read_text())
                if m and key.split("-")[-1] in m.group(1).lower():
                    st, body = f.get(f"https://api.github.com/repos/{m.group(1)}/license", api=True)
                    if st == 200:
                        det = (json.loads(body).get("license") or {}).get("spdx_id") or "UNKNOWN"
                        src = f"{readme.relative_to(src_root)} → {m.group(2)} (GitHub API, default branch)"
            rows.append({"kind": "embedded", "name": name, "license": det, "source": src})
    return rows


def artifacts(f: Fetcher, dd: Path) -> list[dict]:
    """SwiftPM binary artefacts (xcframeworks) as unpacked under build/dd: their bundled LICENSE, and for
    onnxruntime the upstream ThirdPartyNotices.txt at the release tag (the prebuilt library contains that code)."""
    rows = []
    base = dd / "SourcePackages" / "artifacts"
    if not base.is_dir():
        return rows
    pins = {p["identity"]: p for p in json.loads((ROOT / "Package.resolved").read_text())["pins"]}
    for lic in sorted(base.glob("*/*/LICENSE")):
        pkg, art = lic.parts[-3], lic.parts[-2]
        row = {"kind": "artifact", "name": f"{pkg}/{art}", "license": detect(lic.read_text(errors="replace")),
               "source": str(lic.relative_to(ROOT)) if lic.is_relative_to(ROOT) else str(lic), "third_party_notices": None}
        if pkg == "onnxruntime-swift-package-manager" and art == "onnxruntime":
            tag = "v" + (pins.get(pkg, {}).get("state", {}).get("version") or "")
            url = f"https://raw.githubusercontent.com/microsoft/onnxruntime/{tag}/ThirdPartyNotices.txt"
            st, body = f.get(url)
            if st == 200:
                row["third_party_notices"] = {"url": url, "sha256": hashlib.sha256(body.encode()).hexdigest(), "bytes": len(body.encode())}
        rows.append(row)
    return rows


# Ported sources and design references: licence recorded in the repo (tools/licences/github-records.json, keyed by
# `owner/repo@<sha as cited>`, with the licence / NOTICE text beside it), so the scan needs no network or HTTP cache for
# them. A new `Ported from …@…` header without a record is looked up online (or in the cache) and fails as UNKNOWN until
# its licence is recorded.
GITHUB_RECORDS_PATH = ROOT / "tools" / "licences" / "github-records.json"


def recorded_component(slug: str, ref: str) -> dict | None:
    recs = json.loads(GITHUB_RECORDS_PATH.read_text()) if GITHUB_RECORDS_PATH.exists() else {}
    r = recs.get(f"{slug}@{ref}")
    if not r:
        return None
    d = ROOT / "tools" / "licences"
    notice = {"file": r["notice_file"], "text": (d / r["notice_file"]).read_text()} if r.get("notice_file") else None
    return {"repo": slug, "ref": ref, "api_spdx": None, "license_file": r.get("file"), "detected": r["license"],
            "text": (d / r["file"]).read_text() if r.get("file") else "", "notice": notice,
            "recorded": r["license"], "recorded_note": f"recorded in tools/licences/github-records.json: {r['verified']}"}


def github_or_recorded(f: Fetcher, slug: str, ref: str) -> tuple[dict, str, str]:
    c = recorded_component(slug, ref)
    if c:
        return c, c["recorded"], c["recorded_note"]
    c = github_component(f, slug, ref)
    lic, note = resolved_license(c)
    return c, lic, note


def ported(f: Fetcher) -> list[dict]:
    hits: dict[tuple[str, str], set[str]] = {}
    for top in ("App", "Packages", "tools", "Runtimes"):
        for p in (ROOT / top).rglob("*"):
            if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts) or not p.is_file():
                continue
            if p.suffix not in (".swift", ".py", ".sh", ".m", ".h", ".c", ".js", ".ts") and p.name not in ("sign.sh",):
                continue
            try:
                txt = p.read_text(errors="replace")
            except OSError:
                continue
            for m in PORTED_RE.finditer(txt[:6000]):
                hits.setdefault((m.group(1), m.group(2)), set()).add(str(p.relative_to(ROOT)))
    rows = []
    for (slug, sha), files in sorted(hits.items()):
        c, lic, note = github_or_recorded(f, slug, sha)
        rows.append({"kind": "ported", "name": slug, "version": sha[:7], **c, "license": lic, "note": note, "files": sorted(files)})
    return rows


def design_refs(f: Fetcher) -> list[dict]:
    rows = []
    for slug, sha, what in DESIGN_REFS:
        c, lic, note = github_or_recorded(f, slug, sha)
        rows.append({"kind": "design", "name": slug, "version": sha[:7], **c, "license": lic, "note": note, "what": what})
    return rows


# Model licences are read from the repo, never from the network (M4: an audit in a worktree whose HTTP cache lacked a
# new pin failed with UNKNOWN). Catalog pins: catalog/models.yaml `license` (authored when the pin was added, against
# the HF card at that commit; signed into the catalog). Dev-only pins of tools/dev/models-m0.json that are not catalog
# pins: the records below (dev key@commit → licence, how it was verified). `--verify-models` re-reads every HF card online
# and fails on a disagreement (run it when a pin changes).
DEV_MODEL_LICENSE_RECORDS = {
    "chat-lfm3@82d0e45972a9343db2ab5534b257b2d6fb3edd46":
        ("other (lfm1.0)", "HF API cardData license other / license_name lfm1.0 at the pin (scan of 2026-10-30)"),
    "csc-nudity2@4f63fac119fb24a9d98393e57549b1427530ca52":
        ("Apache-2.0", "HF API cardData license apache-2.0 at the pin (scan of 2026-10-30)"),
}
CATALOG_LICENSE_ANCHORS = {"apache": "Apache-2.0", "mit": "MIT", "ccby": "CC-BY-4.0"}


def catalog_models() -> list[dict]:
    """catalog/models.yaml entries (stdlib only: one flow mapping per `  - {key: …}` entry) → key, repo, commit, licence."""
    text = (ROOT / "catalog" / "models.yaml").read_text()
    body = text.split("\nmodels:", 1)[1]
    out = []
    for chunk in re.split(r"\n  - \{", body)[1:]:
        chunk = "\n".join(l for l in chunk.splitlines() if not l.lstrip().startswith("#"))
        key = re.search(r"\bkey: *([\w.-]+)", chunk)
        repo = re.search(r"\brepo: *([\w./-]+)", chunk)
        commit = re.search(r"\bcommit: *([0-9a-f]{40})", chunk)
        lic = re.search(r"\blicense: *([\w.()+-]+)", chunk)
        anchor = re.search(r"<<: *\*(\w+)", chunk)
        out.append({"key": key and key.group(1), "repo": repo and repo.group(1), "commit": commit and commit.group(1),
                    "license": lic.group(1) if lic else CATALOG_LICENSE_ANCHORS.get(anchor.group(1)) if anchor else None})
    return out


def _norm_license(s: str) -> str:
    s = re.sub(r"\s*\(via [^)]*\)", "", s.lower())
    s = re.sub(r"^other \((.*)\)$", r"\1", s)
    return re.sub(r"[^a-z0-9]", "", s)


def hf_card_license(f: Fetcher, repo: str, sha: str) -> tuple[str, int, object, object]:
    """The licence the HF card states at repo@sha (one hop to the base model when the card has none)."""
    st, body = f.get(f"https://huggingface.co/api/models/{repo}/revision/{sha}")
    lic, name, base, gated = "UNKNOWN", None, None, None
    if st == 200:
        j = json.loads(body)
        card = j.get("cardData") or {}
        lic = card.get("license") or next((t.split(":", 1)[1] for t in j.get("tags", []) if t.startswith("license:")), "UNKNOWN")
        name, base, gated = card.get("license_name"), card.get("base_model"), j.get("gated")
    if lic == "other" and name:
        lic = f"other ({name})"
    if lic == "UNKNOWN":
        cand = base if isinstance(base, str) else (base[0] if base else None)
        cand = cand or MODEL_UPSTREAM.get(repo)
        if cand:
            brepo, _, bsha = cand.partition("@")
            st2, body2 = f.get(f"https://huggingface.co/api/models/{brepo}" + (f"/revision/{bsha}" if bsha else ""))
            if st2 == 200:
                j2 = json.loads(body2)
                bl = (j2.get("cardData") or {}).get("license")
                if bl:
                    lic = f"{bl} (via {brepo}@{(j2.get('sha') or bsha)[:7]})"
    return lic, st, base, gated


def models(f: "Fetcher | None", errors: list[str], verify: bool = False) -> list[dict]:
    """Every catalog pin and every dev pin with its recorded licence (offline). `verify`: compare with the HF card."""
    rows, seen = [], set()
    for c in catalog_models():
        if not (c["key"] and c["repo"] and c["commit"]):
            errors.append(f"catalog/models.yaml entry without key/repo/commit: {c}")
            continue
        rows.append({"kind": "model", "name": c["key"], "repo": c["repo"], "commit": c["commit"], "ref": c["commit"][:7],
                     "license": c["license"] or "UNKNOWN", "source": "catalog/models.yaml"})
        seen.add(f"{c['repo']}@{c['commit']}")
    for key, entries in json.loads((ROOT / "tools/dev/models-m0.json").read_text())["models"].items():
        for e in entries:
            if e["repo"] in seen:
                continue
            repo, sha = e["repo"].split("@")
            lic, how = DEV_MODEL_LICENSE_RECORDS.get(f"{key}@{sha}", ("UNKNOWN", None))
            if how is None:
                errors.append(f"dev model {key} {e['repo']}: no recorded licence (add it to DEV_MODEL_LICENSE_RECORDS "
                              "after checking the card, or pin a catalog model)")
            rows.append({"kind": "model", "name": key, "repo": repo, "commit": sha, "ref": sha[:7], "license": lic,
                         "source": f"dev ({how})" if how else "dev"})
            seen.add(e["repo"])
    if verify and f is not None:
        for r in rows:
            card, st, base, gated = hf_card_license(f, r["repo"], r["commit"])
            r.update(card_license=card, http=st, gated=gated)
            if st != 200:
                errors.append(f"--verify-models: {r['name']} {r['repo']}@{r['ref']}: HF API http {st}")
            elif gated:
                errors.append(f"--verify-models: {r['name']} {r['repo']}@{r['ref']} is gated")
            elif _norm_license(card) != _norm_license(r["license"]) and "UNKNOWN" not in card:
                errors.append(f"--verify-models: {r['name']} recorded {r['license']} but the HF card says {card}")
    return rows


def runtime(rt: Path) -> list[dict]:
    rows = []
    root = rt / "video-runtime" if (rt / "video-runtime").is_dir() else rt
    pylic = next(iter(sorted(root.glob("lib/python3*/LICENSE.txt"))), None)
    if pylic:
        rows.append({"kind": "runtime", "name": "CPython (python-build-standalone)", "version": pylic.parent.name,
                     "license": detect(pylic.read_text(errors="replace")).replace("UNKNOWN", "PSF-2.0"), "source": str(pylic.relative_to(rt))})
    for meta in sorted(root.glob("lib/python3*/site-packages/*.dist-info/METADATA")):
        hdr = meta.read_text(errors="replace").split("\n\n", 1)[0]
        get = lambda k: [l.split(":", 1)[1].strip() for l in hdr.splitlines() if l.startswith(k + ":")]
        name, ver = (get("Name") or ["?"])[0], (get("Version") or ["?"])[0]
        lic = (get("License-Expression") or [""])[0]
        if not lic:
            raw = (get("License") or [""])[0]
            lic = raw if raw and len(raw) < 60 and raw.upper() != "UNKNOWN" else ""
        if not lic:
            cls = [c.split("::")[-1].strip() for c in get("Classifier") if c.startswith("License ::")]
            lic = "; ".join(cls)
        if not lic:
            files = sorted(p for p in meta.parent.rglob("*") if p.is_file() and re.match(r"(?i)(licen[cs]e|copying)", p.name))
            lic = " AND ".join(dict.fromkeys(detect(p.read_text(errors="replace")) for p in files)) if files else "UNKNOWN"
        rows.append({"kind": "runtime", "name": name, "version": ver, "license": lic or "UNKNOWN", "source": str(meta.parent.relative_to(rt))})
    return rows


# ---------------------------------------------------------------- output
def md_escape(s: str) -> str:
    return (s or "").replace("|", "\\|").replace("\n", " ")


def write_md(out: Path, data: dict):
    L = []
    L.append("# Acknowledgments\n")
    L.append("<!-- GENERATED by `python3 -I tools/acknowledgments.py` (M0.T12, S-7). Do not edit by hand. -->\n")
    L.append(f"Generated {data['generated']} from `Package.resolved`, `Vendor/VENDORED.json`, the `Binaries/` submodules, "
             "`Ported from` headers, the M0 model list and the video runtime. The licence texts of the SwiftPM "
             "packages, helper-binary sources, vendored donors and ported code are reproduced in full below.\n")
    L.append("## Summary\n")
    L.append("| Kind | Component | Version / ref | Licence | Note |\n|---|---|---|---|---|")
    for r in data["swiftpm"] + data["binaries"] + data["ported"]:
        L.append(f"| {r['kind']} | [{r['name']}](https://github.com/{r['repo']}) | `{r['version']}` @ `{r['ref'][:7]}` | {r['license']} | {md_escape(r['note'])} |")
    for v in data["vendored"]:
        L.append(f"| vendored | [{v['name']}]({v['repo']}) | `{v['ref'][:7]}` ({v['rows']} files: {', '.join(f'{k} {n}' for k, n in sorted(v['modes'].items()))}) | {v['license']} | `{v['license_file']}` |")
    L.append("")
    L.append("## Third-party code inside the helper binaries\n")
    L.append("Compiled into `llama-server`, `sd-server` and `sd-cli` from the pinned submodules; their licence texts "
             "ship with the source at the pinned revision.\n")
    L.append("| Component | Licence | Licence source |\n|---|---|---|")
    for r in data["embedded"]:
        L.append(f"| `{r['name']}` | {r['license']} | `{md_escape(r['source'])}` |")
    L.append("")
    if data["artifacts"]:
        L.append("## SwiftPM binary artefacts\n")
        L.append("| Artefact | Licence (bundled LICENSE) | Third-party notices |\n|---|---|---|")
        for r in data["artifacts"]:
            tpn = r.get("third_party_notices")
            tpn_s = (f"[ThirdPartyNotices.txt]({tpn['url']}) (sha256 `{tpn['sha256'][:16]}…`, {tpn['bytes']} bytes); "
                     "to be bundled into the app's Resources by the M10 release pipeline (G-061)") if tpn else "—"
            L.append(f"| `{r['name']}` | {r['license']} | {tpn_s} |")
        L.append("")
    L.append("## NOTICE duties (Apache-2.0 §4(d))\n")
    any_notice = False
    for r in data["swiftpm"] + data["binaries"] + data["ported"] + [v | {"ref": v["ref"]} for v in data["vendored"]]:
        if r.get("notice"):
            any_notice = True
            L.append(f"### {r['name']} @ `{r['ref'][:7]}` — `{r['notice']['file']}` (copied verbatim)\n")
            L.append("```text\n" + r["notice"]["text"].strip() + "\n```\n")
    if not any_notice:
        L.append("No dependency at its pinned revision ships a NOTICE file.\n")
    no_notice = [r["name"] for r in data["swiftpm"] + data["binaries"] + data["vendored"] if "Apache-2.0" in r["license"] and not r.get("notice")]
    if no_notice:
        L.append("Apache-2.0 components **without** a NOTICE file at the pinned revision (so no NOTICE text to carry): "
                 + ", ".join(f"`{n}`" for n in no_notice) + ".\n")
    L.append("## Design references (no code copied)\n")
    L.append("These projects informed behaviour and design only. No source file, asset or text was copied, so no "
             "licence notice or NOTICE file is owed; they are listed for credit.\n")
    L.append("| Project | Ref | Licence | Used for |\n|---|---|---|---|")
    for r in data["design"]:
        L.append(f"| [{r['name']}](https://github.com/{r['name']}) | `{r['version']}` | {r['license']} | {r['what']} |")
    L.append("")
    L.append("## Models (downloaded at run time, not shipped in the app)\n")
    L.append("| Key | Repository @ revision | Licence | Recorded in |\n|---|---|---|---|")
    for r in data["models"]:
        L.append(f"| `{r['name']}` | [{r['repo']}](https://huggingface.co/{r['repo']}) @ `{r['ref']}` | {r['license']} | {md_escape(r['source'])} |")
    L.append("")
    if data["runtime"]:
        L.append("## Video runtime (separate download, `video-runtime-<ver>.zip`)\n")
        L.append("| Distribution | Version | Licence |\n|---|---|---|")
        for r in data["runtime"]:
            L.append(f"| {r['name']} | {r['version']} | {md_escape(r['license'])} |")
        L.append("\nThe full licence texts of the runtime's distributions ship inside the runtime (`*.dist-info/`, "
                 "`lib/python3.12/LICENSE.txt`).\n")
    L.append("## Licence texts\n")
    seen: dict[str, str] = {}
    for r in data["swiftpm"] + data["binaries"] + data["ported"] + [v | {"version": v["ref"][:7]} for v in data["vendored"]]:
        text = (r.get("text") or "").strip()
        title = f"{r['name']} ({r['license']})"
        if not text:
            continue
        h = hashlib.sha256(re.sub(r"\s+", " ", text).encode()).hexdigest()
        if h in seen:
            L.append(f"### {title}\n\nSame text as **{seen[h]}** above.\n")
            continue
        seen[h] = r["name"]
        L.append(f"### {title}\n\n```text\n{text}\n```\n")
    out.write_text("\n".join(L) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--cache", default=str(CACHE_PATH), help="HTTP cache file (default build/acknowledgments/cache.json)")
    ap.add_argument("--verify-models", action="store_true", help="re-read every model's HF card online and compare it with the recorded licence")
    ap.add_argument("--runtime", default=str(ROOT / "build/runtimes/video-runtime-unzipped"))
    ap.add_argument("--out", default=str(ROOT / "ACKNOWLEDGMENTS.md"))
    ap.add_argument("--json", default=str(ROOT / "build/acknowledgments/summary.json"))
    ap.add_argument("--binaries-src", default=str(ROOT / "Binaries"), help="checkout holding llama.cpp/ and sdcpp/ (vendor/, thirdparty/)")
    ap.add_argument("--gitlink", action="append", default=[], help="PATH=SHA for submodules (default: Binaries/checksums.json)")
    a = ap.parse_args()
    f = Fetcher(a.offline, Path(a.cache))
    errors: list[str] = []
    gitlinks = dict(g.split("=", 1) for g in a.gitlink)
    data = {"generated": time.strftime("%Y-%m-%d", time.gmtime())}
    data["swiftpm"] = swiftpm(f)
    data["vendored"], data["vendor_check"] = vendored(errors, f)
    data["binaries"] = submodules(f, gitlinks, Path(a.binaries_src))
    data["embedded"] = embedded(Path(a.binaries_src), f)
    if not data["embedded"]:
        errors.append(f"no llama.cpp/vendor or sdcpp/thirdparty under {a.binaries_src} (pass --binaries-src)")
    data["artifacts"] = artifacts(f, ROOT / "build" / "dd")
    data["ported"] = ported(f)
    data["design"] = design_refs(f)
    data["models"] = models(f, errors, verify=a.verify_models)
    rt = Path(a.runtime)
    data["runtime"] = runtime(rt) if rt.is_dir() else []
    f.save()
    unknown = [f"{r['kind']}:{r['name']}" for k in ("swiftpm", "binaries", "embedded", "artifacts", "ported", "design", "models", "runtime") for r in data[k] if "UNKNOWN" in r["license"]]
    errors += [f"UNKNOWN licence: {u}" for u in unknown]
    write_md(Path(a.out), data)
    slim = {k: ([{kk: vv for kk, vv in r.items() if kk not in ("text",)} for r in v] if isinstance(v, list) else v) for k, v in data.items()}
    slim["errors"] = errors
    slim["api_rate_limited"] = f.api_blocked
    Path(a.json).parent.mkdir(parents=True, exist_ok=True)
    Path(a.json).write_text(json.dumps(slim, indent=1, default=str))
    for k in ("swiftpm", "binaries", "ported", "design"):
        for r in data[k]:
            print(f"{k:8} {r['name']:40} {r['license']:24} api={r.get('api_spdx')} file={r.get('license_file')} notice={(r.get('notice') or {}).get('file')}")
    for r in data["embedded"]:
        print(f"embedded {r['name']:40} {r['license']:24} {r['source'][:80]}")
    for r in data["models"]:
        print(f"model    {r['name']:14} {r['repo']:50} {r['license']}")
    print(f"runtime  {len(data['runtime'])} distributions; vendored rows {data['vendor_check']['rows']}; donor-dir extra files {data['vendor_check']['donor_dir_extra_files']}")
    for e in errors:
        print("[FAIL]", e)
    print("acknowledgments:", "pass" if not errors else f"{len(errors)} error(s)", "->", a.out)
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
