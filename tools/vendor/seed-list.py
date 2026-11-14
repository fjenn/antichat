#!/usr/bin/env python3
"""Build the Osaurus seed list for vendoring (M0.T02 step 3).

Usage: python3 -I tools/vendor/seed-list.py [--repo /tmp/osaurus] <docs...> > Vendor/osaurus-seed.txt

Extracts every `osaurus@2922745…:<path>` reference from the Phase 9 patch docs and the
patches registry, expands `{a,b}` braces, `*` globs and comma lists against the upstream
checkout, normalises each to `Packages/OsaurusCore/<path>`, adds the files the patch docs
name in prose (SUPPLEMENT), and classifies each file:

  vendored  compiled into the OsaurusVendored target (integration mode "vendored")
  watch     pristine copy tracked in Vendor/.upstream only, for `vendor-sync report --ports`
            (integration mode "ported" or "reference-only"; never compiled)

Output lines: `<mode>\t<path>\t<P-IDs>` sorted by path. Excluded paths (D-05, D-07, D-12, D-15
DENY) are reported on stderr. Exit 1 if a referenced path does not exist upstream.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path

ROOT = "Packages/OsaurusCore/"
REF = re.compile(r"osaurus(?:-ai/osaurus)?@2922745[0-9a-f]*:([A-Za-z0-9_./{},*+-]+)")
PID = re.compile(r"^## (P-[a-z-]+-\d+)", re.M)

# Same pattern as tools/ci/vendored-allowlist.py (M0.md T02 step 3).
DENY = re.compile(r"Orchestrator|/Agents?/|HTTPServer|/Server/|Bonjour|/Relay/|Identity|Aptabase|Sentry|"
                  r"Plugin|/VM/|Sandbox/VM|Channels|ComputerUse|AppleScript|BrowserUse|Billing|ModelsProxy")
# Explicit allowances inside a DENY match (M0.md T02 step 3; A-M0-06).
ALLOW = {
    "Packages/OsaurusCore/Services/Sandbox/Seatbelt/SeatbeltSandbox.swift",  # P-files-tools-14
    "Packages/OsaurusCore/Services/Plugin/FormatAdapter.swift",  # Foundation-only protocol (A-M0-06 c)
}
# Excluded by construction (D-12, D-05, D-07) and files that are not Swift sources of the target.
EXCLUDE = {
    "Packages/OsaurusCore/Services/Documents/ExternalOfficeRuntimeDetector.swift",  # D-12
    "Packages/OsaurusCore/Services/Search/OsaurusRouterSearchBackend.swift",  # D-05
    "Packages/OsaurusCore/Views/Chat/NativeChartView.swift",  # D-07
}

# Files the patch docs name in prose (not as an osaurus@ ref), with the P-ID that names them.
SUPPLEMENT = {
    "Services/ModelRuntime/ModelLease.swift": "P-shell-11",
    "Services/ModelRuntime/MetalGate.swift": "P-shell-11",
    "Services/SwapPressureMonitor.swift": "P-shell-11",
    "Services/MemoryPressureResponder.swift": "P-shell-11",
    "Services/Chat/ContextBudgetManager.swift": "P-shell-08",
    "Services/Chat/CompactionWatermark.swift": "P-shell-08",
    "Services/Chat/TokenEstimator.swift": "P-shell-08",
    "Models/Chat/ConversationSummary.swift": "P-shell-08",
    "Services/SystemPermissionService.swift": "P-shell-20",
    "Services/Tool/ToolSearchService.swift": "P-shell-12",
    "Services/Skill/SkillSearchService.swift": "P-files-tools-16",
    "Views/Chat/ImportGuideSheet.swift": "P-platform-10",
    "Views/Chat/AtFileMenuPopup.swift": "P-shell-06",
    "Models/Chat/AtFileMenu.swift": "P-shell-06",
    "Managers/SlashCommandRegistry.swift": "P-shell-06",
    "Views/Common/PickerCardStyle.swift": "P-shell-06",
    "Views/Settings/MCPProviderDirectoryView.swift": "P-files-tools-12",
    "Services/Voice/MarkdownStripper.swift": "P-media-04",
    "Services/Voice/TranscriptionOverlayWindowService.swift": "P-media-06",
    "Models/Memory/MemoryModels.swift": "P-media-01",
    # gaps.md §4 D-13 (P-files-tools-05): rebranded emitters/renderers.
    "Services/Documents/PPTXEmitter.swift": "P-files-tools-05",
    "Services/Documents/RichTextPDFRenderer.swift": "P-files-tools-05",
    "Services/Documents/PDFEditor.swift": "P-files-tools-05",
    # P-files-tools-16 names Skill.swift "(vendor)", but its path hits DENY `/Agents?/`;
    # not tracked here (DENY wins); M7 ports it from the pinned upstream instead (A-M0-06).
    "Models/Agent/Skill.swift": "P-files-tools-16",
}

# Ported / reference-only files (architecture.md §9.2): tracked, never compiled.
WATCH = {
    "Services/Chat/ChatTitleService.swift", "Services/Chat/SystemPromptComposer.swift",
    "Services/Chat/ContextCompactionService.swift", "Services/Chat/AgentToolLoop.swift",
    "Services/Tool/ToolIndexService.swift", "Services/Tool/ToolSearchService.swift",
    "Tools/CapabilityTools.swift", "Tools/RenderChartTool.swift",
    "Managers/Chat/ChatDraftStore.swift", "Views/Chat/SlashCommandPopup.swift",
    "Views/Chat/AtFileMenuPopup.swift", "Models/Chat/AtFileMenu.swift",
    "Managers/SlashCommandRegistry.swift", "Views/Common/PickerCardStyle.swift",
    "Views/Chat/NativeArtifactCardView.swift", "Managers/SkillManager.swift",
    "Services/Skill/SkillSearchService.swift", "Managers/ProjectManager.swift",
    "Services/MediaGeneration/MediaJobStore.swift", "Services/MediaGeneration/LocalVideoRequestPolicy.swift",
    "Services/SupportDiagnosticsBundle.swift", "Services/NotificationService.swift",
    "Views/Settings/MCPProviderDirectoryView.swift", "Services/MCP/OAuth/MCPOAuthService.swift",
    "Views/Onboarding/OnboardingView.swift", "Resources/Localizable.xcstrings",
    "Models/Memory/MemoryModels.swift", "Views/Memory/MemoryView.swift",
    "Views/Voice/VoiceInputOverlay.swift", "Managers/SpeechService.swift",
    "Services/Sandbox/SandboxManager.swift", "Models/Agent/Skill.swift",
    # P-platform-12 says vendored, but it is a Sparkle wrapper whose three patches rewrite most of
    # it; porting it into AntiChatPlatform keeps OsaurusVendored Apple-framework-only
    # (architecture.md §2), so the XPC helper (Engines → OsaurusVendored) never links Sparkle (A-M0-06).
    "Services/UpdaterService.swift",
    # P-media-04 wants only TTSTextChunker/TTSAudioPipeline from this file; the file itself is the
    # PocketTTS manager and imports FluidAudio (helper-only, architecture.md §2). M0.T05/M3 port the
    # chunker (M0.md T05 P-media-04 "else" branch) (A-M0-06).
    "Managers/TTSService.swift",
    # P-media-06: the overlay window service is Osaurus UI glue (ThemeManager, SpeechConfigurationStore,
    # TranscriptionOverlayView); M8 ports the window pattern (A-M0-06).
    "Services/Voice/TranscriptionOverlayWindowService.swift",
    # P-platform-10: the guide sheet reads the Osaurus `\.theme` environment; M8 ports it onto
    # AntiChatDesign tokens (A-M0-06).
    "Views/Chat/ImportGuideSheet.swift",
    # P-shell-08: both are written against Osaurus' OpenAI wire `ChatMessage` (Models/API/OpenAIAPI.swift,
    # 1,829 lines, which pulls ModelInfo/ModelOptions/RequestValidator/agent settings); M1 G-008 ports
    # them onto AntiChat's message model (A-M0-06).
    "Services/Chat/ContextBudgetManager.swift", "Services/Chat/CompactionWatermark.swift",
    # P-platform-10: the importer emits Osaurus ChatSessionData/ChatTurnData (OpenAI wire ToolCall,
    # Attachment); M0.T11/M8 port the parsers onto AntiChat's message tree, which needs branches
    # anyway (A-M0-06).
    "Managers/Chat/ChatSessionImporter.swift",
}
WATCH_GLOBS = ["Models/Project/*"]
# Named in the docs, deliberately not tracked at all.
SKIP_PREFIXES = ("scripts/",)  # D-06: Osaurus build scripts are not vendored (Nativ's are).
# Reference-only and too large to track (8.5 MB string catalog; P-shell-17 overlap is German only).
SKIP_FILES = {"Packages/OsaurusCore/Resources/Localizable.xcstrings"}


def expand_braces(s: str) -> list[str]:
    m = re.search(r"\{([^{}]*)\}", s)
    if not m:
        return [s]
    out = []
    for alt in m.group(1).split(","):
        out += expand_braces(s[: m.start()] + alt + s[m.end():])
    return out


def split_commas(raw: str) -> list[str]:
    """`dir/a.swift,b.swift` → dir/a.swift, dir/b.swift; braces are kept intact."""
    parts, depth, cur = [], 0, ""
    for ch in raw:
        depth += ch == "{"
        depth -= ch == "}"
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    first = parts[0]
    out = [first]
    for p in parts[1:]:
        p = p.strip()
        if not p:
            continue
        if "/" in p and (p.startswith(("Packages/", "Services/", "Managers/", "Models/", "Views/",
                                       "Utils/", "Tools/", "Folder/", "Resources/"))):
            out.append(p)
        else:
            out.append(first.rsplit("/", 1)[0] + "/" + p)
    return out


def normalise(p: str) -> str:
    p = p.rstrip(".,;:)")
    if p.count("{") != p.count("}"):  # prose like `{ContextBudgetManager.swift (938 lines), …}`
        p = p.replace("{", "").replace("}", "")
    if not p.startswith("Packages/"):
        p = ROOT + p
    return p


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="/tmp/osaurus")
    ap.add_argument("docs", nargs="+")
    a = ap.parse_args()
    repo = Path(a.repo)
    upstream = sorted(str(p.relative_to(repo)) for p in (repo / ROOT).rglob("*") if p.is_file())

    refs: dict[str, set[str]] = {}

    def add(path: str, pid: str) -> None:
        refs.setdefault(path, set()).add(pid)

    for doc in a.docs:
        text = Path(doc).read_text()
        if doc.endswith(".json"):
            for row in json.loads(text):
                for m in REF.finditer(json.dumps(row)):
                    for part in split_commas(m.group(1)):
                        for e in expand_braces(part):
                            add(normalise(e), row["id"])
            continue
        heads = [(m.start(), m.group(1)) for m in PID.finditer(text)]
        for m in REF.finditer(text):
            pid = next((h for pos, h in reversed(heads) if pos < m.start()), "?")
            for part in split_commas(m.group(1)):
                for e in expand_braces(part):
                    add(normalise(e), pid)
    for rel, pid in SUPPLEMENT.items():
        add(ROOT + rel, pid)

    files: dict[str, set[str]] = {}
    missing = []
    for ref, pids in refs.items():
        if ref.endswith("/") or ref.rstrip("/") + "/" == ROOT:
            continue  # bare directory mention
        if any(ref.startswith(ROOT + s) for s in SKIP_PREFIXES) or ref.startswith("Packages/OsaurusCore/scripts"):
            continue
        hits = [u for u in upstream if fnmatch.fnmatchcase(u, ref)] if "*" in ref else ([ref] if ref in upstream else [])
        if "*" in ref and ref.endswith("/*"):
            hits = [u for u in upstream if u.startswith(ref[:-1]) and u.endswith(".swift")]
        if not hits:
            missing.append(ref)
        for h in hits:
            files.setdefault(h, set()).update(pids)

    rows = []
    for f in sorted(files):
        rel = f[len(ROOT):]
        if f in SKIP_FILES:
            continue
        if f in EXCLUDE:
            print(f"exclude (deviation)\t{f}", file=sys.stderr)
            continue
        if DENY.search(f) and f not in ALLOW:
            print(f"exclude (DENY)\t{f}", file=sys.stderr)
            continue
        watch = rel in WATCH or any(fnmatch.fnmatchcase(rel, g) for g in WATCH_GLOBS)
        rows.append(("watch" if watch else "vendored", f, ",".join(sorted(p for p in files[f] if p != "?")) or "-"))
    for r in rows:
        print("\t".join(r))
    for m in missing:
        print(f"missing upstream\t{m}", file=sys.stderr)
    print(f"# vendored={sum(r[0] == 'vendored' for r in rows)} watch={sum(r[0] == 'watch' for r in rows)}",
          file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
