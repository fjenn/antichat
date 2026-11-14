#!/usr/bin/env python3
"""Catalog schema + completeness check (M2.T04 AT-220 part 1; R-220 AC5). Run with `python3 -I` (stdlib only).

  python3 -I tools/ci/catalog-schema-check.py site/public/catalog/v2/catalog.json [--log build/at/AT-220/schema.log]

1. Validates the manifest against catalog/schema/catalog-v2.schema.json (a stdlib validator for the 2020-12 subset
   the schema uses: type, const, enum, pattern, required, properties, additionalProperties, propertyNames, items,
   minItems, minimum, minLength, $ref to #/$defs).
   M7.T01: a `search_engines` section is validated against catalog/schema/search-engines.schema.json (no Google id).
   M7.T06: an `mcp_curated` section is validated against catalog/schema/mcp-curated.schema.json (≥ 10 https servers).
2. Completeness: every tier (T0…T4, each sub-band present) × S1…S4 × pack {chat, voice, photo, video} × mode
   {normal, evil} resolves to a model id or carries `<pack>_reason`; roles embed, title and csam_check (model or
   reason) are present in every cell; every referenced id exists in `models`. Prints the matrix.
Exit 1 on any failure.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "catalog/schema/catalog-v2.schema.json"
SEARCH_SCHEMA = ROOT / "catalog/schema/search-engines.schema.json"  # M7.T01 (R-253): the `search_engines` section
MCP_SCHEMA = ROOT / "catalog/schema/mcp-curated.schema.json"  # M7.T06 (R-081 AC4): the `mcp_curated` section
TIERS = ["T0", "T1", "T2", "T3", "T4"]
CLASSES = ["S1", "S2", "S3", "S4"]
PACKS = ["chat", "voice", "photo", "video"]
MODES = ["normal", "evil"]
TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "number": (int, float), "integer": int}


def validate(v, s, root, path, errs):
    if "$ref" in s:
        s = root["$defs"][s["$ref"].split("/")[-1]]
    t = s.get("type")
    if t:
        ok = isinstance(v, TYPES[t]) and not (t in ("number", "integer") and isinstance(v, bool))
        if not ok:
            errs.append(f"{path}: expected {t}")
            return
    if "const" in s and v != s["const"]:
        errs.append(f"{path}: must be {s['const']!r}")
    if "enum" in s and v not in s["enum"]:
        errs.append(f"{path}: {v!r} not in {s['enum']}")
    if isinstance(v, str):
        if "pattern" in s and not re.search(s["pattern"], v):
            errs.append(f"{path}: {v!r} does not match {s['pattern']}")
        if len(v) < s.get("minLength", 0):
            errs.append(f"{path}: too short")
    if isinstance(v, (int, float)) and "minimum" in s and v < s["minimum"]:
        errs.append(f"{path}: below {s['minimum']}")
    if isinstance(v, list):
        if len(v) < s.get("minItems", 0):
            errs.append(f"{path}: needs ≥ {s['minItems']} items")
        if "items" in s:
            for i, x in enumerate(v):
                validate(x, s["items"], root, f"{path}[{i}]", errs)
    if isinstance(v, dict):
        for r in s.get("required", []):
            if r not in v:
                errs.append(f"{path}: missing {r}")
        props = s.get("properties", {})
        for k, x in v.items():
            if "propertyNames" in s:
                validate(k, s["propertyNames"], root, f"{path}.<{k}>", errs)
            if k in props:
                validate(x, props[k], root, f"{path}.{k}", errs)
            elif s.get("additionalProperties") is False:
                errs.append(f"{path}: unexpected key {k}")
            elif isinstance(s.get("additionalProperties"), dict):
                validate(x, s["additionalProperties"], root, f"{path}.{k}", errs)


def completeness(m, errs):
    a, models = m["assignments"], m["models"]
    rows = []
    for tier in TIERS:
        keys = sorted((k for k in a if k == tier or k.startswith(tier + "-")), key=lambda k: int(k.split("-")[1]) if "-" in k else 0)
        if not keys:
            errs.append(f"{tier}: no assignment cell")
        for key in keys:
            for sc in CLASSES:
                c = a[key].get(sc)
                if c is None:
                    errs.append(f"{key}/{sc}: missing")
                    continue
                line = [f"{key:7} {sc}"]
                for pack in PACKS:
                    for mode in MODES:
                        if pack == "chat":
                            pick = c["chat"].get(mode)
                            ids = [pick["model"]] + ([pick["step_down"]] if pick.get("step_down") else []) if pick else []
                            reason = c["chat"].get(f"{mode}_reason")
                        else:
                            slot = c.get(pack)
                            ids = slot[mode] if slot else []
                            reason = c.get(f"{pack}_reason")
                        if not ids and not reason:
                            errs.append(f"{key}/{sc}: {pack}.{mode} has neither a model nor {pack}_reason")
                        for i in ids:
                            if i not in models:
                                errs.append(f"{key}/{sc}: {pack}.{mode} names unknown {i}")
                        line.append(f"{pack}.{mode}={ids[0] if ids else '(' + str(reason) + ')'}")
                for role in ["embed", "csam_check"]:
                    if c.get(role) is None and not c.get(f"{role}_reason"):
                        errs.append(f"{key}/{sc}: role {role} missing")
                    if c.get(role) and c[role] not in models:
                        errs.append(f"{key}/{sc}: {role} names unknown {c[role]}")
                if not c.get("title"):
                    errs.append(f"{key}/{sc}: role title missing")
                if c["chat"].get("fast_first") not in models:
                    errs.append(f"{key}/{sc}: chat_fast {c['chat'].get('fast_first')} unknown")
                line.append(f"embed={c.get('embed') or '(' + str(c.get('embed_reason')) + ')'} title={c['title']} "
                            f"csam_check={c.get('csam_check') or '(' + str(c.get('csam_check_reason')) + ')'}")
                rows.append(" ".join(line))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("--log")
    args = ap.parse_args()
    m = json.loads(Path(args.catalog).read_text())
    schema = json.loads(SCHEMA.read_text())
    errs: list[str] = []
    validate(m, schema, schema, "$", errs)
    if "search_engines" in m:
        ss = json.loads(SEARCH_SCHEMA.read_text())
        validate(m["search_engines"], ss, ss, "$.search_engines", errs)
        if any("google" in str(e.get("id", "")).lower() for e in m["search_engines"]):
            errs.append("$.search_engines: no Google engine may ship (R-248 AC2, AT-248 c2)")
    if "mcp_curated" in m:
        ms = json.loads(MCP_SCHEMA.read_text())
        validate(m["mcp_curated"], ms, ms, "$.mcp_curated", errs)
    rows = completeness(m, errs) if not errs else []
    out = [f"catalog-schema-check: {args.catalog} catalog_version {m.get('catalog_version')}, {len(m.get('models', {}))} models",
           *rows, *[f"FAIL {e}" for e in errs],
           f"catalog-schema-check: {'ok' if not errs else f'{len(errs)} error(s)'} ({len(rows)} cells × 4 packs × 2 modes)"]
    print("\n".join(out))
    if args.log:
        Path(args.log).parent.mkdir(parents=True, exist_ok=True)
        Path(args.log).write_text("\n".join(out) + "\n")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
