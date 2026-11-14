# vq-00 — M0 proof visual QA (AT-VQ-M0)

Runbook for `AT-VQ-M0` (docs/prd/M0.md, M0.T15). Executed by a QA agent with computer use (permission **P-CU**),
or by a person following the same steps. Captures go to `build/visual/m0/`; findings to
`build/visual/m0/findings.md`. `make m0-gate AT=AT-VQ-M0` (`tools/m0/at-vq-m0.sh`) then checks them.

No product screen exists in M0, so there is no rubric score. Hard check **H5** (copy sync) applies to the two
strings shown and is also checked automatically by the gate script against `copy-deck.md`:
- `engine.restarted` = "The AI engine restarted." + **Retry**
- `voice.permission` = "AntiChat needs the microphone to hear you. Your voice stays on this Mac."

## Preconditions
1. Ad-hoc signed Release build from M0.T12: `make build-release SIGNING_MODE=adhoc` → `build/AntiChat.app`
   (bundle id `app.antichat.AntiChat`). Copy: `ditto build/AntiChat.app /Applications/AntiChat-M0.app`.
2. Dev models present: `chat-0.8b` at least (`python3 -I tools/dev/hf-fetch.py --set min`); the spike UI uses
   the default spike model of `DevModels.swift`.
3. `mkdir -p build/visual/m0`.
4. Computer use: `request_access(["AntiChat","System Settings","Finder"])` (+ the Gatekeeper dialog is shown by
   CoreServicesUIAgent; screenshot it, do not click "Move to Trash"). **This needs the user's one-time approval in
   the computer-use dialog** (and the screen must not be in use by another session, Q-005).
5. Light appearance first, window 1180×820. Then dark for A5.

Screenshots: `screencapture -x build/visual/m0/<name>.png` from Bash is acceptable if the terminal has Screen
Recording permission; otherwise use the computer-use `screenshot` and save it under the same name.

## Part A — engine crash with the UI alive (M0.T04; previews S-25 "engine-crash" for M1)
| Step | Action | Capture | Check |
|---|---|---|---|
| A1 | `open -n /Applications/AntiChat-M0.app --args -SpikeUI YES` | `A1-idle.png` | spike window shown, composer focused |
| A2 | type "Write 300 words about tides." + Return; wait 1 s | `A2-streaming.png` | text visibly streaming |
| A3 | Bash: `kill -9 $(pgrep -f 'AntiChat-M0.app/Contents/XPCServices/AntiChatEngine')` (exact pid, no pattern kill of other apps); within 1 s type "still here" | `A3-after-kill.png` | typed text visible; transcript shows **"The AI engine restarted."** + **Retry** |
| A4 | click Retry | `A4-recovered.png` (≤ 5 s after the kill) | a new reply streams |
| A5 | AntiChat Settings → Appearance → Color mode → Dark (the app's own override; `-AppleInterfaceStyle Dark` does not reach a window whose Color mode is System); repeat A1–A4 | `A5-dark-A1.png` … `A5-dark-A4.png` | same as A1–A4 |

**Pass:** A3 shows the exact copy and the typed text, and A4 streams ≤ 5 s after the kill (both appearances).

## Part B — microphone permission attribution (M0.T05)
| Step | Action | Capture | Check |
|---|---|---|---|
| B1 | `tccutil reset Microphone app.antichat.AntiChat`; `/Applications/AntiChat-M0.app/Contents/MacOS/AntiChat -Bench voice --mode live --seconds 3 --raw build/visual/m0/live.jsonl` | — | helper starts capture |
| B2 | screenshot the system prompt | `B2-tcc-prompt.png` | title names **"AntiChat"**; body is the `voice.permission` text |
| B3 | click **Allow**; System Settings → Privacy & Security → Microphone | `B3-tcc-list.png` | exactly one "AntiChat" entry, enabled |

**Pass:** both checks hold (else the T05 fallback — capture in the app, PCM to the helper — is required and
re-checked). Clicking Allow on a TCC prompt grants a privacy permission: the agent asks the user first, or the
user clicks it (as in M0.T05).

## Part C — signed launch (M0.T12)
| Step | Action | Capture | Check |
|---|---|---|---|
| C1 | `xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" /Applications/AntiChat-M0.app` (simulate a download), then double-click it in Finder | `C1-gatekeeper.png` | record the dialog text (an "unidentified developer"/"cannot be opened" dialog is expected for ad-hoc) |
| C1b | if blocked: right-click → Open → Open (or System Settings → Privacy & Security → "Open Anyway") | `C1b-open.png` | app opens after the documented ad-hoc user path |
| C2 | window appears; repeat A2 | `C2-running.png` | reply streams |

**Pass:** the app runs after the documented user path for ad-hoc builds.

## Findings
Write `build/visual/m0/findings.md`, one line per checkpoint:
`- A3 pass build/visual/m0/A3-after-kill.png — <note>` (use `pass` / `fail`). Every `fail` becomes a bug for
independent triage (test-strategy §11). Then run `make m0-gate AT=AT-VQ-M0`.

## Fallback (M0.md T15 failure modes)
Computer use not granted → `Q-###`; parts A/C fall back to XCUITest screenshots (`XCUIScreen.main.screenshot()`,
needs automation mode, Q-015); part B cannot be automated (the TCC prompt is outside the app) and stays open for
M3 vq-08 (minor).
