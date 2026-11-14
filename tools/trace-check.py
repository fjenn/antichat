#!/usr/bin/env python3
"""Traceability check for the AntiChat research packet.

Registries live in docs/research/registry/*.json, each a JSON list of objects
with at least {"id": ..., "status": ...}. Link fields used:
  features:      verdict (keep|adapt|drop|defer), requirements [R-...] (keep/adapt)
  requirements:  priority (P0|P1|P2), components [C-...], tests [AT-...]
  gaps:          requirement R-..., patches [P-...]
  risks:         status (open|closed|accepted)
Pass --phase N to only enforce rules that apply from that phase on.
Exit code 1 on any violation.
"""
import argparse
import json
import pathlib
import sys

REG = pathlib.Path(__file__).resolve().parent.parent / "docs" / "research" / "registry"


def load(name):
    p = REG / f"{name}.json"
    return json.loads(p.read_text()) if p.exists() else []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", type=int, default=99, help="enforce rules up to this phase")
    phase = ap.parse_args().phase

    feats, reqs, comps = load("features"), load("requirements"), load("components")
    risks, gaps, patches = load("risks"), load("gaps"), load("patches")
    ids = {x["id"] for reg in (feats, reqs, comps, risks, gaps, patches) for x in reg}
    errors = []

    def dangling(owner, refs):
        for r in refs or []:
            if r not in ids and not r.startswith("AT-"):
                errors.append(f"{owner}: references unknown id {r}")

    if phase >= 2:
        for f in feats:
            if f.get("verdict") not in {"keep", "adapt", "drop", "defer"}:
                errors.append(f"{f['id']}: missing verdict")
            if f.get("verdict") in {"keep", "adapt"} and not f.get("requirements"):
                errors.append(f"{f['id']}: {f['verdict']} but no requirement")
            dangling(f["id"], f.get("requirements"))
    if phase >= 3:
        for r in reqs:
            if r.get("priority") in {"P0", "P1"} and not r.get("components"):
                errors.append(f"{r['id']}: no component")
            dangling(r["id"], r.get("components"))
    if phase >= 9:
        for g in gaps:
            if not g.get("patches"):
                errors.append(f"{g['id']}: no patch source")
            dangling(g["id"], g.get("patches"))
    if phase >= 11:
        for r in reqs:
            if r.get("status") == "superseded":
                continue  # retired by a decision (e.g. D-005/D-006); nothing to test
            if r.get("priority") in {"P0", "P1"} and not r.get("tests"):
                errors.append(f"{r['id']}: no acceptance test")
        for k in risks:
            if k.get("status") not in {"closed", "accepted"}:
                errors.append(f"{k['id']}: risk still open")

    counts = {n: len(v) for n, v in
              dict(features=feats, requirements=reqs, components=comps,
                   risks=risks, gaps=gaps, patches=patches).items()}
    print("registry counts:", counts)
    for e in errors:
        print("FAIL", e)
    print("OK" if not errors else f"{len(errors)} violation(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
