#!/usr/bin/env python3
"""M10.T09: split the release journey's tagged checks (vm-release-smoke.sh: `[ok]   AT-FA-01: …`) into one
result.json + checks.tsv per AT under build/at/AT-FA-<nn>/<date>/ (run `python3 -I`).
Usage: fa-split.py <journey.log> <build/at> <date> [--form dev|devid]"""
import datetime, json, re, sys
from pathlib import Path


def main() -> int:
    log, at_root, date = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    form = sys.argv[sys.argv.index("--form") + 1] if "--form" in sys.argv else "dev"
    labels = {"dev": "dev (Release RC, dev-signed, dev keys, UNNOTARIZED; clean VM; local download host + dev appcast)",
              "devid": "devid (notarized, production feed)"}
    rows: dict[str, list[tuple[str, str]]] = {}
    for line in log.read_text(errors="replace").splitlines():
        m = re.match(r"\[(ok|FAIL)\]\s+(AT-FA-\d\d): (.*)", line)
        if m:
            rows.setdefault(m.group(2), []).append(("ok" if m.group(1) == "ok" else "FAIL", m.group(3)))
    for at, checks in rows.items():
        out = at_root / at / date
        if at == "AT-FA-13":
            out = out / "release-manual"
        out.mkdir(parents=True, exist_ok=True)
        (out / "checks.tsv").write_text("".join(f"{s}\t{c}\n" for s, c in checks))
        fails = sum(1 for s, _ in checks if s == "FAIL")
        json.dump({"at": at, "form": labels.get(form, form), "pass": fails == 0, "fails": fails, "pending_subchecks": 0,
                   "checks": [{"status": s, "check": c} for s, c in checks],
                   "finished": datetime.datetime.now(datetime.timezone.utc).isoformat()},
                  open(out / "result.json", "w"), indent=1)
        print(f"{at}: {'PASS' if fails == 0 else f'FAIL ({fails})'} → {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
