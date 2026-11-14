"""Shared helpers for the M1 audits (import-graph, forbidden-deps, r241-audit, copy-sync, url-session-lint).

Uses `swift package dump-package` (manifest only, no resolution) on the root package, local path packages and
every `.build/checkouts/<pkg>`; results are cached in build/audit/dump-cache.json keyed by the manifest's
sha256 (so the audit stays fast on every commit). A dependency condition limited to non-macOS platforms is
dropped; a trait-gated dependency counts only when the trait is enabled (traits requested by any depender,
`default` expanded through the package's own trait table, transitively).
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "build/audit/dump-cache.json"


def _manifest_key(pkg: Path) -> str:
    h = hashlib.sha256()
    for m in sorted(pkg.glob("Package*.swift")):
        h.update(m.name.encode())
        h.update(m.read_bytes())
    return h.hexdigest()


class Dumper:
    def __init__(self) -> None:
        self.cache: dict = {}
        if CACHE.exists():
            try:
                self.cache = json.loads(CACHE.read_text())
            except ValueError:
                self.cache = {}
        self.dirty = False

    def dump(self, pkg: Path) -> dict:
        key = f"{pkg.resolve()}:{_manifest_key(pkg)}"
        if key not in self.cache:
            out = subprocess.run(
                ["swift", "package", "dump-package", "--package-path", str(pkg)],
                capture_output=True, text=True, check=True,
            ).stdout
            self.cache[key] = json.loads(out)
            self.dirty = True
        return self.cache[key]

    def save(self) -> None:
        if self.dirty:
            CACHE.parent.mkdir(parents=True, exist_ok=True)
            tmp = CACHE.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.cache))
            os.replace(tmp, CACHE)


def _on_macos(cond, traits: set[str] | None = None) -> bool:
    if not cond:
        return True
    names = cond.get("platformNames") or []
    if names and "macos" not in names:
        return False
    need = cond.get("traits")
    if need and traits is not None and not (set(need) & traits):
        return False
    return True


def dep_refs(target: dict, traits: set[str] | None = None) -> list[tuple[str, str, str | None]]:
    """[(kind, name, package)] with kind in target|product|byName; `traits` = the package's enabled traits."""
    out = []
    for d in target.get("dependencies", []):
        if "target" in d:
            name, cond = d["target"][0], d["target"][1] if len(d["target"]) > 1 else None
            if _on_macos(cond, traits):
                out.append(("target", name, None))
        elif "product" in d:
            name, pkg = d["product"][0], d["product"][1]
            cond = d["product"][3] if len(d["product"]) > 3 else None
            if _on_macos(cond, traits):
                out.append(("product", name, (pkg or "").lower() or None))
        elif "byName" in d:
            name, cond = d["byName"][0], d["byName"][1] if len(d["byName"]) > 1 else None
            if _on_macos(cond, traits):
                out.append(("byName", name, None))
    return out


class Graph:
    """Packages by identity (lowercased checkout dir / path dir name)."""

    def __init__(self, root: Path = ROOT) -> None:
        self.d = Dumper()
        self.pkgs: dict[str, dict] = {}
        self.paths: dict[str, Path] = {}
        self.root_id = "antichatkit"
        self._load(self.root_id, root)
        co = root / ".build/checkouts"
        if co.is_dir():
            for p in sorted(co.iterdir()):
                if (p / "Package.swift").exists():
                    self._load(p.name.lower(), p)
        for dep in self.pkgs[self.root_id].get("dependencies", []):
            if "fileSystem" in dep:
                fs = dep["fileSystem"][0]
                path = Path(fs["path"])
                self._load(fs["identity"].lower(), path if path.is_absolute() else root / path)
        self.d.save()
        self.traits = self._enabled_traits()

    def _enabled_traits(self) -> dict[str, set[str]]:
        req: dict[str, set[str]] = {i: set() for i in self.pkgs}
        req[self.root_id].add("default")
        for ident, pkg in self.pkgs.items():
            for dep in pkg.get("dependencies", []):
                for kind in ("sourceControl", "fileSystem", "registry"):
                    if kind in dep:
                        d = dep[kind][0]
                        tr = d.get("traits")
                        names = {"default"} if tr is None else {t["name"] for t in tr}
                        req.setdefault(d["identity"].lower(), set()).update(names)
        out: dict[str, set[str]] = {}
        for ident, names in req.items():
            table = {t["name"]: t.get("enabledTraits", []) for t in (self.pkgs.get(ident, {}).get("traits") or [])}
            on, stack = set(), list(names)
            while stack:
                n = stack.pop()
                if n in on:
                    continue
                on.add(n)
                stack.extend(table.get(n, []))
            out[ident] = on
        return out

    def _load(self, ident: str, path: Path) -> None:
        if ident not in self.pkgs:
            self.pkgs[ident] = self.d.dump(path)
            self.paths[ident] = path

    def targets(self, ident: str) -> dict[str, dict]:
        return {t["name"]: t for t in self.pkgs[ident]["targets"]}

    def product_targets(self, ident: str, product: str) -> list[str]:
        for p in self.pkgs.get(ident, {}).get("products", []):
            if p["name"] == product:
                return p["targets"]
        return []

    def find_product(self, product: str, among: list[str]) -> str | None:
        for ident in among:
            if self.product_targets(ident, product):
                return ident
        return None

    def package_deps(self, ident: str) -> list[str]:
        out = []
        for dep in self.pkgs[ident].get("dependencies", []):
            for kind in ("sourceControl", "fileSystem", "registry"):
                if kind in dep:
                    out.append(dep[kind][0]["identity"].lower())
        return out

    def closure(self, ident: str, target: str) -> set[tuple[str, str]]:
        """Every (package, target) linked by `target` of package `ident` (incl. itself)."""
        seen: set[tuple[str, str]] = set()
        stack = [(ident, target)]
        while stack:
            pk, tn = stack.pop()
            if (pk, tn) in seen or pk not in self.pkgs:
                continue
            seen.add((pk, tn))
            tmap = self.targets(pk)
            t = tmap.get(tn)
            if not t:
                continue
            for kind, name, dpk in dep_refs(t, self.traits.get(pk)):
                if kind == "target" or (kind == "byName" and name in tmap):
                    stack.append((pk, name))
                    continue
                owner = dpk if kind == "product" else self.find_product(name, self.package_deps(pk))
                if owner is None:
                    continue
                for pt in self.product_targets(owner, name):
                    stack.append((owner, pt))
        return seen


def repo_files(root: Path = ROOT, suffixes: tuple[str, ...] = (".swift",)) -> list[Path]:
    """Tracked + untracked-not-ignored files of the superproject (submodule contents excluded)."""
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"],
                         capture_output=True, text=True, check=True).stdout
    files = []
    for name in out.split("\0"):
        if name and name.endswith(suffixes):
            p = root / name
            if p.is_file():
                files.append(p)
    return sorted(files)


def load_allowlist(path: Path) -> list[dict]:
    """A YAML list of flat string mappings (`- path: …` / `  match: …`). PyYAML when present, else this subset
    parser (so the audits run under the system `python3 -I`). Values may be single- or double-quoted; no
    inline comments, no multi-line values."""
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text) or []
        if isinstance(data, dict):
            data = data.get("entries", [])
        return [dict((k, str(v)) for k, v in e.items()) for e in data]
    except ImportError:
        pass
    entries: list[dict] = []
    for raw in text.splitlines():
        line = raw.rstrip()  # full-line `#` comments only (values are regexes and may contain `#`)
        if not line.strip() or line.lstrip().startswith("#") or line.strip() == "entries:":
            continue
        s = line.strip()
        if s.startswith("- "):
            entries.append({})
            s = s[2:]
        if ":" not in s or not entries:
            raise ValueError(f"{path}: cannot parse line {raw!r}")
        k, v = s.split(":", 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1].replace("''", "'") if v[0] == "'" else v[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        entries[-1][k.strip()] = v
    return entries


def validate_allowlist(entries: list[dict], required: tuple[str, ...], name: str) -> list[str]:
    errs = []
    for i, e in enumerate(entries):
        miss = [k for k in required if not e.get(k)]
        if miss:
            errs.append(f"{name}: entry {i + 1} missing {', '.join(miss)}")
    return errs


def allowed(entries: list[dict], relpath: str, line: str) -> bool:
    import fnmatch
    import re as _re

    for e in entries:
        if fnmatch.fnmatch(relpath, e["path"]) and _re.search(e["match"], line):
            return True
    return False
