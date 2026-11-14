#!/usr/bin/env python3
"""Fixture databases per schema version (M8.T01 step 0; M8.md convention "Migrations").

  make-db-fixture.py --upto <identifier> [--out <path>]   one fixture (default fixtures/chats/db/<identifier>.sqlite)
  make-db-fixture.py --all                                every identifier of this build + migrations.lock + future-v999
  make-db-fixture.py --future                             only the two future-v999 variants

Calls the DEBUG `antichat-cli db make-fixture` (seed 20261030): migrate up to the identifier with this build's
migrator, then a deterministic seed (20 chats with branches, 2 images, every table of that version). Files are named
by identifier, not number, so a renumber at merge keeps the old fixture valid (it migrates through `Migrations.renamed`).
Existing fixtures are frozen: `--all` only writes missing ones (pass --force to rewrite).
`legacy-m1-v2_tool_permission.sqlite`: the M1-era Release container (`v1_core` + `v2_tool_permission`).
`future-v999.sqlite` (journal DELETE) and `future-v999-wal/antichat.sqlite` (+ -wal + -shm of a live WAL database).
"""
from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DB_DIR = os.path.join(os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures")), "chats", "db")
SEED = "20261030"


def cli(*args: str) -> str:
    cmd = ["swift", "run", "--disable-keychain", "--force-resolved-versions", "-c", "debug", "antichat-cli", *args]
    return subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout


def make(upto: str, out: str, future: bool = False) -> None:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cli("db", "make-fixture", "--upto", upto, "--out", out, "--seed", SEED, *(["--future"] if future else []))
    print(f"wrote {os.path.relpath(out, ROOT)}")


def make_future() -> None:
    ids = identifiers()
    make(ids[-1], os.path.join(DB_DIR, "future-v999.sqlite"), future=True)
    # WAL variant: open the DELETE copy in WAL mode, keep a connection with uncheckpointed frames, copy the triple.
    wal_dir = os.path.join(DB_DIR, "future-v999-wal")
    shutil.rmtree(wal_dir, ignore_errors=True)
    os.makedirs(wal_dir)
    with tempfile.TemporaryDirectory() as tmp:
        live = os.path.join(tmp, "antichat.sqlite")
        shutil.copy(os.path.join(DB_DIR, "future-v999.sqlite"), live)
        con = sqlite3.connect(live)
        con.execute("PRAGMA journal_mode=WAL")
        con.execute("PRAGMA wal_autocheckpoint=0")
        con.execute("UPDATE local_counter SET value = value + 1 WHERE key = 'fixture'")
        con.commit()
        for suffix in ("", "-wal", "-shm"):
            shutil.copy(live + suffix, os.path.join(wal_dir, "antichat.sqlite" + suffix))
        con.close()
    print(f"wrote {os.path.relpath(wal_dir, ROOT)}/")


def identifiers() -> list[str]:
    return [l for l in cli("db", "identifiers").splitlines() if l.strip()]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--upto")
    ap.add_argument("--out")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--future", action="store_true")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    if a.upto:
        make(a.upto, a.out or os.path.join(DB_DIR, f"{a.upto}.sqlite"))
    if a.all:
        ids = identifiers()
        for ident in ids:
            out = os.path.join(DB_DIR, f"{ident}.sqlite")
            if a.force or not os.path.exists(out):
                make(ident, out)
        lock = os.path.join(DB_DIR, "migrations.lock")
        old = open(lock).read().splitlines() if os.path.exists(lock) else []
        renames = [l for l in old if "->" in l and not l.startswith("#")]
        with open(lock, "w") as f:
            f.write("# M8.T01: migration identifiers in registration order (append-only; MigrationRunnerTests).\n")
            f.write("# A renumbered identifier stays listed as `old -> new` (Migrations.renamed).\n")
            for l in renames:
                f.write(l + "\n")
            for ident in ids:
                f.write(ident + "\n")
        print(f"wrote {os.path.relpath(lock, ROOT)} ({len(ids)} identifiers)")
    if a.future or (a.all and (a.force or not os.path.exists(os.path.join(DB_DIR, "future-v999.sqlite")))):
        make_future()
    if a.all:
        legacy = os.path.join(DB_DIR, "legacy-m1-v2_tool_permission.sqlite")
        if a.force or not os.path.exists(legacy):
            cli("db", "make-fixture", "--legacy-m1", "--out", legacy)
            print(f"wrote {os.path.relpath(legacy, ROOT)}")
    if not (a.upto or a.all or a.future):
        ap.print_help()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
