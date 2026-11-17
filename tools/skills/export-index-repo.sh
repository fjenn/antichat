#!/bin/zsh
# Copies the skills index tooling from here (the source) into the public index repository's working folder, so the
# two cannot drift silently. Nothing is committed or pushed: look at `git status` there, then commit and push.
#   tools/skills/export-index-repo.sh [--check] [DEST]     DEST defaults to ~/AntiChat-skills-index
#   --check   copy nothing; exit 1 when a file there differs from its source here
# skills-index.json is the index repository's own file once it exists (its weekly workflow writes it): it is
# seeded from the app's bundled copy only when DEST has none.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
check=0
if [[ ${1:-} == --check ]]; then check=1; shift; fi
dest=${1:-$HOME/AntiChat-skills-index}
pairs=(
  build-index.py build-index.py
  refresh.py refresh.py
  overrides.json overrides.json
  NOTICE.md NOTICE.md
  index-repo/README.md README.md
  index-repo/LICENSE LICENSE
  index-repo/.github/workflows/refresh.yml .github/workflows/refresh.yml
)
drift=0
for src to in $pairs; do
  if (( check )); then
    cmp -s "$here/$src" "$dest/$to" || { echo "differs: $dest/$to (source: tools/skills/$src)"; drift=1; }
  else
    mkdir -p "${dest}/${to:h}"
    cp "$here/$src" "$dest/$to"
  fi
done
if (( check )); then
  (( drift )) && exit 1
  echo "index repository tooling matches tools/skills"
  exit 0
fi
chmod +x "$dest/build-index.py" "$dest/refresh.py"
if [[ ! -f $dest/skills-index.json ]]; then
  cp "$root/Packages/Tools/Sources/AntiChatTools/Resources/skills-index.json" "$dest/skills-index.json"
  echo "seeded $dest/skills-index.json from the app's bundled index"
fi
echo "copied the tooling into $dest"
[[ -d $dest/.git ]] && git -C "$dest" status --short
exit 0
