#!/bin/bash
# tools/release/export-public.sh — copy the committed main tree (HEAD) into a working clone of the public
# repository, filtered. Releases are built there by GitHub (.github/workflows/release.yml).
#
#   tools/release/export-public.sh [DEST]           DEST = a clone of the public repo (default ~/AntiChat-public)
#   tools/release/export-public.sh --plain DEST     DEST = a new or empty directory, no git (a look at the result)
#
# What it does (nothing is committed, nothing is pushed, no network):
#   1. checks: DEST is a clean clone whose `origin` is Config/Hosting.json githubRepo, outside this repository;
#   2. empties DEST of its tracked files, then extracts `git archive HEAD` minus every `exclude` line of
#      tools/release/public-export.manifest (one pass, deterministic: the same HEAD gives the same tree);
#   3. drops the .gitmodules entries of submodules that are not exported, keeps the others as gitlinks (the pinned
#      commits are staged in DEST's index, the only way to record them without a checkout);
#   4. writes SOURCE_REVISION (this tree's commit and commit count; build-release.sh uses the count as the build
#      number, so builds made on GitHub keep counting where the local ones stopped);
#   5. refuses the result (exit 1) when anything private is in it: a path under an exclude, a key / certificate /
#      .env file, or text that looks like a credential (list: the manifest's header);
#   6. checks that everything release.yml needs is there, then prints what changed (added / changed / removed)
#      and the commands to review, commit and push — which stay with the owner.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
manifest="tools/release/public-export.manifest"
plain=0 dest=""
while (($# > 0)); do
    case "$1" in
        --plain) plain=1; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; exit 2 ;;
        *) [[ -z "$dest" ]] || { echo "error: one destination only" >&2; exit 2; }; dest="$1"; shift ;;
    esac
done
dest="${dest:-$HOME/AntiChat-public}"
fail() { echo "export-public: $*" >&2; exit 1; }
repo="$(python3 -I -c 'import json; print(json.load(open("Config/Hosting.json"))["githubRepo"])')"

# ---- 1. checks -------------------------------------------------------------------------------------------------
[[ -f "$manifest" ]] || fail "$manifest missing"
[[ -z "$(git ls-files -- SOURCE_REVISION)" ]] || fail "SOURCE_REVISION is tracked in the main tree; it belongs to the public snapshot only"
dirty="$(git status --porcelain -- . ':(exclude)build' | wc -l | tr -d ' ')"
[[ "$dirty" == 0 ]] || echo "note: $dirty uncommitted change(s) in the main tree are NOT exported (only HEAD is)"
if ((plain)); then
    mkdir -p "$dest"
    [[ -z "$(ls -A "$dest")" ]] || fail "--plain needs a new or empty directory: $dest"
else
    [[ -d "$dest/.git" ]] || fail "$dest is not a clone of the public repository. Once: git clone https://github.com/$repo.git \"$dest\""
fi
dest="$(cd "$dest" && pwd -P)"
case "$dest/" in "$ROOT"/*) fail "the destination must be outside this repository" ;; esac
[[ "$dest" != "$HOME" && "$dest" != / ]] || fail "refusing $dest"
if ((!plain)); then
    origin="$(git -C "$dest" remote get-url origin 2>/dev/null || true)"
    [[ "$origin" =~ [:/]${repo}(\.git)?/?$ ]] || fail "$dest: origin is '${origin:-none}', expected $repo (its tracked files would be replaced)"
    [[ -z "$(git -C "$dest" status --porcelain)" ]] || fail "$dest has uncommitted changes; commit or discard them first (git -C \"$dest\" status)"
fi

excl=() ; allow=()
while read -r kind pattern; do
    case "$kind" in
        exclude) excl+=("$pattern") ;;
        allow) allow+=("$pattern") ;;
        ""|\#*) ;;
        *) fail "$manifest: unknown line '$kind $pattern'" ;;
    esac
done < "$manifest"
((${#excl[@]} > 0)) || fail "$manifest has no exclude lines"
spec=(.); for p in "${excl[@]}"; do spec+=(":(exclude,glob)$p"); done

commit="$(git rev-parse HEAD)"
count="$(git rev-list --count HEAD)"
# The submodules that are exported, as "<sha> <path>" lines (gitlinks of HEAD that no exclude matches).
links="$(git ls-files -s -- "${spec[@]}" | awk '$1 == "160000" { print $2, $4 }')"
if ((!plain)); then
    while read -r sha path; do
        [[ -n "$path" && -e "$dest/$path/.git" ]] || continue
        [[ "$(git -C "$dest/$path" rev-parse HEAD)" == "$sha" ]] || fail "$dest/$path is checked out at another commit than the pinned $sha (git -C \"$dest\" submodule deinit -f $path)"
    done <<< "$links"
fi

# ---- 2. replace the tracked files with the filtered archive ------------------------------------------------------
if ((!plain)); then
    git -C "$dest" ls-files -s -z | python3 -I -c '
import os, sys
dest = sys.argv[1]
for rec in sys.stdin.buffer.read().split(b"\0"):
    if not rec:
        continue
    meta, path = rec.split(b"\t", 1)
    if meta.startswith(b"160000"):
        continue                                   # a submodule: its directory stays
    full = os.path.join(dest, os.fsdecode(path))
    if os.path.commonpath([dest, os.path.realpath(os.path.dirname(full))]) != dest:
        sys.exit(f"export-public: {full} resolves outside the destination")
    if os.path.lexists(full):
        os.remove(full)
' "$dest"
fi
git archive --format=tar HEAD -- "${spec[@]}" | tar -x -C "$dest"

# ---- 3. submodules ------------------------------------------------------------------------------------------------
while read -r name; do
    [[ -n "$name" ]] || continue
    path="$(git config -f .gitmodules "submodule.$name.path")"
    grep -q " $path\$" <<< "$links" || git config -f "$dest/.gitmodules" --remove-section "submodule.$name"
done < <(git config -f .gitmodules --name-only --get-regexp '^submodule\..*\.path$' | sed -e 's/^submodule\.//' -e 's/\.path$//')
if ((!plain)); then
    while read -r sha path; do
        [[ -n "$path" ]] || continue
        have="$(git -C "$dest" ls-files -s -- "$path" | awk '{ print $2 }')"
        [[ "$have" == "$sha" ]] || git -C "$dest" update-index --add --cacheinfo "160000,$sha,$path"
    done <<< "$links"
fi

# ---- 4. SOURCE_REVISION -------------------------------------------------------------------------------------------
cat > "$dest/SOURCE_REVISION" <<EOF
# Written by tools/release/export-public.sh: the revision of the main tree this snapshot was exported from.
# build = the CFBundleVersion of a release built from this snapshot (tools/release/build-release.sh).
commit=$commit
build=$count
EOF

# ---- 5 + 6. leak scan, required files, summary ------------------------------------------------------------------
python3 -I - "$dest" "$plain" "$HOME" "${#excl[@]}" "${excl[@]}" ${allow[@]+"${allow[@]}"} <<'PY'
import fnmatch, os, re, subprocess, sys

dest, plain, home, n_excl = sys.argv[1], sys.argv[2] == "1", sys.argv[3], int(sys.argv[4])
excl, allow = sys.argv[5:5 + n_excl], sys.argv[5 + n_excl:]


def glob_re(pattern: str) -> re.Pattern:
    """git `:(glob)` rules: `**` crosses directories, `*` and `?` stay inside one component."""
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif pattern.startswith("**", i):
            out += ".*"; i += 2
        elif pattern[i] == "*":
            out += "[^/]*"; i += 1
        elif pattern[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(pattern[i]); i += 1
    return re.compile(out + "(?:/.*)?$")   # a matched directory covers everything below it


excl_re, allow_re = [glob_re(p) for p in excl], [glob_re(p) for p in allow]

# Every file a `git add -A` in the destination would commit (plain: every file).
if plain:
    paths = [os.path.relpath(os.path.join(d, f), dest) for d, _, fs in os.walk(dest) for f in fs]
else:
    out = subprocess.run(["git", "-C", dest, "ls-files", "-co", "--exclude-standard", "-z"],
                         capture_output=True, check=True).stdout
    paths = [os.fsdecode(p) for p in out.split(b"\0") if p]
    paths = [p for p in paths if os.path.isfile(os.path.join(dest, p)) or os.path.islink(os.path.join(dest, p))]
paths.sort()

NAMES = ("*.priv", "*.p12", "*.p8", "*.pem", "*.cer", "*.mobileprovision", "*.keychain-db", ".env*")
CONTENT = [
    ("private key block", r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----\s*[A-Za-z0-9+/]{32}"),
    ("GitHub token", r"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})"),
    ("Hugging Face token", r"(?<![A-Za-z0-9_])hf_[A-Za-z0-9]{30,}"),
    ("AWS access key", r"(?<![A-Za-z0-9])AKIA[0-9A-Z]{16}(?![A-Za-z0-9])"),
    ("Slack token", r"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{20,}"),
    ("Anthropic / OpenAI key", r"(?<![A-Za-z0-9_-])sk-(?:ant-|proj-)?[A-Za-z0-9_-]{40,}"),
    ("Composio key", r"(?<![A-Za-z0-9_])(?:ak|ck|uak)_[A-Za-z0-9]{20,}(?![A-Za-z0-9_])"),
    ("Apple app-specific password", r"(?<![a-z-])[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}(?![a-z-])"),
    ("credential assignment",
     r"(?:SECRET|TOKEN|PASSWORD|API_KEY|PRIVATE_KEY)[A-Z_]*[\"']?\s*[:=]\s*[\"']?(?=[A-Za-z0-9+/_-]*[0-9])(?=[A-Za-z0-9+/_-]*[a-z])(?=[A-Za-z0-9+/_-]*[A-Z])[A-Za-z0-9+/_-]{32,}"),
]
CONTENT = [(name, re.compile(rx.encode())) for name, rx in CONTENT]
home_b = home.encode()

bad, home_refs = [], []
for p in paths:
    if any(r.match(p) for r in excl_re):
        bad.append(f"{p}: under an exclude of the manifest")
    base = os.path.basename(p)
    if any(fnmatch.fnmatchcase(base, n) for n in NAMES):
        bad.append(f"{p}: key / certificate / .env file")
    full = os.path.join(dest, p)
    if os.path.islink(full) or any(r.match(p) for r in allow_re):
        continue
    with open(full, "rb") as f:
        data = f.read()
    if b"\0" in data[:8192]:
        continue                                    # binary
    for name, rx in CONTENT:
        m = rx.search(data)
        if m:
            line = data.count(b"\n", 0, m.start()) + 1
            bad.append(f"{p}:{line}: looks like a {name}")   # the match itself is never printed
    if home_b in data:
        home_refs.append(p)

NEED = [
    ".github/workflows/release.yml", ".github/actionlint.yaml", ".gitmodules", "SOURCE_REVISION", "Makefile",
    "project.yml", "Package.swift", "Package.resolved", "AntiChat.xcodeproj/project.pbxproj",
    "AntiChat.xcworkspace/contents.xcworkspacedata", "AntiChat.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "AntiChat.xcodeproj/xcshareddata/xcschemes/AntiChat-Release.xcscheme",
    "Binaries/checksums.json", "tools/env.sh", "tools/binaries/build.sh", "tools/binaries/stage.sh",
    "tools/binaries/git-pinned.sh", "Config/Keys.release.plist", "Config/Keys.dev.plist", "Config/Endpoints.plist",
    "Config/Hosting.json", "catalog/test-keys/FINGERPRINTS", "catalog/test-keys/sparkle-test.key",
    "catalog/runtimes.yaml", "tools/release/release.sh", "tools/release/build-release.sh", "tools/release/sign.sh",
    "tools/release/verify-signing.sh", "tools/release/notarize.sh", "tools/release/package-dmg.sh",
    "tools/release/verify-dmg.sh", "tools/release/appcast.sh", "tools/release/appcast-post.py",
    "tools/release/appcast-lint.py", "tools/release/notes-check.py", "tools/release/checklist-check.py",
    "tools/release/preflight.py", "tools/release/gen-keys-swift.py", "tools/release/sparkle-pubkey.swift",
    "tools/release/CHECKLIST.md", "tools/release/requirements.lock", "tools/release/lib/identity.sh",
    "tools/release/dmg/settings.py", "tools/release/dmg/background.tiff", "tools/release/dmg/dropinstall/build.sh",
    "tools/ci/dev-modes-guard.py", "tools/ci/perfharness-guard.py", "tools/ci/devfeed-guard.py",
    "tools/ci/tryout-guard.py", "tools/ci/release-lint.py", "tools/ci/endpoints-check.py",
]
NEED_DIRS = ["App", "Packages", "Vendor", "notes", "tools/release/entitlements", "Vendor/patches/sdcpp"]
have = set(paths)
missing = [p for p in NEED if p not in have]
missing += [d + "/" for d in NEED_DIRS if not any(p.startswith(d + "/") for p in paths)]
gm = open(os.path.join(dest, ".gitmodules")).read() if ".gitmodules" in have else ""
if "file://" in gm or home in gm:
    bad.append(".gitmodules: still names a local repository")
for sub in ("Binaries/llama.cpp", "Binaries/sdcpp"):
    if f"path = {sub}" not in gm:
        missing.append(f".gitmodules entry for {sub}")
if not plain:
    idx = subprocess.run(["git", "-C", dest, "ls-files", "-s"], capture_output=True, text=True, check=True).stdout
    links = {l.split("\t", 1)[1] for l in idx.splitlines() if l.startswith("160000")}
    missing += [f"gitlink {s}" for s in ("Binaries/llama.cpp", "Binaries/sdcpp") if s not in links]
    if "fixtures" in links:
        bad.append("fixtures: gitlink still in the index (git -C DEST rm --cached fixtures)")

size = sum(os.lstat(os.path.join(dest, p)).st_size for p in paths)
print(f"export-public: {len(paths)} files, {size / 1048576:.0f} MB in {dest}")
if plain:
    print("  plain export (no clone): no added / changed / removed counts")
else:
    st = subprocess.run(["git", "-C", dest, "status", "--porcelain", "-uall"], capture_output=True, text=True,
                        check=True).stdout.splitlines()
    added = sum(1 for l in st if l[:2] in ("??", "A ", " A"))
    removed = sum(1 for l in st if "D" in l[:2])
    changed = len(st) - added - removed
    print(f"  against the clone's HEAD: {added} added, {changed} changed, {removed} removed")
    for l in st:
        if l[:2] != "??" and l[3:] in links:
            print(f"  submodule pin staged: {l[3:]}")
if home_refs:
    print(f"  note: {len(home_refs)} file(s) mention {home} (a path, not a secret): " + ", ".join(home_refs[:12])
          + (" …" if len(home_refs) > 12 else ""))
for m in missing:
    print(f"  MISSING (release.yml needs it): {m}")
for b in bad:
    print(f"  PRIVATE: {b}")
if bad or missing:
    print("export-public: REFUSED. Do not commit this tree. Fix the main tree or the manifest, then export again"
          + ("" if plain else f" (undo: git -C \"{dest}\" reset --hard && git -C \"{dest}\" clean -fd)") + ".")
    sys.exit(1)
print("export-public: ok. Nothing private found, everything release.yml needs is there. Nothing was committed.")
if not plain:
    print(f"""next (yours):
  git -C "{dest}" status --short | less          # review
  git -C "{dest}" add -A && git -C "{dest}" commit -m "AntiChat <version>: <summary>"
  git -C "{dest}" push origin main""")
PY
