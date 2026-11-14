# vq-14 — Mac integration visual QA (M8.T13: menu bar item S-23, quick panel S-22)

Executed at M8.T16 (AT-VQ-M8) by the QA agent with the computer-use grant for AntiChat and Finder **[perm]**. This
is the one place visual QA brings AntiChat to the front (BackgroundRun exception: the capture must show its windows).
Captures: `build/visual/<version>/vq-14/`, light and dark (`osascript -e 'tell app "System Events" to tell appearance
preferences to set dark mode to <true|false>'`). Scores on parity-rubric §1 against S-22 / S-23 ≥ 4.0.

## Menu bar item (AT-105; S-23 ≥ 4.0)
1. Launch `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq14 -SkipOnboarding YES`
   (Settings › General › Menu bar item is on by default).
2. Click the AntiChat item in the menu bar: New Chat ⌘N · Quick Panel (⌥Space) · Start Voice (disabled with
   "Install Voice to use this" without the Voice pack) · ─ · Open AntiChat · Quit AntiChat ⌘Q.
   `screencapture -x -R0,0,600,400 build/visual/$VER/vq-14/menubar-menu-light.png`, then `-dark`.
3. Start a scripted job (the probe's `menubar` mode recipe: a `scripted:30:150` job, or a real picture with the
   Photo pack) and open the menu: the icon shows the activity dot and the menu a progress row ("Photo 42%",
   "Video · 1:20 left") → `menubar-progress`.
4. Settings › General › Menu bar item off: the item disappears at once; on: it is back.

## Quick panel (AT-106; S-22 ≥ 4.0, C: NFR-U9 hard check)
1. Finder in front; press ⌥Space (computer-use `key` "option+space") → the floating composer, empty and focused,
   centred a fifth down the screen → `qp-open`.
2. Type "What's 2+2?" + Return → the reply streams under the field, the panel grows to 640×480 → `qp-streaming`;
   when done → `qp-done`.
3. Esc → the reply area collapses (640×120) → `qp-collapsed`; Esc again hides the panel.
4. ⌥Space, ask again, ⌘O while it streams → the main window shows the same chat, still streaming → `qp-open-in-app`.
5. Repeat 1–4 in dark mode.
6. Settings › General › Quick panel hotkey: record ⌃⌥Q (⌥Space no longer opens it), clear it (Off: nothing opens),
   restore ⌥Space. With a launcher holding ⌥Space (Raycast/Alfred), the row shows `qp.conflict`.
