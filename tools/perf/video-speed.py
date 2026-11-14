#!/usr/bin/env python3
"""The video speed table (M5.T08 step 3; R-046, G-046, P-media-12; K-015). Stdlib, run with `python3 -I`.

Writes `catalog/video-speed.yaml` (the reviewed source) and its bundled copy
`Packages/Harness/Resources/video-speed.json` (what `VideoEstimator` reads; A-M5-10: bundled until the catalog
carries the table). One row per speed class × preset:

  encode_s            fixed cost of a job: request → first step (text encode, weight load, scheduling) + the mux,
                      i.e. final − denoise − decode of each run (median)
  t_step_s            one denoise step (median denoise ÷ steps)
  decode_s_per_frame  latent → RGBA decode per output frame (median decode ÷ frames)
  peak_gb             the job's memory peak (1 GB = 1e9 B), compared with the budget B (fits / tight / exceeds)
  source              measured (S4, this Mac) | scaled (S1–S3 = S4 × pp512(M5 Max) ÷ pp512(class reference chip))

Every time term scales with pp512 (K-015; the same conservative rule as tools/perf/vid-scale.py: text encode, load
and mux do not really scale, they are < 20 % of a job on S4). peak_gb does not scale. Scaled rows are hypotheses for
hardware we do not have (D-003); the local history factor (VideoHistory, median of the last 5 runs) corrects them.

  video-speed.py --from-raw [--raw-dir build/perf/raw]     rebuild the table from existing bench rows (no GPU)
  video-speed.py --run --bin <AntiChat binary> --runtime <video-runtime dir> [--runs 3]
        runs each S4 preset 3× through the real runtime (the app's `-Bench video` path: XPC → helper → VideoEngine →
        MediaJobRunner, gate included), then rebuilds the table. GPU job: run it through
        `~/AntiChat-tools/gpu-run.sh timing -- python3 -I tools/perf/video-speed.py --run …` (exit 75 = deferred).
  video-speed.py --check                                   the bundled JSON equals the YAML rows (CI-safe, no raw rows)

Raw rows: `build/perf/raw/video-t2v-480p.jsonl`, `video-t2v-720p.jsonl`, `video-i2v-480p.jsonl` (M0.T07 spike,
docs/research/07-spikes/S-10-video-runtime.md), or `video-speed-<preset>.jsonl` written by `--run`.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
YAML = os.path.join(ROOT, "catalog", "video-speed.yaml")
JSON = os.path.join(ROOT, "Packages", "Harness", "Resources", "video-speed.json")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scale import CHIPS  # noqa: E402  (pp512 table, hardware-tiers §1.1)

SRC_CHIP = "M5 Max"
# The class reference chips of tools/perf/vid-scale.py (hardware-tiers §2.3; the class's common chip).
CLASS_CHIP = {"S1": "M4", "S2": "M4 Pro", "S3": "M5"}
GIB = 1024 ** 3 / 1e9

# Preset geometry = the M0.T07 bench clips (Wan2.2: frames = 4k + 1; ≈ 3 s at 24 fps). M5.T09's video-presets.yaml
# picks among these keys per tier × speed class.
PRESETS = [
    {"key": "t2v-480p-short", "model": "vid-5b", "mode": "t2v", "width": 832, "height": 480, "frames": 73, "steps": 3,
     "raw": ["video-speed-t2v-480p-short", "video-t2v-480p"]},
    {"key": "t2v-720p-short", "model": "vid-5b", "mode": "t2v", "width": 1280, "height": 704, "frames": 81, "steps": 3,
     "raw": ["video-speed-t2v-720p-short", "video-t2v-720p"]},
    {"key": "i2v-480p-short", "model": "vid-i2v", "mode": "i2v", "width": 832, "height": 480, "frames": 73, "steps": 20,
     "raw": ["video-speed-i2v-480p-short", "video-i2v-480p"]},
    # M5.T10: LTX-2.3 with sound (vid-ltx + vid-ltx-te, M5.T07), 8 + 3 distilled steps, frames = 8k + 1. One real run
    # (build/at/AT-292/2026-11-08-test_ltx.log): the runtime reports generate = text encode + denoise as one stage, so
    # encode is folded into t_step; the audio decode (5.3 s) and the mux are the fixed part; decode peak 24.9 GiB.
    {"key": "t2v-ltx-512p-short", "model": "vid-ltx", "mode": "t2v", "width": 768, "height": 512, "frames": 97, "steps": 11,
     "raw": ["video-speed-t2v-ltx-512p-short"],
     "note": "LTX sound (8+3 steps): encode folded into t_step; fixed = audio decode + mux; measured n=1"},
]


class PresetMismatch(SystemExit):
    """A raw row ran another model or size than its preset asked for (fix/t05-video: `--res ltx` ran vid-5b at
    832×480 and the table was built from it). Exits 3 with every mismatch named."""


def actual(r: dict) -> dict:
    """What a `-Bench video` row actually ran: the model (the request's model key; older rows: `model`, else the model
    dir's name) and the clip size (the MP4's `meta_*`, i.e. the runtime's `frames_ready`; older rows: `out_*`, then
    the request's size). None = the row does not say."""
    def first(*keys):
        for k in keys:
            v = r.get(k)
            if v not in (None, "", -1):
                return v
        return None
    model = first("model_key", "meta_model", "model") or (os.path.basename(r["model_dir"]) if r.get("model_dir") else None)
    w, h, f = first("meta_width", "out_width", "width"), first("meta_height", "out_height", "height"), first("meta_frames", "out_frames", "frames")
    return {"model": model, "width": int(w) if w is not None else None, "height": int(h) if h is not None else None,
            "frames": int(f) if f is not None else None}


def mismatches(preset: dict, rr: list[dict], strict: bool) -> list[str]:
    """Rows whose model / width / height / frames differ from the preset. `strict` (rows `--run` just wrote): a value
    the row does not report is a mismatch too; older rows (`--from-raw`) may lack the model (M0 spike rows)."""
    out = []
    for r in rr:
        got = actual(r)
        for k in ("model", "width", "height", "frames"):
            if got[k] is None and not strict:
                continue
            if got[k] != preset[k]:
                out.append(f"{preset['key']} run {r.get('run')}: {k} {got[k]!r} != asked {preset[k]!r}")
    return out


def check_rows(preset: dict, name: str, rr: list[dict], strict: bool) -> None:
    bad = mismatches(preset, rr, strict)
    if bad:
        print(f"video-speed: FAIL {name}.jsonl did not run preset {preset['key']} as asked:", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        raise PresetMismatch(3)


def rows(raw_dir: str, names: list[str]) -> tuple[str, list[dict]]:
    for n in names:
        p = os.path.join(raw_dir, n + ".jsonl")
        if os.path.exists(p):
            rr = [json.loads(l) for l in open(p) if l.strip()]
            rr = [r for r in rr if r.get("run", -1) >= 0 and r.get("status") == "completed"]
            if rr:
                return n, rr
    return "", []


def med(xs):
    xs = [x for x in xs if isinstance(x, (int, float)) and x >= 0]
    return statistics.median(xs) if xs else None


def child_stages(r: dict) -> dict:
    """fix/t05-video: the LTX runtime reports its text encode + denoise as one `generate_s` stage (ltx_generator.py);
    the table folds encode into t_step for LTX anyway (preset note), so `generate_s` stands in for `denoise_s`."""
    if r.get("h_child_denoise_s") is None and r.get("h_child_generate_s") is not None:
        return dict(r, h_child_denoise_s=r["h_child_generate_s"])
    return r


def s4_row(preset: dict, rr: list[dict]) -> dict:
    steps, frames = preset["steps"], preset["frames"]
    rr = [child_stages(r) for r in rr]
    if all(r.get("h_child_denoise_s") is not None for r in rr):
        # The runtime reports its stages (child clock): split exactly.
        denoise = med([r["h_child_denoise_s"] for r in rr])
        decode = med([r.get("h_child_decode_s") or 0 for r in rr])
        fixed = med([r["final_s"] - r["h_child_denoise_s"] - (r.get("h_child_decode_s") or 0) for r in rr])
        peak_gib = max(max(r.get("h_child_te_peak_gib") or 0, r.get("h_child_denoise_peak_gib") or 0,
                           r.get("h_child_decode_peak_gib") or 0) for r in rr)
        # M5.T02 decodes in chunks (frames.py StreamingTAEHV: decode peak 3.6 GiB), so the old one-shot decode peak
        # (A-M0-T07d, 26 GiB at 720p) is not the job peak; the text encoder / DiT peak is.
        peak = peak_gib * GIB
        note = "stage split from the runtime's child clock"
    else:
        # sd.cpp I2V reports steps only: first step at t1, the rest evenly to the exit; decode folds into the steps.
        # M9.T05: rows without the child exit time (sd.cpp I2V metrics absent) fall back to the job's final time.
        t_step = med([(r.get("h_child_exit_s", r["final_s"]) - r["first_step_s"]) / max(1, steps - 1) for r in rr])
        denoise = t_step * steps
        decode = 0.0
        fixed = med([r["final_s"] - t_step * steps for r in rr])
        peak = max((r.get("h_peak_helper_child_bytes") or r.get("peak_footprint_bytes") or 0) for r in rr) / 1e9
        note = "steps only (sd.cpp): decode folded into t_step"
    return {
        "speed_class": "S4", "preset": preset["key"],
        "encode_s": round(fixed, 3), "t_step_s": round(denoise / steps, 4),
        "decode_s_per_frame": round(decode / frames, 5), "peak_gb": round(peak, 2),
        "source": "measured", "n": len(rr), "note": preset.get("note", note),
    }


def scaled(row: dict, cls: str) -> dict:
    f = CHIPS[SRC_CHIP][1] / CHIPS[CLASS_CHIP[cls]][1]
    return dict(row, speed_class=cls, encode_s=round(row["encode_s"] * f, 3), t_step_s=round(row["t_step_s"] * f, 4),
                decode_s_per_frame=round(row["decode_s_per_frame"] * f, 5), source="scaled",
                note=f"S4 × pp512 {CHIPS[SRC_CHIP][1]} / {CHIPS[CLASS_CHIP[cls]][1]} ({CLASS_CHIP[cls]}) = × {f:.3f}")


def table(raw_dir: str) -> dict:
    out_rows, presets, sources = [], [], {}
    for p in PRESETS:
        name, rr = rows(raw_dir, p["raw"])
        if not rr:
            print(f"[skip] {p['key']}: no completed raw rows in {raw_dir}", file=sys.stderr)
            continue
        check_rows(p, name, rr, strict=name == p["raw"][0])  # rows `--run` writes must say what they ran
        sources[p["key"]] = f"build/perf/raw/{name}.jsonl"
        presets.append({k: p[k] for k in ("key", "model", "mode", "width", "height", "frames", "steps")})
        s4 = s4_row(p, rr)
        out_rows.append(s4)
        out_rows.extend(scaled(s4, c) for c in ("S3", "S2", "S1"))
    return {
        "schema": 1,
        "reference": {"chip": SRC_CHIP, "speed_class": "S4", "pp512": CHIPS[SRC_CHIP][1]},
        "class_reference": {c: {"chip": ch, "pp512": CHIPS[ch][1]} for c, ch in CLASS_CHIP.items()},
        "raw": sources,
        "presets": presets,
        "rows": sorted(out_rows, key=lambda r: (r["preset"], r["speed_class"])),
    }


def write(t: dict) -> None:
    lines = [
        "# Video speed table (M5.T08; R-046, G-046, P-media-12; K-015). GENERATED by tools/perf/video-speed.py — edit",
        "# the script or re-run it, not this file. Bundled copy: Packages/Harness/Resources/video-speed.json (A-M5-10).",
        "# estimate_s = (encode_s + steps × t_step_s + frames × decode_s_per_frame) × history factor (VideoEstimator).",
        "# S4 rows: measured on the dev Mac (M5 Max, warm cache, n runs, medians). S1–S3: S4 × the pp512 ratio of the",
        "# class reference chip (hypotheses, D-003; the local history factor corrects them after 5 runs).",
        "# Each row and preset is one JSON-compatible flow mapping per line (VideoEstimatorTests.yamlMatchesBundledJSON reads them).",
        f"schema: {t['schema']}",
        f"reference: {json.dumps(t['reference'], ensure_ascii=False)}",
        f"class_reference: {json.dumps(t['class_reference'], ensure_ascii=False)}",
        f"raw: {json.dumps(t['raw'], ensure_ascii=False)}",
        "presets:",
        *[f"  - {json.dumps(p, ensure_ascii=False)}" for p in t["presets"]],
        "rows:",
        *[f"  - {json.dumps(r, ensure_ascii=False)}" for r in t["rows"]],
    ]
    with open(YAML, "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(JSON, "w") as f:
        json.dump(t, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {os.path.relpath(YAML, ROOT)} and {os.path.relpath(JSON, ROOT)}: {len(t['rows'])} rows")


def read_yaml() -> dict:
    t: dict = {"presets": [], "rows": []}
    section = None
    for line in open(YAML):
        s = line.rstrip("\n")
        if not s or s.startswith("#"):
            continue
        if s.startswith("  - "):
            t[section].append(json.loads(s[4:]))
            continue
        key, _, val = s.partition(":")
        val = val.strip()
        section = key
        if val:
            t[key] = json.loads(val)
    return t


def check() -> int:
    y = read_yaml()
    j = json.load(open(JSON))
    if y != j:
        print("video-speed: catalog/video-speed.yaml and the bundled JSON differ; re-run tools/perf/video-speed.py")
        return 1
    print(f"video-speed: {len(j['rows'])} rows, YAML == bundled JSON")
    return 0


def bench_cmd(a, p: dict, raw: str) -> list[str]:
    """fix/t05-video (AT-290 b): the preset's model and size are requested explicitly (`--model`, `--width`,
    `--height`), never derived from the key: `--res ltx` (from "t2v-ltx-512p-short") ran vid-5b at 832×480."""
    cmd = [a.bin, "-Bench", "video", "--mode", p["mode"], "--model", p["model"], "--width", str(p["width"]),
           "--height", str(p["height"]), "--frames", str(p["frames"]), "--runs", str(a.runs), "--tier-cap", "T3-48",
           "--runtime", a.runtime, "--out-dir", os.path.join(ROOT, "build", "perf", "video-speed-out"), "--raw", raw]
    if p["mode"] == "i2v":
        cmd += ["--steps", str(p["steps"]), "--init-image", a.init_image]
    return cmd


def run(a) -> None:
    os.makedirs(a.raw_dir, exist_ok=True)
    for p in PRESETS:
        raw = os.path.join(a.raw_dir, p["raw"][0] + ".jsonl")
        if os.path.exists(raw):
            os.remove(raw)
        cmd = bench_cmd(a, p, raw)
        print("[..]", " ".join(cmd), flush=True)
        subprocess.run(cmd, check=True)
        # Fail loudly right after the preset that ran something else (model, size or frame count).
        name, rr = rows(a.raw_dir, [p["raw"][0]])
        if not rr:
            print(f"video-speed: FAIL {p['key']}: no completed row in {raw}", file=sys.stderr)
            raise PresetMismatch(3)
        check_rows(p, name, rr, strict=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--from-raw", action="store_true")
    g.add_argument("--run", action="store_true")
    g.add_argument("--check", action="store_true")
    ap.add_argument("--raw-dir", default=os.path.join(ROOT, "build", "perf", "raw"))
    ap.add_argument("--bin", help="AntiChat binary with -Bench (Release bench build)")
    ap.add_argument("--runtime", help="unzipped video-runtime directory")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--init-image", default=os.path.join(ROOT, "fixtures", "images", "photos-cc0", "019.jpg"))
    a = ap.parse_args()
    if a.check:
        return check()
    if a.run:
        if not a.bin or not a.runtime:
            ap.error("--run needs --bin and --runtime")
        # M9.T05: the helper (XPC, cwd /) resolves the runtime path: a relative one was `runtimeMissing` for every T2V row.
        a.runtime = os.path.abspath(a.runtime)
        run(a)
    t = table(a.raw_dir)
    if not t["rows"]:
        print("video-speed: no raw rows; nothing written", file=sys.stderr)
        return 1
    write(t)
    return 0


if __name__ == "__main__":
    sys.exit(main())
