<!-- Draft of ~/Desktop/AntiChat-tryout/TRY-ME.md for the final try-out build (M9.T10 / M10.T11).
     Before copying it to the Desktop: fill ⟦BUILD⟧ / ⟦SHA⟧ / ⟦DATE⟧, the T05/T06 lines marked ⟦…⟧, and check the
     "Known gaps" list against the M9 report. The build should include fix/xcuitest-r7, fix/hello-timeout and the U5
     renderer parts 3–4 (on m9/t05-run and fix/u5-renderer-4 on 2026-11-12, not yet on main). -->

# AntiChat try-out preview (⟦DATE⟧)

Build ⟦BUILD⟧ (main ⟦SHA⟧). This is the release-candidate preview with all four packs on. It isn't a release yet:
it's ad-hoc signed and not notarized, and it still uses the test signing keys.

**To open it:** double-click AntiChat.app. If macOS blocks it, right-click it, choose Open, then click Open again.

## New since build 1079

- **Every screen was checked against the design bar.** All the main screens now pass; ten screens that were below it
  were fixed. Some examples:
  - The empty composer shows one pale Send button instead of a second, disabled waveform.
  - In Evil mode the selected "Evil" switch is red, like the frame and the badge.
  - The Library, Projects and Chats pages are named in the toolbar.
  - Error lines use plain names ("Web search didn't work. Retry") instead of tool ids.
  - A damaged model offers **Re-download** instead of Retry.
  - The quick panel shows formatted replies instead of raw Markdown.
- **Accessibility:**
  - VoiceOver reads replies when they finish, or sentence by sentence (Settings › General).
  - Every icon-only button has a name, and the automated accessibility audit now reports 0 issues.
  - Generated pictures get a short description that VoiceOver reads; you can edit it in the viewer.
  - Better contrast for small text, and Reduce Motion / Reduce Transparency / Increase Contrast are followed.
- **Languages:** the app is in English, German, French, Spanish, Dutch and Portuguese. Pick one in Settings › General ›
  App language, then click Restart now.
- **Search on large Macs is faster.** The first word of an answer after a web search now arrives in about 4 s (it was
  about 11.5 s). Multi-part questions ("weather in Lyon and Marseille") now cite both parts.
- **Voice:**
  - A sentence you leave unfinished no longer waits 2 s to be answered: it ends at 1.5 s.
  - The spoken caption shows the whole sentence being spoken, not half of it.
  - Arabic dictation misses fewer words.
- **Fixes found by the UI tests (about 80 in all).** Some you might notice:
  - Signing in to an MCP server no longer crashes the app.
  - Typing after ⌘K goes into the palette, not into the composer.
  - "Describe the change" on a picture takes the keyboard.
  - A long chat no longer hangs when you select text in it.
  - A picture job that was interrupted shows **Interrupted · Restart**.
  - The quick panel hotkey works while AntiChat is hidden.
  - Composio's "Connections are busy" message is shown instead of an HTTP error.
- **Fixed from the last list:**
  - Long Evil-mode prompts are no longer cut off: a long prefill counts as progress, not a stall.
  - On 16 GB Macs a video job no longer runs its safety check alongside the clip, so it stays within memory.
- **Under the hood:** the app's libraries were updated (osaurus 0.25.33, FluidAudio 0.18.3 and others) with no change
  in voice quality or speed.

## Try first

1. Change the app language in Settings › General, restart, and look around. Change it back the same way.
2. Turn on VoiceOver (⌘F5), ask a question, and listen to the reply being read. Turn VoiceOver off with ⌘F5.
3. Ask something that needs the web ("What happened in the news today?"), then click a citation.
4. Have a short spoken conversation. Stop in the middle of a sentence once and wait: it should answer after about 1.5 s.
5. Press ⌘K, type "settings", press Return.
6. Ask for a picture, open it, and read the description under it.

## Known gaps in this build

- **Voice end of turn:** after you finish a sentence, the app waits about 0.9 s before answering. The target is under
  0.5 s; no turn-detection model we can run on the Mac gets there yet without cutting people off. It will be re-tested
  after release with a newer model.
- **Search on large Macs:** "what is / history of" questions (Wikipedia-style pages) take about 7 s to the first word,
  because the app reads a lot of text before answering. A faster way is planned after release.
- **Long replies on small Macs** can still stutter a little while they stream. ⟦update from the T05 U5 re-run⟧
- **Speed and memory test results** for this build are still coming in: ⟦T05 Phase A/B summary, one line⟧ ·
  ⟦8-hour soak: crash-free / memory, one line⟧.
- **Cloud connectors (Composio) are off**, because the relay isn't deployed. Hosting isn't live either, so the model
  list comes from the copy inside the app, and the File tools and Video runtimes download from a test address.
- **Keyboard-only use** works, but the automatic keyboard-only tests haven't run yet (they need Full Keyboard Access on).

## Owner steps

All of them are listed in order in `~/AntiChat/docs/prd/OWNER-STEPS.md`. The ones that help most right now:

```
kill 5587                                   # the leftover test copy of AntiChat (check with: ps -p 5587)
tools/dev/clean-test-plists.sh --delete     # old test preference files (run without --delete first to see them)
defaults write -g AppleKeyboardUIMode -int 2   # Full Keyboard Access, for the keyboard-only tests
```
