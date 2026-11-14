#!/bin/bash
# Removes the preference plists AntiChat's tests and probe scripts left in ~/Library/Preferences
# (fix/test-plist-hygiene; inventory and patterns: docs/prd/owner/plist-cleanup.md).
#
#   tools/dev/clean-test-plists.sh            # dry run: counts per pattern, deletes nothing
#   tools/dev/clean-test-plists.sh --list     # dry run + every matched path
#   tools/dev/clean-test-plists.sh --delete [--backup <file.tar.gz>]
#
# --delete (a) writes every matched file into a tar.gz backup (default ~/AntiChat-test-plists-<timestamp>.tar.gz) and
# checks it holds exactly the matched files, (b) deletes only those literal paths — regular files directly in
# /Users/armando/Library/Preferences/ whose name matches one of the patterns below exactly (prefix + UUID / pid /
# timestamp / mktemp suffix, each traced to a test or probe in this repo) — and (c) prints counts per pattern.
# Never touched: com.apple.*, the app's own domains (app.antichat.AntiChat*), anything a pattern does not match.
# Restore: tar -xzf <backup> -C /Users/armando/Library/Preferences
set -euo pipefail
export LC_ALL=C

PREFS=/Users/armando/Library/Preferences
mode=dry list=0 backup=""
while [ $# -gt 0 ]; do
  case $1 in
    --delete) mode=delete ;;
    --list) list=1 ;;
    --backup) backup=${2:?--backup needs a path}; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -d "$PREFS" ] || { echo "no $PREFS" >&2; exit 1; }

U='[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'  # Swift UUID().uuidString / "\(UUID())"
N='[0-9]+'                                                       # $$ / ProcessInfo pid / date +%s
X='[A-Za-z0-9]{6}'                                               # mktemp -d /tmp/<name>-XXXXXX

# label <TAB> anchored ERE on the file name. Unit/integration tests (now UserDefaults.inMemory()):
PATTERNS=$(cat <<EOF
caps-<UUID>	caps-$U
inj-<UUID>	inj-$U
inj-sw-<UUID>	inj-sw-$U
antichat-net-test-<UUID>	antichat-net-test-$U
mcp-turn-<UUID>	mcp-turn-$U
mcp-host-tests-<UUID>	mcp-host-tests-$U
EvilSnapshotTests-<UUID>	EvilSnapshotTests-$U
ConsentVersionTests-<UUID>	ConsentVersionTests-$U
thr-<UUID>	thr-$U
updater-bridge-<UUID>	updater-bridge-$U
updater-beta-<UUID>	updater-beta-$U
privacy-tests-<UUID>	privacy-tests-$U
gate-<UUID>	gate-$U
crash-<UUID>	crash-$U
antichat-ui-net-<UUID>	antichat-ui-net-$U
OnboardingGateTests-<UUID>	OnboardingGateTests-$U
antichat.test.<UUID>	antichat\.test\.$U
sidepanel-<UUID>	sidepanel-$U
ship-<UUID>	ship-$U
ship-all-<UUID>	ship-all-$U
starter-sugg-<UUID>	starter-sugg-$U
refuse-<UUID>	refuse-$U
ModeLockTests-<UUID>	ModeLockTests-$U
safe-<UUID>	safe-$U
wsa-<UUID>	wsa-$U
consent-<UUID>	consent-$U
composio-host-<UUID>	composio-host-$U
composio-live-<UUID>	composio-live-$U
relay-tests-<UUID>	relay-tests-$U
relay-live-<UUID>	relay-live-$U
noauto-<UUID>	noauto-$U
mover-<UUID>	mover-$U
export-restore-<UUID>	export-restore-$U
whatsnew-<UUID>	whatsnew-$U
ft-client-<UUID>	ft-client-$U
tools-page-<UUID>	tools-page-$U
AppLanguageTests-<UUID>	AppLanguageTests-$U
LaunchOverrideTests-<UUID>	LaunchOverrideTests-$U
r241-m7-<UUID>	r241-m7-$U
r241-m7-sw-<UUID>	r241-m7-sw-$U
EvilEntryHostTests-<UUID>	EvilEntryHostTests-$U
script-policy-<UUID>	script-policy-$U
switches-<UUID>	switches-$U
last-shown-<UUID>	last-shown-$U
memory-defaults-<UUID>	memory-defaults-$U
mvm-<UUID>	mvm-$U
video-elig-<UUID>	video-elig-$U
base-<UUID>	base-$U
t13-<UUID>	t13-$U
t13v-<UUID>	t13v-$U
snap-<UUID>	snap-$U
t-<UUID>	t-$U
fix-<UUID>	fix-$U
ff-<UUID>	ff-$U
dp-<UUID>	dp-$U
ssr-<UUID>	ssr-$U
tool-loop-<UUID>	tool-loop-$U
tool-loop-net-<UUID>	tool-loop-net-$U
npd-<UUID>	npd-$U
antichat-test-net-policy.<pid>	antichat-test-net-policy\.$N
antichat-uitest-<UUID>	antichat-uitest-$U
antichat-uitest-help-<UUID>	antichat-uitest-help-$U
antichat-uitest-legal-<UUID>	antichat-uitest-legal-$U
com.antichat.uitest.a11y.<UUID>	com\.antichat\.uitest\.a11y\.$U
mb-ui-<UUID>	mb-ui-$U
qp-ui-<UUID>	qp-ui-$U
notif-ui-<UUID>	notif-ui-$U
antichat-sec-ui-<UUID>	antichat-sec-ui-$U
tools-ui-<UUID>	tools-ui-$U
app.antichat.at105.<mode>.<pid>	app\.antichat\.at105\.[a-z-]+\.$N
app.antichat.at108.<mode>.<pid>	app\.antichat\.at108\.[a-z-]+\.$N
app.antichat.at109.<mode>.<pid>	app\.antichat\.at109\.[a-z-]+\.$N
app.antichat.s2.<pid>	app\.antichat\.s2\.$N
com.antichat.at100[.args].<time>	com\.antichat\.at100\.(args\.)?$N
com.antichat.at101.<time>	com\.antichat\.at101\.$N
com.antichat.at103.<time>[.w|.on|.off]	com\.antichat\.at103\.$N(\.(w|on|off))?
com.antichat.at223.<lang>.<time>	com\.antichat\.at223\.[A-Za-z_-]+\.$N
antichat-at080-<mktemp>	antichat-at080-antichat-at080-$X
antichat-at248-<mktemp>	antichat-at248-antichat-at248-$X
antichat-vqm6-<mktemp>	antichat-vqm6-antichat-vqm6-$X
antichat-vqm7-<mktemp>	antichat-vqm7-antichat-vqm7-$X
antichat-defcap-<mktemp>	antichat-defcap-antichat-defcap-$X
EOF
)

work=$(mktemp -d "${TMPDIR:-/tmp}/clean-test-plists.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Regular files directly in $PREFS (no symlinks, no subdirectories), names only.
find "$PREFS" -maxdepth 1 -type f -name '*.plist' -print | sed "s|^$PREFS/||" | sort > "$work/all"

: > "$work/matched"
total=0
printf '%-44s %7s\n' pattern files
while IFS=$'\t' read -r label rx; do
  [ -n "$label" ] || continue
  grep -E "^${rx}\.plist\$" "$work/all" > "$work/hit" || true
  n=$(wc -l < "$work/hit" | tr -d ' ')
  [ "$n" -gt 0 ] && printf '%-44s %7d\n' "$label" "$n"
  cat "$work/hit" >> "$work/matched"
  total=$((total + n))
done <<< "$PATTERNS"
sort -u "$work/matched" -o "$work/matched"
unique=$(wc -l < "$work/matched" | tr -d ' ')
[ "$unique" -eq "$total" ] || { echo "patterns overlap ($total hits, $unique files): refusing" >&2; exit 1; }
# Belt and braces: never com.apple.*, never the app's own domains.
if grep -E '^(com\.apple\.|app\.antichat\.AntiChat)' "$work/matched" >&2; then echo "refusing: protected name matched" >&2; exit 1; fi
printf '%-44s %7d\n' TOTAL "$total"
[ "$list" = 1 ] && sed "s|^|$PREFS/|" "$work/matched"

if [ "$mode" != delete ]; then
  echo "dry run: nothing deleted (pass --delete to back up and delete these $total files)"
  exit 0
fi
[ "$total" -gt 0 ] || { echo "nothing to delete"; exit 0; }

backup=${backup:-$HOME/AntiChat-test-plists-$(date +%Y%m%d-%H%M%S).tar.gz}
case $backup in "$PREFS"/*) echo "the backup must live outside $PREFS" >&2; exit 1 ;; esac
tar -czf "$backup" -C "$PREFS" -T "$work/matched"
tar -tzf "$backup" | sort > "$work/inbackup"
cmp -s "$work/inbackup" "$work/matched" || { echo "backup $backup does not hold exactly the matched files: nothing deleted" >&2; exit 1; }
echo "backup: $backup ($(wc -l < "$work/inbackup" | tr -d ' ') files)"

deleted=0
while IFS= read -r name; do
  case $name in */*|''|.*) echo "skipping odd name: $name" >&2; continue ;; esac
  path="$PREFS/$name"
  [ -f "$path" ] && [ ! -L "$path" ] || continue
  rm -f -- "$path"
  deleted=$((deleted + 1))
done < "$work/matched"
echo "deleted: $deleted of $total matched files under $PREFS/"
echo "restore: tar -xzf '$backup' -C '$PREFS'"
