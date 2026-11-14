#!/bin/bash
# AT-FA-07 Evil mode (journey 7) in the clean VM, FinalAcceptanceProbe leg `evil`: off → refused without the 18+ box →
# enabled with it → ⇧⌘E new Evil chat → frame + text badge → a lawful prompt answered on the Evil model → mode locked.
set -uo pipefail
source "$(dirname "$0")/fa-common.sh"
o="$(fa_out AT-FA-07)"; p="$HOME/fa/evil"; rm -rf "$p"
probe "$p" evil 1800
cp -R "$p/." "$o/"
j="$o/probe.json"
check "Evil switch hidden while Evil is off" "[ \"\$(json '$j' 'j[\"switchHiddenWhenOff\"]')\" = True ]"
check "enable refused without the 18+ box" "[ \"\$(json '$j' 'j[\"refusedWithoutAdultBox\"]')\" = True ]"
check "enabled with the 18+ box (consent recorded)" "[ \"\$(json '$j' 'j[\"enabled\"]')\" = True ]"
check "⇧⌘E opened a new Evil chat" "[ \"\$(json '$j' 'j[\"newEvilChat\"]')\" = True ]"
check "frame + text badge shown (S-06)" "[ \"\$(json '$j' 'j[\"frameShown\"]')\" = True ] && [ \"\$(json '$j' 'j[\"badgeShown\"]')\" = True ]"
check "lawful prompt answered on the Evil model ($(json "$j" 'j["evilSlot"]'))" "[ \"\$(json '$j' 'j[\"reply\"][\"status\"]')\" = done ] && [ -n \"\$(json '$j' 'j[\"reply\"][\"text\"].strip()')\" ]"
chat="$(json "$j" 'j["reply"]["chatID"]')"
check "the chat row is an Evil chat and the reply ran on an evil-* model" "[ \"\$(sql \"SELECT mode FROM chat WHERE id='$chat'\")\" = evil ] && sql \"SELECT model_id FROM message WHERE chat_id='$chat' AND role='assistant'\" | grep -q '^evil-'"
check "mode switch locked once the chat has messages" "[ \"\$(json '$j' 'j[\"modeLocked\"]')\" = True ]"
check "sidebar row marked Evil" "[ \"\$(json '$j' 'j[\"sidebarEvilRow\"]')\" = True ]"
collect_logs "$o"; fa_result "$o" AT-FA-07 "dev (Debug test build, clean VM, real Evil model)"
