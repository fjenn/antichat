#!/usr/bin/env python3
"""Assemble the lawful ChildSafetyCheck calibration proxies (M0.T08 step 6; R-285 AC7; D-006, D-017).

Writes ONLY to ~/AntiChatPrivateFixtures/csc/ (never the repo, environment.md §4). Sets:

  age/utkface/   UTKFace aligned & cropped faces (Zhang et al., CVPR 2017), ages from the file names.
                 Mirror py97/UTKFace-Cropped@e80f21f (UTKFace.tar.gz, sha256 checked against the HF tree API).
                 Non-sexual face crops; licence: UTKFace non-commercial research use (mirror tag: MIT).
  age/lagenda/   LAGENDA benchmark (LayerTeam, CC BY 2.0; Open Images photos), person rows with face and
                 person boxes. Mirror uaebn/lagenda@9bb66bf. Non-sexual everyday photographs of people.
  nudity/        SFW rows only: the unique LAGENDA images sampled above (people-heavy everyday photos,
                 the hardest SFW case for over-blocking) + the 40 reviewed CC0 photos in fixtures/.
                 No adult NSFW rows are assembled by this script (see QUESTIONS.md Q-### for why).

Binding data rule: the age estimator is calibrated only on non-sexual faces; nothing here is sexual;
no image ever combines nudity with a minor. The script prints counts only, never file names.

Usage: python3 -I tools/m0/csc-prepare-proxies.py [--fixtures DIR] [--seed 8] [--jobs 1] [--skip-utkface]
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import hashlib
import json
import os
import random
import shutil
import tarfile
import time
import urllib.error
import urllib.request

HF = "https://huggingface.co"
UA = "AntiChat-csc-prepare/0.1"
ROOT = os.path.expanduser("~/AntiChatPrivateFixtures/csc")
UTK = ("py97/UTKFace-Cropped", "e80f21fb21fa3631380c3cb634b79be3ac2f4cba", "UTKFace.tar.gz")
LAG = ("uaebn/lagenda", "9bb66bf60c2ab640f6f995385b3e0e5558c63bf9", "lagenda_annotation.csv")
# Stratified sample sizes per true-age bucket (NFR-F2 buckets: ≤15, 16–17, ≥30; 18–29 reported too).
BUCKETS = [("le15", 0, 15, 1500), ("16_17", 16, 17, 600), ("18_29", 18, 29, 800), ("ge30", 30, 200, 1500)]
# LAGENDA images are fetched one by one through the HF resolver, whose anonymous quota (3000 per 5 min,
# shared with every other HF download on this IP) is the limit; so a smaller sample, paced at ~3 req/s.
LAG_BUCKETS = [("le15", 0, 15, 600), ("16_17", 16, 17, 400), ("18_29", 18, 29, 300), ("ge30", 30, 200, 600)]
PACE_S = 0.33


def get(url: str, dest: str) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    tmp = dest + ".part"
    for attempt in range(8):
        try:
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            os.replace(tmp, dest)
            return
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 7:
                raise
            time.sleep(min(300, int(e.headers.get("Retry-After") or 60)) + 1)  # honour the HF quota
        except Exception:
            if attempt >= 3:
                raise
            time.sleep(2)


def lfs_oid(repo: str, sha: str, path: str) -> str | None:
    url = f"{HF}/api/datasets/{repo}/tree/{sha}"
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60) as r:
        for f in json.load(r):
            if f["path"] == path:
                return (f.get("lfs") or {}).get("oid")
    return None


def gated(repo: str) -> object:
    with urllib.request.urlopen(urllib.request.Request(f"{HF}/api/datasets/{repo}", headers={"User-Agent": UA}), timeout=60) as r:
        return json.load(r).get("gated")


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_verified(repo: str, sha: str, path: str, dest: str) -> None:
    if gated(repo) is not False:
        raise SystemExit(f"refused: {repo} is gated (D-007)")
    oid = lfs_oid(repo, sha, path)
    if not (os.path.exists(dest) and oid and sha256(dest) == oid):
        get(f"{HF}/datasets/{repo}/resolve/{sha}/{path}", dest)
    if oid and sha256(dest) != oid:
        raise SystemExit(f"checksum mismatch for {repo}:{path}")


def sample(rows: list, key, rng: random.Random, buckets=BUCKETS) -> list:
    out = []
    for name, lo, hi, n in buckets:
        pool = [r for r in rows if lo <= key(r) <= hi]
        rng.shuffle(pool)
        out += pool[:n]
        print(f"  bucket {name}: available {len(pool)}, sampled {min(n, len(pool))}")
    return out


def utkface(rng: random.Random) -> None:
    dl = os.path.join(ROOT, "_dl", "utkface")
    os.makedirs(dl, exist_ok=True)
    tgz = os.path.join(dl, UTK[2])
    fetch_verified(*UTK, tgz)
    rows = []
    with tarfile.open(tgz) as tf:
        members = [m for m in tf.getmembers() if m.isfile() and m.name.lower().endswith(".jpg")]
        for m in members:
            try:
                age = int(os.path.basename(m.name).split("_")[0])
            except ValueError:
                continue
            rows.append((m, age))
        print(f"utkface: {len(rows)} labelled faces")
        picked = sample(rows, lambda r: r[1], rng)
        out = os.path.join(ROOT, "age", "utkface")
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(os.path.join(out, "img"))
        with open(os.path.join(out, "ages.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["file", "age"])
            for i, (m, age) in enumerate(picked):
                rel = f"img/{i:05d}.jpg"
                with tf.extractfile(m) as src, open(os.path.join(out, rel), "wb") as dst:
                    shutil.copyfileobj(src, dst)
                w.writerow([rel, age])
    print(f"utkface: wrote {len(picked)} rows")


def mirror_files(dl: str) -> set[str]:
    """Image paths present in the pinned mirror (tree API, paginated; cached). The annotation CSV lists
    more images than the mirror holds, and each missing one would cost a resolver request."""
    cache = os.path.join(dl, "lag_benchmark-files.json")
    if os.path.exists(cache):
        return set(json.load(open(cache)))
    url, files = f"{HF}/api/datasets/{LAG[0]}/tree/{LAG[1]}/lag_benchmark?limit=1000", []
    while url:
        for attempt in range(6):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=60) as r:
                    files += [f["path"] for f in json.load(r) if f.get("type") == "file"]
                    nxt = None
                    for part in (r.headers.get("Link") or "").split(","):
                        if 'rel="next"' in part:
                            nxt = part.split(";")[0].strip().strip("<>")
                    url = nxt
                break
            except urllib.error.HTTPError as e:
                if e.code != 429 or attempt == 5:
                    raise
                time.sleep(min(300, int(e.headers.get("Retry-After") or 60)) + 1)
    json.dump(sorted(files), open(cache, "w"))
    return set(files)


def lagenda(rng: random.Random, jobs: int) -> list[str]:
    dl = os.path.join(ROOT, "_dl", "lagenda")
    os.makedirs(dl, exist_ok=True)
    ann = os.path.join(dl, LAG[2])
    fetch_verified(*LAG, ann)
    rows, seen = [], set()
    with open(ann, newline="") as f:
        for r in csv.DictReader(f):
            try:
                age = int(float(r["age"]))
                face = [int(float(r[f"face_{k}"])) for k in ("x0", "y0", "x1", "y1")]
            except (ValueError, KeyError):
                continue
            if age < 0 or min(face) < 0 or face[2] <= face[0] or face[3] <= face[1]:
                continue
            key = (r["img_name"], tuple(face))
            if key in seen:  # the mirror's CSV repeats rows
                continue
            seen.add(key)
            rows.append(r | {"_age": age})
    print(f"lagenda: {len(rows)} unique person rows with a face box and an age")
    present = mirror_files(dl)
    rows = [r for r in rows if r["img_name"] in present]
    print(f"lagenda: {len(rows)} rows whose image is in the mirror ({len(present)} images listed)")
    picked = sample(rows, lambda r: r["_age"], rng, LAG_BUCKETS)
    images = sorted({r["img_name"] for r in picked})
    out = os.path.join(ROOT, "age", "lagenda")
    manifest = os.path.join(out, ".sample.json")  # ids are only reusable for the same sample
    if not (os.path.exists(manifest) and json.load(open(manifest)) == images):
        shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, "img"), exist_ok=True)
    json.dump(images, open(manifest, "w"))
    ids = {name: f"img/{i:05d}.jpg" for i, name in enumerate(images)}

    def one(name: str) -> bool:
        dest = os.path.join(out, ids[name])
        if os.path.exists(dest) and os.path.getsize(dest) > 0:
            return True
        try:
            time.sleep(PACE_S)
            get(f"{HF}/datasets/{LAG[0]}/resolve/{LAG[1]}/{name}", dest)
            return True
        except Exception:
            return False

    with cf.ThreadPoolExecutor(jobs) as ex:
        ok = dict(zip(images, ex.map(one, images)))
    print(f"lagenda: {sum(ok.values())}/{len(images)} images downloaded")
    cols = ["face_x0", "face_y0", "face_x1", "face_y1", "person_x0", "person_y0", "person_x1", "person_y1"]
    with open(os.path.join(out, "ages.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file", "age"] + cols)
        n = 0
        for r in picked:
            if ok.get(r["img_name"]):
                w.writerow([ids[r["img_name"]], r["_age"]] + [r[c] for c in cols])
                n += 1
    print(f"lagenda: wrote {n} rows")
    return [os.path.join(out, ids[name]) for name in images if ok[name]]


def nudity_sfw(lagenda_images: list[str], fixtures: str) -> None:
    out = os.path.join(ROOT, "nudity")
    shutil.rmtree(os.path.join(out, "sfw"), ignore_errors=True)
    os.makedirs(os.path.join(out, "sfw"))
    srcs = list(lagenda_images)
    cc0 = os.path.join(fixtures, "images", "photos-cc0")
    if os.path.isdir(cc0):
        srcs += sorted(os.path.join(cc0, f) for f in os.listdir(cc0) if f.lower().endswith(".jpg"))
    labels = os.path.join(out, "labels.csv")
    # Keep any adult NSFW rows a human added later (label nsfw_adult); rewrite the SFW rows.
    keep = []
    if os.path.exists(labels):
        with open(labels, newline="") as f:
            keep = [r for r in csv.DictReader(f) if r.get("label") == "nsfw_adult"]
    with open(labels, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["file", "label"])
        for r in keep:
            w.writerow([r["file"], r["label"]])
        for i, s in enumerate(srcs):
            rel = f"sfw/{i:05d}.jpg"
            os.link(s, os.path.join(out, rel)) if os.stat(s).st_dev == os.stat(out).st_dev else shutil.copy(s, os.path.join(out, rel))
            w.writerow([rel, "sfw"])
    print(f"nudity: {len(srcs)} sfw rows, {len(keep)} nsfw_adult rows kept")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixtures", default=os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "fixtures"))
    ap.add_argument("--seed", type=int, default=8)
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--skip-utkface", action="store_true")
    a = ap.parse_args()
    os.makedirs(ROOT, exist_ok=True)
    if not a.skip_utkface:
        utkface(random.Random(a.seed))
    imgs = lagenda(random.Random(a.seed), a.jobs)
    nudity_sfw(imgs, a.fixtures)
    with open(os.path.join(ROOT, "SOURCES.md"), "w") as f:
        f.write(__doc__ + f"\nseed={a.seed}; buckets={BUCKETS}\n")


if __name__ == "__main__":
    main()
