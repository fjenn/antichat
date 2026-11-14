#!/usr/bin/env python3
"""Per-bump checks of the vendor-sync rehearsal (M0.T03 step 4). Run with `python3 -I` from the rehearsal tree.

  rehearsal-check.py <k> --start <ISO-8601 UTC> [--bump-output FILE] [--name osaurus] [--head-git main]

After a bump's conflicts are resolved: runs `tools/vendor-sync closure-check <name>` (build of the donor
target alone), `closure-check --tests` (ported upstream tests), `python3 -I tools/ci/patch-lint.py`, and counts
`ANTICHAT-PATCH: UP-###` markers (`grep -c` per row). Rows of UPSTREAM_PATCHES.md's table above "Not applied"
must each have ≥ 1 marker and their number must equal the distinct markers found. With --final (k = last
step) also runs the root `swift build --target <target>` + `swift test --filter <test_target>` and
`diff -r` against <head-git>'s compiled copy. Writes build/at/AT-M0-03/bump-<k>.log and bump-<k>.json; exit 0
only when everything is green.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path.cwd()
OUT = ROOT / "build/at/AT-M0-03"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("k", type=int)
    ap.add_argument("--start", required=True)
    ap.add_argument("--bump-output")
    ap.add_argument("--name", default="osaurus")
    ap.add_argument("--head-git", default="main")
    ap.add_argument("--final", action="store_true")
    ap.add_argument("--note", default="")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    log = open(OUT / f"bump-{a.k}.log", "w")

    def say(s: str) -> None:
        print(s)
        log.write(s + "\n")
        log.flush()

    def run(label: str, cmd: list[str]) -> tuple[int, str]:
        say(f"== {label}: {' '.join(cmd)}")
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        out = r.stdout + r.stderr
        keep = [l for l in out.splitlines() if re.search(r"error|Test run with|✘|patch-lint|closure-check|Build complete|"
                                                          r"passed after|failed after|missing symbols", l)]
        log.write("\n".join(keep[-200:]) + "\n")
        say(f"== {label} exit={r.returncode}")
        return r.returncode, out

    donors = json.loads((ROOT / "Vendor/donors.json").read_text())
    d = donors[a.name]
    short = d["ref"][:7]
    say(f"# AT-M0-03 bump {a.k}: {a.name}@{short} ({d['ref']}) on {subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()}")
    say(f"started {a.start}")
    if a.bump_output:
        say("== bump output")
        log.write(Path(a.bump_output).read_text())
    rc_build, _ = run("closure_build", ["tools/vendor-sync", "closure-check", a.name])
    rc_test, tout = run("closure_tests", ["tools/vendor-sync", "closure-check", a.name, "--tests"])
    m = re.search(r"Test run with (\d+) tests? in (\d+) suites? (passed|failed)", tout)
    tests = {"tests": int(m.group(1)) if m else 0, "suites": int(m.group(2)) if m else 0,
             "result": m.group(3) if m else "none"}
    rc_lint, lout = run("patch_lint", [sys.executable, "-I", "tools/ci/patch-lint.py"])

    compiled = ROOT / "Vendor" / f"{a.name}@{short}"
    table = (ROOT / "Vendor/UPSTREAM_PATCHES.md").read_text()
    applied = table.split("## Not applied", 1)[0]
    rows = re.findall(r"^\| (UP-[A-Z]+-\d{3}) \| [^|]+ \| [^|]+ \| ([^|]+) \|", applied, re.M)
    marker_rows = [up for up, kind in rows if kind.strip() != "access"]
    counts = {}
    for up in marker_rows:
        r = subprocess.run(["grep", "-rc", f"ANTICHAT-PATCH: {up}\\b", str(compiled)], capture_output=True, text=True)
        counts[up] = sum(int(l.rsplit(":", 1)[1]) for l in r.stdout.splitlines() if l.rsplit(":", 1)[1] != "0")
    found = set(re.findall(r"ANTICHAT-PATCH: (UP-[A-Z]+-\d{3})",
                           subprocess.run(["grep", "-rho", r"ANTICHAT-PATCH: UP-[A-Z]*-[0-9]*", str(compiled)],
                                          capture_output=True, text=True).stdout))
    all_rows = re.findall(r"^\| (UP-[A-Z]+-\d{3}) \| [^|]+ \| [^|]+ \| ([^|]+) \|", table.split("## Not applied")[0]
                          if a.final else _head_table(a.head_git), re.M)
    say(f"== markers: {len(marker_rows)} active marker rows (+ {len(rows) - len(marker_rows)} access row), "
        f"{len(found)} distinct markers present; head has {len([r for r in all_rows if r[1].strip() != 'access'])} marker rows")
    for up in marker_rows:
        say(f"   {up}: grep -c = {counts[up]}")
    markers_ok = all(counts[up] >= 1 for up in marker_rows) and found == set(marker_rows)

    # Info: string literals naming Osaurus / ai.osaurus (rebrand rows cover only the lines they patch; new
    # upstream strings arrive unbranded and nothing but review catches them).
    lit = subprocess.run(["grep", "-rhoE", r'"[^"]*([Oo]saurus|OSAURUS)[^"]*"', "--include=*.swift", str(compiled)],
                         capture_output=True, text=True).stdout.splitlines()
    say(f"== info: {len(lit)} string literals naming Osaurus in the compiled copy")
    diff_ok = None
    rc_root_build = rc_root_test = None
    if a.final:
        rc_root_build, _ = run("root_build", ["swift", "build", "--disable-keychain", "--target", d["target"]])
        rc_root_test, rout = run("root_tests", ["swift", "test", "--disable-keychain", "--filter", d["test_target"]])
        with tempfile.TemporaryDirectory() as t:
            subprocess.run(f"git archive {a.head_git} Vendor/{a.name}@{short} | tar -x -C {t}", shell=True, cwd=ROOT, check=True)
            r = subprocess.run(["diff", "-r", str(Path(t) / "Vendor" / f"{a.name}@{short}"), str(compiled)],
                               capture_output=True, text=True)
            say(f"== diff -r {a.head_git}:Vendor/{a.name}@{short} Vendor/{a.name}@{short}: exit={r.returncode}")
            log.write(r.stdout[-5000:])
            diff_ok = r.returncode == 0
    end = datetime.now(timezone.utc)
    start = datetime.fromisoformat(a.start.replace("Z", "+00:00"))
    minutes = round((end - start).total_seconds() / 60, 1)
    green = rc_build == 0 and rc_test == 0 and tests["result"] == "passed" and rc_lint == 0 and markers_ok and \
        (not a.final or (rc_root_build == 0 and rc_root_test == 0 and diff_ok))
    res = {"k": a.k, "ref": d["ref"], "short": short, "start": a.start, "green_at": end.isoformat(timespec="seconds"),
           "active_minutes": minutes, "closure_build_exit": rc_build, "closure_tests_exit": rc_test, "tests": tests,
           "patch_lint_exit": rc_lint, "active_marker_rows": len(marker_rows), "distinct_markers": len(found),
           "marker_counts": counts, "markers_ok": markers_ok,
           "compiled_files": sum(1 for f in compiled.rglob("*") if f.is_file()) - 3,
           "root_build_exit": rc_root_build, "root_tests_exit": rc_root_test, "diff_r_empty": diff_ok,
           "osaurus_string_literals": len(lit), "note": a.note, "green": green}
    (OUT / f"bump-{a.k}.json").write_text(json.dumps(res, indent=1) + "\n")
    say(f"== bump {a.k} {'GREEN' if green else 'NOT GREEN'} at {res['green_at']} ({minutes} min since start)")
    return 0 if green else 1


def _head_table(rev: str) -> str:
    r = subprocess.run(["git", "show", f"{rev}:Vendor/UPSTREAM_PATCHES.md"], cwd=ROOT, capture_output=True, text=True)
    return r.stdout.split("## Not applied")[0]


if __name__ == "__main__":
    sys.exit(main())
