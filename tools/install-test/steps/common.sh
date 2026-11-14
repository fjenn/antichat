#!/bin/bash
# Shared by the in-VM steps (sourced). `app` = the installed bundle.
bin="$app/Contents/MacOS/AntiChat"
bundle="$(defaults read "$app/Contents/Info" CFBundleIdentifier)"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The test build is a Debug build (the install hooks are DEBUG-only): its folders are AntiChat-Dev, its defaults
# domain the .dev bundle id. Check the documented list for both spellings.
paths="$here/antichat-paths.all.txt"
{ cat "$here/antichat-paths.txt"; sed -n 's#/AntiChat$#/AntiChat-Dev#p' "$here/antichat-paths.txt"; } > "$paths"
# A real launch in the logged-in GUI session (the VM auto-logs in admin) creates the container, caches and logs.
launch_once() {
  echo "guest uptime: $(uptime)"
  # The in-process scripted engine: no helper or Metal work in the VM (its paravirtual GPU is not what is tested here).
  open -g -n "$app" --args -SkipOnboarding YES -UseScriptedEngine "$here/basic.jsonl" -OfflineOnly YES
  for _ in $(seq 1 60); do [ -d "$HOME/Library/Application Support/AntiChat-Dev" ] && break; sleep 1; done
  sleep 8
  # SIGTERM, not an Apple event: `osascript … quit` waits on an Automation consent dialog nobody answers in a VM.
  pkill -TERM -f "$bin" 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -f "$bin" >/dev/null || break; sleep 1; done
  pkill -KILL -f "$bin" 2>/dev/null || true
  [ -d "$HOME/Library/Application Support/AntiChat-Dev" ] || { echo "precondition: the launch created no container"; exit 1; }
  echo "seeded: $(du -sh "$HOME/Library/Application Support/AntiChat-Dev" | cut -f1) container"
}
zero() {
  "$here/zero-files.sh" --paths "$paths" --bundle-id "$bundle" && return 0
  echo "-- leftovers in detail:"
  for d in "$HOME/Library/Logs/AntiChat" "$HOME/Library/Logs/AntiChat-Dev" "$HOME/Library/Caches/AntiChat" "$HOME/Library/Caches/AntiChat-Dev"; do
    [ -e "$d" ] && ls -laR "$d" | head -30
  done
  for f in "$HOME/Library/Preferences/$bundle.plist"; do [ -e "$f" ] && { ls -la "$f"; plutil -p "$f" | head -30; }; done
  return 1
}
