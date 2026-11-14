#!/usr/bin/env python3
"""M2.T08: the deterministic download fixtures (AT-NFR-D6, AT-204). Run with `python3 -I`.

  make-blobs.py --seed 7 [--out fixtures/downloads] [--only blob-300m] [--check]

Writes `blob-300m.bin` (300 MiB) and `blob-1200m.bin` (1200 MiB) from `random.Random(seed)` in 4 MiB blocks; the
blobs are not committed (fixtures/downloads/.gitignore), their sha256 is pinned in `<out>/lock.json`. An existing
file with the pinned size and sha256 is kept. `--check` only verifies. A sha256 that differs from the lock fails
(the generator drifted); `--write-lock` records new values instead.
"""
import argparse, hashlib, json, os, random, sys

BLOBS = {"blob-300m.bin": 300 * 1024 * 1024, "blob-1200m.bin": 1200 * 1024 * 1024}
BLOCK = 4 * 1024 * 1024


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while b := f.read(BLOCK):
            h.update(b)
    return h.hexdigest()


def generate(path, size, seed):
    rnd = random.Random(f"{seed}:{os.path.basename(path)}")
    h = hashlib.sha256()
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        left = size
        while left:
            b = rnd.randbytes(min(BLOCK, left))
            f.write(b)
            h.update(b)
            left -= len(b)
    os.replace(tmp, path)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "../../fixtures/downloads"))
    ap.add_argument("--only", action="append")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--write-lock", action="store_true")
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    lock_path = os.path.join(out, "lock.json")
    lock = json.load(open(lock_path)) if os.path.exists(lock_path) else {"seed": a.seed, "files": {}}
    bad = 0
    for name, size in BLOBS.items():
        if a.only and name not in a.only:
            continue
        path = os.path.join(out, name)
        want = lock["files"].get(name, {}).get("sha256")
        if os.path.exists(path) and os.path.getsize(path) == size and want and sha256(path) == want:
            print(f"ok   {name} {want}")
            continue
        if a.check:
            print(f"FAIL {name}: missing or not matching lock.json"); bad += 1; continue
        got = generate(path, size, a.seed)
        if want and got != want and not a.write_lock:
            print(f"FAIL {name}: generated {got} != lock {want}"); bad += 1; continue
        lock["files"][name] = {"size": size, "sha256": got}
        print(f"made {name} {got}")
    if a.write_lock or not os.path.exists(lock_path):
        lock["seed"] = a.seed
        with open(lock_path, "w") as f:
            json.dump(lock, f, indent=2, sort_keys=True)
            f.write("\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
