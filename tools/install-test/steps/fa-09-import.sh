#!/bin/bash
# AT-FA-09 import a ChatGPT export (fixtures/chats/chatgpt-export/export.zip, synthetic) in the clean VM, through the
# Import sheet's own path (ImportCoordinator after Choose File; FinalAcceptanceProbe leg `import`): summary counts,
# chats tagged Imported in the sidebar, branches kept.
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o="$(fa_out AT-FA-09)"; p="$HOME/fa/import"; rm -rf "$p"; mkdir -p "$p"
zip="$ANTICHAT_FIXTURES/chats/chatgpt-export/export.zip"
printf '%s\n' "$zip" > "$p/import-file"
probe "$p" import 900
cp -R "$p/." "$o/"
j="$o/probe.json"
check "import finished without error" "[ -z \"\$(json '$j' 'j[\"failed\"]')\" ]"
check "summary: $(json "$j" 'j["summary"]["chats"]') chats, $(json "$j" 'j["summary"]["messages"]') messages, $(json "$j" 'j["summary"]["images"]') images" "[ \"\$(json '$j' 'j[\"summary\"][\"chats\"]')\" -gt 0 ]"
n="$(sql "SELECT count(*) FROM chat WHERE source = 'chatgpt'")"
check "the database holds the imported chats tagged source=chatgpt ($n = summary)" "[ '$n' = \"\$(json '$j' 'j[\"summary\"][\"chats\"]')\" ]"
check "the sidebar shows them tagged Imported" "[ \"\$(json '$j' 'j[\"sidebarShowsImported\"]')\" = True ]"
b="$(sql "SELECT count(*) FROM (SELECT parent_id FROM message m JOIN chat c ON c.id = m.chat_id WHERE c.source = 'chatgpt' AND parent_id IS NOT NULL GROUP BY parent_id HAVING count(*) > 1)")"
check "branches kept ($b branch points; the open chat shows $(json "$j" 'j["maxVersionsShown"]') versions)" "[ '$b' -gt 0 ] && [ \"\$(json '$j' 'j[\"maxVersionsShown\"]')\" -gt 1 ]"
fa_result "$o" AT-FA-09 "dev (Debug test build, clean VM)"
