#!/usr/bin/env bash
# Background test runs (BackgroundRun, Packages/UI/Sources/AntiChatUI/Window/BackgroundRun.swift): tests and automation
# never bring AntiChat forward or inject input into the owner's session. Exit 1 on a hit.
#   1. No global (CGEvent/HID/AppleScript) keyboard or mouse event posting anywhere in our code or tools.
#   2. Test code (unit + integration suites) and the in-process probes never activate the app or order a window front
#      themselves: they go through BackgroundRun (present / makeKeyAndOrderFront / activate). Exceptions: XCUITest
#      (App/UITests, a real foreground app, Q-015) and the visual-QA capture (VisualQAProbe), which shows its windows.
#   3. Scripts never `open` an app or document in the foreground (`open -g`).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${NO_FOCUS_STEAL_ROOT:-$root}"
bad=0

post=$(git ls-files -- 'Packages/*' 'App/*' 'tools/*' 'Benchmarks/*' | grep -E '\.(swift|m|c|sh|py|applescript|scpt)$' \
  | grep -v '^tools/ci/no-focus-steal.sh$' \
  | xargs grep -nE 'CGEventPost|\.post\(tap:|postToPid|CGEventTapPostEvent|CGPostKeyboardEvent|CGPostMouseEvent|IOHIDPostEvent|keystroke +["$]|key code +[0-9$]' 2>/dev/null || true)
if [[ -n $post ]]; then echo "$post"; echo "global input event posting is forbidden (deliver synthetic input with NSWindow.sendEvent)"; bad=1; fi

front=$(git ls-files -- 'Packages/*/Tests/*.swift' 'App/IntegrationTests/*.swift' 'App/AntiChat/*Probe.swift' \
  | grep -v '^App/AntiChat/VisualQAProbe.swift$' \
  | xargs grep -nE 'makeKeyAndOrderFront\(|orderFrontRegardless\(|\.orderFront\(|NSApp\.activate|activateIgnoringOtherApps|\.activate\(options|setActivationPolicy\(\.(regular|accessory)' 2>/dev/null \
  | grep -v 'BackgroundRun\.' || true)
if [[ -n $front ]]; then echo "$front"; echo "tests/probes must show windows through BackgroundRun (never activate, never front)"; bad=1; fi

opens=$(git ls-files -- 'tools/*' | grep -E '\.(sh|py|zsh)$|^tools/[^.]*$' | grep -v '^tools/ci/no-focus-steal.sh$' \
  | xargs grep -nE '(^|[;&|(` ])open +(-[a-zA-Z]+ +)*(-[abn]\b|"?\$|[^ -]+\.app)' 2>/dev/null \
  | grep -vE 'open +(-[a-zA-Z]+ +)*-[a-zA-Z]*g' || true)
if [[ -n $opens ]]; then echo "$opens"; echo "scripts must open apps in the background (open -g)"; bad=1; fi

[[ $bad == 0 ]] && echo "ok: no focus stealing, no global input events"
exit $bad
