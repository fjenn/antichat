#!/usr/bin/env python3
"""Build the AntiChat video runtime (M5.T01; P-media-11). Run: `make runtime-video [SIGN=1] [CHECK=1]`
(= `python3 -I tools/runtime/build_video_runtime.py`). Moved from the M0.T07 spike's Runtimes/video-runtime/build.py;
`Runtimes/video-runtime/` now holds only the lock inputs (requirements.in, requirements.lock, base.sha256).

Port of the bundling flow of Blaizzy/nativ@72f4b9192ffc258f10a543d774e44d8db1a81ebb
`PythonDistribution/Scripts/build_mlx_vlm_server.py` (MIT): download python-build-standalone
`install_only_stripped`, safe-extract, install pinned wheels, verify the imports. Differences (D-014): the
tarball is pinned by sha256 (`base.sha256`), wheels by hash (`uv pip install --require-hashes`, Nativ used
`pip install` with `>=` pins), only binary wheels; the launcher is ours (tools/runtime/launcher/, Nativ's design).

Layout of `build/runtimes/video-runtime/` (the runtime root; the zip holds its contents, no parent folder):
  bin/python3.12                    CPython 3.12.16 (python-build-standalone 20261026, fa506e0)
  bin/video-runtime-launcher        clean env + `python3.12 -I -B -m antichat_video.server` (--selftest)
  lib/python3.12/site-packages/     wheels of requirements.lock + fastvideo/ (Vendor/FastVideo@d9e6c3e,
                                    allow-listed `vendored` rows) + antichat_video/ (our package)
  RUNTIME.json                      version, inputs and their hashes

Steps: [--check-lock] → fetch → extract → install → copy sources → prune → compileall → launcher → smoke → zip
(ditto, contents at the root) → size → dev overlay. The zip (the shipped runtime) has the release launcher and no
devtest module; only AFTER zipping does the local tree get the dev overlay (M5.T14 review): a launcher built with
-DANTICHAT_VIDEO_DEVTEST (`--pytest`) and antichat_video/devtest.py, for `make runtime-video-test`. Signing is tools/runtime/sign_video_runtime.sh (wraps
tools/release/sign-runtime.sh, M6.T16, D-026), run by `make runtime-video SIGN=1`.
Flags: --no-zip, --offline (cached tarball and uv cache only), --check-lock (re-resolve requirements.in and fail if
requirements.lock differs; no build).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "Runtimes" / "video-runtime"  # lock inputs only
LAUNCHER_C = ROOT / "tools" / "runtime" / "launcher" / "video_runtime_launcher.c"
VERSION = "0.3.5"  # 0.1.0 = the M0.T07 spike runtime; 0.2.0 = M5.T01 server stack; 0.3.0 = M5.T07 LTX-2.3 + sound;
# 0.3.1 = M5.T14 review: no file-writing driver, release launcher without --pytest (dev overlay only)
# 0.3.2 = NFR-VID3 memory miss: run_job collects and synchronises before clear_cache on every terminal path
# 0.3.3 = perf/t4-video (NFR-VID1): `/frames` serves the frames decoded so far while the job runs (the helper's final
#         check overlaps the decode); the DiT forward is compiled (upstream compile=True, bit-identical); decoded
#         frames go to RGBA8 on the GPU (byte-identical)
# 0.3.4 = fix/t05-video (VID2, NFR-F7): job fields `preview_short_side` (the helper asks for the gate's valid preview
#         size) and `preview_min_fraction` (no preview decode for steps the helper never shows); defaults = 0.3.3
# 0.3.5 = fix/t05-video-t4 (NFR-VID1 T4 footprint): a step preview is decoded one latent frame at a time with carried
#         TAEHV state, MLX's buffer cache dropped before and after, instead of one-shot at full resolution beside the
#         DiT (+19 GB at T4)
PBS_TAG = "20261026"
PBS_COMMIT = "fa506e0858ac9f2cc5b289c137b888a2aa24d1ee"
PBS_ASSET = "cpython-3.12.16+20261026-aarch64-apple-darwin-install_only_stripped.tar.gz"
PBS_URL = f"https://github.com/astral-sh/python-build-standalone/releases/download/{PBS_TAG}/{PBS_ASSET.replace('+', '%2B')}"
PYVER = "3.12"
FASTVIDEO = ROOT / "Vendor" / "FastVideo@d9e6c3e"
DRIVER = ROOT / "Packages" / "Engines" / "Python" / "antichat_video"
LTX = ROOT / "Vendor" / "ltx-2-mlx@895201d"  # M5.T07 (A-M5-04)
# Not needed by a headless MLX job; removing them also removes Mach-Os that would need signing.
PRUNE_STDLIB = ["ensurepip", "idlelib", "tkinter", "turtledemo", "turtle.py", "lib2to3", "pydoc_data",
                "lib-dynload/_tkinter.cpython-312-darwin.so", "test", "unittest/test"]
PRUNE_TOP = ["lib/tcl*", "lib/tk*", "lib/itcl*", "lib/thread*", "lib/libtcl*", "lib/libtk*", "lib/pkgconfig", "share",
             "include", "bin/idle3*", "bin/pydoc3*", "bin/2to3*", "bin/pip*", "bin/python3*-config"]


def log(msg: str) -> None:
    print(f"[runtime-video] {msg}", flush=True)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    log("$ " + " ".join(str(c) for c in cmd))
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def expected_base_sha() -> str:
    for line in (HERE / "base.sha256").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            digest, name = line.split()
            if name == PBS_ASSET:
                return digest
    raise SystemExit(f"{PBS_ASSET} not in base.sha256")


def fetch_base(cache: Path, offline: bool) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    dst = cache / PBS_ASSET
    want = expected_base_sha()
    if dst.exists() and sha256(dst) == want:
        log(f"[ok] cached {PBS_ASSET}")
        return dst
    if offline:
        raise SystemExit(f"offline and {dst} missing or wrong hash")
    log(f"download {PBS_URL}")
    tmp = dst.with_suffix(".part")
    with urllib.request.urlopen(urllib.request.Request(PBS_URL, headers={"User-Agent": "AntiChat-runtime-build"}), timeout=120) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    got = sha256(tmp)
    if got != want:
        tmp.unlink()
        raise SystemExit(f"checksum mismatch for {PBS_ASSET}: {got} != {want}")
    tmp.replace(dst)
    return dst


def extract(tarball: Path, out: Path) -> None:
    staging = out.parent / (out.name + ".extract")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    with tarfile.open(tarball) as tar:
        tar.extractall(staging, filter="data")  # Nativ safe_extract_tar (Python ≥ 3.12 data filter)
    root = staging / "python"
    if not (root / "bin" / "python3").exists():
        raise SystemExit(f"no bin/python3 under {root}")
    shutil.rmtree(out, ignore_errors=True)
    root.rename(out)
    shutil.rmtree(staging)


def site_packages(out: Path) -> Path:
    return out / "lib" / f"python{PYVER}" / "site-packages"


def install(out: Path, offline: bool) -> None:
    py = out / "bin" / "python3"
    sp = site_packages(out)
    # The tarball ships pip/setuptools in site-packages; the runtime never installs anything itself.
    for d in list(sp.iterdir()):
        if d.name.startswith(("pip", "setuptools", "_distutils_hack", "distutils-precedence")):
            shutil.rmtree(d) if d.is_dir() else d.unlink()
    cmd = ["uv", "pip", "install", "--require-hashes", "--only-binary", ":all:", "--no-deps", "--python", py,
           "--target", sp, "-r", HERE / "requirements.lock"]
    if offline:
        cmd.append("--offline")
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="26.0", PYTHONNOUSERSITE="1")
    run(cmd, env=env)


def copy_sources(out: Path) -> list[str]:
    sp = site_packages(out)
    allow = [l.split("\t")[1] for l in (ROOT / "Vendor/FastVideo-allowlist.tsv").read_text().splitlines()
             if l.strip() and not l.startswith("#") and l.split("\t")[0] == "vendored"]
    for rel in allow:
        dst = sp / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(FASTVIDEO / rel, dst)
    shutil.copy2(FASTVIDEO / "LICENSE", sp / "fastvideo" / "LICENSE")
    shutil.copy2(FASTVIDEO / "ORIGIN", sp / "fastvideo" / "ORIGIN")
    # Upstream `fastvideo/__init__.py` and `mlx_runtime/__init__.py` import the torch pipeline and every
    # MLX model; the runtime ships empty package markers instead (our files, not vendored).
    stub = "# AntiChat video runtime: package marker (upstream __init__ imports the torch pipeline; A-M0-T07a).\n"
    (sp / "fastvideo" / "__init__.py").write_text(stub)
    (sp / "fastvideo" / "mlx_runtime" / "__init__.py").write_text(stub)
    # M5.T07: ltx-2-mlx's two packages, `packages/<pkg>/src/<module>/…` → site-packages/<module>/… (allow-listed rows).
    ltx = [l.split("\t")[1] for l in (ROOT / "Vendor/ltx-2-mlx-allowlist.tsv").read_text().splitlines()
           if l.strip() and not l.startswith("#") and l.split("\t")[0] == "vendored"]
    for mod in ("ltx_core_mlx", "ltx_pipelines_mlx"):
        shutil.rmtree(sp / mod, ignore_errors=True)
    for rel in ltx:
        dst = sp / rel.split("/src/", 1)[1]
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(LTX / rel, dst)
    for mod in ("ltx_core_mlx", "ltx_pipelines_mlx"):
        shutil.copy2(LTX / "LICENSE", sp / mod / "LICENSE")
        if (LTX / "ORIGIN").exists():
            shutil.copy2(LTX / "ORIGIN", sp / mod / "ORIGIN")
    allow = allow + ltx
    shutil.rmtree(sp / "antichat_video", ignore_errors=True)
    shutil.copytree(DRIVER, sp / "antichat_video", ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "tests", "devtest.py"))
    return allow


def prune(out: Path) -> None:
    std = out / "lib" / f"python{PYVER}"
    for rel in PRUNE_STDLIB:
        p = std / rel
        if p.is_dir():
            shutil.rmtree(p)
        elif p.exists():
            p.unlink()
    for pattern in PRUNE_TOP:
        for p in out.glob(pattern):
            if p.is_dir() and not p.is_symlink():
                shutil.rmtree(p)
            elif p.exists() or p.is_symlink():
                p.unlink()
    for p in list(out.rglob("__pycache__")):
        shutil.rmtree(p, ignore_errors=True)
    sp = site_packages(out)
    # A-M9-T05a: console-script shims (`uv pip install --target`) carry a #! to the build dir's interpreter, so the zip
    # depended on the checkout dir; nothing runs them (the launcher starts python directly). Their RECORD lines go too.
    shutil.rmtree(sp / "bin", ignore_errors=True)
    for rec in sp.glob("*.dist-info/RECORD"):
        lines = rec.read_text().splitlines(keepends=True)
        rec.write_text("".join(ln for ln in lines if not ln.startswith("bin/")))
    for d in ("numpy/_core/tests", "numpy/tests", "numpy/f2py", "numpy/testing/tests", "PIL/tests"):
        shutil.rmtree(sp / d, ignore_errors=True)
    for p in list(sp.rglob("tests")):
        if p.is_dir() and p.parent.name in ("numpy", "linalg", "fft", "random", "ma", "polynomial", "lib", "typing", "_core"):
            shutil.rmtree(p, ignore_errors=True)


def compile_all(out: Path) -> None:
    # Precompiled, hash-checked .pyc: the signed tree never needs to be written at run time
    # (the supervisor also sets PYTHONDONTWRITEBYTECODE=1).
    # A-M9-T05a: -s/-p strip the build path from co_filename (importlib fixes the name up at load time) and -B -f
    # rewrite the .pyc that compileall's own imports would otherwise leave with the full path, so the zip is the same
    # from every checkout dir (it was not: the catalog sha only reproduced in the worktree that built it).
    run([out / "bin" / "python3", "-I", "-B", "-m", "compileall", "-q", "-f", "-j", "0", "--invalidation-mode",
         "unchecked-hash", "-s", out, "-p", "/", out / "lib" / f"python{PYVER}"], stdout=subprocess.DEVNULL)


def smoke(out: Path) -> None:
    code = ("import sys, mlx.core as mx, numpy, safetensors, sentencepiece, PIL, fastapi, uvicorn; "
            "import fastvideo.mlx_runtime.wan22, fastvideo.mlx_runtime.wan22_sample, fastvideo.mlx_runtime.wan_vae; "
            "import antichat_video.server, antichat_video.wan22_generator, antichat_video.umt5, antichat_video.ltx_generator; "
            "import ltx_pipelines_mlx.distilled, ltx_core_mlx.model.video_vae.video_vae; "
            "assert 'torch' not in sys.modules, 'torch imported'; "
            "print(sys.version.split()[0], 'mlx', mx.__version__, 'numpy', numpy.__version__, 'metal', mx.metal.is_available())")
    env = {"PATH": "/usr/bin:/bin", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "HOME": os.environ.get("HOME", "/tmp")}
    run([out / "bin" / "python3", "-I", "-c", code], env=env)


def macho_files(root: Path) -> list[Path]:
    out = []
    for p in root.rglob("*"):
        if p.is_file() and not p.is_symlink():
            with open(p, "rb") as f:
                magic = f.read(4)
            if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
                out.append(p)
    return out


def build_launcher(out: Path, dev: bool = False) -> None:
    dst = out / "bin" / "video-runtime-launcher"
    flags = ["-DANTICHAT_VIDEO_DEVTEST=1"] if dev else []
    run(["clang", "-O2", "-Wall", "-Werror", "-arch", "arm64", "-mmacosx-version-min=26.0", *flags, "-o", dst, LAUNCHER_C])


def dev_overlay(out: Path) -> None:
    """The local dev tree only (never in the zip): `--pytest` launcher + the devtest module."""
    build_launcher(out, dev=True)
    shutil.copy2(DRIVER / "devtest.py", site_packages(out) / "antichat_video" / "devtest.py")
    log("dev overlay: launcher with --pytest + antichat_video/devtest.py (local tree only, not in the zip)")


LOCK_ARGS = ["--python-version", PYVER, "--python-platform", "aarch64-apple-darwin", "--only-binary", ":all:",
             "--generate-hashes", "--no-header"]


def check_lock() -> int:
    """`uv lock --check` for a requirements-style lock: re-resolve requirements.in and compare."""
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        fresh = Path(d) / "requirements.lock"
        env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="26.0")
        run(["uv", "pip", "compile", "Runtimes/video-runtime/requirements.in", *LOCK_ARGS, "-o", fresh], env=env, cwd=ROOT,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        same = fresh.read_text() == (HERE / "requirements.lock").read_text()
    log(f"lock check: {'ok' if same else 'requirements.lock is stale (re-run with uv pip compile)'}")
    return 0 if same else 1


def dir_size(p: Path) -> int:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file() and not f.is_symlink())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=str(ROOT / "build" / "runtimes"))
    ap.add_argument("--no-zip", action="store_true")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--check-lock", action="store_true")
    args = ap.parse_args()
    if args.check_lock:
        return check_lock()
    out_dir = Path(args.out_dir)
    out = out_dir / "video-runtime"
    tarball = fetch_base(out_dir / "cache", args.offline)
    extract(tarball, out)
    install(out, args.offline)
    allow = copy_sources(out)
    prune(out)
    compile_all(out)
    build_launcher(out)
    smoke(out)
    meta = {
        "name": "video-runtime", "version": VERSION,
        "python": {"release": PBS_TAG, "commit": PBS_COMMIT, "asset": PBS_ASSET, "sha256": expected_base_sha()},
        "requirements_lock_sha256": sha256(HERE / "requirements.lock"),
        "launcher_c_sha256": sha256(LAUNCHER_C),
        "fastvideo": {"repo": "hao-ai-lab/FastVideo", "ref": "d9e6c3eb82a16250fe17747d6dc797243bd8012f",
                      "files": {r: sha256(FASTVIDEO / r) for r in allow if not r.startswith("packages/ltx-")}},
        "ltx-2-mlx": {"repo": "dgrauet/ltx-2-mlx", "ref": "895201df379b079c2154738bcf92005b7a371923",
                      "files": {r: sha256(LTX / r) for r in allow if r.startswith("packages/ltx-")}},
        "driver": {str(p.relative_to(DRIVER)): sha256(p) for p in sorted(DRIVER.rglob("*.py"))
                   if "__pycache__" not in p.parts and p.name != "devtest.py"},
    }
    (out / "RUNTIME.json").write_text(json.dumps(meta, indent=1, sort_keys=True) + "\n")
    n = len(macho_files(out))
    log(f"runtime tree {dir_size(out) / 1e6:.1f} MB, {n} Mach-O files")
    if not args.no_zip:
        z = out_dir / f"video-runtime-{VERSION}.zip"
        z.unlink(missing_ok=True)
        # ditto keeps symlinks and modes; contents at the zip root (RuntimeInstaller unzips into <name>@<ver>/).
        run(["ditto", "-c", "-k", "--norsrc", out, z])
        size = {"zip_bytes": z.stat().st_size, "tree_bytes": dir_size(out), "macho_files": n, "zip": str(z.relative_to(ROOT))}
        (out_dir / "video-runtime-size.json").write_text(json.dumps(size, indent=1) + "\n")
        log(f"zip {z} {size['zip_bytes'] / 1e6:.1f} MB (tree {size['tree_bytes'] / 1e6:.1f} MB)")
    dev_overlay(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
