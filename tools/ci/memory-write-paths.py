#!/usr/bin/env python3
"""Memory write paths (M8.T02, R-242 AC2: memory is written only by the tool or by the user).

Fails when `MemoryStore` writes (`.insert(topic:`, `.update(id:`, `.delete(id:`, `.undo(eventID:`, `.resetAll(`) are
called from any Swift file outside the allow-list below. Allowed entries that do not exist yet are fine (later tasks).
Tests are exempt. Run with `python3 -I`.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ALLOWED = {
    "Packages/Knowledge/Sources/AntiChatKnowledge/Memory/MemoryStore.swift",       # the store itself
    "Packages/Knowledge/Sources/AntiChatKnowledge/Memory/MemoryTool.swift",        # the model, via the tool (M8.T02)
    "Packages/UI/Sources/AntiChatUI/Settings/Personalization/MemorySettingsViewModel.swift",  # the user (M8.T03)
    "Packages/UI/Sources/AntiChatUI/Conversation/MemoryNoticeView.swift",          # the user's Undo tap (M8.T03)
    "Packages/Knowledge/Sources/AntiChatKnowledge/Memory/MemoryReviewService.swift",  # save after the user's tap (M8.T03)
    "Packages/Knowledge/Sources/AntiChatKnowledge/Memory/MemoryImporter.swift",    # R-063 after a tap (M11)
}
# A write is a call on a MemoryStore value: `store.insert(topic:`, `memory.store.update(id:`, `MemoryStore(…).delete(id:`.
WRITE = re.compile(r"(?:\bstore|\bMemoryStore\([^)]*\))\s*\.(?:insert\(topic:|update\(id:|delete\(id:|undo\(eventID:|resetAll\()")


def main() -> int:
    files = subprocess.run(["git", "ls-files", "*.swift"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    bad = []
    for f in files:
        # Benches measure the decider on throwaway in-memory stores (no user data).
        if f.startswith("App/AntiChat/BenchMode") or "/Tests/" in f or f.startswith("App/UITests") or f.startswith("App/IntegrationTests") or f.startswith("Vendor/"):
            continue
        text = (ROOT / f).read_text(encoding="utf-8", errors="replace")
        if "MemoryStore" not in text and "memory.store" not in text and "MemoryRuntime" not in text:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if WRITE.search(line) and f not in ALLOWED:
                bad.append(f"{f}:{n}: memory write outside the allowed callers: {line.strip()}")
    for b in bad:
        print(b)
    print(f"memory-write-paths: {'FAIL' if bad else 'ok'} ({len(ALLOWED)} allowed callers)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
