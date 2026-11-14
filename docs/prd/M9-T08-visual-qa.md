# M9.T08 visual QA against the parity rubric (AT-VQ-M9)

**Branch:** `qa/visual` · **Date:** 2026-11-10 · **Rubric:** [`parity-rubric.md`](../research/10-architecture/design-system/parity-rubric.md) §1–§3 · **Reference:** ChatGPT for macOS screens `001`, `003`–`007` plus the onboarding images. We match the reference design language and never copy its assets or wording.

## 1. How the run was done

- **Build:** Debug `make build` (ad-hoc signed). `codesign --verify --deep --strict` passed before every launch (`tools/visual/vq-m9.sh` checks it itself).
- **Driving the app:** this session had no desktop computer-use tool, only the browser extension. So every screen was walked by the app's in-process visual-QA probes, the same mechanism as AT-VQ-M2…M7. Each probe puts the app into a state and asks the runner shell, which holds the Screen Recording grant, to take a `screencapture -l <window>`. Every shot was taken in system Light and Dark.
  - New this task: **`tools/visual/vq-m9.sh`**. Legs `m9` (S-05, S-08 streaming / done / populated sidebar, S-06, S-07, S-18, S-19, S-20, the Chats page, the 1180×820 repeat, all 13 S-21 sections) and `m9-crash` (S-25 engine restart).
  - Existing legs re-run: `vq-m7.sh` (S-10, S-21 Tools / Connections / Skills, S-24 search and MCP consent, S-25 offline chip), `vq-m6.sh` (S-14 / S-15), `vq-m3.sh` (S-16 / S-17), `vq-m2.sh` (S-01…S-04, install cards, Settings › Capabilities / Evil / Storage).
- **Isolation:** each leg ran in a fresh dev container (`-ANTICHAT_DEV_CONTAINER`) and a `com.antichat.uitest.*` defaults suite (`-FreshDefaultsSuite YES` where nothing is pre-seeded). The owner's app data was never touched. The scripted engine was used, with no model and no GPU.
- **Screenshots:** `build/at/AT-VQ-M9/after/<leg>__<shot>-{light,dark}.jpg` (151 shots, 1000 px), `build/at/AT-VQ-M9/before/` (the 12 shots behind the fixed findings), plus the probe JSONs and the vq-m6 / vq-m7 hard-check JSONs. Full-resolution sets were in `build/visual/` (not committed, deleted after the run).
- **Scoring:** a single scorer (this agent), dimensions L/V/C/S/K/A, score = (2L+2V+2C+S+K+A)/9. One line of evidence per change. **Deviation from rubric §4:** this is not the two-agent blind panel. The scores below come from the builder who made the fixes. They are an input to the blind M9 exit scoring, not a replacement for it.
- **Hard checks H1/H2/H4/H8** come from CI and perf artefacts (rubric §4.4) and were not re-measured here. H3/H5/H6/H7 ran through `hard-checks.swift` on the vq-m6 and vq-m7 sets.

## 2. Scores, before → after

★ = primary screen (bar ≥ 4.5 with L, V, C ≥ 4). Other screens: bar ≥ 4.0. Settings › Capabilities, Privacy & Data and Storage: bar 4.5. Global floor: no dimension below 3.

Scores are L V C S K A → score. "=" means unchanged. Evidence comes from the shots in `build/at/AT-VQ-M9/{before,after}/`.

| Screen | Bar | Before (L V C S K A → score) | After | Verdict | What moved the score |
|---|---|---|---|---|---|
| ★ S-01 Welcome | 4.5 | 5 4.5 4.5 4.5 5 4.5 → **4.67** | = | pass | Layout parity with onboarding_page1; art scrim keeps the white text legible. |
| ★ S-02 Capabilities | 4.5 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | Real pack sizes (H7 pass); Video unticked and dimmed with "Needs 24 GB memory". |
| ★ S-03 Evil Mode | 4.5 | 4.5 4.5 5 4.5 4.5 4.5 → **4.61** | = | pass | Red Continue is gated by the 18+ box; cost and availability lines are live. |
| ★ S-04 Preparing | 4.5 | 4.5 4.5 4.5 4.5 **4** 4.5 → **4.44** ✗ | K 4.5 → **4.50** | pass | The subtitle said "Chat is ready…" above "0 of 4 ready". The footer now counts Chat once the starter model answers. |
| ★ S-05 New chat (empty) | 4.5 | 4.5 **4** 4.5 4.5 4.5 4.5 → **4.39** ✗ | V 4.5, K 5 → **4.56** | pass | Two waveform buttons (Voice plus a disabled "send" waveform with a stale "Install Voice" tooltip). Empty is now a pale disabled Send, as in ChatGPT and components.md. |
| S-06 Evil (empty) | 4.0 | 4.5 **3.5** 4.5 4.5 4.5 4.5 → **4.28** | V 4.5 → **4.50** | pass | The selected "Evil" segment was the blue accent. It is now `evil.base`, matching the frame, badge and send. |
| S-07 Incognito (empty) | 4.0 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | Dashed composer, badge, Personalized/Unpersonalized. |
| ★ S-08 Conversation | 4.5 | 4.5 **4** 4.5 4.5 4.5 4.5 → **4.39** ✗ | V 4.5 → **4.50** | pass | The reply's ⋯ and the toolbar Share and ⋯ drew in the accent next to grey neighbours. The duplicate waveform also showed here. Turn spacing matches 001 (about 50 pt). |
| ★ S-09 Edit / versions | 4.5 | not captured | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | pass | R1 leg `m9-edit` (`residuals/`): full-width inline editor with `edit.keepsVersions` and Cancel / Send; 2 / 2 switcher under the edited bubble; Regenerate popover ("Ask to change response", Try again, Think harder); Versions viewer (list, Use this version, Branch in new chat); ⋯ menu (timestamp, Branch in new chat); the branched chat opens. |
| S-10 Web search answer | 4.0 | 4 3.5 **2.5** 3.5 4.5 4.5 → **3.61** ✗ (C < 3) | 4 4 4.5 4.5 4.5 4.5 → **4.28** | pass | Zero citation pills under the scripted engine: the generative verifier was asking the ScriptedEngine. Pills are back (`citation.1`, `.2`). The pill sits after the paragraph (A-M7-T03a d). |
| ★ S-11 Image job | 4.5 | 4.5 4.5 4.5 4.5 **4** 4.5 → **4.44** ✗ | K 4.5 → **4.50** | pass | "Used create_image" showed the raw tool id. Activity lines now use a readable name. Scored on the AT-VQ-M4 captures and ImageJobCard snapshots, plus this run's install card (residual R4). |
| S-12 Video plan / job | 4.0 | 4.5 4 4.5 4.5 4.5 4.5 → **4.39** | = | pass | Plan, countdown, battery and paused states from the VideoPlanCard / VideoJobCard snapshots. The truthful "needs 24 GB" card is from this run. The "Paused — your Mac is hot. Resume" line is all link-blue (polish). |
| S-13 Image viewer / editor | 4.0 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | Versions rail, Erase, Remove background, Describe the change (AT-VQ-M4 shots). |
| ★ S-14 Files in | 4.5 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | Errors on the tiles (IS-10), real reading %, page pill. |
| S-15 Files out + side panel | 4.0 | 4 4.5 4.5 4.5 4.5 4.5 → **4.39** | = | pass | File card, chart card and PDF panel. The transcript column gets narrow with the panel open. |
| ★ S-16 Voice conversation | 4.5 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | Every overlay state, the half-duplex hint, no-device error. Barge-in timing not re-measured. |
| S-17 Dictation | 4.0 | 4.5 4.5 4.5 4 4.5 4.5 → **4.44** | = | pass | DictationBar snapshots only (no live leg). |
| ★ S-18 ⌘K palette | 4.5 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | Tabs, grouped results, key-hint footer. |
| S-19 Library | 4.0 | 4 4 4.5 4.5 **3.5** 4.5 → **4.17** | K 4.5 → **4.28** | pass | The toolbar read "New chat" on the Library page. It now reads "Library". |
| S-20 Projects | 4.0 | **3.5** 4 4.5 4 **3.5** 4.5 → **4.00** | L 4.5, K 4.5 → **4.33** | pass | Same toolbar title fix. R6: the page now has the Library / Chats frame (title3 header on the leading edge, full width). |
| Chats page (sidebar › Chats) | 4.0 | 4 **3** 4.5 4.5 3.5 4.5 → **3.94** ✗ | V 4.5, K 4.5 → **4.39** | pass | Zebra-striped empty rows filled the page like placeholders. Title fix too. |
| S-21 General | 4.0 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | |
| S-21 Appearance | 4.0 | → **4.50** | = | pass | |
| S-21 Capabilities | 4.5 | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | = | pass | Pack rows with live %, Pause / Cancel, Advanced. |
| S-21 Evil Mode | 4.0 | **3.5 3.5** 4 4.5 **3.5** 4.5 → **3.83** ✗ | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | pass | "Use memory in Evil chats" appeared twice, one copy a dead M2 flag. The notes were separate caption rows. The rows were off the SettingsItem inset. |
| S-21 Voice | 4.0 | → **4.50** | = | pass | |
| S-21 Personalization | 4.0 | 4.5 4 4.5 4.5 4 4.5 → **4.33** | = | pass | A long label carries its explanation in parentheses (polish). |
| S-21 Tools & Connections | 4.0 | 4.5 **3.5** 4 4.5 **2.5** 4.5 → **3.94** ✗ (K < 3) | V 4.5, K 4.5 → **4.39** | pass | The add-server failure printed the whole NSError dump in red. It is now one sentence. |
| S-21 Skills | 4.0 | 4.5 4 4.5 4.5 4.5 4.5 → **4.39** | = | pass | |
| S-21 Privacy & Data | 4.5 | **4** 4.5 4.5 4.5 5 4.5 → **4.44** ✗ | L 4.5 → **4.56** | pass | The statement and the empty line sat 4 pt left of the rows. Non-expandable Network rows sat 4 pt right of the expandable one. |
| S-21 Storage | 4.5 | **4** 4.5 4.5 4.5 **4** 4.5 → **4.33** ✗ | L 4.5, K 4.5 → **4.50** | pass | The bar and paths block sat off the row inset. The "Clean up…" button repeated its label; it now says "Clean up". |
| S-21 Updates / Shortcuts / About | 4.0 | → **4.50** each | = | pass | |
| S-22 Quick panel | 4.0 | not captured | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | pass | R1 leg `m9-mac`, Finder in front: floating field, reply below, "Open in AntiChat ⌘O", collapse. The first capture showed the reply as raw Markdown ("## …", a run-together code block); it now renders like the chat column (re-captured). |
| S-23 Menu bar | 4.0 | not captured | 4.5 4.5 4.5 4.5 4.5 4.5 → **4.50** | pass | R1 leg `m9-mac`: template icon; New Chat ⌘N, Quick Panel, Start Voice, Open AntiChat, Quit ⌘Q; a download adds "Photo 42%" and the busy dot. |
| S-24 Sheets (search, MCP consent, files in chat) | 4.0 | 4.5 4.5 4.5 4 4.5 4.5 → **4.44** | K 4.5, S 4.5 → **4.50** | pass | R2: the untrusted ApprovalCard is reached and captured (vq-inject pass: the untrusted line, three buttons, the send denied after Deny). Its title read the raw tool id under "Using Team Chat"; it now reads "Team Chat · Send message". |
| S-25 Failure states | 4.0 | 4.5 4.5 4 4.5 4 4.5 → **4.33** | C 4.5, K 4.5 → **4.50** | pass | Engine restart (InterruptedNotice + Retry) and offline chip are good. R3: a `model.corrupt` reply now offers [Re-download ({size})] as S-25 specifies (ModelCorruptNotice snapshot; no live leg has a damaged model now that vq-m3 runs the scripted engine). |

**Release bar after the fixes (rubric §3):** every scored ★ screen passes (≥ 4.5 with L, V, C ≥ 4). Every scored non-★ screen passes (≥ 4.0; Capabilities, Privacy and Storage ≥ 4.5). No screen is below 3.5 and no dimension is below 3. S-09, S-22 and S-23 were scored in the residuals pass (§4a). **Before the fixes:** 4 ★ screens failed (S-04, S-05, S-08, S-11). 6 other screens or sections failed: S-10 (C < 3), the Chats page, S-21 Evil Mode, S-21 Tools & Connections (K < 3), and S-21 Privacy & Data and Storage (both below their 4.5 bar).

## 3. Fixes (commits on `qa/visual`)

| Commit | Screen | Fix | Test |
|---|---|---|---|
| `c9f4afcc2` | S-05, S-08, S-06, S-07 | Empty composer: a pale, disabled Send instead of a second (disabled) waveform with a stale "Install Voice" tooltip | Composer snapshots re-recorded; `ComposerModelTests.emptyStateIsADisabledSend` |
| `0135ee570` | S-06 | ModeSwitch: the selected Evil segment uses `evil.base`, not the accent | — (seen in vq-m9) |
| `59b0852a7` | S-19, S-20, Chats, S-08 | Toolbar names the Library / Projects / Chats pages; Share, ⋯ and the reply's ⋯ are label/secondary coloured, not accent | `ComposerModelTests.toolbarNamesPageRoutes`; ResponseActions snapshots (`ea8b58cf0`) |
| `b74c5cad9` | Chats page | No alternating row stripes | — |
| `5ff616298`, `8d20b2790`, `ea8b58cf0` | S-21 Evil Mode | One "Use memory in Evil chats" (the live M8 `useMemoryInEvil` row; the dead M2 `evil.memory` row removed); notes as SettingsRow descriptions; rows on the SettingsItem inset | Evil panel snapshots re-recorded |
| `8d20b2790` | S-21 Privacy & Data, Storage | Free-standing blocks get the SettingsItem 4 pt inset; non-expandable Network rows align with the expandable one; Clean up button = `storage.cleanUp.cta` | Settings snapshots re-recorded |
| `4b4f169a6` | S-21 Tools & Connections | Add-server failure `{reason}` is the error's localized sentence, not the NSError dump | `ConnectionsReasonTests` |
| `7cf3a78e0` | S-10 | DEBUG: the generative citation verifier is off under `-UseScriptedEngine`. It was asking the ScriptedEngine, which answered with the script's next turn, so every pill was dropped (AT-VQ-M7 vq-chat and WebSearchUITests saw 0 pills). Release unchanged. | vq-m7 vq-chat probe: `pills [1, 2]`, pass |
| `39e317983` | S-11, S-25 | Activity lines use a readable tool name ("Web search didn't work. Retry", "Used Create image"); a connection's tool reads as its app in every state | `ToolActivityModelTests.activityLinesUseAReadableToolName` |
| `73be6f854` | S-04 | The footer counts Chat as ready once the starter model answers, agreeing with "Chat is ready. Open it while the others finish." | `Step4ReadyCountTests` |
| `64d8b1ceb` | tooling | `tools/visual/vq-m9.sh` + probe legs `m9` / `m9-crash`; all VQ runners use `com.antichat.uitest.*` suites (`-FreshDefaultsSuite YES` where not pre-seeded); the runner codesign-verifies the build | — |
| `a175e6544` | tooling | `ConnectionsReasonTests` uses isolated settings (SettingsIsolationTests) | — |

The final capture build (`build/visual/m9final`) contains every fix except the last three: `39e317983` (readable tool names), `73be6f854` (step-4 footer) and the Show Evil items inset in `ea8b58cf0`. Those were landed after the screen slot ended and are verified by their unit and snapshot tests. The before shots come from the build at `d7cf94821` (`build/visual/m9before`, plus `m9after1` for S-10 and the add-server error).

**Post-r3 pass:** `fix/xcuitest-r3` landed on main during the run. Main was merged into `qa/visual` and the build re-captured with vq-m9 (S-05…S-08, S-18…S-21, S-25) and the voice leg. The shots are in `build/at/AT-VQ-M9/post-r3/`, 69 in all. This build includes every fix, including the last three. The r3 changes (ComposerView, VoiceOverlay, UserBubble, TourTip) changed no score: the composer, conversation, Evil empty and voice overlay read as in the table.

The bar was not loosened anywhere. No copy-deck strings were added or changed; every fix uses existing keys.

## 4. Residual findings (below-bar or noted, not fixed here)

Proposed severities are for independent triage (test-strategy §11). The builder does not set them.

- **R1: screens not captured.** *Resolved (§4a).* Legs `m9-edit` (S-09) and `m9-mac` (S-22, S-23) in `tools/visual/vq-m9.sh`.
- **R2: vq-m7 `vq-inject` does not reach the untrusted ApprovalCard.** *Resolved (§4a).* The leg failed at M7 too (`build/at/AT-VQ-M7/probe-vq-inject.json`: `card: false`); it was a runner bug, not the approval path.
- **R3: S-25 corrupt model offers "Retry" where screens.md S-25 says Re-download.** *Resolved (§4a).*
- **R4: vq-05 `main` could not create a picture on this host.** `create_image` was registered but not offered: Photo is not ready in the dev store. S-11 / S-13 were scored on the AT-VQ-M4 captures plus the card snapshots. Proposed S3, owner: the M9 exit VQ run on a host with the Photo models.
- **R5: S-10 citation pill on its own line after a wrapping paragraph.** This is the accepted MarkdownView flow-layout limit (A-M7-T03a d, `PillLineBreakTests`). ChatGPT places chips inline. Proposed S3.
- **R6: polish.** *Resolved or justified (§4a).* Projects page is a centred narrow column while Library / Chats are full width (S-20). The composer's memory (brain) toggle sits alone under the composer (S-05 / S-08). The Evil frame's top edge runs under the floating sidebar. The video "Paused — your Mac is hot. Resume" line is all link-blue. The vq-m6 "Couldn't read …" toast sits on the composer's lower edge. Proposed S3.
- **R7: hard checks.** Screenshot H3 / H5 / H6 stay at the M7 level and are inconclusive: vq-m7 H3 381 OCR pairs below the bar, H5 0.86, H6 0.51; vq-m6 H5 0.89, H6 0.37. They come from OCR and edge detection on the captures (M7-report §4); `DesignTokenContrastTests` is the H3 authority. H7 passes. H1 / H2 / H4 / H8 were not re-measured here (CI / perf artefacts, XCUITest Q-015).
- **R8: method.** One builder-scorer instead of the two-agent blind panel (§1). Step 4's capture shows "Didn't finish. Retry" rows because the loopback range server could not serve every file from the base container. The earlier AT-VQ-M2 capture of the same screen (progress rows) was used for C.

## 4a. Residuals pass (`qa/visual-residuals`)

Captures: `build/at/AT-VQ-M9/residuals/` (1000 px; probe JSONs alongside). Same method as §1: fresh dev containers, `com.antichat.uitest.*` suites, codesign-verified Debug build, scripted engine. The region shots (popovers, menus, the quick panel over Finder) show whatever else was on screen: another agent's AntiChat test instance (its window and its own empty quick panel) and a system notification appear in some S-09 / S-22 frames. They are not this build's UI and were not scored.

- **R2 cause.** `vq-m7.sh` set Tool access to "Always offer all" so the connection's write tool would be offered. On the leg's T1 profile that mode is bounded by the 1200-token schema cap (tier-budgets.json) and keeps tools in name order (ToolSelector, R-268 AC3). The file tools filled the cap, so `web_search` and `team_chat_send_message` were never offered. Both scripted calls failed with "no tool named …", the turn wrote "Done." and no card was shown. Nothing in the approval path was wrong: PermissionGate asked with `untrusted: true` as soon as the call was offered. **Fix:** the leg asks like a user. It picks the Web search chip (a forced tool is pinned, never cut) and keeps "Load tools when needed" on `-FakeHardware T3`. The probe records each tool step (state and the start of its result) and passes only when web_search is done, the card shows with the untrusted line and its three buttons, and the send is `denied` after Deny. Result: pass.
- **R3.** `AssistantMessageView` shows `ModelCorruptNotice` for a `model.corrupt` reply: `model.corrupt` + [Re-download ({size})] (`model.corrupt.redownload`; AntiChatError's recovery for the code is already `.redownload`). {size} is the bad files only (`Repair.redownloadBytes`), or the model's catalog size when the view checks clean (an engine-side fault). The button evicts the model, runs `Repair.run` and retries the turn. It falls back to [Retry] only when this launch has no store or catalog. Settings › Storage › Repair uses the same `ModelRepair.run`. Runner: `vq-m3.sh` passes `tools/fixtures/scripts/basic.jsonl` (it passed `basic`, which is not a path, so the XPC engine loaded the base container's damaged model). Tests: `StatusPillSnapshotTests.corruptReplyOffersRedownload` (new snapshot + the size rule).
- **R1.** S-09: inline editor, 2 / 2 versions, Regenerate popover, Versions viewer, ⋯ menu, branched chat. ActionBar actions got probe anchors so the leg can press them. S-22: open, streaming, done, collapsed, with Finder in front and the main window ordered out. S-23: the status item menu, idle and with a download row. Open menus are captured by opening them from the run loop, so the probe keeps running while AppKit tracks the menu. Found and fixed on the way: the quick panel reply rendered raw Markdown (now `MessageMarkdownView`), and the ApprovalCard title showed the raw tool id (`ApprovalCardNameTests`).
- **R6.**
  - *Projects column:* fixed. The page uses the Library / Chats frame (title3 header, full width).
  - *Lone memory toggle:* fixed where it said nothing. Once the first message locks it, the switch shows only when memory is off for that chat (`brain.slash` then states the chat's mode). It stays under the composer of a new, empty chat, because M8.md T03 step 4 puts it in the composer status row there. `ComposerModelTests.memorySwitchShowsWhileChangeableOrOff`; `MemoryUITests.testMemoryOffPerChat` still holds (it turns memory off first).
  - *Evil frame line under the sidebar:* fixed. The 2 pt frame covers the window's whole inner edge, toolbar included, as the incognito frame does (`.ignoresSafeArea()`).
  - *All-blue video paused line:* fixed. `TrailingActionLine`: the status reads in text.secondary and only the trailing action ("Resume", "Retry") takes the accent; the whole line stays one button. It splits at the last ". ", which holds for every translation of `video.paused.hot` / `video.lost`. VideoJobCard pausedHot / lost / failed snapshots re-recorded (intended).
  - *Files toast on the composer edge:* fixed. The composer's intake toast floats space3 above the field (`toast(_:above:)`) instead of over its tiles and controls (re-captured).

| Commit | Change |
|---|---|
| `88dce8eea` | R2 leg and runner; R3 notice, repair helper and vq-m3 path; R1 legs and region captures; R6 fixes |
| `6ffc38716` | ModelCorruptNotice snapshot; VideoJobCard pausedHot / lost / failed re-recorded |
| `768daa3e8` | Quick panel Markdown; toast lift by measured height; ActionBar probe anchors |
| `6674d0045` | ApprovalCard readable action name |

No bar was loosened. The only snapshots re-recorded are the intended ones above. No copy-deck keys were added; the card title and the action split reuse existing strings.

## 5. Gates

Run in order on `qa/visual` after merging main, which includes `fix/xcuitest-r3`:

1. `make test-unit`: **pass**. Every module's Swift Testing and XCTest runs pass, including the re-recorded Composer, ResponseActions, VoiceOverlay, Evil and Settings snapshots and the new tests.
2. `make test-integration-stub`: **pass**. 90 tests, 20 skipped, 0 failures, 900 s. In the first pre-r3 run, `SecuritySuiteTests` failed once under host load (load average about 40): `06_infinite_loop` rep 5 took 652 s against its timeout bound. It passed alone at normal load, and the whole suite passed post-r3. No File tools code is touched by this branch.
3. `BINARIES_SRC=/Users/armando/AntiChat/Binaries make audit`: **pass**. 37 checks ok; the l10n `missing …` lines are its non-blocking warnings.

Worktree notes, none committed: the `fixtures` submodule was filled by an APFS clone of the main checkout's fixtures at the same commit (`c3133f2c9`). `tools/.venv` linked to the main checkout's venv, and the signed `filetools-runtime-0.1.0.zip` with the catalog's sha256 was taken from another worktree's build: `Binaries/llama.cpp` (gguf-py) is not initialised in agent worktrees and the runtime build does not reproduce the catalog sha there.

**Residuals pass gates** (`qa/visual-residuals`, after merging main at `c77127f1d`, round 44):
1. `make test-unit`: **pass**. A first run failed twice: `SettingsIsolationTests.everySuiteIsIsolated`, because the new `ApprovalCardNameTests` lacked `.isolatedSettings` (fixed); and `BasicVoiceEngineTests.midSessionInstallDoesNotSwitch` under load (Engines module, not touched here; it passed alone and in the re-run).
2. `make test-integration-stub`: **pass**. 90 tests, 20 skipped, 0 failures.
3. `BINARIES_SRC=/Users/armando/AntiChat/Binaries make audit`: **pass**. 38 checks ok; the l10n `missing …` lines are its non-blocking warnings.

Worktree notes, none committed: `fixtures/` was filled by an APFS clone of the main checkout's fixtures at the pinned commit. `build/binaries/sd-server` and `sd-cli` were taken from another worktree's build after main moved their checksums, and verified by `tools/binaries/stage.sh --verify`. `tools/.venv` was linked to a complete venv from another worktree.
