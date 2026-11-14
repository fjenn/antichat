#!/usr/bin/env python3
"""Shared read/write of build/perf/report.json (M1.T26a; fixes CR-T-12 and CR-T-13). Stdlib only.

The file holds two layers:
  * legacy flat keys (`m0.<metric>.<tier>.<model>[@chip]`, `m1.<label>.…`) written by the M0/M1 bench scripts
    (report.py, scale.py, sd-scale.py, vid-scale.py, tools/audio/rt-report.py, tools/m0/*);
  * the M1 schema (M1.T26 step 2, tools/perf/report_schema.json) under the reserved top-level keys
    `schema`, `build`, `commit`, `date`, `machine`, `metrics` (`metrics.<ID>.<tier>` = one entry).
Readers that walk the legacy keys skip RESERVED (`legacy_items`).

Write semantics (C4 "merge appends"):
  * CR-T-12: a key that exists is never overwritten unless `replace=True` (`--replace` on every writer).
  * CR-T-13: writes go to a temp file in the same directory, fsync, then os.replace (atomic on APFS), under an
    exclusive flock on `<report>.lock`, and the file is re-read inside the lock, so concurrent writers (several
    agents share this Mac) never lose each other's keys.
"""
from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_REPORT = os.path.join(ROOT, "build/perf/report.json")
RESERVED = frozenset({"schema", "build", "commit", "date", "machine", "metrics"})
SCHEMA_ID = "antichat-perf-report/1"


def load(path: str) -> dict:
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def legacy_items(data: dict):
    """(key, entry) for the flat legacy keys only."""
    for k, v in data.items():
        if k not in RESERVED and isinstance(v, dict):
            yield k, v


def save(path: str, data: dict) -> None:
    """Atomic write: temp file in the target directory → fsync → os.replace."""
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".report.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def locked(path: str):
    """Exclusive lock for a read-modify-write of `path`; yields the freshly loaded data, saves it on exit."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path + ".lock", "a") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            data = load(path)
            yield data
            save(path, data)
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def put_legacy(data: dict, key: str, val, replace: bool, log=print) -> bool:
    """Append-only put of a flat key (CR-T-12). Returns True when written."""
    if val is None:
        log(f"[skip] {key}: no values")
        return False
    if key in RESERVED:
        raise ValueError(f"{key} is a reserved report key")
    if key in data and not replace:
        log(f"[skip] {key} exists (use --replace)")
        return False
    data[key] = val
    return True


def put_metric(data: dict, metric: str, tier: str, entry: dict, replace: bool, log=print) -> bool:
    """Append-only put of `metrics.<metric>.<tier>` (M1 schema)."""
    m = data.setdefault("metrics", {}).setdefault(metric, {})
    if tier in m and not replace:
        log(f"[skip] metrics.{metric}.{tier} exists (use --replace)")
        return False
    m[tier] = entry
    return True
