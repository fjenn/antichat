# XCUITest catch-up report (Q-015)

## Round 7 (`fix/xcuitest-r7`, 2026-11-11/12, from main `8806b1d74`; main `4f1756f65` (round 58: stray-kill, overlay-field-focus, at254-t3b) merged)

**State:** chunks c1–c8 + probe pf1 (logs `build/xcuitest/2026-11-11-r7/<chunk>.log`, `.sum`; xcresults deleted after
summarising). J09 runs on a fresh `build/fixtures/big-10k.sqlite` (`python3 -I tools/fixtures/gen-chats.py --chats 10000
--long 1:1000 --out build/fixtures/big-10k.sqlite`, token_hits 1). Round 59 (a11y-audit) was not on main yet.

| | Tests |
|---|---|
| Round 6 still failing, in scope here (KeyboardOnly ×2, the accessibility audits and the overlay-field-focus three excluded) | 6 + J09 ×4 = 10 |
| … now pass | **10** |
| … still fail | 0 |

Newly passing: MCPOAuth sign-in, FilesJourney 4, ImageUnderstanding, Composio rate-limited, Privacy network activity,
VoiceTools connection, J09 ×4 (search, actions/settings rows, settings row opens Settings, Tab asks). Regression chunk c6
(+ c7): Composio ×2, MCPOAuth, ImageUnderstanding, FilesIntake ×3, FilesJourney, ImageEdit ×2, ImageViewer ×4 (round 58's
overlay-field-focus fix: they pass on this branch), J09 ×4, VoiceOverLabel ×2, ComposerMenus ×9, Privacy ×3,
VoiceTools ×4, VoiceConversation ×8 pass.

### Product bugs found and fixed (round 7)
| # | Bug | Impact | Fix / test |
|---|---|---|---|
| P75 | ⌘K: the vendored palette's `@FocusState` request never moved AppKit's first responder off the composer (an NSTextView) — the same class as fix/overlay-field-focus | **Typing after ⌘K went into the composer**: the palette's query stayed empty, Esc / Tab / Return did nothing in it (J09 ×4: "8 vs 1", rows not found, Tab ask) | `focusOnAppear(_, inside: true)` (TextFieldFocusAnchor finds the first editable field inside the palette's frame); the card's stroke overlay `.allowsHitTesting(false)`. J09 ×4 pass |
| P76 | Palette: the 8 recents stayed on screen under a typed query until the debounced search returned | rows not matching the query; Return in that window opened a recent chat | `PaletteController`: a non-empty query drops the recents at once (a refined query keeps the previous matches until its own arrive). Unit `typingDropsTheRecentsBeforeTheSearchReturns` |
| P77 | Composio: the relay's own refusal on `/v1/mcp` (429 `{code:"relay.rateLimited"}`, also 426 / 503) became `HTTP 429` on the row; [Connect] went on to ask for a sign-in link | "Connections are busy" (AT-255 c5-app, A-M7-06) never shown | `MCPHTTPTransport` (relay) throws `RelayClient.error`; `MCPHost.code` keeps `relay.*`; `ComposioConnection.begin` throws it (no link); ConnectionRow shows the relay copy. Unit `rateLimitedMCPEndpointSurfacesTheRelayCode`. Composio rate-limited passes |
| P78 | Settings window's accessibility title pinned to "Settings" (`windowAccessibilityTitle`) while the window shows the section ("Capabilities") | VoiceOver / XCUITest read "Settings" for every section; the [Packs & Models] link's target unverifiable | `windowAccessibilityTitle(_, windowTitle: false)` for Settings: names the hosting view only, the window keeps its drawn title. ImageUnderstanding passes |
| P79 | Privacy › Network activity: (a) a row toggled only on its 10 pt chevron; (b) the DisclosureGroup's id was stamped over every event row inside (`networkActivity.event` read `networkActivity.row.search`, AX dump c2) | a click on "Web search" did nothing; the events had no own id | the label toggles (tap); the events are rows after the group, not inside it (on the label the id renamed the row's own "Last used" / state texts instead, c3). Privacy ×3 pass |
| P80 | Voice caption = the chunk being spoken; the helper speaks a sentence's first clause as a chunk of its own (time to first audio) | the caption showed half a sentence, then the rest — never "the current spoken sentence" (R-052 AC5); found with a temporary trace (removed) | `VoiceSessionController.caption(after:chunk:)`: chunks of one sentence add up, a new sentence starts afresh, cleared at thinking. Unit in `VoiceTurnBridgeTests`. VoiceTools connection passes |

### Test-side changes (no AT weakened)
- FilesJourney toast, MCPOAuth "Connected": a macOS static text's words are its AX **value** (label empty; AX probe pf1
  and the c1 hierarchy); the queries read `label OR value` (FilesIntake already reads the same toast that way).
- ComposerMenus "Enable in Settings": finds the Settings window by its `settings.root` container (P78: its title is the
  section's), as J09 does.

### Not run / still open
- KeyboardOnly ×2 (owner's Full Keyboard Access + A-Q015-r6-kb) and the accessibility audits (a11y agent) not touched;
  run read-only in c6: `testEverySettingsSection` / `testPaletteAndShortcuts` fail with the known S-21 / S-18 findings
  (Parent/Child mismatch, Action is missing, contrast) — round 59 is not on main yet.

### Gates (this branch, sequential)
- `make test-unit`: EXIT=0 (a first run had SettingsSnapshotTests general / voice / voice-noDevices / search failing:
  the pointer, left by the UI runs over the window's spot, drew the "Send with" popup hovered; with the pointer parked
  the suite and the full run pass).
- `make test-integration-stub`: 93 executed, 20 skipped, 2 failures — LoadGateWiringTests
  `testAnAppPushDoesNotOverrideAPinnedPolicy` and LlamaServerSupervisionTests `testSetPolicyAppliesBeforeTheNextRequest`,
  both `engine.helloTimeout` under load (avg ~12), the r5/r6 flake (fix/hello-timeout); both suites alone: 10 tests,
  0 failures.
- `BINARIES_SRC=…/agent-ab2f916cd531f2084/Binaries make audit`: EXIT=0 (the first run's a11y-lint flagged P79's row tap
  with no accessibility action: the label now carries the same toggle as an action; Privacy ×3 re-run c8 pass; l10n-langs
  lists untranslated de/fr/es/nl/pt keys, non-blocking).
- Setup only: fixtures rsynced from the main checkout (`c3133f2`), `Binaries/llama.cpp/gguf-py` and the sd binaries from
  agent-ab2f916cd531f2084, `uv sync --frozen` in tools/.

## Round 6 (`fix/xcuitest-r6`, 2026-11-11, from main `555eda3a0`; main `f767a630c` (r5) and `60c69cc85` merged)

**State:** code work during the M9.T05 quiet window, then UI chunks in short screen slots shared with other agents
(logs `build/xcuitest/2026-11-11-r6/<chunk>.log`, `.sum`; chunks p1, p1b, p2–p8, probes ws*, vp1, ie*). xcresult bundles
were deleted after summarising (the disk filled up; run.sh now does this unless `KEEP_XCRESULT` is set).

| | Tests |
|---|---|
| Round 5 failing | 38 |
| … now pass (latest run per test) | **21** |
| … still fail | 17 (of which 6 are the accessibility audits, owned by the a11y agent and not run here) |

Newly passing: J08 incognito journey, Dictation incognito, Queue follow-ups + type-before-ready, WindowLayout disclaimer
/ jump to bottom, VideoJobCard percent/stage, WebSearch ×2, ImageViewer zoom/save/copy/reveal, ModelInfo, VideoPlayer
inline controls, VideoEntry Animate, Library sound icon, VoiceOverLabel inventory, JIT notifications, J12 loop limit,
JobQueue positions, Context, FilesIntake, FilesScan, Composio Gmail.

### Product bugs found and fixed (round 6)
| # | Bug | Impact | Fix / test |
|---|---|---|---|
| P60 | After the first send the empty-state field (still in the window during the animated dock) answered the send's focus request and left the window holding focus | **The docked composer had no keyboard focus after the first message** (typing went nowhere); with P61, an incognito chat could not continue | `ComposerFocusOwner` (ComposerTextView): only the newest field takes focus; a focused field leaving hands it over (never from a text field). Units in ComposerInteractionTests. J08, Dictation incognito, WindowLayout pass |
| P61 | Incognito composer's dashed border overlay could take clicks | mic / field clicks in incognito | border `.allowsHitTesting(false)` |
| P62 | "Memory off" switch shown in incognito chats | misleading control | `memoryToggleVisible` false when incognito; unit |
| P63 | Queued follow-up bubbles raise the transcript's bottom margin; the list read that as "scrolled away" and stopped following | the streaming reply grew under the bubbles and the composer | TranscriptList re-follows on bottom-margin growth only (content growth stays the size-change anchor's: counting it yanked a reader scrolling up back down); a reader's upward scroll while already away detaches. Unit `TranscriptFollowTests`. Queue, WindowLayout pass |
| P66 | AX hit test: SwiftUI overlays over the transcript and `Menu` popups in replies unreachable | viewer toolbar / reply ⋯ not hittable for VoiceOver | `ScrollViewHitTest`: deepest element under the point (topmost child first, capped), then the hosting views, then the NSControl under the point; units |
| P67 | Side-panel PDFView is an ignored AX container | `panelPDF` / "p. 3" never exposed | `PDFContainerView` group with id, label and page value |
| P68 | Library sound icon from the plan's flag, not the file | a clip with sound showed none | the file's audio tracks decide |
| P69 | Voice: a reply arriving while an approval prompt still spoke was dropped (state stuck `.speaking`) | the session sat on "Speaking" | back to listening before the new turn |
| P70 | First notifying event while hidden (⌘H) counted as "Not now" | no explainer / notification | `canAnswer(in:)` accepts a hidden app / minimized window |
| P71 | Settings search: Return did nothing, ⌘F did not focus it | keyboard-only users could not reach a result | Return opens the best match; ⌘F focuses the field |
| P72 | Queued bubble's edit field: focus requested in onAppear (dropped), and focusing selected all | Edit opened without focus; the first keystroke replaced the follow-up | focus retried until it holds, caret at the end |
| P73 | Citation pill hit test landed on the reply's whole-text element drawn behind it | pill not hittable (VoiceOver mouse-follow, XCUITest) | a static-text answer resolves into the later sibling drawn on top; unit. WebSearch ×2 pass |
| P74 | **MCP sign-in crashed the app**: AuthenticationServices calls the web-auth completion on its XPC queue; the closure, written in a @MainActor method, trapped Swift 6's isolation check (EXC_BREAKPOINT `_dispatch_assert_queue_fail`, AntiChat-2026-11-11-145008.ips) | any MCP sign-in | completion is an explicit nonisolated @Sendable closure; releases the session on the main queue |
| — | Needs-larger-model card's eye.slash read "Hide" to VoiceOver | noise | hidden |
| — | Onboarding steps had no container ids (M9.T01 step 4 expects them) | KeyboardOnly paths | `onboarding.step1–4` on the step containers |

Removed: r5's P43 and r6's P65 (NSTextView inline-pill AX machinery + tests): the pills are not in an NSTextView; a live
probe showed it registered nothing (separate commit).

### Test / fixture / harness changes (no AT weakened)
- J08: the follow-up turn of `regen-slow.jsonl` streams 2 s (Stop showed ~1 s, between XCTest's 1 s polls).
- Queue type-before-ready: `slow-load-12s.jsonl` (same rate; the test's own steps outlasted the 8 s load).
- VideoJobCard: reads the pill's label (its AX value is "" since M9.T05 P3) and the stage line while running; bar unchanged.
- WebSearch: the scripted evidence states every cited claim (R-250 AC2's grounding correctly dropped pills 2–4).
- ImageUnderstanding: the CTA is a Link; DEBUG `ANTICHAT_TEXT_ONLY_CHAT` makes the dev chat model text-only.
- JobQueue: three chats (a chat's turn waits for its picture); position 1 reads "Waiting for the current job", 2 "2 in line" (M4 copy).
- FilesJourney: the failed tile's own label; FilesIntake / FilesScan: queries scoped to static texts / the tile (same text).
- VideoPlayer: AVKit's full-screen toggle is a CheckBox. J12: the message names `echo`. JIT: waits 5 s hidden.
- **VideoEntry Animate (lead decision):** R-290 AC2 — over 5 min (i2v at T3 ≈ 50 min) the explicit card waits for Start; the test presses Start and the job runs.
- **VoiceOverLabel:** NSScroller page-area buttons (Button, direct child of a ScrollBar, no id, no label) excluded. Reviewer: lead (orchestrator) 2026-11-11 — accepted, AppKit-owned NSScroller page buttons, same class as _XCUI titlebar exclusion.
- KeyboardOnly: the generator expects the real ids (22); the 16 ⌘K page actions have no requirement (R-012 AC2) → spec gap **A-Q015-r6-kb** in docs/PRD-AMENDMENTS.md; Full Keyboard Access left as the user set it (owner's).
- Harness: `tools/ci/with-relay-dev.sh` (two `make relay-dev` mock relays on free ports, `RELAY_DEV_LOCAL=1`); `webauth-continue.swift` broader matching + log; MediaUIApp forwards the runner's `ANTICHAT_AX_HIT_REFINE` (diagnosis).

### Environment (round 6)
- Homebrew node broke mid-round (simdjson upgrade removed `libsimdjson.34`); the coordinator upgraded node. Composio / MCP harnesses depend on it.
- UI test runners were SIGKILLed several times while other agents' `swift test` runs were active (sender not logged); a separate agent is tracing it.
- The disk filled up (125 MB free); r6 xcresults deleted.
- Orphan pid 5587 still running (100 % CPU); hidden, not killed (owner's call).

### Still failing (latest run per test)
| Test | Latest failure / status |
|---|---|
| ImageEditTests ×2, ImageViewerTests/testVersionRailListsVersions | **Product bug, in progress on a separate branch (fix/overlay-field-focus):** a SwiftUI TextField in an overlay on the transcript ("Describe the change") never becomes first responder — neither a real click (CGEvent; AppKit's hit test returns the column's hosting view) nor @FocusState; the composer keeps focus |
| MCPOAuthUITests/testSignInFlow | no crash any more (P74); fails at line 154 (after the sign-in alert) |
| FilesJourneyTests/testJourney4 | the toast naming corrupt.pdf |
| ImageUnderstandingTests | card + CTA found and clicked; no Settings window titled Capabilities |
| ComposioUITests/testRateLimitedShowsCopy | rate-limited copy not shown |
| PrivacyUITests/testNetworkActivityAfterSearch | `networkActivity.event` after the disclosure |
| VoiceToolsTests/testConnectionDuringVoice | the session returns to Listening (P69) but the reply's spoken caption was not seen |
| KeyboardOnlyTests ×2 | Full Keyboard Access off (owner's setting) + spec gap A-Q015-r6-kb |
| AccessibilityAuditTests ×5, FileActionsTests/testAccessibilityAudit | owned by the a11y agent |

### Gates (this branch, sequential, after main `649531722` merged)
- `make test-unit`: EXIT=0 (the earlier run on `f21f02cdc` had 2 snapshot tests flaking on the live pointer / focus
  state — LibraryViewTests grid, WindowSnapshotTests settings search — both pass alone; that run also found and P60's
  hand-off fixed an objc abort: no weak reference to a deallocating window).
- `make test-integration-stub`: 93 executed, 20 skipped, 2 failures — LlamaServerSupervisionTests
  `testSetPolicyAppliesBeforeTheNextRequest` and LoadGateWiringTests `testAnAppPushDoesNotOverrideAPinnedPolicy`, both
  `engine.helloTimeout` under load (avg ~16); LoadGateWiringTests alone passes twice, the supervision suite passed in the
  pre-merge run (0 failures) — same load flake as r5.
- `BINARIES_SRC=…/agent-ab2f916cd531f2084/Binaries make audit`: EXIT=0 (a11y-lint fixed: Settings ⌘F key equivalent is a
  `.hidden()` button with an id; l10n-langs lists untranslated de/fr/es/nl/pt keys, non-blocking).
- The worktree needed `Binaries/llama.cpp/gguf-py` (rsynced from that worktree) and `uv sync --frozen` in tools/ (setup only).

## Round 5 (`fix/xcuitest-r5`, 2026-11-11, from r4's merge `a12b19d04`; main `d61bc8668` merged — fix/selection-hang)

**State:** after the perf pause, chunks `r3`–`r5` ran on main `d61bc8668` merged (fix/selection-hang; its follow-up
fix/selection-hang-2 is not on main yet). Latest result per test below.

Chunks (logs `build/xcuitest/2026-11-11-r5/<chunk>.log`, `.sum`; samples `a1-samples/`): `a1` (the 9 orphan-launch tests +
the r4 failures), `n2` (the 35 not re-run in r4), `r1` (re-runs after fixes), `d1` (SafetyMissing with a diagnostic log
stream), `r2` (re-runs after the main merge; stopped at the perf pause), `r3` (pending re-runs after the pause), `r4`/`r5`
(re-runs after fixes). Code-only triage of n2 by two forks.

| | Tests |
|---|---|
| Round 4 failing (75 counted; 76 by test id: + the 4 P0-blocked of the r4 table) | 76 |
| … now pass | **38** |
| … still fail | 38 (latest run per test) |
| **Failing now** | **38** (76 − 38) |

Newly passing: AudioFile, Dictation recent recordings, SidePanel, VideoPlan change, QuickPanel ×2, ThinkHarder tooltip,
ToolsPage ×2, UpdateAsk ×2, VideoBackground window close, VoiceConversation typed turn, VoiceSettings, VoiceTools image +
video, WebSearch offline chip + Read this URL, WindowLayout docking, ImageEntry aspect, ArtifactsPanel ×3, ComposerTests
mic card, J03, J07, JobQueue window close; after the pause (r3–r5): SafetyMissing, RendererStreaming, Skills, Spike restart,
VideoEntry ×2, Library evil badge, VideoPlan advanced, AdvancedOverride, FileVersion, JobQueue interrupted restart (R-291 AC2).

### Environment
- **Orphan pid 5587** (r3's deleted snapshot app) is still running; not killed (owner's call). Cause of r4's 9 "Failed to
  determine bundle identifier": its two on-screen windows made XCTest's interrupting-element check build an
  XCUIApplication for its deleted bundle. `run.sh` now **hides** it (`NSRunningApplication.hide`, reversible) and
  `lsregister -f`s the snapshot before each run (`-u` after). 0 hijacks in r5.
- The worktree had no `fixtures/` (submodule; `file://` transport refused): rsynced from the main checkout at the pinned
  commit `c3133f2`.
- A macOS "quit unexpectedly" dialog sat on screen through `n2` (coordinator): its audit/contrast/hit-test results in the
  dialog's area are suspect. `run.sh` quits Problem Reporter before each chunk.
- `$TMPDIR` held ~359k entries: launches took 25–40 s (sweep on the main thread) until main's fix (r2 launches ~5 s).
- The UI test runner is **sandboxed**: the Accessibility API returns nothing there, and a distributed notification with a
  userInfo dictionary is dropped (both cost tests in r4).

### Product bugs found and fixed (round 5)
| # | Bug | Impact | Fix / test |
|---|---|---|---|
| P38 | `create_image` with missing detector files queued a job; the helper's gate then failed it (D-006 held, but late) | **A job was submitted before `safety.missing`** (AT says none); a job card showed first | `SafetyStatus.preflight` in ImageTools / ImageEditorActions: absent files → `safety_missing` with the repair size, no job; the repair card's container is `imageJobSafetyMissing`, not a job card. Unit `missingDetectorsSubmitNoJob`; UI: no `media_job` row (d1 DB) |
| P39 | Image/video card: a `.task(id:)` follow cancelled by the call's state change still wrote its stale placeholder | The settled card (safety repair) went back to "Creating image 0 %" | `guard !Task.isCancelled` before the write (ImageJobActivityCard, VideoJobActivityCard); found with a DEBUG log stream (d1) |
| P40 | `RecentRecordingsView`: identifier on a Section | every recording row read `recordings`, not `recording.row` | ids on the header. Dictation recent recordings passes |
| P41 | Capabilities › Advanced: label did nothing (chevron at the trailing edge), no press action (audit), and the group's id stamped over every row inside (`override.chat.normal` unreachable) | VoiceOver could not open it; the override pickers had no ids | label is a toggle Button carrying the id |
| P42 | ModeSwitch: label + id on a Group | the lock button read "Chat mode"/`modeSwitch`; VoiceOver never said the chat is locked | on the picker branches only. J07 passes |
| P43 | Web citation pills are NSHostingViews inside RichText's NSTextView, which lists no subviews as AX children | pills invisible to VoiceOver/XCUITest | `InlineViewAccessibility` adds the hosts to the text view's AX children; hit test refined into them. Pill 1 now found; pills 2–4 / hit test still open |
| P44 | `ToolChipsModel.add` ignored `.offline` items | picking Web search offline added no chip | accepts `.offline`; unit `pickingWebSearchOfflineAddsAnOfflineChip`. WebSearch offline + ToolsPage pass |
| P45 | ToolsPage probe id on a Section | every row (incl. the T0–T2 warning) renamed | `.probeAnchor`. ToolsPage T1 warning passes |
| P46 | Video card stopped following at the first `done` (the helper's xfer path, deleted right after) | player error phase, no poster | follows to the stored path. Poster check passes |
| P47 | Menu bar "Open AntiChat" after closing the window opened a new chat | a running picture/video was off screen (R-042 AC3) | reopens the last shown chat. VideoBackground passes |
| P48 | A restored window whose chat no longer exists opened an empty docked "chat" (Incognito disabled) | after a chat delete (or another container's window state) | `WindowRestoration` skips a missing chat |
| P49 | Sent attachment chip: label on a non-element | two AX elements "clip.m4a" | one element. AudioFile passes |
| P50 | AVPlayerView is an ignored AX container | `videoPlayer.view` never exposed | wrapped as a `.contain` group with the id |
| P51 | Transcript column `.contain` group unnamed (audit) | "Element has no description" | `a11y.transcript` "Conversation" (copy-deck + xcstrings regenerated) |
| P52 | Personalization text areas unnamed | VoiceOverLabel inventory | labelled with their row titles |
| P53 | Side-panel PDF did not say its page | a page pill's target page unverifiable by AT | `panelPDF` AX value `files.pageCite` ("p. 3"), updated on page change |
| P54 | VoiceOrb ran a 60 fps `TimelineView` (P0 follow-up c) | per-frame SwiftUI transactions for the whole call | `VoiceOrbLayer` (CAGradientLayer scale pulses, same ranges/periods; level steps set directly) |
| P55 | `MessageMarkdownView` built a binder in `State(initialValue:)` on every parent re-evaluation (P0 follow-up d) | a source + reveal + parse per re-evaluation, thrown away | lazy box in `@State`, binder made once |

P0 follow-ups (a) and (b): the "Skipped a repeated Create image call" is correct — the dedupe is per run, and a
one-segment scripted turn replays its `create_image` on the tool-loop step; (b) every `ScriptedImageEngine.run` crash
report is its deliberate DEBUG `crashAtStep` abort (MediaJobUITests' helper-crash test, another session's run in r4);
the real engine path is unaffected.

DEBUG-only seams added (compiled out of Release): `AXAttributeProbe` (`ANTICHAT_AX_ATTR_LOG/IDS`: AXValueDescription /
AXHelp read in-process — the sandboxed runner cannot), `TileStateLog` (`ANTICHAT_TILE_STATE_LOG`: every rendered tile
state line), `ANTICHAT_NO_VISION_HELPER`, the spike's `app.antichat.test.spikeKillEngine` hook. ScriptedEngine: per-step
`"when"` (last user message) so a later turn can call a tool (unit `whenPicksStepsByTheUsersWords`).

### Test-side limits resolved without dropping a check
- VoiceSettings speed: the spoken "1.5×" is the slider's AXValueDescription → read via AXAttributeProbe (passes).
- ThinkHarder tooltip: AXHelp via AXAttributeProbe (passes).
- AudioFile: the transcription ends between two AX reads → TileStateLog must show "Transcribing clip.m4a · n%" (passes).

### Harness / test fixes (round 5)
run.sh (hide orphan, lsregister, Problem Reporter), gpu-run.sh shared around chunks with real models; Quick Panel hook
posted without userInfo; `tools/ci/webauth-continue.swift` (presses the web-auth alert's Continue from outside the runner;
started by with-mcp-ref.sh — it has not found the alert yet); UpdateAsk seeds an installed chat-0.8b container
(with-catalog-fixtures.sh); WindowLayout centring measured against the detail area (`chatColumn`'s AX frame is the union
of its children); FilesJourney fixed tier/context (whole document → "Reading … %" now shows) and side panel at "p. 3";
lazy transcript index (ImageEntry), lazy Form rows (`scrollUntilVisible`), `clickDisclosure` 8 pt in, transcript
controls via `clickReliably`, coordinate hover, caption read from a snapshot (VoiceTools), React's split text nodes
(ArtifactsPanel), fileout-version second-turn segment, regen-slow.jsonl (J03/J08), J12 on T3 (T1 prunes `echo`),
stale ids/scripts in JIT/JobQueue/Keyboard/Library/Skills/Spike/VideoEntry/VoiceOverLabel.

Audit ignore added with the lead's sign-off: `main-AppWindow-1, SidebarNavigationSplitView` / description / sameFrame —
SwiftUI's own NavigationSplitView detail column group; standalone repro extended
(`tools/a11y/repros/navsplit-sidebar-group.swift plain detaillabel`).

Snapshots: `WindowSnapshotTests.sidebarContent` references re-recorded for r4's P35 (`ac9163653`, cherry-picked to the
merge queue).

### Failing now (latest run per test)
| Test | Latest failure [chunk] |
|---|---|
| DictationTests/testIncognitoKeepsNoRecording | XCTAssertTrue failed [r3] |
| ImageEditTests/testEditGeneratedImage | Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [r2] |
| ImageViewerTests/testViewerZoomSaveCopyReveal | XCTAssertTrue failed [r2] |
| ModelInfoTests/testTenTurnsCarryProvenanceAndModelInfoShowsThem | Not hittable: MenuButton, {{911.0, 736.0}, {22.0, 16.0}}, identifier: 'action.more', title: 'More', label: 'More' [r3] |
| QueueTests/testTypeBeforeReady | Failed to get matching snapshot: No matches found for Elements matching predicate '"queuedBubble.remove" IN identifiers' from input {( [r3] |
| FilesJourneyTests/testJourney4 | XCTAssertTrue failed - opens the document [r3] |
| FileActionsTests/testAccessibilityAudit | failed - FileActions: Action is missing [action.more] type=16 frame=(609.0, 455.0, 22.0, 16.0) label='More' — This element is missing accessibility action suppo [r2] |
| MCPOAuthUITests/testSignInFlow | XCTAssertTrue failed - consent sheet after sign-in (alert Continue pressed: false) [r1] |
| PrivacyUITests/testNetworkActivityAfterSearch | XCTAssertTrue failed [r1] |
| QueueTests/testFollowUpQueued | XCTAssertTrue failed - three queued bubbles [r5] |
| VideoPlayerTests/testInlineControls | XCTAssertTrue failed - full-screen toggle [r3] |
| VoiceToolsTests/testConnectionDuringVoice | XCTAssertTrue failed [r1] |
| WebSearchUITests/testChipForcesSearchAndPills | Not hittable: Button, {{512.0, 424.0}, {119.5, 16.0}}, identifier: 'citation.1', label: 'Source 1: macOS release notes, source1.example' [r1] |
| WebSearchUITests/testEveryPillMapsToFetchedSource | XCTAssertTrue failed - pill 2 [r1] |
| WindowLayoutTests/testDisclaimerSeparatorAndJumpToBottom | Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: TextView, {{562.0, 900.5}, {552.0, 22.0}}, identifie [r1] |
| AccessibilityAuditTests/testEverySettingsSection | failed - S-21 settings.nav.general: Parent/Child mismatch [] no element — This element is not an accessibility child of the parent element. [r2] |
| AccessibilityAuditTests/testEvilChat | failed - S-06: Action is missing [shareButton] type=16 frame=(1222.5, 143.0, 38.0, 38.0) label='Share' — This element is missing accessibility action support eq [r2] |
| AccessibilityAuditTests/testNewChatAndChat | failed - S-05: Contrast nearly passed [] type=48 frame=(702.0, 246.59130859375, 288.0, 14.0) label='' — Contrast is not high enough for Ask anything · Talk to m [r2] |
| AccessibilityAuditTests/testOnboarding | failed - S-01: Element has no description [] type=4 frame=(224.0, 104.0, 1280.0, 800.0) label='' — This element is missing useful accessibility information. [r2] |
| AccessibilityAuditTests/testPaletteAndShortcuts | failed - S-18: Element has no description [] type=1 frame=(446.0, 364.0, 624.0, 611.5) label='' — This element is missing useful accessibility information. [r2] |
| ComposioUITests/testConnectGmailThreeSteps | failed - the app opened no sign-in link [n2] |
| ComposioUITests/testRateLimitedShowsCopy | XCTAssertTrue failed [n2] |
| ContextTests/testUsageRisesThenSummarisedNoticeOnce | Failed to get matching snapshots: Timed out while evaluating UI query. [r2] |
| FilesIntakeTests/testCorruptPDFShowsErrorTileAndToast | Failed to get matching snapshots: Timed out while evaluating UI query. [r2] |
| FilesScanTests/testScanTileCountsPagesAndSendsEarly | Failed to get matching snapshots: Timed out while evaluating UI query. [r2] |
| ImageUnderstandingTests/testTextOnlyModelShowsNeedsLargerModelWithCapabilitiesLink | XCTAssertTrue failed [r3] |
| J08IncognitoTests/testJourneyLeavesNoTraceAndAsksOnClose | XCTAssertTrue failed [r3] |
| J12ToolApprovalTests/testLoopLimitAndContinue | XCTAssertTrue failed - no loop-limit notice [r3] |
| JITPermissionsUITests/testNotificationsOnFirstEvent | XCTAssertTrue failed [r3] |
| JobQueueTests/testOneAtATimeWithPositions | XCTAssertTrue failed [r3] |
| KeyboardOnlyTests/testEveryKeyboardPath | XCTAssertTrue failed - app.newIncognito [r3] |
| KeyboardOnlyTests/testShortcutRebind | XCTAssertTrue failed [r3] |
| LibraryTests/testSoundIcon | XCTAssertTrue failed - sound icon: video.mp4, 0:03 [r3] |
| VideoEntryTests/testAnimateOnImageCard | XCTAssertTrue failed - Animate is an explicit intent [r3] |
| VoiceOverLabelTests/testInventory | XCTAssertEqual failed: ("["9 id= label=\'\'"]") is not equal to ("[]") - S-18 [r3] |
| ImageEditTests/testVersionsKept | Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [r2] |
| ImageViewerTests/testVersionRailListsVersions | Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [r2] |
| VideoJobCardTests/testRealPercentAndStage | XCTAssertLessThan failed: ("3.317521095275879") is not less than ("3.0") - never > 3 s without a UI change [r3] |

### After the pause (r3–r5)
- P57 (R-273 AC4): a later turn could never make version 2 of a file — past turns' tool results (with the
  `artifact_id`) are not in the prompt history, so a model only made a new file. With a file-out tool offered, the turn
  context names the chat's produced files and ids ("Files made in this chat: … artifact_id … To change one, call its
  create tool again with revises …"), as the picture-in-focus line does. Unit `FileOutContextTests`; FileVersion passes.
- P58 (R-291 AC2): after a relaunch the interrupted card found no job (the call→job map is in memory); it now finds the
  reply's `lost` row by message id. JobQueue interrupted restart passes.
- P59: the Advanced group's content id (`settings.cap.advanced.content`) and the picker option's fit-pill id were
  stamped over the override pickers' ids; the versioned file card's `fileOutCard` id over the version switcher's.
  AdvancedOverride and FileVersion pass. J10 now checks the real content ids for "collapsed".
- `TurnApp.send` clicks the composer at its centre (no hit point with follow-ups queued).

### Open (round 5)
- **P0 residual**: on main's fix, ImageEdit ×2 / ImageViewer versions still "main thread busy" (r2: 100 % CPU, 1.17 GB at
  38 s; `SelectionOverlay.updateNSView` + a `TimelineView` still ticking; `a1-samples/imageedit-r2.txt`). Reported.
  QueueTests.testFollowUpQueued (a1, before the fix: same signature, 8.4 GB) and RendererStreaming / VideoJobCard were
  not reached in r2.
- WebSearch: only `citation.1` reaches the AX tree; pills 2–4 missing and the pill's hit test still lands on the text
  view (needs an AX dump of the live reply: `build/xcuitest/probe2.sh`). Privacy network-activity event after expand.
- MCPOAuth: the web-auth alert is out of process; `webauth-continue` found no window with "wants to use … AntiChat"
  (needs a screenshot of the alert to match its text).
- WindowLayout disclaimer: after the first send the docked composer has no keyboard focus (product candidate; not
  isolated yet).
- ImageViewer: `imageViewer.reveal` not hittable even with the pointer moved off the toolbar.
- R-291 AC2 (lead decision: implement): **P56**, unit-tested (`ImageJobRestartTests`) and the UI leg passes (r4). A `lost` picture
  job's card shows `job.interrupted` "Interrupted · Restart" (the line is the action, `imageJobRestart`; the card is
  named by it), distinct from a failed job's `media.error` + Retry. Restart → `ImageTools.restartInterrupted`: the same
  request as a new job (`MediaJobQueue.restart(_:callID:)`, the card's key follows it), the result stored as the call's
  artifact, the reply's activity + tool result rewritten with the new outcome. Image job rows now carry the reply id
  (`message_id`), so a relaunched card finds its lost job (`MediaJobQueue.lostJob(messageID:)`) — no schema change.
  Unit `ImageJobRestartTests`; UI `JobQueueTests.testInterruptedRestartAfterForceQuit` after "resume". Video jobs keep
  `video.lost` + Retry (same pattern can follow).
- Composio ×2 need `make relay-dev` (mock Composio) running; Context / FilesIntake / FilesScan time out evaluating
  queries with the app idle (XCTest side, not sampled further).
- Accessibility audits (×5 + FileActions): toolbar/menu `Menu` buttons "Action is missing", contrast, parent/child —
  M9.T03 scale; the a11y-audit agent owns them.
- VoiceOverLabel: the test excludes XCUITest's `_XCUI:*` window buttons (AppKit's traffic lights), `_XCUI:` prefix
  only. Reviewer: lead (orchestrator) 2026-11-11 — accepted, AppKit/XCTest-owned titlebar buttons, same scope as
  _XCUI:FullScreenWindow.
- J08 / Dictation incognito: the incognito empty state shows, but in J08 the sends after the first never go out and the
  mic click starts no dictation bar; JIT notifications, JobQueue positions/restart; FilesJourney's side panel `panelPDF` not found in r2.
- FileVersion: fixed by P57 (the files context line) with the script's `"when"` + `revises: "{{artifact}}"`; passes (r5).

### Gates (final, at `ad2d87794` + report)
- `make test-unit`: EXIT=0.
- `make test-integration-stub`: EXIT=0 — 93 executed, 20 skipped, 0 failures (an earlier run in the perf rebuild window
  had 2 LlamaServerSupervisionTests load flakes; that suite alone and this full run pass).
- `BINARIES_SRC=…/agent-ab2f916cd531f2084/Binaries make audit`: EXIT=0 (`uitests-build` ok; l10n-check lists untranslated
  de/fr/es keys, non-blocking).

## Round 4 (`fix/xcuitest-r4`, 2026-11-10, main `d6c80bbc5` merged)

Re-ran the round-3 failures and the 43 tests round 3 did not re-run, in chunks on the shared screen: `c2` (13 transcript
/ files / OAuth tests), `c2b` (its failures after fixes), `nr1` (22 not re-run in round 3), `r1` (the nr1 and c2
failures after fixes), `nr2` (22 not re-run), plus single-test probes (`pA`, `pB`, `abOn`, `abOff`, `pSide`) with `axhit` /
`axdump` against the live app. Logs: `build/xcuitest/2026-11-10-r4/<chunk>.{log,sum,json}` and `*-samples/` (the 7 GB of `.xcresult` bundles were deleted at cleanup). Per AT:
`build/at/<AT>/xcuitest-2026-11-10.json` rewritten for every test re-run here (leg "XCUITest (Q-015 r4)"); a test not
re-run keeps its round-3 result.

| | Tests |
|---|---|
| Round 3 failing | 116 (73 failed their round-3 re-run, 43 kept their round-2 result) |
| Re-run in round 4 | 81 of the 116 |
| … now pass | **41** (40 + ToolApprovalUITests.testPerChatToggleAndActivityLine, passed in the interrupted `nr2` run) |
| … still fail | 40, of which **9 failed to launch** (orphan pid 5587, environmental) |
| Not re-run in round 4 | 35 (AccessibilityAudit ×5, ArtifactsPanel ×3, Composio ×2, AdvancedOverride, Composer mic card, Context, FileVersion, FilesIntake, FilesScan, ImageUnderstanding, J03 / J07 / J08 / J12, JIT permissions, JobQueue ×3, KeyboardOnly ×2, Library ×2, Skills, SpikeRestart, VideoEntry ×3, VoiceOverLabel; they keep their round-3 result) |
| **Failing now** | **75** (116 − 41), 9 of them environmental |

All tests run in round 4 (including round-3 passes re-checked in the same suites): 107 distinct, 64 pass, 41 fail, 2 skipped
(per AT: 53 `build/at/<AT>/xcuitest-2026-11-10.json` files rewritten, leg "XCUITest (Q-015 r4)").

### Product bugs found and fixed (round 4)

| # | Bug | Impact | Fix / test |
|---|---|---|---|
| P29 | A `.contain` container with `.contentShape(Rectangle())` gives the child that is alone in it when it appears the container's whole AX frame, and it keeps it. The pending reply shows only its PendingDot for 2.5 s, so the dot's frame became the whole reply (532 × 415 pt). | The accessibility hit test resolved every point of a pending reply to the "Thinking…" dot: a tool card's Stop / Cancel was not hittable to VoiceOver mouse-follow, Switch Control and XCUITest. The same container shape was on UserBubble. | Reply and user bubble take their hover area from a clear background with the shape (`.background { Color.clear.contentShape(Rectangle()) }`). Standalone repro `tools/a11y/repros/container-contentshape-frame.swift`; AX dump of the live app: the dot is 8 × 8. ImageJobCard Stop passes. docs/prd/M9-T03-hit-test-feedback.md items 5–7. |
| P30 | A send carried only the drawn tool chips; the aspect pick (`aspect:<ratio>`, not a chip) never reached the turn. | **Every aspect chip was ignored** (AT-030): a forced picture came out at the model's aspect. | `ToolChipsModel.turnIDs` (send and send-now). Unit test `AspectChipsModelTests.aSendCarriesTheAspect`. ImageEntry 1:1 and 2:3 legs pass. |
| P31 | A new turn did not bring the transcript back to the bottom when the column had been left above it (a tall picture card growing under a still view). | The user's own message and the new reply were drawn below the fold (and, lazily, not at all). | `TranscriptList`: a growing item count scrolls to the bottom and re-attaches. |
| P32 | The newer-data window's identifier was set on a non-container, so it replaced its children's identifiers. | `blocking.message`, `newerData.quit` / `.update` were unreachable to accessibility clients by id; the window read as three elements all named `newerData.window`. | `.accessibilityElement(children: .contain)` before the id. MigrationUITests.testNewerDataWindow passes. |
| P33 | The DEBUG notification spy wrote `opened-urls.txt` into a folder that exists only after a notification was recorded. | The denied-banner leg recorded nothing (DEBUG only). | The folder is created first. NotificationsUITests.testDeniedBanner passes. |
| P34 | The Quick Panel hotkey ordered the panel in while AntiChat was hidden (⌘H), which shows nothing. | The global hotkey did nothing after the user hid the app. | Unhide without activating before ordering the panel in. |
| P35 | Sidebar section titles (Today, …) were List section headers, and a List header sits in an unnamed AXGroup that SwiftUI owns (AX dump of the live app). | Audit "Element has no description" (FileActions / S-05). | The title is the section's first row: one element named by its text, header trait, not selectable. |
| P37 | The round-4 WIP moved PendingDot to a phase animator and out of StatusVerbView's timeline. With a long streaming reply and queued follow-ups the main thread ran SwiftUI transactions without end (SelectionOverlay updates, memory 13 MB → 1.3 GB in 2 min). | QueueTests.testFollowUpQueued: "main thread busy" for 10 min, 5.6 GB. | A/B on the same runner: main's app no hang (140 MB); branch hangs, also with the hit-test override off; branch with the two files at main's form no hang (118 MB). Both files are back to main's form, plus the dot's "Thinking…" name. |
| P36 | ChatSessions (WIP r4) observed `MCPHost.didChange` on the main queue; MCPHost posts from its own executor, so the post waited for the main thread. | **Deadlock** while the main run loop was nested: `MCPOAuthFlowTests.testCIMD` hung in `MCPHost.notify` (sampled). | Observer on the posting thread, async hop to the main actor. |

Kept from the round-4 WIP (now verified): `Entry.main` creates `AntiChatApplication` first (the principal class was
ignored before); the hit-test override (see M9.T03 below); PendingDot named "Thinking…" (its phase-animator and
timeline changes were reverted, P37); SettingsRow labels; FileCard focus; the M3 level-meter main-thread hang fix.

### Open P0 candidate: SwiftUI transactions without end on the image-edit path (also on main)
ImageEditTests.testVersionsKept and ImageViewerTests.testVersionRailListsVersions fail "main thread busy 30 s". Sampled
every 15 s: the main thread runs `NSHostingView.beginTransaction` → `GraphHost.flushTransactions` back to back, each
running every `SelectionOverlay.updateNSView` (`.textSelection(.enabled)` text) and invalidating layout; memory
20 MB → 1.5 GB in 2.5 min. **The same test on main's app (`c77127f1d`) grows 39 MB → 1.3 GB in 90 s**, so it is not
this branch. Same signature as P37: a running animation / timeline in the window re-runs every selectable text's
overlay per frame. Candidates on this path: DotMatrixPlaceholder's `TimelineView(.animation)`, AnimatedPreview /
ProgressPill timelines. Samples: `build/xcuitest/2026-11-10-r4/{ie,ieM}-samples/` (qB / qR / qM / qA / qF for P37).
Needs its own perf task (isolate the animation from the selectable text, or measure SelectionOverlay per frame).

### M9.T03 (transcript hit test)
- A/B after P29 (`ANTICHAT_AX_HIT_REFINE=0` vs on, `axhit` at the Stop button of a live image job): off → the
  `transcript` AXScrollArea; on → `imageJobCard.cancel`. The override stays; it changes only `accessibilityHitTest(_:)`
  (`PrincipalClassTests`).
- No standalone program reproduces the remaining scroll-view stop (window, NavigationSplitView detail, toolbar, bottom
  inset all return the button), so no Feedback is filed; docs/prd/M9-T03-hit-test-feedback.md lists the bisect still to do.
- Audit: the sidebar's unnamed group is SwiftUI's own NavigationSplitView column group (standalone repro
  `tools/a11y/repros/navsplit-sidebar-group.swift`). Ignore entry `sidebar` / `sufficientElementDescription` with the new
  `scope: sameFrame` (only the element with exactly the outline's frame; the rows are still audited). Reviewer: lead
  (orchestrator) 2026-11-10, accepted. FileActionsTests' audit now uses the ignore list.

### AT-031 AC2 amended (A-M4-R1b)
Live previews stay withheld below the ChildSafetyCheck's valid size (A-M4-R1, D-006). Making them checkable needs a ≥ 512-px
decode per preview; measured (`gpu-run.sh timing`, load 5, sd-cli, klein Q4, 1024², 4 steps): `--preview vae` costs
3.9 s per preview, 32.5 / 37.6 s per job against 17.3–19.7 s with `none` / `proj` (+85–110 %), and no FLUX.2 TAE is
pinned. docs/PRD-AMENDMENTS.md A-M4-R1b; M4.md AC2 text; `testPreviewEveryTwoSteps` asserts the amended behaviour
(no uncheckable preview shown, progress rising) and passes.

### Harness / test fixes (round 4)
- Test runner sandbox: it cannot bind a port, so `tools/ci/with-mcp-ref.sh` starts the reference OAuth AS outside it and
  passes `TEST_RUNNER_ANTICHAT_MCP_REF_URL` (`make test-ui` uses it). macOS XCUITest has no process-id initialiser; the
  web-auth alert is pressed through the app.
- Static texts carry their words as AXValue on macOS: `displayText` / `shownText` (a snapshot read that returns nil for a
  vanished element instead of failing). `wait(_:until:)` skips an absent element.
- Stale ids and roles: the Quick Panel is an AX dialog, not a window; a made file is `fileOutCard`; the excerpt note and
  activity line are one button whose label is the sentence; the sidebar unread dot is ", Unread" in the row label; the
  Quick Look panel is titled "Quick Look"; PDFView exposes its scroll view; the network-activity row is a disclosure;
  chat rows by `chatRow.` id, not outline-row index.
- Scripts: FilesExcerpt runs `files-excerpt.jsonl` (a real prefill; `basic.jsonl` had none, so "Reading … %" could
  never show); NotificationsUITests' script used a non-existent step type (`token`) and fell back to a real model; the
  temporary-title leg uses a slow title; MediaAlt makes a real picture (MediaUIApp).
- Timing: ImageJobCard Stop's 1 s bar runs from the press landing (the click's own pointer move is ~0.5 s) and the click
  itself is bounded; the status is read by value at 20 ms. ModelInfo waits for the last action bar.
- AT-104 restore leg quits with ⌘Q (a kill leaves macOS nothing to restore).
- Environment: LaunchServices held 299 records of deleted AntiChat.app snapshots; XCUITest resolved the dev bundle id to
  them ("Failed to determine bundle identifier"). The records were unregistered. An orphaned round-3 app (pid 5587, a
  deleted snapshot of agent-a35d…) kept running; tests that failed to launch on it are counted as environmental
  ("orphan pid 5587"); the kill is the owner's call.

### Open (round 4)
- **P0 candidate** (above): SwiftUI transactions without end on the image-edit path, also on main.
- FileActions audit: its last failure (the 244 × 19 header group) is what P35 fixes; P35 landed after that run (not re-run).
- Hit test: no standalone repro of the remaining scroll-view stop (M9.T03 doc); the override stays.
- Product / unclear, not fixed: FilesJourney never shows "Reading text-10p.pdf · n%" (verb.1 then nothing; the excerpt
  path's re-run does show it); SafetyMissing submits a job before `safety.missing` (AT says none); MCPOAuth sign-in
  never reaches consent after Continue; UpdateAsk shows no offer row from the served fixture catalogs; QuickPanel
  second hotkey / hidden-app legs; inline video player goes to its error phase with no poster on the scripted clip;
  VoiceTools image (AntiChatEngine crashed in `ScriptedImageEngine.run`), video (no plan card), connection;
  RendererStreaming never reaches 13,000 chars in 60 s (likely the P0 candidate's cost); WindowLayout docking offset
  74.5 > 57.85 and the disclaimer leg's focus; VideoJobCard 3.76 s without a UI change (bar 3 s); WebSearch pills /
  Read this URL / offline notice; ToolsPage offline chip and T1 warning.
- Test-side limits: VoiceSettings speed reads the slider's raw value (the "1.5×" is its value description, which
  XCUITest does not expose); ThinkHarder's tooltip (`.help`) is not in the AX tree; AudioFile's transcription finishes
  before its % is observed.
- Environmental: orphan pid 5587 (a deleted round-3 snapshot's app, still running; killing it is the owner's call).

### Gates (this branch, sequential)
- `make test-unit`: EXIT=0 (at 128f5aa83).
- `make test-integration-stub`: EXIT=0 — 92 executed, 30 skipped, 0 failures (after P36; the first run hung in
  MCPOAuthFlowTests and was stopped).
- `BINARIES_SRC=…/agent-ab2f916cd531f2084/Binaries make audit`: EXIT=0 (incl. `uitests-build`).
- Later commits: P37 (two UI files back to main's form), sidebar section rows, UI tests and docs; `uitests-build` ok.

### Failing tests (round 4, latest run per test)
| Suite | Failing tests (first failure; chunk) |
|---|---|
| AudioFileTests | testAttachAndSummarise (XCTAssertTrue failed - the tile shows the transcription's % (value ready) [m3]) |
| DictationTests | testIncognitoKeepsNoRecording (launch failed: orphan pid 5587 (environmental) [m3])<br>testRecentRecordingsList (XCTAssertTrue failed [m3]) |
| FileActionsTests | testAccessibilityAudit (failed - FileActions: Element has no description [] type=3 frame=(82.0, 382.0, 244.0, 19.0) label='' — This element is missing useful access [r2]) |
| FilesJourneyTests | testJourney4 (XCTAssertTrue failed - status lines seen: ["Thinking…", ""] [r2]) |
| ImageEditTests | testEditGeneratedImage (launch failed: orphan pid 5587 (environmental) [ie])<br>testVersionsKept (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [ie]) |
| ImageEntryTests | testCreateImageChipForcesAndAspect (launch failed: orphan pid 5587 (environmental) [r2]) |
| ImageViewerTests | testVersionRailListsVersions (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [ie])<br>testViewerZoomSaveCopyReveal (launch failed: orphan pid 5587 (environmental) [ie]) |
| MCPOAuthUITests | testSignInFlow (XCTAssertTrue failed - consent sheet after sign-in (alert Continue pressed: true) [r2]) |
| ModelInfoTests | testTenTurnsCarryProvenanceAndModelInfoShowsThem (launch failed: orphan pid 5587 (environmental) [mi]) |
| PrivacyUITests | testNetworkActivityAfterSearch (XCTAssertTrue failed [r2]) |
| QueueTests | testFollowUpQueued (Unable to find hit point for ScrollView, {{564.0, 981.5}, {552.0, 22.0}}, identifier: 'composerScroll' [qF])<br>testTypeBeforeReady (launch failed: orphan pid 5587 (environmental) [r2]) |
| QuickPanelUITests | testEscapeBehaviour (XCTAssertTrue failed [r2])<br>testOpensAboveOtherAppsStreamsAndOpensInApp (XCTAssertTrue failed [r2]) |
| RendererStreamingTests | testMixedReplyRendersWhileStreamingAndWhenDone (failed - assistant text did not reach 13000 characters [r2]) |
| SafetyMissingTests | testMissingDetectorsShowRepairAndRunNoJob (XCTAssertFalse failed - no job is submitted [r2]) |
| SidePanelTests | testOpenSwitchVersionEditSelectionClose (launch failed: orphan pid 5587 (environmental) [r2]) |
| ThinkHarderTests | testPresetTooltipWithoutReasoning (XCTAssertTrue failed [r2]) |
| ToolsPageUITests | testOfflineChipsAndNoSchemas (XCTAssertTrue failed [r2])<br>testToolAccessWarnsOnT0toT2 (XCTAssertEqual failed: ("false") is not equal to ("true") - T1 [r2]) |
| UpdateAskUITests | testAutoUpdateOffAsksInsteadOfDownloading (XCTAssertTrue failed [r2])<br>testBigUpdateAsks (XCTAssertTrue failed [r2]) |
| VideoBackgroundUITests | testWindowCloseKeepsJob (XCTAssertTrue failed [r2]) |
| VideoJobCardTests | testRealPercentAndStage (XCTAssertLessThan failed: ("3.7570769786834717") is not less than ("3.0") - never > 3 s without a UI change [r2]) |
| VideoPlanTests | testAdvancedOnlyInSettings (launch failed: orphan pid 5587 (environmental) [r2])<br>testChangeEditsPresets (launch failed: orphan pid 5587 (environmental) [r2]) |
| VideoPlayerTests | testInlineControls (XCTAssertTrue failed - poster first [nr2b]) |
| VoiceConversationTests | testOverlayAnatomyAndTyping (XCTAssertTrue failed - the typed turn's reply is spoken [m3]) |
| VoiceSettingsTests | testAllRows (XCTAssertEqual failed: ("1.5") is not equal to ("1.5×") [m3]) |
| VoiceToolsTests | testConnectionDuringVoice (XCTAssertTrue failed [m3])<br>testImageDuringVoiceSpokenPointer (Critical process AntiChatEngine crashed in ScriptedImageEngine.run(_:thermal:isCancelled:stop:outputs:emit:) [m3])<br>testVideoDuringVoiceSpokenPointer (Failed to get matching snapshot: No matches found for first query match sequence: `Descendants matching type Any` -> `Elements matching pred [m3]) |
| WebSearchUITests | testChipForcesSearchAndPills (XCTAssertTrue failed [r2])<br>testEveryPillMapsToFetchedSource (XCTAssertTrue failed [r2])<br>testOfflineChipAndNotice (XCTAssertTrue failed [r2])<br>testReadThisURL (XCTAssertTrue failed [r2]) |
| WindowLayoutTests | testDisclaimerSeparatorAndJumpToBottom (Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: TextView, {{591.0, 889.5}, {552. [nr2b])<br>testEmptyStateHeadlineAndDocking (XCTAssertLessThanOrEqual failed: ("74.5") is greater than ("57.85") [nr2b]) |

## Round 3 (`fix/xcuitest-r3`, 2026-11-10, main `d29a4b503` merged)

Re-ran the round-2 failures on this branch. The UI slot was shared (m7/final AT-248 window), and a failing test costs
1.5–5 min on this Mac (its waits run out), so the 144 failures were not all re-run on the final build:

- `c-all` and `d-rest` ran 62 of them on the earlier builds of this branch.
- `e-final`, chunks f1–f4 / v1–v3 and the single-test probes `g-hit*` re-ran the rest on the final code: every test
  that failed "Not hittable" / "hit point", the suites touched here, and the M3 voice, M4 image and M7 Composio /
  OAuth sets. In all, 101 of the 144 were re-run.

Result bundles: `build/xcuitest/2026-11-10/{c-all,d-rest,e-final,f1..f4,v1..v3,g-hit*}.xcresult` (+ `.log`, `.sum`, `.err`). Per AT:
`build/at/<AT>/xcuitest-2026-11-10.json`, rewritten for the re-run tests (leg "XCUITest (Q-015 r3)"). A test that was
not re-run keeps its round-2 result.

| Milestone | Round 2 fail | Re-run in round 3 | Now pass | Still fail |
|---|---|---|---|---|
| M1 | 23 | 12 | 5 | 18 |
| M2 | 7 | 5 | 2 | 5 |
| M3 | 24 | 23 | 9 | 15 |
| M4 | 16 | 11 | 0 | 16 |
| M5 | 17 | 14 | 2 | 15 |
| M6 | 14 | 12 | 1 | 13 |
| M7 | 17 | 8 | 2 | 15 |
| M8 | 10 | 1 | 0 | 10 |
| M9 | 10 | 9 | 1 | 9 |
| M10 | 6 | 6 | 6 | 0 |
| **Total** | **144** | **101** | **28** | **116** |

**Not green.** 28 of the 144 round-2 failures pass now. 101 were re-run (91 on the final code); the other 43 keep their round-2 failure. Every M10 failure (Help, Legal) passes. M3 voice conversations work: barge-in, hands-free / push-to-talk, the empty session, read aloud's 1 s stop, the mic permission flows and the waveform pass. The remaining M3 failures are VoiceTools (5), captions / background / typed-turn speech, Journey11 and AudioFile.

### Product bugs found and fixed (round 3)

| # | Bug | Impact | Fix / test |
|---|---|---|---|
| P18 | The DEBUG probe anchor (`probeID` / `probeAnchor`) was a shown NSView placed above the SwiftUI view it measures. The accessibility hit test resolved every point over a probed card, row or toolbar menu to the anchor. The anchor is ignored for accessibility, so the hit landed on its container. | **The open "Not hittable" finding.** Reply-card controls, Settings popups and checkboxes, skill menus and toolbar menus were "Not hittable" to XCUITest. In DEBUG builds, VoiceOver's mouse-follow and Switch Control point scanning landed on the card, not the control. Release has no anchors, so it was never affected; the cause was a DEBUG artifact, not SwiftUI. | The anchor is hidden: `isHidden` is always true and `accessibilityHitTest` returns nil, while `convert(_:to:)` still gives probes the frame. Verified by J10SettingsTests and J03EditVersionsTests.testRegenerateVersions (both failed "Not hittable" in round 2, now pass) and VoiceSettings. Unit test `ProbeAnchorHitTestTests` (hidden anchors still report frames). Skills menus now pass too, as do the Settings audit's "Action is missing" items (all gone). **Not the whole finding:** inside the chat transcript the hit test still returns the `transcript` AXScrollArea over a card's Cancel button. The element chain and frames were checked with an AX dump: every ancestor contains the point, the transcript column is an AXOpaqueProviderGroup, and swapping the LazyVStack for a VStack did not change the result (experiment reverted). So the transcript's SwiftUI ScrollView does not descend in hit tests on macOS 26 — an Apple-side defect with a repro (`ImageJobCardTests/testStopWithinOneSecond`), to be filed with M9.T03. `clickReliably()` stays for transcript controls only. VoiceOver's own navigation (element order) is unaffected; mouse-follow and Switch Control point mode inside replies are affected. |
| P19 | The voice suites run in a throwaway container with no Voice pack. The helper got an empty model set, so every voice session ended `voice.unavailable`. Also, `BenchMode.conversationModels()` looked up `turn-coreml` whenever `installs/turn` existed, and the dev store has no `turn-coreml`. | All 23 M3 failures: no orb, no mute buttons, no turns. `-Bench voice-session` hit the same turn-model miss. | DEBUG `-FakeVoiceInstalled` / `-FakePackState voice=…` hands the helper the dev store's models (`ChatModels.voiceFallback`). The turn model is the dev store's Core ML folder (`Models/turn/coreml`; `installs/turn` is ONNX only). Test: `ShippedPacksAndSetupTests.voiceFallbackOnlyWhenNothingIsInstalled`. |
| P20 | The voice overlay showed a raw error code (`voice.unavailable`) as its caption. | Users saw an internal code. | Codes with no copy get `engine.error` (VoiceOverlay `captionText`). |
| P21 | `.accessibilityValue` on `.contain` containers was never exposed: the voice overlay's mode (Hands-free / Push-to-talk) and the dictation waveform's "Recording" / level count. | VoiceOver never announced the mode or "Recording". The UI legs read "". | The overlay carries the mode as its label. The waveform is one element: its label is the last partial, else "Recording", and its value is the level probe in automation only. |
| P22 | The mic button had two `.popover` modifiers, so only one of them could present. The denied popover's identifier also replaced its button's `voice.denied` (the P3 pattern). | **Clicking the mic with microphone access denied showed nothing** (no "open System Settings" popover). | The denied popover hangs off its own background anchor (`ComposerView`), with `children: .contain`. PermissionJITTests.testMicDenied **passes**. |
| P23 | SettingsRow labels every element of a row's control. The Speed row's visible "1.5×" text was read as "Speed", and the slider read its raw value 1.5. | VoiceOver never read the speed. | The slider's value is the shown text ("1.5×"); the duplicate text is hidden from accessibility. |
| P24 | `KeychainSecrets` used the login keychain even in a DEBUG dev container. An item an earlier ad-hoc-signed build had created (`app.antichat.composio.install`) made every read open the "wants to use your confidential information" prompt, which blocked the caller until someone typed the Mac's password. | **Composio Connect opened no link and showed no error.** UI tests also wrote into the owner's keychain. | A dev container keeps its secrets in `<container>/Secrets/secrets.json` (0600). Release and every other launch still use the keychain. Test: `ContainerSecretsTests`. |
| P25 | A chart whose data sat inline in the spec (`data.values`, no `data_ref`) saved no table. | **View data was disabled on every such chart** (the common case for typed numbers). | `CreateChartTool.inlineTable` fills the snapshot's columns and rows. Test: `ChartInlineTableTests`. |
| P26 | AttachmentTileView had a second `onHover` on its content. Moving onto the Animate button, a layer above the content, ended the hover, the button went away, and the click landed on the tile (Quick Look). | **Animate on an attachment never reached `onAnimateAttachment`** (open finding). | Hover only on the whole tile. |
| P27 | The user bubble's left inset was 30 % of the full reading width, not of the column the row really has. | With the side panel open, a one-line request became a 53 pt × 569 pt sliver (seen in ArtifactsPanel trees). | `UserBubble.leadingInset(readingWidth:rowWidth:)`. Test: `UserBubbleInsetTests`. |
| P28 | A dismissed tour tip stayed as an empty, zero-size element (TipView collapses but stays in the tree). | VoiceOver had an empty element in every later new chat, and "gone for good" could not be told apart from "still there". | TourTipView renders nothing once `shouldDisplayUpdates` says false. |

### Harness / test fixes (round 3)
- Stale ids: `message.user` / `message.assistant` → `userBubble` / `assistantMessage`, interrupted → `interruptedNotice`,
  `userMessage` → `userBubble`.
- Container labels: tiles, rows and cards are one element (or a container), so their text is read from the
  element's label or its child (`installCardText`, legal rows, file tile "Upload failed" / "Reading scan · page n").
  Toasts are checked before they dismiss themselves.
- macOS 26 `URL.path` drops the trailing slash (`path(percentEncoded:)`). `waitForExistence` was used as a "gone"
  check; it is now `waitForNonExistence`. ReadAloud's 1 s bar is polled at 20 ms (an NSPredicate expectation
  re-evaluates about once a second, so the cadence alone broke the bar).
- `clickDisclosure()` waits for the value before its fallback press. The fallback had closed the group the first click
  opened.
- Crash legs (DraftTests, J13CrashRecoveryTests, SpikeRestartTests): `pkill` exits 3 from the sandboxed runner, so the
  app is killed by its pid and the helper is found by its executable path through libproc (`TestProcesses`).
- EvilEntryPointsTests uses the shared app lifecycle. ComposerTests' install card is on the Talk button: dictation
  works without the pack since R-281, through Basic voice. Granting the mic starts the dictation the click asked for
  (PermissionJIT). A paste over 10,000 characters is a paste card in every composer mode (ContextTests). The lazy
  transcript is scrolled back to the summary notice before it is counted.
- ArtifactsPanel Edit selection double-clicks a word on the first line. The 60-line text view's centre was below the
  visible part of the panel.
- Accessibility audit: S-21 minimises the chat window first, so the Settings screens are audited alone. Left behind
  the Settings window, the chat window's toolbar menus and placeholder were audited too. Ignore entries are scoped to
  one element's frame and one audit type.

### SessionPoolTests.betweenRunsTheInterpreterIsStopped (FileToolsHost)
The test failed on main too: the test file and FileToolsHost are identical on main and on this branch. Its main form
failed 2 of 30 runs at load 9–15 (a temporary copy, deleted). The cause is the test. It compared the counter across
two one-line runs, and under load both runs can finish inside one GIL switch interval before the woken thread is
scheduled. `a == b` there is a race, not a defect: the SIGSTOP between runs is asserted separately (`SSTOP`). The run
now waits in-process until the counter moves, bounded at 10 s with no fixed sleep, and the test asserts `SSTOP` before
and after that run. 20 of 20 runs passed at the same load.

### Accessibility audit (M9.T03)
- Ignore entry (tools/a11y/audit-ignores.yml): `_XCUI:FullScreenWindow`, parentChild, for elements inside that button's
  frame. AppKit's own green window button exposes an unnamed AXGroup child on macOS 26; Terminal and TextEdit show the
  same in an AX dump. **Reviewer: pending.** The code-review agent declined to sign it, because an agent signing would
  look like human approval. It needs the owner's or lead's sign-off.
- Still open, not fixed here:
  - "Action is missing" on Settings popups and checkboxes (`settings.control.*`, pack toggles) and on the
    Capabilities Advanced disclosure.
  - Doubled labels ("App language, App language"): SettingsRow puts the row label on a control that already has the
    same label.
  - "Element may need a title" on `settings.pack.*.toggle` (empty label).
  - Unnamed groups in Settings.
  - "Unknown role" on `settings.voice.levelMeter`.

  These need a SettingsRow-wide change (the labeled-pair pattern) and an inventory re-check, so they were left for
  M9.T03. Contrast: the tokens meet 4.5:1 on paper (tokens.md); the S-21 failures were measured through the covering
  window. Re-check after the minimise change.

### Open (round 3)
- **Transcript hit test** (P18, Apple side): `clickReliably()` stays for controls inside replies. Tests that still call
  `.click()` on them fail "Not hittable": VideoJobCard ×4, VideoPlan.testChangeEditsPresets,
  ImageJobCard.testStopWithinOneSecond, QueueTests / JobQueue "hit point" on `composerScroll`.
- **M4 image:** the ImageEdit / ImageViewer edit legs time out on "main thread busy 30 s" after the edit turn (a
  sample during a hang showed the main thread in `ChatSessions.syncSetup` → `InstallQueue.plan`, polled every 400 ms;
  not conclusive, not changed). ImageEntry aspect chips don't appear from the + menu row.
- **File card ⋯ menu** still opens nothing on a click (FileCard / FileActions). Moving the card's tap gesture off the
  menu didn't help and was reverted.
- **M7:** Composio Connect now opens the sign-in link and connects (P24). The test now looks for the link-styled
  Disconnect and only presses Connect while it is shown; the rate-limit leg is not re-run on that last change.
  MCPOAuth still never reaches consent. ToolsPage, WebSearch, Security, ToolApproval and ToolChange were not
  re-run.
- **M6:** the excerpt note never appears for `doc-020p.pdf` at a 32k window (FilesExcerpt ×3, FilesJourney). The
  artifact Fix / Edit-selection legs now script a changed second reply (an identical reply is the same artifact by
  SHA-256); not re-run after that change.
- **Not re-run this round (43):** most of M1 (Queue, Sidebar, ThinkHarder, WindowLayout, Renderer, ModelInfo,
  Menus), M8 (10), and part of M7 / M5. Each keeps its round-2 failure in the table below.
- **Audit:** see "Accessibility audit" above (the ignore entry still needs a sign-off).

### Gates (this branch, sequential, after the runs; code at `79bc9f348`, later commits are UI tests, report and json only)
- `make test-unit`: pass. An earlier run under load 40 (UI batch and two GPU jobs) failed RunPythonToolTests' idle
  reaper and LlamaWatchdogTests' group-exit leg. Neither is touched here, and both passed in the gate run.
- `make test-integration-stub`: 90 executed, 30 skipped, **1 failure**:
  `SystemReportEngineTests.testProbeCarriesResidentSetAndLoadTimes` (`probeConnected` saw no resident bytes). It
  passes alone (`FILTER=SystemReportEngineTests`, TEST SUCCEEDED). The engine code is not touched here; it is a
  flake under the shared load.
- `BINARIES_SRC=$HOME/AntiChat/Binaries make audit`: EXIT=0 (incl. `uitests-build`).

### Failing tests (round 3, combined)
| Suite | Failing tests (first failure; bundle) |
|---|---|
| AccessibilityAuditTests | testEverySettingsSection (failed - S-21 settings.nav.general: Parent/Child mismatch [] no element — This element is not an accessibility [e-final])<br>testEvilChat (failed - S-06: Element has no description [] type=3 frame=(176.0, 144.0, 260.0, 844.0) label='' — This element [c-all])<br>testNewChatAndChat (failed - S-05: Element has no description [] type=3 frame=(176.0, 144.0, 260.0, 844.0) label='' — This element [e-final])<br>testOnboarding (failed - S-01: Element has no description [] type=4 frame=(224.0, 104.0, 1280.0, 800.0) label='' — This elemen [c-all])<br>testPaletteAndShortcuts (failed - S-18: Element has no description [] type=1 frame=(446.0, 364.0, 624.0, 611.5) label='' — This element [c-all]) |
| AdvancedOverrideUITests | testOverridePickerFitPillsAndReset (XCTAssertTrue failed [e-final]) |
| ArtifactsPanelTests | testCopyDownloadAndFix (XCTAssertTrue failed - Fix made version 2 [f1])<br>testEditSelection (XCTAssertTrue failed [f1])<br>testPreviewsRender (Application 'app.antichat.AntiChat.dev' does not have a process ID [f1]) |
| AudioFileTests | testAttachAndSummarise (Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "Expect predicate `va [v2]) |
| ComposerTests | testMicShowsTheVoiceInstallCard (XCTAssertNotEqual failed: ("packMissing") is equal to ("packMissing") - Basic voice dictates without the pack [f1]) |
| ComposioUITests | testConnectGmailThreeSteps (XCTAssertTrue failed [f1])<br>testRateLimitedShowsCopy (Failed to click "composio.connect.slack" Any: No matches found for first query match sequence: `Descendants ma [f1]) |
| ContextTests | testUsageRisesThenSummarisedNoticeOnce (XCTAssertEqual failed: ("0") is not equal to ("1") [f1]) |
| DictationTests | testIncognitoKeepsNoRecording (XCTAssertTrue failed [v2])<br>testRecentRecordingsList (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [v2]) |
| FileActionsTests | testAccessibilityAudit (failed - Element has no description: 3 id= label= frame=(176.0, 144.0, 260.0, 844.0) [f1])<br>testOpenSaveReveal (XCTAssertTrue failed - Save As… [f1]) |
| FileCardTests | testOpenSaveRevealOnFixtures (XCTAssertTrue failed [f2])<br>testQuickLookSpace (XCTAssertTrue failed - click opens Quick Look [f2]) |
| FileVersionTests | testChangeRequestShowsVersionTwoWithSwitcher (XCTAssertTrue failed [c-all]) |
| FilesExcerptTests | testExcerptNoteListsPages (XCTAssertTrue failed [c-all])<br>testReadWholeFileShowsEstimateAndReadingPercent (XCTAssertTrue failed [c-all])<br>testSummariseWholeShowsRisingProgress (XCTAssertTrue failed [d-rest]) |
| FilesIntakeTests | testCorruptPDFShowsErrorTileAndToast (Failed to get matching snapshots: Timed out while evaluating UI query. [f2]) |
| FilesJourneyTests | testJourney4 (XCTAssertTrue failed - Thinking… [d-rest]) |
| FilesScanTests | testScanTileCountsPagesAndSendsEarly (Failed to get matching snapshots: Timed out while evaluating UI query. [f2]) |
| ImageEditTests | testEditGeneratedImage (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [d-rest])<br>testVersionsKept (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [d-rest]) |
| ImageEntryTests | testCreateImageChipForcesAndAspect (XCTAssertTrue failed [f2]) |
| ImageJobCardTests | testPreviewEveryTwoSteps (XCTAssertTrue failed [f2])<br>testStopWithinOneSecond (Not hittable: Button, {{1012.0, 681.5}, {24.0, 24.0}}, identifier: 'imageJobCard.cancel', label: 'Cancel' [g-hit4]) |
| ImageUnderstandingTests | testTextOnlyModelShowsNeedsLargerModelWithCapabilitiesLink (XCTAssertTrue failed [d-rest]) |
| ImageViewerTests | testVersionRailListsVersions (XCTAssertTrue failed [f2])<br>testViewerZoomSaveCopyReveal (XCTAssertTrue failed [f2]) |
| J03EditVersionsTests | testActionBar (XCTAssertTrue failed [d-rest]) |
| J07EvilChatTests | testEvilChatJourney (XCTAssertTrue failed [d-rest]) |
| J08IncognitoTests | testJourneyLeavesNoTraceAndAsksOnClose (XCTAssertTrue failed [d-rest]) |
| J12ToolApprovalTests | testLoopLimitAndContinue (XCTAssertTrue failed - no loop-limit notice [d-rest]) |
| JITPermissionsUITests | testNotificationsOnFirstEvent (XCTAssertTrue failed [d-rest]) |
| JobQueueTests | testInterruptedRestartAfterForceQuit (XCTAssertTrue failed [d-rest])<br>testOneAtATimeWithPositions (Unable to find hit point for ScrollView, {{562.0, 900.5}, {552.0, 22.0}}, identifier: 'composerScroll' [f3])<br>testWindowCloseKeepsJob (XCTAssertTrue failed - the job finished with no window [d-rest]) |
| Journey11VoiceTests | testDictationThenVoiceWithBargeIn (Failed to get matching snapshot: No matches found for first query match sequence: `Descendants matching type A [v2]) |
| KeyboardOnlyTests | testEveryKeyboardPath (XCTAssertTrue failed - app.newIncognito [d-rest])<br>testShortcutRebind (XCTAssertTrue failed [d-rest]) |
| LibraryTests | testEvilBadgeAndToggle (XCTAssertTrue failed [f3])<br>testSoundIcon (XCTAssertTrue failed - sound icon: video.mp4, 0:03 [f3]) |
| MCPOAuthUITests | testSignInFlow (XCTAssertTrue failed [f3]) |
| MediaAltTests | testGeneratedImageHasDescription (Failed to get matching snapshot: No matches found for first query match sequence: `Descendants matching type A [round 2, not re-run]) |
| MenuBarUITests | testMenuItemsInOrderAndActions (XCTAssertTrue failed [round 2, not re-run]) |
| MenusWindowsTests | testMenusAndWindows (XCTAssertEqual failed: ("1") is not equal to ("2" [round 2, not re-run]) |
| MigrationUITests | testNewerDataWindow (Failed to get matching snapshot: No matches found for first query match sequence: `Descendants matching type S [round 2, not re-run]) |
| ModelInfoTests | testTenTurnsCarryProvenanceAndModelInfoShowsThem (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s [round 2, not re-run]) |
| NotificationsUITests | testDeniedBanner (XCTAssertEqual failed: ("nil") is not equal to ("Optional("x-apple.systempreferences:com.apple.Notifications-S [round 2, not re-run])<br>testNoNotificationWhenFocused (XCTAssertTrue failed [round 2, not re-run]) |
| PresentationTests | testPanelPreview (XCTAssertTrue failed [round 2, not re-run]) |
| PrivacyUITests | testLocationNotRequestedUntilEnabled (XCTAssertTrue failed [round 2, not re-run])<br>testNetworkActivityAfterSearch (XCTAssertTrue failed [round 2, not re-run]) |
| QueueTests | testFollowUpQueued (Unable to find hit point for ScrollView, {{562.0, 900.5}, {552.0, 22.0}}, identifier: 'composerScroll' [f3])<br>testTypeBeforeReady (Failed to get matching snapshot: No matches found for Elements matching predicate '"queuedBubble.remove" IN id [round 2, not re-run]) |
| QuickPanelUITests | testEscapeBehaviour (XCTAssertTrue failed [round 2, not re-run])<br>testOpensAboveOtherAppsStreamsAndOpensInApp (XCTAssertTrue failed [round 2, not re-run])<br>testRecorderChangesAndOff (Failed to click Button (First Match): No matches found for first query match sequence: `Descendants matching t [round 2, not re-run]) |
| RendererStreamingTests | testMixedReplyRendersWhileStreamingAndWhenDone (failed - assistant text did not reach 13000 characters [round 2, not re-run]) |
| SafetyMissingTests | testMissingDetectorsShowRepairAndRunNoJob (XCTAssertTrue failed [round 2, not re-run]) |
| SecurityUITests | testInjectedPageAsksWithUntrustedLine (XCTAssertTrue failed [round 2, not re-run]) |
| SheetQueryTests | testQueryStepCollapsedAndExpanded (XCTAssertTrue failed [round 2, not re-run]) |
| SidePanelTests | testOpenSwitchVersionEditSelectionClose (Failed to get matching snapshot: No matches found for Descendants matching type MenuItem from input {( [round 2, not re-run]) |
| SidebarStatusTests | testSpinnerAndUnreadDot (XCTAssertTrue failed [round 2, not re-run])<br>testTemporaryThenAutoTitle (XCTAssertTrue failed - Harbour town weekend plan [round 2, not re-run]) |
| SkillsUITests | testCreateByChatInstallCard (XCTAssertTrue failed [f3]) |
| SpikeRestartTests | testUIStaysAliveWhenEngineIsKilled (XCTAssertTrue failed - no running helper at /Users/armando/AntiChat/.claude/worktrees/agent-a35d1546213c178b3/ [f3]) |
| ThinkHarderTests | testPresetTooltipWithoutReasoning (XCTAssertTrue failed [round 2, not re-run])<br>testThinkingLineTimingAndCollapse (XCTAssertTrue failed [round 2, not re-run]) |
| ToolApprovalUITests | testPerChatToggleAndActivityLine (Failed to click "addButton" Button: No matches found for Elements matching predicate '"addButton" IN identifie [round 2, not re-run]) |
| ToolChangeReviewUITests | testRugPullRevertsToAsk (XCTAssertTrue failed [round 2, not re-run]) |
| ToolsPageUITests | testOfflineChipsAndNoSchemas (Failed to click "addRow.web" Any: No matches found for first query match sequence: `Descendants matching type  [round 2, not re-run])<br>testPlusMenuPerChatDoesNotChangeGlobal (Failed to click "addRow.tools" Any: No matches found for first query match sequence: `Descendants matching typ [round 2, not re-run])<br>testToolAccessWarnsOnT0toT2 (XCTAssertEqual failed: ("false") is not equal to ("true") - T1 [round 2, not re-run]) |
| UpdateAskUITests | testAutoUpdateOffAsksInsteadOfDownloading (XCTAssertTrue failed [round 2, not re-run])<br>testBigUpdateAsks (XCTAssertTrue failed [round 2, not re-run]) |
| VideoBackgroundUITests | testNavigateAwayKeepsJob (XCTAssertTrue failed [round 2, not re-run])<br>testNotificationClickOpensResult (XCTAssertTrue failed [round 2, not re-run])<br>testWindowCloseKeepsJob (XCTAssertTrue failed [round 2, not re-run]) |
| VideoEntryTests | testAnimateOnImageCard (XCTAssertTrue failed - plan card [f4])<br>testCompletionEventPosted (XCTAssertTrue failed - the finished job offers Open [f4])<br>testPlainLanguageVideo (XCTAssertTrue failed [f4]) |
| VideoJobCardTests | testCancelFreesMemory (Not hittable: Button, {{1012.0, 621.5}, {24.0, 24.0}}, identifier: 'videoJob.cancel', label: 'Cancel' [g-hit4])<br>testNavigateAwayAndBack (Not hittable: OutlineRow, {{176.0, 188.0}, {260.0, 32.0}} [f4])<br>testRealPercentAndStage (XCTAssertLessThan failed: ("3.2834030389785767") is not less than ("3.0") - never > 3 s without a UI change [round 2, not re-run])<br>testSurvivesWindowClose (Not hittable: OutlineRow, {{176.0, 188.0}, {260.0, 0.0}} [f4])<br>testThermalCriticalPausesAndResumes (Not hittable: Link, {{532.0, 661.5}, {197.5, 15.0}}, identifier: 'videoJob.resume', label: 'Paused — your Mac  [f4]) |
| VideoPlanTests | testAdvancedOnlyInSettings (XCTAssertTrue failed - settings.row.videoAdvancedSteps [round 2, not re-run])<br>testChangeEditsPresets (Not hittable: Button, {{617.0, 408.0}, {71.5, 20.0}}, identifier: 'videoPlan.shape.portrait', label: 'Portrait [f4]) |
| VideoPlayerTests | testInlineControls (XCTAssertTrue failed - AVPlayerView mounted [round 2, not re-run]) |
| VoiceConversationTests | testHalfDuplexHint (XCTAssertTrue failed [v2])<br>testKeepsRunningInBackground (XCTAssertTrue failed [v3])<br>testOverlayAnatomyAndTyping (XCTAssertTrue failed - the typed turn's reply is spoken [v3])<br>testTranscriptAsTurnsAndCaptions (XCTAssertTrue failed [v3]) |
| VoiceOverLabelTests | testInventory (XCTAssertEqual failed: ("["9 id=_XCUI:CloseWindow label=\'\'", "9 id=_XCUI:ZoomWindow label=\'\'", "9 id=_XCUI [v3]) |
| VoiceSettingsTests | testAllRows (Application 'app.antichat.AntiChat.dev' has not loaded accessibility [v3])<br>testPreviewPlays3s (Asynchronous wait failed: Exceeded timeout of 10 seconds, with unfulfilled expectations: "Expect predicate `BL [v3]) |
| VoiceToolsTests | testConnectionDuringVoice (XCTAssertTrue failed [v3])<br>testFileDuringVoiceSpokenPointer (XCTAssertTrue failed [v3])<br>testImageDuringVoiceSpokenPointer (XCTAssertTrue failed [v3])<br>testSearchDuringVoice (XCTAssertTrue failed [v3])<br>testVideoDuringVoiceSpokenPointer (XCTAssertTrue failed [round 2, not re-run]) |
| WebSearchUITests | testChipForcesSearchAndPills (XCTAssertTrue failed [f4])<br>testConsentSheetWhenEnabledLater (XCTAssertTrue failed [f4])<br>testEveryPillMapsToFetchedSource (XCTAssertTrue failed - pill 2 [round 2, not re-run])<br>testOfflineChipAndNotice (XCTAssertTrue failed [round 2, not re-run])<br>testOnboardingSwitchDefaultOn (XCTAssertTrue failed [round 2, not re-run]) |
| WindowLayoutTests | testDisclaimerSeparatorAndJumpToBottom (Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: Te [round 2, not re-run])<br>testEmptyStateHeadlineAndDocking (XCTAssertLessThanOrEqual failed: ("84.5") is greater than ("59.85" [round 2, not re-run])<br>testSidebarWidthAndCollapse (XCTAssertTrue failed [round 2, not re-run]) |

---

## Round 2 (`fix/xcuitest-r2`, 2026-11-10, main `0fe4cfd20` merged)

Re-ran every failing test of round 1 plus the suites added since (EvilEntryPointsTests, ImageProgressTextTests,
LegalUITests, HelpUITests). Result bundles: `build/xcuitest/2026-11-10/{r2-M5,r3,r4-R5,r4-M1,r4-M2,r4-M3,r4-M4,r4-M6,r4-M8,r4-M9,r4-NEW}.xcresult`
(+ `.log`, `.sum`); per AT: `build/at/<AT>/xcuitest-2026-11-10.json` (117 ATs, rewritten with the combined status).
Tests not re-run keep their round-1 result (all round-1 passes).

| Milestone | Round 1 pass / fail | Round 2 pass | Fail | Blocked | Skipped |
|---|---|---|---|---|---|
| M1 | 47 / 41 | 61 | 23 | 0 | 6 |
| M2 | 8 / 7 | 9 (+5 new EvilEntryPoints) | 6 (+1 new) | 0 | 1 |
| M3 | 10 / 23 | 10 | 23 | 1 | 0 |
| M4 | 14 / 16 | 14 (+1 new ImageProgressText) | 16 | 0 | 4 |
| M5 | 4 / 38 | 25 | 17 | 0 | 1 |
| M6 | 6 / 15 | 7 | 14 | 0 | 0 |
| M7 | 11 / 25 | 19 | 17 | 0 | 0 |
| M8 | 24 / 11 | 25 | 10 | 0 | 0 |
| M9 | 5 / 15 | 13 | 7 | 3 | 0 |
| M10 (new: Legal, Help) | — | 1 | 6 | 0 | 0 |
| **Total (332 round-1 tests)** | **129 / 191** | **183** | **133** | **4** | **12** |
| **With the 14 new tests (346)** | | **190** | **140** | **4** | **12** |

**Not green.** AT248RenderedPillsUITests was not run (live network + real model; the m7 track owns it).

### Product bugs found and fixed (round 2)

| # | Bug | Impact | Fix / test |
|---|---|---|---|
| P10 | `VideoJobActivityCard` drew nothing until the plan existed, and `.task` on an empty `Group` never starts, so the card never looked for the call's request. | **Every `create_video` waited forever for a plan card** (the M5 "plan card" failures; P9 was not the cause). | a zero-size placeholder keeps the view (and its task) alive; VideoPlanTests 8/12 now pass |
| P11 | Media tool calls ran under `TurnContext.toolCallID = call.id` while the card keys by the unique activity key (P2: `call_1#2`). | a repeated media call's card followed the first call's job | the media key is the activity key (TurnController) |
| P12 | MCP consent: the sheet dismissed itself (clearing `pending`) before Allow's Task ran `confirm()`, which then found nothing to add. | **Allow on any MCP server added nothing** (the round-1 "token auth" finding; every journey-12 / AT-081 leg). | `confirm(_ shown:)` takes the request the sheet showed; the add error now shows on the page (`connections.error`) |
| P13 | Side panel width was never limited by the window: a remembered 766 pt panel in a 1180 pt window pushed the split view past both window edges and squeezed the composer to 0 pt. | composer unusable with the panel open (M4/M6 "hit point" failures) | `SidePanelModel.shownWidth(in:)` keeps ≥ 360 pt (or half) for the chat — `SidePanelModelTests.shownWidthLeavesRoomForTheConversation` |
| P14 | Network category launch overrides (`-net.category.search NO`) arrive as strings; `as? Bool` ignored them. | Freshness hint and offline legs could not switch search off | `bool(forKey:)` — `NetworkPolicyDefaultsTests.stringOverrideIsRead` |
| P15 | Scripted video jobs (DEBUG) had no detector manifest unless an image script was also given. | every scripted clip failed `safety.missing` | the dev detectors also for `-UseScriptedVideoEngine` |
| P16 | `+` menu rows that do nothing (not on this Mac) were enabled for accessibility. | VoiceOver / XCUITest saw an enabled row (AT-046 "dimmed") | `.disabled` on rows that are neither pickable nor a Settings link |
| P17 | Message attachment id stamped over the inline editor's remove button id (P3 pattern). | "attachment not removable in the editor" (AT-006) | identifier before the overlay |
| — | Composer harness probes exposed no text; hosting view / Settings window unnamed to accessibility. | ComposerTests read ""; audit "no description" | probes labelled; window content view carries the spoken title |

### Harness / test fixes (round 2)
- Video Start vs the countdown: an explicit request on AC power starts by itself, so clicking Start raced it (`startVideoPlan()`).
- `clickReliably()`: SwiftUI's transcript reports controls inside reply cards as "Not hittable" to the accessibility hit
  test although a mouse click lands (verified with a coordinate click that started the job). Used for plan, approval,
  job, install and panel controls. **Open finding:** the AX hit test inside the transcript is wrong (VoiceOver uses
  element actions, so the impact is limited; worth an M9.T03 look).
- MCP suites add "Team Chat" through Settings first (`MCPUI.addTeamChat`): `-ScriptedMCP` only answers for connections
  the user added. The rug-pull session is generated by the test (`afterCalls` in the scripted MCP format; the fixture
  `scripted-server-rugpull.jsonl` never existed) — `ToolHashReviewTests.scriptedRugPullAfterCalls`.
- ComposioUITests play the browser through `-OpenURLSpy` (no real browser on the owner's Mac); the rate-limit case uses a
  second relay-dev (`ANTICHAT_RELAY_URL_LIMITED`, `RELAY_TEST_MCP_PER_MIN=1`).
- SwiftUI menu items carry no identifiers: menus are checked by item title (file card, skills); library cells are one
  element whose label carries the badges ("image.png, Evil", "0:03", "Has sound").
- Stale ids / flows: `createFiles`/`runCode`, `onb.cta.*`, status item menu, onboarding steps need Return, incognito
  chat with messages is left through the sidebar (AT-022 AC3 now **passes**), Library newest-first makes two different
  pictures, ineligible video request scripts the model's `create_video`, TextSizeClip ignores copy that ends in "…" by
  design (the round-1 `sugg.image` "truncation" was the copy's own ellipsis), MCP directory counts cards while
  scrolling the lazy grid, disclosure triangles, the completion-event leg checks the finished card (M8 replaced the log).
- Runner: `relay-dev` (:3000/:3001) and `node tools/mcp-ref/mcp.ts --port 39700` started for the M7 batch and stopped after.

### Open (round 2)
- **M3 voice (23):** unchanged; not triaged this round (voice overlay ids, scripted voice, preview playback).
- **M4 image (16):** ImageEdit "main thread busy 30 s", viewer, job card preview cadence, FileCard Quick Look, JobQueue.
- **Composio:** `begin()` neither opens a link nor reports an error within the test window (relay-dev reachable).
- **MCPOAuthUITests:** the ASWebAuthenticationSession leg does not reach the consent sheet.
- **Animate on an attachment:** the tile's Animate click never reaches `onAnimateAttachment` (diagnosed by log).
- **File card More menu** opens nothing in FileActions/FileCard (click lands, no menu).
- **Accessibility audit:** besides the fixed unnamed groups, the audit reports contrast failures (assistant text,
  suggestions line, Built-in badges), "Action is missing" on toolbar menu buttons, Parent/Child mismatch inside the
  window's zoom button (AppKit). Needs M9.T03 decisions (ignores need reason + reviewer).
- **UpdateAskUITests:** needs a catalog fixture server on :4399 serving `<name>/catalog.json` + an installed starter.
- Help / Legal (M10, new): 6 of 7 fail — not triaged.

### Failing tests (round 2, combined)
| Suite | Failing tests (first failure) |
|---|---|
| AccessibilityAuditTests | testEverySettingsSection (failed - S-21 settings.nav.about: Parent/Child mismatch [] type=3 frame=(145.0, 196.0, 14.0, 14.0) label='' — )<br>testEvilChat (failed - S-06: Parent/Child mismatch [] type=3 frame=(145.0, 196.0, 14.0, 14.0) label='' — This element is not)<br>testNewChatAndChat (failed - S-08: Parent/Child mismatch [] type=3 frame=(145.0, 196.0, 14.0, 14.0) label='' — This element is not)<br>testOnboarding (failed - S-04: Contrast failed [] type=48 frame=(1416.0, 862.0, 28.0, 16.0) label='' — Contrast failed for 2 /)<br>testPaletteAndShortcuts (failed - S-22: Parent/Child mismatch [] type=3 frame=(145.0, 196.0, 14.0, 14.0) label='' — This element is not) |
| AdvancedOverrideUITests | testOverridePickerFitPillsAndReset (XCTAssertTrue failed) |
| ArtifactsPanelTests | testCopyDownloadAndFix (XCTAssertTrue failed - Fix made version 2)<br>testEditSelection (Failed to activate application 'app.antichat.AntiChat.dev at /Users/armando/AntiChat/.claude/worktrees/agent-a)<br>testPreviewsRender (Application 'app.antichat.AntiChat.dev' has not loaded accessibility) |
| AudioFileTests | testAttachAndSummarise (Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "Expect predicate `va) |
| BasicVoiceTests | testSwitchesAtNextSession (XCTAssertFalse failed) |
| ChartCardTests | testChartCardActions (XCTAssertTrue failed) |
| ComposerTests | testMicShowsTheVoiceInstallCard (XCTAssertTrue failed) |
| ComposioUITests | testConnectGmailThreeSteps (failed - the app opened no sign-in link)<br>testRateLimitedShowsCopy (XCTAssertTrue failed) |
| ContextTests | testOversizePromptRefused (XCTAssertGreaterThan failed: ("0") is not greater than ("10000") - the text left the composer)<br>testUsageRisesThenSummarisedNoticeOnce (XCTAssertEqual failed: ("0") is not equal to ("1")) |
| DictationTests | testIncognitoKeepsNoRecording (XCTAssertTrue failed)<br>testRecentRecordingsList (Failed to get matching snapshots: Timed out while evaluating UI query.)<br>testRecordingBarAnatomy (XCTAssertGreaterThanOrEqual failed: ("1") is less than ("5"))<br>testSendNow (XCTAssertTrue failed) |
| DraftTests | testCrashRestoresDraft (XCTAssertTrue failed) |
| EvilEntryPointsTests | testComposerSwitchAfterNewChat (Application 'app.antichat.AntiChat.dev' does not have a process ID) |
| FileActionsTests | testAccessibilityAudit (failed - Element has no description: 3 id= label= frame=(80.0, 177.0, 1180.0, 860.0))<br>testOpenSaveReveal (XCTAssertTrue failed - Save As…) |
| FileCardTests | testOpenSaveRevealOnFixtures (XCTAssertTrue failed)<br>testQuickLookSpace (XCTAssertTrue failed - click opens Quick Look) |
| FileVersionTests | testChangeRequestShowsVersionTwoWithSwitcher (XCTAssertTrue failed) |
| FilesExcerptTests | testExcerptNoteListsPages (XCTAssertTrue failed)<br>testReadWholeFileShowsEstimateAndReadingPercent (XCTAssertTrue failed)<br>testSummariseWholeShowsRisingProgress (XCTAssertTrue failed) |
| FilesIntakeTests | testCorruptPDFShowsErrorTileAndToast (XCTAssertTrue failed) |
| FilesJourneyTests | testJourney4 (XCTAssertTrue failed - Thinking…) |
| FilesScanTests | testScanTileCountsPagesAndSendsEarly (XCTAssertTrue failed) |
| HelpUITests | testHelpOfflineShowsBundledGuide (XCTAssertEqual failed: ("") is not equal to ("You're offline, so this is the short built-in guide."))<br>testHelpOnlineOpensBrowser (XCTAssertEqual failed: ("Optional("/help/faq")") is not equal to ("Optional("/help/faq/")") - the help centre,)<br>testTourCardDismissForGood (XCTAssertFalse failed - dismissed)<br>testWhatsNewAfterUpdate (XCTAssertTrue failed) |
| ImageEditTests | testEditGeneratedImage (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s)<br>testVersionsKept (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s) |
| ImageEntryTests | testCreateImageChipForcesAndAspect (XCTAssertTrue failed)<br>testPhotoNotEnabledInstallCard (XCTAssertTrue failed - install.card with the catalog size) |
| ImageJobCardTests | testPreviewEveryTwoSteps (XCTAssertTrue failed)<br>testStopWithinOneSecond (Not hittable: Button, {{924.0, 722.5}, {24.0, 24.0}}, identifier: 'imageJobCard.cancel', label: 'Cancel') |
| ImageUnderstandingTests | testTextOnlyModelShowsNeedsLargerModelWithCapabilitiesLink (XCTAssertTrue failed) |
| ImageViewerTests | testVersionRailListsVersions (XCTAssertTrue failed)<br>testViewerZoomSaveCopyReveal (XCTAssertTrue failed) |
| J03EditVersionsTests | testActionBar (XCTAssertTrue failed)<br>testRegenerateVersions (Not hittable: MenuButton, {{649.0, 424.0}, {22.0, 16.0}}, identifier: 'action.more', label: 'More') |
| J07EvilChatTests | testEvilChatJourney (Failed to click "modeSwitch.locked" Any: No matches found for Elements matching predicate '"modeSwitch.locked") |
| J08IncognitoTests | testJourneyLeavesNoTraceAndAsksOnClose (XCTAssertTrue failed) |
| J10SettingsTests | testRowsSaveInstantlyAndPersist (Not hittable: PopUpButton, {{659.5, 377.0}, {247.5, 26.0}}, identifier: 'settings.control.sendWithCommandEnter) |
| J12ToolApprovalTests | testLoopLimitAndContinue (XCTAssertTrue failed - no loop-limit notice) |
| J13CrashRecoveryTests | testKillMidStream (XCTAssertEqual failed: ("3") is not equal to ("0") - pkill found no AntiChat process) |
| JITPermissionsUITests | testNotificationsOnFirstEvent (XCTAssertTrue failed) |
| JobQueueTests | testInterruptedRestartAfterForceQuit (XCTAssertTrue failed)<br>testOneAtATimeWithPositions (Unable to find hit point for ScrollView, {{474.0, 941.5}, {552.0, 22.0}}, identifier: 'composerScroll')<br>testWindowCloseKeepsJob (XCTAssertTrue failed - the job finished with no window) |
| Journey11VoiceTests | testDictationThenVoiceWithBargeIn (XCTAssertTrue failed) |
| KeyboardOnlyTests | testEveryKeyboardPath (Input key '' is an empty string (not really a key). (NSInvalidArgumentException))<br>testOnboardingKeyboardOnly (XCTAssertTrue failed)<br>testShortcutRebind (Failed to get matching snapshot: No matches found for first query match sequence: `Descendants matching type A) |
| LegalUITests | testAboutLegalListsEightVersionedPagesOffline (XCTAssertTrue failed - terms: no 'Version x.y.z · yyyy-mm-dd' in [""])<br>testHelpMenuLegalAndViewOnline (XCTAssertTrue failed - terms: no 'Version x.y.z · yyyy-mm-dd' in [""]) |
| LibraryTests | testEvilBadgeAndToggle (XCTAssertTrue failed)<br>testSoundIcon (XCTAssertTrue failed - sound icon: video.mp4, 0:03) |
| MCPOAuthUITests | testSignInFlow (XCTAssertTrue failed) |
| MediaAltTests | testGeneratedImageHasDescription (Failed to get matching snapshot: No matches found for first query match sequence: `Descendants matching type A) |
| MenuBarUITests | testMenuItemsInOrderAndActions (XCTAssertTrue failed) |
| MenusWindowsTests | testMenusAndWindows (XCTAssertEqual failed: ("1") is not equal to ("2")) |
| MigrationUITests | testNewerDataWindow (Failed to get matching snapshot: No matches found for first query match sequence: `Descendants matching type S) |
| ModelInfoTests | testTenTurnsCarryProvenanceAndModelInfoShowsThem (Failed to get matching snapshots: Unable to perform work on main run loop, process main thread busy for 30.0s) |
| NotificationsUITests | testDeniedBanner (XCTAssertEqual failed: ("nil") is not equal to ("Optional("x-apple.systempreferences:com.apple.Notifications-S)<br>testNoNotificationWhenFocused (XCTAssertTrue failed) |
| PermissionJITTests | testMicDenied (XCTAssertTrue failed)<br>testMicPromptFlow (Asynchronous wait failed: Exceeded timeout of 5 seconds, with unfulfilled expectations: "Expect predicate `val) |
| PresentationTests | testPanelPreview (XCTAssertTrue failed) |
| PrivacyUITests | testLocationNotRequestedUntilEnabled (XCTAssertTrue failed)<br>testNetworkActivityAfterSearch (XCTAssertTrue failed) |
| QueueTests | testFollowUpQueued (Unable to find hit point for ScrollView, {{474.0, 941.5}, {552.0, 22.0}}, identifier: 'composerScroll')<br>testTypeBeforeReady (Failed to get matching snapshot: No matches found for Elements matching predicate '"queuedBubble.remove" IN id) |
| QuickPanelUITests | testEscapeBehaviour (XCTAssertTrue failed)<br>testOpensAboveOtherAppsStreamsAndOpensInApp (XCTAssertTrue failed)<br>testRecorderChangesAndOff (Failed to click Button (First Match): No matches found for first query match sequence: `Descendants matching t) |
| ReadAloudTests | testSecondClickStops (XCTAssertLessThan failed: ("1.651432991027832") is not less than ("1.0")) |
| RendererStreamingTests | testMixedReplyRendersWhileStreamingAndWhenDone (failed - assistant text did not reach 13000 characters) |
| SafetyMissingTests | testMissingDetectorsShowRepairAndRunNoJob (XCTAssertTrue failed) |
| SecurityUITests | testInjectedPageAsksWithUntrustedLine (XCTAssertTrue failed) |
| SheetQueryTests | testQueryStepCollapsedAndExpanded (XCTAssertTrue failed) |
| SidePanelTests | testOpenSwitchVersionEditSelectionClose (Failed to get matching snapshot: No matches found for Descendants matching type MenuItem from input {() |
| SidebarStatusTests | testSpinnerAndUnreadDot (XCTAssertTrue failed)<br>testTemporaryThenAutoTitle (XCTAssertTrue failed - Harbour town weekend plan) |
| SkillsUITests | testCreateByChatInstallCard (XCTAssertTrue failed)<br>testPerChatToggleAndApplyAll (Not hittable: MenuButton, {{888.0, 368.5}, {23.0, 17.0}}, identifier: 'skills.menu.meeting-notes', label: 'Mor)<br>testStarterSkillsPresentEditable (Not hittable: MenuButton, {{888.0, 368.5}, {23.0, 17.0}}, identifier: 'skills.menu.meeting-notes', label: 'Mor) |
| SpikeRestartTests | testUIStaysAliveWhenEngineIsKilled (XCTAssertTrue failed) |
| ThinkHarderTests | testPresetTooltipWithoutReasoning (XCTAssertTrue failed)<br>testThinkingLineTimingAndCollapse (XCTAssertTrue failed) |
| ToolApprovalUITests | testPerChatToggleAndActivityLine (Failed to click "addButton" Button: No matches found for Elements matching predicate '"addButton" IN identifie) |
| ToolChangeReviewUITests | testRugPullRevertsToAsk (XCTAssertTrue failed) |
| ToolsPageUITests | testOfflineChipsAndNoSchemas (Failed to click "addRow.web" Any: No matches found for first query match sequence: `Descendants matching type )<br>testPlusMenuPerChatDoesNotChangeGlobal (Failed to click "addRow.tools" Any: No matches found for first query match sequence: `Descendants matching typ)<br>testToolAccessWarnsOnT0toT2 (XCTAssertEqual failed: ("false") is not equal to ("true") - T1) |
| UpdateAskUITests | testAutoUpdateOffAsksInsteadOfDownloading (XCTAssertTrue failed)<br>testBigUpdateAsks (XCTAssertTrue failed) |
| VideoBackgroundUITests | testNavigateAwayKeepsJob (XCTAssertTrue failed)<br>testNotificationClickOpensResult (XCTAssertTrue failed)<br>testWindowCloseKeepsJob (XCTAssertTrue failed) |
| VideoEntryTests | testAnimateOnAttachment (XCTAssertTrue failed - plan card)<br>testAnimateOnImageCard (XCTAssertTrue failed - plan card)<br>testCompletionEventPosted (XCTAssertTrue failed - the finished job offers Open)<br>testPlainLanguageVideo (XCTAssertTrue failed) |
| VideoJobCardTests | testCancelFreesMemory (Not hittable: Button, {{924.0, 662.5}, {24.0, 24.0}}, identifier: 'videoJob.cancel', label: 'Cancel')<br>testNavigateAwayAndBack (Not hittable: OutlineRow, {{88.0, 229.0}, {260.0, 32.0}})<br>testRealPercentAndStage (XCTAssertLessThan failed: ("3.2834030389785767") is not less than ("3.0") - never > 3 s without a UI change)<br>testSurvivesWindowClose (Not hittable: OutlineRow, {{88.0, 229.0}, {260.0, 0.0}})<br>testThermalCriticalPausesAndResumes (Not hittable: Link, {{444.0, 702.5}, {197.5, 15.0}}, identifier: 'videoJob.resume', label: 'Paused — your Mac ) |
| VideoPlanTests | testAdvancedOnlyInSettings (XCTAssertTrue failed - settings.row.videoAdvancedSteps)<br>testChangeEditsPresets (Not hittable: Button, {{529.0, 449.0}, {71.5, 20.0}}, identifier: 'videoPlan.shape.portrait', label: 'Portrait) |
| VideoPlayerTests | testInlineControls (XCTAssertTrue failed - AVPlayerView mounted)<br>testViewerSaveAs (Not hittable: Button, {{924.0, 424.0}, {24.0, 24.0}}, identifier: 'videoPlayer.expand', label: 'Open in viewer) |
| VoiceConversationTests | testBargeInAnswersNewUtterance (XCTAssertTrue failed - a second reply exists)<br>testEmptySessionWritesNothing (XCTAssertFalse failed - no chat row was created)<br>testHalfDuplexHint (XCTAssertTrue failed)<br>testHandsFreeDefaultAndPTT (XCTAssertEqual failed: ("Optional("")") is not equal to ("Optional("Hands-free")"))<br>testKeepsRunningInBackground (XCTAssertTrue failed)<br>testOverlayAnatomyAndTyping (XCTAssertTrue failed - voice.muteMic)<br>testTranscriptAsTurnsAndCaptions (XCTAssertTrue failed) |
| VoiceOverLabelTests | testInventory (XCTAssertEqual failed: ("["9 id=_XCUI:CloseWindow label=\'\'", "9 id=_XCUI:FullScreenWindow label=\'\'", "9 id) |
| VoiceSettingsTests | testAllRows (Not hittable: PopUpButton, {{766.5, 246.0}, {140.5, 26.0}}, identifier: 'settings.control.voiceInputDevice', l)<br>testPreviewPlays3s (Not hittable: Button, {{808.0, 378.0}, {98.0, 24.0}}, identifier: 'settings.voice.preview', label: 'Voice') |
| VoiceToolsTests | testConnectionDuringVoice (XCTAssertTrue failed)<br>testFileDuringVoiceSpokenPointer (XCTAssertTrue failed)<br>testImageDuringVoiceSpokenPointer (XCTAssertTrue failed)<br>testSearchDuringVoice (XCTAssertTrue failed)<br>testVideoDuringVoiceSpokenPointer (XCTAssertTrue failed) |
| WebSearchUITests | testChipForcesSearchAndPills (Not hittable: Button, {{424.0, 465.0}, {119.5, 16.0}}, identifier: 'citation.1', label: 'Source 1: macOS relea)<br>testConsentSheetWhenEnabledLater (Not hittable: CheckBox, {{870.0, 248.5}, {36.0, 16.0}}, identifier: 'settings.control.webSearch', label: 'Web )<br>testEveryPillMapsToFetchedSource (XCTAssertTrue failed - pill 2)<br>testOfflineChipAndNotice (XCTAssertTrue failed)<br>testOnboardingSwitchDefaultOn (XCTAssertTrue failed) |
| WindowLayoutTests | testDisclaimerSeparatorAndJumpToBottom (Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event dispatch snapshot: Te)<br>testEmptyStateHeadlineAndDocking (XCTAssertLessThanOrEqual failed: ("84.5") is greater than ("59.85"))<br>testSidebarWidthAndCollapse (XCTAssertTrue failed) |

---

# Round 1

Branch `fix/xcuitest-catchup` (main `ae7416ae3` merged). The first time the project's XCUITests ran on this Mac:
the owner ran `sudo automationmodetool enable-automationmode-without-authentication`, so XCUITest enables Automation
Mode itself. Xcode 27.2, macOS 26.6.2, a MacBook Pro shared with 4–5 agent tracks (load average 13–30 during runs).

## Totals (final pass, 332 tests in 99 suites)

| Milestone | Pass | Fail | Blocked (owner / GPU) | Skipped |
|---|---|---|---|---|
| M1 | 47 | 41 | 0 | 2 |
| M2 | 8 | 7 | 0 | 1 |
| M3 | 10 | 23 | 1 | 0 |
| M4 | 14 | 16 | 0 | 4 |
| M5 | 4 | 38 | 0 | 1 |
| M6 | 6 | 15 | 0 | 0 |
| M7 | 11 | 25 | 0 | 0 |
| M8 | 24 | 11 | 0 | 0 |
| M9 | 5 | 15 | 3 | 0 |
| **Total** | **129** | **191** | **4** | **8** |

Before this branch **0** tests could pass: the test bundle did not load (see harness fix 1). The first full pass
after the harness fixes passed 22 of M1's 90. Result bundles of the final pass:
`build/xcuitest/2026-11-10/{g-M1,g-M2,g-M3,g-M4,f-M5,f-M6,h-M7,h-M8,h-M9}.xcresult` (+ `.log`; M5/M6 ran on the
build just before the main merge, the rest on the merged build). Per AT: `build/at/<AT>/xcuitest-2026-11-10.json`
(117 ATs); the 21 `pending.txt` files that said "XCUITest … (Q-015)" now carry the real result line.

**Not green.** 191 failures remain. Most were triaged to a cause but not all fixed (the full 332-test pass takes
4–5 h on this shared Mac at ~1 min a test, and the UI slot was shared with the AT-248 run). The table at the end lists
each failing test with its first failure; the causes below cover most of them.

## How it ran
- `tools/ci/uitests-build.sh` (build-for-testing in `build/dd`). Each pass ran from an APFS clone of the products
  (`build/xcuitest/snapN/`, `xcodebuild test-without-building -xctestrun …`, one `-only-testing:` per class, batch per
  milestone), so fixes could be rebuilt while a pass ran. Screen recordings switched to screenshots in the cloned
  `.xctestrun`; every failing test attaches the app's UI tree and prints it to the log (`UITREE-BEGIN …`).
- Before each batch: a warm-up launch (the first launch of a freshly cloned app can exceed XCUITest's launch wait), the
  `-DefaultsSuite` test suites in `~/Library/Preferences` and the dev app's `AppleLanguages` are cleared.
- The host issue (SwiftUI windows never ordered in for background/.prohibited launches) does **not** affect XCUITest:
  launched as a foreground app the main window appears normally.

## Harness fixes (test bugs)
1. Runner and bundle are ad-hoc signed with the hardened runtime → `dlopen` refused the bundle ("different Team IDs").
   `ENABLE_HARDENED_RUNTIME: NO` on the `AntiChatUITests` target only.
2. Suites built their own `XCUIApplication()`; a dev-container launch turned BackgroundRun on. All suites go through
   `XCUIApplication.foreground()` (`AntiChatUIApp`, `ANTICHAT_BACKGROUND=0`).
3. `windows["AntiChat"]` never matches (the window is `main-AppWindow-1`, titled after the chat) → `app.mainWindow`.
4. Script arguments the app reads as paths (`-UseScriptedEngine basic|YES`, repo-relative `fixtures/…`, bare names)
   fell back to the XPC engine — **a real model on the GPU** — or to nothing. `AntiChatUIApp` resolves them, fails the
   test on a missing script, gives scripted tool calls a tool-capable chat model (D-023) and writes the `create_video`
   turn the video suites assumed. Three file-out scripts never existed: `tools/fixtures/scripts/fileout-{chart,deck,version}.jsonl`.
5. Hygiene on a Mac in use: the owner's clipboard is restored after a test changed it; each test's app is killed at
   test end (a quit that asks "Cancel or wait" left apps running and broke every later test); **DraftTests,
   SpikeRestartTests and MediaJobUITests killed every AntiChat / AntiChatEngine process on the machine** (other tracks'
   test hosts) — now only their own; no test activates TextEdit/Finder any more (hide AntiChat instead);
   LocalisationTests puts the dev app's language back (it had left the dev app in German).
6. Stale expectations: texts exposed as AX value (`displayText`), checkbox values are NSNumber (`stringValue`),
   segmented pickers are radio groups, toolbar menus are menu buttons, renamed ids (`composer.mic`, `settings.nav.*`,
   `composerText`, `activityLine`), M9.T01 copy ("Stop generating"), read aloud always offered (M3.T04), onboarding
   only with `-ResetOnboarding`, rows below the fold of Settings forms need scrolling, the 10k palette fixture copied
   into a throwaway container, `-ForceOnboarding` → `-ResetOnboarding`, uninstall confirm logic.

## Product bugs found and fixed

| # | Bug | Impact | Fix / test |
|---|---|---|---|
| P1 | After the first send of a new chat the composer loses keyboard focus (docking rebuilds the field). | The next message typed went nowhere (AT-001). | field takes the focus over from nothing / the old composer field only — `ComposerInteractionTests.dockedFieldKeepsTheFocus` |
| P2 | Tool activity keyed by the engine's call id; engines restart ids per step, so a repeated call ("call_1" again) **replaced the first call's line and its image card**. | The picture card vanished whenever the model repeated `create_image` (AT-030/031). | unique keys per turn (`call_1#2`) — `DuplicateCallGuardTests.repeatWithAReusedCallIDKeepsBothLines`, `uniqueActivityKey` |
| P3 | Container accessibility identifiers stamped over every child's own id (sidebar footer, Settings root/search, personalization fields, + menu rows, paste viewer, conversation, palette, side panel, Connections/Composio, MCP directory, skill review, Scroll-to-bottom, and 80 identified stacks). | UI tests and VoiceOver tooling could not reach Settings search, the + menu rows, Edit selection, Composio Connect, skill Install, … | `.accessibilityElement(children: .contain)` on identified containers; `transcript`/`sidebar` ids on the scroll view / list |
| P4 | `activityLine`, `notificationExplainer`, `citation.N` ids overwritten by a second `probeID`. | invisible to UI tests | `probeAnchor(_:)` (probe anchor without replacing the id) |
| P5 | Inline message editor and the image "Describe the change" field set focus in `onAppear`, which macOS drops. | Edit → type went nowhere until a click (AT-006, AT-033). | focus on the next turn; UserBubble.editing snapshots re-recorded (now focused) |
| P6 | Adding an MCP server swallowed the add error (`try?`). | Allow did nothing and said nothing. | error logged and shown |
| P7 | File › New Evil Chat (and ⇧⌘E) disabled after launch until the composer had focus (`.disabled(state == nil)` on a focused value Commands never re-read). | dead menu item at launch | resolved at click time (`MenuTarget.frontmost`) |
| P8 | Main-menu items exposed `menuAction:` instead of their ids. | id-based lookups never matched | `MenuItemIdentifiers` (id = the item's `menu.*` copy key) — `MenuItemIdentifiersTests` |
| P9 | Pack state (composer menus, video plan card) read the catalog once at window creation; a catalog that arrived later was never seen, so `create_video` waited for a plan card that could not be built. | video entry silently stalled on a fresh install | refresh on `CatalogStore.didChange` + while the call waits (built after M5's final pass: **not yet re-verified in XCUITest**) |

## Open product findings (not fixed here)
- **Text size / RTL clipping:** `TextSizeClipTests` (7) — the `suggestion.sugg.image` card truncates at every size,
  RTL and double-length pseudo-locale (S-05). AT-223 / NFR-A4.
- **Accessibility audit:** `AccessibilityAuditTests` (5) — "Element has no description" on S-01/05/06/18 (an unnamed
  full-window group) and "Parent/Child mismatch" on Settings (S-21); `VoiceOverLabelTests.testInventory`,
  `MediaAltTests`. M9.T03.
- **Video:** the M5 suites failed on the missing plan card (P9); re-run after P9.
- **Incognito → Library (AT-022 AC3):** unverified — the test could not leave the incognito chat; re-run.
- **MCP token auth:** Allow on a token server added nothing (P6 now surfaces the reason; re-run to read it).

## Blocked (need a human or the GPU)
- `KeyboardOnlyTests` (3): Full Keyboard Access — OWNER-STEPS 1.4: `defaults write -g AppleKeyboardUIMode -int 2`
  (undo `defaults delete -g AppleKeyboardUIMode`).
- `AudioFileTests`: the real Voice pack (WhisperKit) in the container; agent step via `gpu-run.sh shared --`.
- Skipped by design: `BlockedMediaTests` (2) need a `-DANTICHAT_UI_TESTING` app build (no such configuration;
  at-285-runner covers the gate); `InstallCardUITests.testInstallThenOriginalRequestReruns` install leg downloads the
  real 6.3 GB Photo pack (`TEST_RUNNER_ANTICHAT_UITEST_REAL_INSTALL=1`); suites that `XCTSkip` on absent fixtures.
- Computer-use / real permission dialogs: none of the remaining failures need them (the JIT permission suites use
  `-FakePermission`).

## Next pass
1. Rebuild, re-run the failing tests only (list below, ~3 h), starting with M5 (P9) and the suites added by
   `fix/evil-toggle-progress` (EvilEntryPointsTests, ImageProgressTextTests).
2. Fix the open product findings above (M9.T03 owns the audit/clipping items).

## Failing tests (round 1 final pass)
| Suite | Failing tests (first failure) |
|---|---|
| AccessibilityAuditTests | testEverySettingsSection (failed - S-21 settings.nav.general: Parent/Child mismatch [])<br>testEvilChat (failed - S-06: Element has no description [])<br>testNewChatAndChat (failed - S-05: Element has no description [])<br>testOnboarding (failed - S-01: Element has no description [])<br>testPaletteAndShortcuts (failed - S-18: Element has no description []) |
| AdvancedOverrideUITests | testOverridePickerFitPillsAndReset (XCTAssertTrue failed) |
| ArtifactsPanelTests | testCopyDownloadAndFix (XCTAssertTrue failed - Fix made version 2)<br>testEditSelection (XCTAssertTrue failed)<br>testPreviewsRender (XCTAssertTrue failed) |
| AudioFileTests | testAttachAndSummarise (Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: ") |
| BasicVoiceTests | testSwitchesAtNextSession (XCTAssertFalse failed) |
| ChartCardTests | testChartCardActions (XCTAssertTrue failed) |
| ComposerMenusTests | testLeg1_PhotoInstalledButOff_EnableInSettings (XCTAssertTrue failed - clicking it opens Settings) |
| ComposerTests | testLeg2_GrowsToExactlyTwelveLinesThenScrollsAndControlsMoveDown (XCTAssertTrue failed - harnessLineCount stayed , expected 2)<br>testLeg3_SendDisabledWhenEmptyStopWhileGeneratingBackOnDone (XCTAssertEqual failed: ("") is not equal to ("1"))<br>testLeg4_CommandEnterSetting (XCTAssertEqual failed: ("") is not equal to ("0") - Return inserts a newline)<br>testLeg4_ReturnSendsShiftReturnInsertsNewlineByDefault (XCTAssertEqual failed: ("") is not equal to ("0"))<br>testLeg5_PlainTextComposerIsUnstyled (XCTAssertEqual failed: ("") is not equal to ("0"))<br>testLeg5_RichTextByDefaultBoldRunRendersBold (XCTAssertTrue failed - harnessBoldRuns stayed , expected 1)<br>testLeg6_CardIsSentAsAnAttachment (XCTAssertEqual failed: ("") is not equal to ("1"))<br>testMicShowsTheVoiceInstallCard (XCTAssertTrue failed) |
| ComposioUITests | testConnectGmailThreeSteps (XCTAssertTrue failed)<br>testRateLimitedShowsCopy (XCTAssertTrue failed) |
| ConnectionsUITests | testAddRemoteWithTokenListsTools (XCTAssertTrue failed)<br>testCuratedListAtLeastTen (XCTAssertGreaterThanOrEqual failed: ("3") is less than ("10")) |
| ContextTests | testOversizePromptRefused (XCTAssertGreaterThan failed: ("0") is not greater than ("10000") - the text left the compo)<br>testUsageRisesThenSummarisedNoticeOnce (XCTAssertEqual failed: ("0") is not equal to ("1")) |
| DictationTests | testIncognitoKeepsNoRecording (XCTAssertTrue failed)<br>testRecentRecordingsList (Failed to get matching snapshots: Timed out while evaluating UI query.)<br>testRecordingBarAnatomy (XCTAssertGreaterThanOrEqual failed: ("1") is less than ("5"))<br>testSendNow (XCTAssertTrue failed) |
| DraftTests | testCrashRestoresDraft (XCTAssertTrue failed) |
| FileActionsTests | testAccessibilityAudit (failed - Element has no description: 3 id= label= frame=(80.0, 177.0, 1180.0, 860.0))<br>testOpenSaveReveal (Not hittable: MenuButton, {{703.0, 702.5}, {22.0, 16.0}}, identifier: 'fileCardMore', labe) |
| FileCardTests | testOpenSaveRevealOnFixtures (XCTAssertTrue failed)<br>testQuickLookSpace (XCTAssertTrue failed - click opens Quick Look) |
| FileToolsSettingsTests | testFileToolsRowsAndInstantSave (XCTAssertTrue failed - createFiles) |
| FileVersionTests | testChangeRequestShowsVersionTwoWithSwitcher (Unable to find hit point for ScrollView, {{366.5, 925.5}, {0.0, 22.0}}, identifier: 'compo) |
| FilesExcerptTests | testExcerptNoteListsPages (XCTAssertTrue failed)<br>testReadWholeFileShowsEstimateAndReadingPercent (XCTAssertTrue failed)<br>testSummariseWholeShowsRisingProgress (XCTAssertTrue failed) |
| FilesIntakeTests | testCorruptPDFShowsErrorTileAndToast (XCTAssertTrue failed) |
| FilesJourneyTests | testJourney4 (XCTAssertTrue failed - Thinking…) |
| FilesScanTests | testScanTileCountsPagesAndSendsEarly (XCTAssertTrue failed) |
| FreshnessHintUITests | testHintButtonsOpenConsent (XCTAssertTrue failed)<br>testNotNowHidesForChat (XCTAssertTrue failed) |
| ImageEditTests | testEditGeneratedImage (Failed to get matching snapshots: Unable to perform work on main run loop, process main th)<br>testVersionsKept (Failed to get matching snapshots: Unable to perform work on main run loop, process main th) |
| ImageEntryTests | testCreateImageChipForcesAndAspect (XCTAssertTrue failed)<br>testPhotoNotEnabledInstallCard (XCTAssertTrue failed - install.card with the catalog size) |
| ImageJobCardTests | testPreviewEveryTwoSteps (XCTAssertTrue failed)<br>testStopWithinOneSecond (Not hittable: Button, {{924.0, 722.5}, {24.0, 24.0}}, identifier: 'imageJobCard.cancel', l) |
| ImageUnderstandingTests | testTextOnlyModelShowsNeedsLargerModelWithCapabilitiesLink (XCTAssertTrue failed) |
| ImageViewerTests | testVersionRailListsVersions (XCTAssertTrue failed)<br>testViewerZoomSaveCopyReveal (XCTAssertTrue failed) |
| J03EditVersionsTests | testActionBar (XCTAssertTrue failed)<br>testEditCreatesVersion (XCTAssertEqual failed: ("") is not equal to ("2 / 2"))<br>testEditWithImageAttachment (XCTAssertTrue failed - attachment not removable in the editor)<br>testRegenerateVersions (XCTAssertEqual failed: ("") is not equal to ("3 / 3")) |
| J07EvilChatTests | testEvilChatJourney (XCTAssertTrue failed - evil.frame missing)<br>testTouchIDCancelLeavesTheChat (XCTAssertTrue failed) |
| J08IncognitoTests | testJourneyLeavesNoTraceAndAsksOnClose (XCTAssertTrue failed) |
| J09PaletteTests | testActionsAndSettingsRows (XCTAssertTrue failed)<br>testSearchTitlesAndBodies (XCTAssertEqual failed: ("8") is not equal to ("1"))<br>testSettingsRowOpensSettingsAtThatRow (XCTAssertTrue failed)<br>testTabAsksInANewChat (XCTAssertFalse failed) |
| J10SettingsTests | testRowsSaveInstantlyAndPersist (XCTAssertEqual failed: ("Optional("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) |
| J12ToolApprovalTests | testAllowOnce (Not hittable: Button, {{465.0, 503.0}, {90.0, 24.0}}, identifier: 'approveAllowOnce', labe)<br>testAlwaysAllow (Not hittable: Button, {{563.0, 503.0}, {101.0, 24.0}}, identifier: 'approveAlways', label:)<br>testDeny (Not hittable: Button, {{672.0, 503.0}, {55.0, 24.0}}, identifier: 'approveDeny', label: 'D)<br>testLoopLimitAndContinue (XCTAssertTrue failed - no loop-limit notice) |
| J13CrashRecoveryTests | testKillMidStream (XCTAssertEqual failed: ("3") is not equal to ("0") - pkill found no AntiChat process) |
| JITPermissionsUITests | testNotificationsOnFirstEvent (XCTAssertTrue failed)<br>testOnboardingRequestsNothing (Failed to click "onboarding.continue" Button: No matches found for first query match seque) |
| JobQueueTests | testInterruptedRestartAfterForceQuit (XCTAssertTrue failed)<br>testOneAtATimeWithPositions (Unable to find hit point for ScrollView, {{474.0, 941.5}, {552.0, 22.0}}, identifier: 'com)<br>testWindowCloseKeepsJob (XCTAssertTrue failed - the job finished with no window) |
| Journey11VoiceTests | testDictationThenVoiceWithBargeIn (XCTAssertTrue failed) |
| KeyboardOnlyTests | testEveryKeyboardPath (XCTAssertTrue failed - app.newIncognito)<br>testOnboardingKeyboardOnly (XCTAssertTrue failed)<br>testShortcutRebind (XCTAssertTrue failed) |
| LibraryTests | testEvilBadgeAndToggle (XCTAssertTrue failed - default on: Evil is enabled)<br>testGridListNewestFirst (XCTAssertTrue failed)<br>testIncognitoNeverAdded (XCTAssertTrue failed)<br>testSoundIcon (XCTAssertTrue failed)<br>testVideosTab (XCTAssertTrue failed) |
| MCPOAuthUITests | testSignInFlow (XCTAssertTrue failed) |
| MediaAltTests | testGeneratedImageHasDescription (XCTAssertTrue failed) |
| MenuBarUITests | testMenuItemsInOrderAndActions (Failed to click "New Chat" MenuItem: Find single matching element. Multiple matching eleme) |
| MenusWindowsTests | testMenusAndWindows (XCTAssertEqual failed: ("1") is not equal to ("2")) |
| MigrationUITests | testNewerDataWindow (Failed to get matching snapshot: No matches found for first query match sequence: `Descend) |
| ModelInfoTests | testTenTurnsCarryProvenanceAndModelInfoShowsThem (Failed to click "regenerate.tryAgain" Button: No matches found for Elements matching predi) |
| NotificationsUITests | testDeniedBanner (XCTAssertEqual failed: ("nil") is not equal to ("Optional("x-apple.systempreferences:com.a)<br>testNoNotificationWhenFocused (XCTAssertTrue failed) |
| PermissionJITTests | testMicDenied (XCTAssertTrue failed)<br>testMicPromptFlow (Asynchronous wait failed: Exceeded timeout of 5 seconds, with unfulfilled expectations: "E) |
| PresentationTests | testPanelPreview (XCTAssertTrue failed) |
| PrivacyUITests | testLocationNotRequestedUntilEnabled (XCTAssertTrue failed)<br>testNetworkActivityAfterSearch (XCTAssertTrue failed) |
| QueueTests | testFollowUpQueued (Unable to find hit point for ScrollView, {{503.0, 930.5}, {552.0, 22.0}}, identifier: 'com)<br>testTypeBeforeReady (Failed to no matches found for Elements matching predicate '"queuedBubble.remove" IN ident) |
| QuickPanelUITests | testEscapeBehaviour (XCTAssertTrue failed)<br>testOpensAboveOtherAppsStreamsAndOpensInApp (XCTAssertTrue failed)<br>testRecorderChangesAndOff (Failed to click Button (First Match): No matches found for first query match sequence: `De) |
| ReadAloudTests | testSecondClickStops (XCTAssertLessThan failed: ("1.6998310089111328") is not less than ("1.0")) |
| RendererStreamingTests | testMixedReplyRendersWhileStreamingAndWhenDone (failed - assistant text did not reach 13000 characters) |
| SafetyMissingTests | testMissingDetectorsShowRepairAndRunNoJob (XCTAssertTrue failed) |
| SecurityUITests | testInjectedPageAsksWithUntrustedLine (XCTAssertTrue failed) |
| SheetQueryTests | testQueryStepCollapsedAndExpanded (XCTAssertTrue failed) |
| SidePanelTests | testOpenSwitchVersionEditSelectionClose (Failed to double click "panelPDF" Any: No matches found for Elements matching predicate '") |
| SidebarStatusTests | testSpinnerAndUnreadDot (XCTAssertTrue failed)<br>testTemporaryThenAutoTitle (XCTAssertTrue failed - Harbour town weekend plan) |
| SkillsUITests | testCreateByChatInstallCard (XCTAssertTrue failed)<br>testPerChatToggleAndApplyAll (XCTAssertEqual failed: ("nil") is not equal to ("Optional(0)") - Apply to every chat is of)<br>testStarterSkillsPresentEditable (XCTAssertTrue failed - Show in Finder (edit the SKILL.md)) |
| SpikeRestartTests | testUIStaysAliveWhenEngineIsKilled (XCTAssertTrue failed - engine.restarted copy not shown) |
| TextSizeClipTests | test12pt (XCTAssertEqual failed: ("["truncated: suggestion.sugg.image"]") is not equal to ("[]") - 1)<br>test14pt (XCTAssertEqual failed: ("["truncated: suggestion.sugg.image"]") is not equal to ("[]") - 1)<br>test18pt (XCTAssertEqual failed: ("["truncated: suggestion.sugg.image"]") is not equal to ("[]") - 1)<br>test24pt (XCTAssertEqual failed: ("["truncated: suggestion.sugg.image"]") is not equal to ("[]") - 2)<br>testForcedRTL (XCTAssertEqual failed: ("["truncated: suggestion.sugg.image"]") is not equal to ("[]") - r)<br>testPseudoDoubleLength (XCTAssertEqual failed: ("["truncated: suggestion.sugg.image"]") is not equal to ("[]") - d)<br>testScale200 (XCTAssertEqual failed: ("["truncated: suggestion.sugg.image"]") is not equal to ("[]") - s) |
| ThinkHarderTests | testPresetTooltipWithoutReasoning (XCTAssertTrue failed)<br>testThinkingLineTimingAndCollapse (XCTAssertTrue failed) |
| ToolApprovalUITests | testAllowOnceAlwaysDeny (XCTAssertTrue failed)<br>testNoTimeoutAutoApprove (XCTAssertTrue failed)<br>testPerChatToggleAndActivityLine (Failed to click "addButton" Button: No matches found for Elements matching predicate '"add) |
| ToolChangeReviewUITests | testRugPullRevertsToAsk (XCTAssertTrue failed - no tools-changed banner) |
| ToolsPageUITests | testConnectorToolPermissions (XCTAssertTrue failed)<br>testEveryToolListedWithSwitch (XCTAssertTrue failed - toolFiles)<br>testOfflineChipsAndNoSchemas (Failed to click "addRow.web" Any: No matches found for first query match sequence: `Descen)<br>testPlusMenuPerChatDoesNotChangeGlobal (Failed to click "addRow.tools" Any: No matches found for first query match sequence: `Desc)<br>testToolAccessWarnsOnT0toT2 (XCTAssertEqual failed: ("false") is not equal to ("true") - T1) |
| UpdateAskUITests | testAutoUpdateOffAsksInsteadOfDownloading (XCTAssertTrue failed)<br>testBigUpdateAsks (XCTAssertTrue failed) |
| VideoBackgroundUITests | testNavigateAwayKeepsJob (XCTAssertTrue failed)<br>testNotificationClickOpensResult (XCTAssertTrue failed)<br>testWindowCloseKeepsJob (XCTAssertTrue failed) |
| VideoEligibilityTests | testDimmedEverywhereT0T1 (Failed to get matching snapshot: No matches found for first query match sequence: `Descend)<br>testIneligibleRequestExplains (XCTAssertTrue failed) |
| VideoEntryTests | testAnimateOnAttachment (XCTAssertTrue failed - plan card)<br>testAnimateOnImageCard (XCTAssertTrue failed)<br>testCompletionEventPosted (Failed to click "videoPlan.start" Any: No matches found for first query match sequence: `D)<br>testCreateVideoChip (XCTAssertTrue failed - plan card)<br>testImageAttachmentStartsI2V (XCTAssertTrue failed - plan card)<br>testIneligibleExplains (XCTAssertFalse failed - dimmed with the reason (M5.T08))<br>testPlainLanguageVideo (XCTAssertTrue failed - plan card) |
| VideoJobCardTests | testAnimatedPreviewUpdates (XCTAssertTrue failed - plan card)<br>testCancelFreesMemory (XCTAssertTrue failed - plan card)<br>testNavigateAwayAndBack (XCTAssertTrue failed - plan card)<br>testPreviewFailureDoesNotFailJob (XCTAssertTrue failed - plan card)<br>testRealPercentAndStage (XCTAssertTrue failed - plan card)<br>testSurvivesWindowClose (XCTAssertTrue failed - plan card)<br>testThermalCriticalPausesAndResumes (XCTAssertTrue failed - plan card) |
| VideoPlanTests | testAdvancedOnlyInSettings (XCTAssertTrue failed - plan card)<br>testBatteryAskBelow20 (XCTAssertTrue failed - plan card)<br>testCancelRemovesCard (XCTAssertTrue failed - plan card)<br>testChangeEditsPresets (XCTAssertTrue failed - plan card)<br>testCountdownAutoStartsWhenAllowed (XCTAssertTrue failed - plan card)<br>testEstimateShownBeforeStart (XCTAssertTrue failed - plan card)<br>testLowPowerAsks (XCTAssertTrue failed - plan card)<br>testPlanCardContents (XCTAssertTrue failed - plan card)<br>testWaitsForStartOnInferredIntent (XCTAssertTrue failed - plan card)<br>testWaitsOnBattery (XCTAssertTrue failed - plan card)<br>testWaitsWhenChatWouldPause (XCTAssertTrue failed - plan card)<br>testWaitsWhenEstimateOver5Min (XCTAssertTrue failed - plan card) |
| VideoPlayerTests | testExportMP4 (XCTAssertTrue failed - plan card)<br>testInlineControls (XCTAssertTrue failed - plan card)<br>testViewerSaveAs (XCTAssertTrue failed - plan card) |
| VoiceConversationTests | testBargeInAnswersNewUtterance (XCTAssertTrue failed - a second reply exists)<br>testEmptySessionWritesNothing (XCTAssertFalse failed - no chat row was created)<br>testHalfDuplexHint (XCTAssertTrue failed)<br>testHandsFreeDefaultAndPTT (XCTAssertEqual failed: ("Optional("")") is not equal to ("Optional("Hands-free")"))<br>testKeepsRunningInBackground (XCTAssertTrue failed)<br>testOverlayAnatomyAndTyping (XCTAssertTrue failed - voice.muteMic)<br>testTranscriptAsTurnsAndCaptions (XCTAssertTrue failed) |
| VoiceOverLabelTests | testEvilTitleAnnounced (XCTAssertTrue failed)<br>testInventory (XCTAssertEqual failed: ("["9 id=_XCUI:CloseWindow label=\'\'", "9 id=_XCUI:FullScreenWindo) |
| VoiceSettingsTests | testAllRows (XCTAssertEqual failed: ("Speed") is not equal to ("1.5×"))<br>testPreviewPlays3s (Asynchronous wait failed: Exceeded timeout of 10 seconds, with unfulfilled expectations: ") |
| VoiceToolsTests | testConnectionDuringVoice (XCTAssertTrue failed)<br>testFileDuringVoiceSpokenPointer (XCTAssertTrue failed)<br>testImageDuringVoiceSpokenPointer (XCTAssertTrue failed)<br>testSearchDuringVoice (XCTAssertTrue failed)<br>testVideoDuringVoiceSpokenPointer (XCTAssertTrue failed) |
| WebSearchUITests | testChipForcesSearchAndPills (Not hittable: Button, {{424.0, 465.0}, {119.5, 16.0}}, identifier: 'citation.1', label: 'S)<br>testConsentSheetWhenEnabledLater (XCTAssertTrue failed)<br>testEveryPillMapsToFetchedSource (XCTAssertTrue failed - pill 2)<br>testOfflineChipAndNotice (XCTAssertTrue failed)<br>testOnboardingSwitchDefaultOn (XCTAssertTrue failed) |
| WindowLayoutTests | testDisclaimerSeparatorAndJumpToBottom (Failed to synthesize event: Neither element nor any descendant has keyboard focus. Event d)<br>testEmptyStateHeadlineAndDocking (XCTAssertLessThanOrEqual failed: ("74.5") is greater than ("57.85"))<br>testSidebarWidthAndCollapse (XCTAssertEqualWithAccuracy failed: ("262.0") is not equal to ("260.0") +/- ("1.0"))<br>testSuggestionsFillComposer (XCTAssertTrue failed - Talk to me) |

## Gates (on this branch, sequential, after the final pass)
- `make test-unit`: pass (main 495 tests / 116 suites, + 296 / 24 + childsafety 87).
- `make test-integration-stub`: pass (90 executed, 30 skipped, 0 failures).
- `BINARIES_SRC=$HOME/AntiChat/Binaries make audit`: EXIT=0 (incl. `uitests-build`).
