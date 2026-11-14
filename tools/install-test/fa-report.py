#!/usr/bin/env python3
"""M10.T09: the AT-FA-01…14 table from build/at/AT-FA-<nn>/<date>/result.json (run `python3 -I`).

For each AT the newest run (or --date) is reported; an AT with two halves (AT-FA-13: the Debug hook in the debug
pass + the Release manual way in release-manual/) passes only when both do. AT-FA-01 and -12 also get their devid row,
pending until the owner's M10.T10 steps (notarized DMG + production feed and key).
Usage: fa-report.py [--date YYYYmmdd-HHMMSS] [--out summary.md] [--json]"""
import argparse, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TITLES = {1: "Download from the website; Gatekeeper passes", 2: "Onboarding", 3: "Fast first chat (NFR-M5)",
          4: "Offline chat", 5: "Dictation and voice conversation", 6: "Image, then video", 7: "Evil mode",
          8: "The safety floor fires", 9: "Import a ChatGPT export", 10: "Crash recovery",
          11: "Relaunch keeps history", 12: "Appcast update N-1 → N", 13: "Uninstall cleans up",
          14: "Low-RAM tier run"}
DEVID_RERUN = ("after M10-owner-steps §1–5: `make build-release SIGNING_MODE=devid` (N-1 and N) + `make dmg` → "
               "`make test-final PASS=release FORM=devid PREV_DMG=<N-1 dmg> DMG=<N dmg>` (production feed: "
               "FEED=stable SPARKLE_KEY_FILE=…)")


def results(at: str, date: str | None) -> tuple[Path | None, list[dict]]:
    base = ROOT / "build" / "at" / at
    runs = sorted(p for p in base.glob("*/") if p.is_dir()) if base.is_dir() else []
    if date:
        runs = [p for p in runs if p.name == date]
    # The newest result per sub-path: a leg with halves from different passes (AT-FA-13: the debug pass's top-level
    # result + the release pass's release-manual/) reports both.
    newest: dict[str, dict] = {}
    for run in runs:
        for f in sorted(run.rglob("result.json")):
            newest[str(f.parent.relative_to(run))] = json.loads(f.read_text()) | {"_path": str(f.parent.relative_to(ROOT))}
    return (runs[-1] if runs else None), [newest[k] for k in sorted(newest)]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--date")
    ap.add_argument("--out")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    rows = []
    for n in range(1, 15):
        at = f"AT-FA-{n:02d}"
        run, rs = results(at, a.date)
        if not rs:
            rows.append({"at": at, "title": TITLES[n], "result": "not run", "form": "", "evidence": ""})
        else:
            ok = all(r["pass"] for r in rs)
            pend = sum(r.get("pending_subchecks", 0) for r in rs)
            res = ("pass" if ok else "FAIL") + (f" ({pend} sub-check(s) pending)" if ok and pend else "")
            rows.append({"at": at, "title": TITLES[n], "result": res, "form": "; ".join(r["form"] for r in rs),
                         "evidence": ", ".join(r["_path"] for r in rs)})
        if n in (1, 12):
            rows.append({"at": at, "title": TITLES[n] + " — devid form", "result": "pending M10.T10 owner steps",
                         "form": "devid", "evidence": DEVID_RERUN})
    if a.json:
        print(json.dumps(rows, indent=1))
    else:
        lines = ["| AT | Leg | Result | Form | Evidence / rerun |", "|---|---|---|---|---|"]
        lines += [f"| {r['at']} | {r['title']} | {r['result']} | {r['form']} | {r['evidence']} |" for r in rows]
        text = "\n".join(lines) + "\n"
        print(text, end="")
        if a.out:
            Path(a.out).write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
