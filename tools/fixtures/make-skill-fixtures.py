#!/usr/bin/env python3
"""Skill import fixtures (M7.T12; R-082, R-261; AT-082, AT-261). Stdlib only, run with `python3 -I`.

  make-skill-fixtures.py --examples <anthropics/skills checkout>   copy the licence-checked official examples
  make-skill-fixtures.py --bad                                     (re)write fixtures/skills/bad/

--examples copies the Apache-2.0 example skills listed in EXAMPLES, unedited, from a local clone of
https://github.com/anthropics/skills at the commit it is checked out at, into
fixtures/skills/agentskills-examples@<short sha>/<skill>/ (the clone must be clean; its HEAD is the pinned SHA recorded in
fixtures/skills/SOURCES.md). Each copied skill keeps its own LICENSE.txt.
--bad writes the rejection cases (synthetic, CC0): a 65-character name, a `--` name, a folder that does not match
the name, a zip-slip archive (`../`), an absolute-path archive, a symlink inside a folder and inside an archive, and a
600-file archive (over the 500-file limit). Archives are deterministic (fixed timestamps, sorted entries).
"""
from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIX = os.path.join(os.environ.get("ANTICHAT_FIXTURES", os.path.join(ROOT, "fixtures")), "skills")
# Apache-2.0 skills (each has LICENSE.txt with the Apache text) that pass the reference validator at the pin.
# Excluded: claude-api (description over 1024 characters, fails skills-ref), doc-coauthoring (no LICENSE.txt),
# canvas-design (5.5 MB of OFL fonts), docx/pptx/xlsx (≥ 1.2 MB each; pdf represents the document skills).
EXAMPLES = [
    "academy-guide", "algorithmic-art", "brand-guidelines", "discernment-nudge", "frontend-design", "internal-comms",
    "slack-gif-creator", "theme-factory", "mcp-builder", "skill-creator", "webapp-testing", "pdf",
]
STAMP = (2026, 11, 7, 0, 0, 0)


def git(repo: str, *args: str) -> str:
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout.strip()


def examples(src: str) -> None:
    if git(src, "status", "--porcelain"):
        sys.exit("the anthropics/skills checkout has local changes")
    sha = git(src, "rev-parse", "HEAD")
    out = os.path.join(FIX, f"agentskills-examples@{sha[:7]}")
    shutil.rmtree(out, ignore_errors=True)
    for name in EXAMPLES:
        s = os.path.join(src, "skills", name)
        lic = open(os.path.join(s, "LICENSE.txt"), encoding="utf-8").read()
        if "Apache License" not in lic:
            sys.exit(f"{name}: LICENSE.txt is not Apache-2.0")
        shutil.copytree(s, os.path.join(out, name), symlinks=True)
    print(f"copied {len(EXAMPLES)} skills from anthropics/skills@{sha} -> {os.path.relpath(out, ROOT)}")
    forms(out)


def forms(examples_dir: str) -> None:
    """The Add forms of one example (brand-guidelines) for the UI legs: .zip, .skill and a lone SKILL.md."""
    out = os.path.join(FIX, "forms")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, "single"))
    src = os.path.join(examples_dir, "brand-guidelines")
    entries = []
    for dp, dns, fns in os.walk(src):
        dns.sort()
        for fn in sorted(fns):
            full = os.path.join(dp, fn)
            rel = os.path.join("brand-guidelines", os.path.relpath(full, src))
            entries.append((rel, open(full, "rb").read(), stat.S_IFREG | 0o644))
    zip_entries(os.path.join(out, "brand-guidelines.zip"), entries)
    shutil.copy(os.path.join(out, "brand-guidelines.zip"), os.path.join(out, "brand-guidelines.skill"))
    shutil.copy(os.path.join(src, "SKILL.md"), os.path.join(out, "single", "SKILL.md"))
    print(f"wrote {os.path.relpath(out, ROOT)}")


def skill_md(name: str, description: str = "A fixture skill for import tests.") -> str:
    return f"---\nname: {name}\ndescription: {description}\n---\n\n# {name}\n\nFixture body.\n"


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def zip_entries(path: str, entries: list[tuple[str, bytes, int]]) -> None:
    """entries: (name, data, unix mode); mode with S_IFLNK makes a symlink entry whose data is the target."""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for name, data, mode in entries:
            info = zipfile.ZipInfo(name, STAMP)
            info.create_system = 3
            info.external_attr = (mode & 0xFFFF) << 16
            z.writestr(info, data)


def bad() -> None:
    out = os.path.join(FIX, "bad")
    shutil.rmtree(out, ignore_errors=True)
    long_name = "a" * 65
    write(os.path.join(out, "name-too-long", long_name, "SKILL.md"), skill_md(long_name))
    write(os.path.join(out, "double-hyphen", "my--skill", "SKILL.md"), skill_md("my--skill"))
    write(os.path.join(out, "folder-mismatch", "wrong-folder", "SKILL.md"), skill_md("right-name"))
    # A folder skill with a symlink that points out of the skill, to another fixture (git stores the link itself).
    link_dir = os.path.join(out, "symlink", "linked-skill")
    write(os.path.join(link_dir, "SKILL.md"), skill_md("linked-skill"))
    os.makedirs(os.path.join(link_dir, "references"), exist_ok=True)
    os.symlink("../../../double-hyphen/my--skill/SKILL.md", os.path.join(link_dir, "references", "outside.md"))
    f = stat.S_IFREG | 0o644
    zip_entries(os.path.join(out, "zip-slip.zip"), [
        ("zip-slip/SKILL.md", skill_md("zip-slip").encode(), f),
        ("../zip-slip-escaped.txt", b"written outside the extraction folder\n", f),
    ])
    zip_entries(os.path.join(out, "absolute-path.zip"), [
        ("absolute-path/SKILL.md", skill_md("absolute-path").encode(), f),
        ("/tmp/antichat-absolute-path.txt", b"absolute\n", f),
    ])
    zip_entries(os.path.join(out, "symlink-entry.zip"), [
        ("symlink-entry/SKILL.md", skill_md("symlink-entry").encode(), f),
        ("symlink-entry/references/hosts.md", b"/etc/hosts", stat.S_IFLNK | 0o777),
    ])
    many = [("too-many-files/SKILL.md", skill_md("too-many-files").encode(), f)]
    many += [(f"too-many-files/references/note-{i:03d}.md", f"note {i}\n".encode(), f) for i in range(600)]
    zip_entries(os.path.join(out, "too-many-files.zip"), many)
    print(f"wrote {os.path.relpath(out, ROOT)}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--examples", metavar="CHECKOUT")
    ap.add_argument("--bad", action="store_true")
    a = ap.parse_args()
    if not a.examples and not a.bad:
        ap.error("--examples and/or --bad")
    if a.examples:
        examples(os.path.abspath(a.examples))
    if a.bad:
        bad()
    return 0


if __name__ == "__main__":
    sys.exit(main())
