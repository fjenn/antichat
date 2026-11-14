#!/bin/bash
# AT-FA-11 relaunch keeps history, in the clean VM after AT-FA-02…10 filled it: quit → canonical dump of the database
# (tools/ci/db-canon.py: chats, messages, parts, attachments, drafts, feedback, projects, memories) + the settings
# domain → relaunch (FinalAcceptanceProbe leg `relaunch`: what the window shows) → quit → dump again → equal.
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o="$(fa_out AT-FA-11)"; p="$HOME/fa/relaunch"; rm -rf "$p"
app_quit
dump() {  # dump <tag>
    python3 -I "$STEPS/db-canon.py" "$DB" --out "$o/db-$1.json" 2> "$o/db-$1.sha"
    defaults export "$DOMAIN" - | plutil -convert json -o - - | python3 -I -c 'import json,sys
d=json.load(sys.stdin)
# Window frames, launch counters and probe-only keys move on every launch; settings are everything else.
skip=("NSWindow", "NSSplitView", "NSStatusItem", "NSNavLast", "NSTableView", "SULast", "Apple", "com.apple", "WebKit")
print(json.dumps({k: d[k] for k in sorted(d) if not k.startswith(skip)}, indent=1, sort_keys=True, default=str))' > "$o/settings-$1.json"
}
dump before
probe "$p" relaunch 600
app_quit
dump after
cp -R "$p/." "$o/"
j="$o/probe.json"
counts() { python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1])); t=d.get("tables", d)
print(", ".join(f"{k} {len(v)}" for k, v in sorted(t.items()) if isinstance(v, list) and v))' "$1"; }
echo "before: $(counts "$o/db-before.json")"
check "history present before relaunch ($(counts "$o/db-before.json"))" "[ \"\$(json '$o/db-before.json' 'len((j.get(\"tables\") or j).get(\"chat\", []))')\" -gt 0 ]"
check "the window shows the history after relaunch ($(json "$j" 'j["sidebarTotal"]') chats in the sidebar)" "[ \"\$(json '$j' 'j[\"pass\"]')\" = True ]"
check "canonical database dump identical after the relaunch" "cmp -s '$o/db-before.json' '$o/db-after.json'"
check "settings identical after the relaunch" "cmp -s '$o/settings-before.json' '$o/settings-after.json'"
[ -f "$o/db-after.json" ] && ! cmp -s "$o/db-before.json" "$o/db-after.json" && diff "$o/db-before.json" "$o/db-after.json" | head -40 > "$o/db-diff.txt"
fa_result "$o" AT-FA-11 "dev (Debug test build, clean VM)"
