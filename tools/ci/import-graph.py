#!/usr/bin/env python3
"""Module import-graph audit (architecture §3, PRD §6.1 rule 2; M1.T02). Run with `python3 -I`.

Allowed = the transitive closure of the architecture §3 edges (EDGES below). Checks, each printed as
`file:line: message` and failing the run:
  1. root Package.swift: every internal target dependency of AntiChat<Group> is allowed;
  2. every `import <internal module>` in Packages/<Group>/Sources (and Tests: module itself + allowed) is allowed;
  3. rule 1: the app target (project.yml `AntiChat`) never links AntiChatEngines or ChildSafetyCheck
     (SwiftPM closure of its products) and no file in App/AntiChat, App/UITests, App/IntegrationTests imports them;
  4. rule 3: nothing imports AntiChatUI except App/AntiChat and the UI module's own tests.
(Rule 2, the single ChildSafetyCheck importer, is r241-audit.py rule 1. Rule 4 is forbidden-deps.py.
 Rule 5 is url-session-lint.py.)
Fallback when `swift package dump-package` is unavailable: none needed (dump-package needs no resolution).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_common import ROOT, Graph, repo_files  # noqa: E402

UI, HARNESS, PLATFORM, DESIGN = "AntiChatUI", "AntiChatHarness", "AntiChatPlatform", "AntiChatDesign"
TOOLS, KNOW, STORE, EP = "AntiChatTools", "AntiChatKnowledge", "AntiChatStorage", "AntiChatEngineProtocol"
NET, F, ENG, HOST = "AntiChatNetwork", "AntiChatFoundation", "AntiChatEngines", "AntiChatEngineHost"
FTH = "AntiChatFileToolsHost"  # M6.T17: the File tools XPC service module (architecture §1.2: EngineProtocol only)
OV, SSV, CSC = "OsaurusVendored", "SpeechSwiftVendored", "ChildSafetyCheck"
CPK = "CommandPaletteKit"  # vendored donor (M1.T11), a leaf used only by AntiChatUI (architecture §2)
TUFF = "TUFFVendored"  # vendored donor (M2.T09, P-platform-05): DownloadETAEstimator, a leaf used only by Platform
XLS, XLSB = "CLibXLS", "CLibXLSBridge"  # M6.T07 (A-M6-10): vendored libxls + our C module over it, used only by Knowledge

# architecture.md §3 mermaid edges (+ §2 table: Engines → SpeechSwiftVendored).
EDGES: dict[str, set[str]] = {
    UI: {DESIGN, HARNESS, PLATFORM, CPK},
    HARNESS: {TOOLS, KNOW, STORE, EP, OV},
    TOOLS: {NET, STORE, OV, EP},  # M6.T17: FileToolsClient speaks the File tools contract (EngineProtocol)
    KNOW: {STORE, EP, OV, XLSB},  # M6.T07: XLSAdapter (legacy .xls)
    PLATFORM: {NET, STORE, OV, TUFF},  # M2.T09: the one new edge M2 allows (Platform → TUFFVendored)
    STORE: {F}, NET: {F}, EP: {F},
    DESIGN: {F, OV},
    HOST: {ENG},
    FTH: {EP},
    ENG: {CSC, EP, OV, SSV},
    CSC: {"CSCOrt"},  # the package's own C shim over onnxruntime
    F: set(), OV: set(), SSV: set(), CPK: set(), TUFF: set(), "CSCOrt": set(), XLSB: {XLS}, XLS: set(),
}
INTERNAL = set(EDGES)
IMPORT_RE = re.compile(r"^\s*(?:@testable\s+|@_implementationOnly\s+|@preconcurrency\s+|public\s+|package\s+|internal\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias|actor)\s+)?([A-Za-z_][A-Za-z0-9_]*)")


def closure(m: str, edges: dict[str, set[str]] = EDGES) -> set[str]:
    out, stack = set(), list(edges.get(m, ()))
    while stack:
        n = stack.pop()
        if n not in out:
            out.add(n)
            stack.extend(edges.get(n, ()))
    return out


def imports(path: Path):
    for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        m = IMPORT_RE.match(line)
        if m:
            yield i, m.group(1)


def app_products(project_yml: Path) -> dict[str, list[str]]:
    """target name → AntiChatKit products it links (regex over the XcodeGen spec; no yaml needed)."""
    out: dict[str, list[str]] = {}
    cur = None
    in_targets = False
    lines = project_yml.read_text().splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^targets:\s*$", line):
            in_targets = True
            continue
        if in_targets and re.match(r"^\S", line):
            in_targets = False
        if not in_targets:
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            cur = m.group(1)
            out[cur] = []
            continue
        m = re.match(r"^\s+product:\s*(\S+)", line)
        if m and cur:
            out[cur].append(m.group(1))
    return out


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def check(root: Path = ROOT) -> list[str]:
    errs: list[str] = []
    g = Graph(root)
    tmap = g.targets(g.root_id)
    # 1. manifest edges
    for name, t in tmap.items():
        if name not in EDGES or t["type"] == "test":
            continue
        allowed = closure(name)
        for d in t.get("dependencies", []):
            dep = (d.get("byName") or d.get("target") or [None])[0] if ("byName" in d or "target" in d) else None
            if dep is None and "product" in d:
                dep = d["product"][0]
            if dep in INTERNAL and dep not in allowed:
                errs.append(f"Package.swift: {name} depends on {dep} (not allowed by architecture §3)")
    # 2. source imports
    for gdir in sorted((root / "Packages").iterdir()):
        for kind in ("Sources", "Tests"):
            base = gdir / kind
            if not base.is_dir():
                continue
            for mdir in sorted(p for p in base.iterdir() if p.is_dir()):
                mod = mdir.name
                if kind == "Tests":
                    owner = mod[:-len("Tests")] if mod.endswith("Tests") else mod
                    owner = UI if owner == "AntiChatUIModule" else owner
                    allowed = {owner} | closure(owner)
                    if owner == UI:
                        allowed.add(UI)
                else:
                    owner, allowed = mod, {mod} | closure(mod)
                if owner not in EDGES and owner != "CSCOrt":
                    continue
                for f in sorted(mdir.rglob("*.swift")):
                    if ".build" in f.parts:
                        continue
                    for ln, imp in imports(f):
                        if imp in INTERNAL and imp not in allowed:
                            errs.append(f"{rel(f)}:{ln}: {owner} imports {imp} (not allowed by architecture §3)")
    # 3. rule 1 (app never links engines / CSC)
    prods = app_products(root / "project.yml")
    for prod in prods.get("AntiChat", []):
        for pt in g.product_targets(g.root_id, prod):
            for pk, tn in g.closure(g.root_id, pt):
                if tn in (ENG, CSC, HOST) or pk == "childsafetycheck":
                    errs.append(f"project.yml: app target links {prod} → {pk}/{tn} (architecture §3 rule 1)")
    for d in ("App/AntiChat", "App/UITests", "App/IntegrationTests"):
        for f in sorted((root / d).rglob("*.swift")) if (root / d).is_dir() else []:
            for ln, imp in imports(f):
                if imp in (ENG, CSC, HOST, "CSCOrt"):
                    errs.append(f"{rel(f)}:{ln}: app-side file imports {imp} (architecture §3 rule 1)")
    # 4. rule 3 (only the app imports AntiChatUI)
    for f in repo_files(root):
        r = f.relative_to(root)
        if r.parts[:2] == ("App", "AntiChat") or r.parts[:3] == ("Packages", "UI", "Sources") \
                or r.parts[:4] == ("Packages", "UI", "Tests", "AntiChatUIModuleTests"):
            continue
        for ln, imp in imports(f):
            if imp == UI:
                errs.append(f"{r}:{ln}: imports AntiChatUI (architecture §3 rule 3)")
    return errs


def main() -> int:
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT
    errs = check(root)
    for e in errs:
        print(e)
    print(f"import-graph: {'FAIL ' + str(len(errs)) if errs else 'ok'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
