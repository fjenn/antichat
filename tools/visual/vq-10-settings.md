# vq-10 — Settings visual QA

Runbook sections are added by the tasks that build each page (M2.md shared conventions); M2.T26 consolidates and
executes them (AT-VQ-M2). Captures: `build/visual/<version>/vq-10/`, light + dark at 1440×900 (`tools/visual/capture.sh`).

## Privacy & Data (M2.T03, AT-209; S-21 formally scored in M8, findings triaged only here)
1. Launch the Debug build with a fresh container: `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq10 -DefaultsSuite vq10`.
2. ⌘, → Privacy & Data. Capture: the Offline only row (switch off, note `set.privacy.offlineOnly.note` under it)
   and the Network activity list in its empty state (`set.privacy.activity.empty`).
3. Run one scripted turn that uses the network (or let the catalog fetch run once), reopen the page: capture the
   list with rows (day header; time · category · host · bytes).
4. Turn Offline only on: capture the row on and the sidebar footer indicator showing "Offline only".

## Privacy & Data: Restore from backup (M8.T01, AT-301 AC2; S-21 Privacy & Data ≥ 4.5, scored in M8.T16)
1. `mkdir -p /tmp/vq10r && cp fixtures/chats/db/v13_artifact.sqlite /tmp/vq10r/antichat.sqlite`; launch with
   `-ANTICHAT_DEV_CONTAINER /tmp/vq10r` (the upgrade writes a "Before update" backup).
2. ⌘, → Privacy & Data → Restore from backup [Choose…] → capture `restore-sheet` (date, kind, size, chat count,
   [Restore] per row), then [Restore] → the confirm alert `backup.restore.confirm` → `restore-confirm`.

## Capabilities: catalog banner states (M2.T05, AT-220 part 2; S-21 Capabilities bar ≥ 4.5 in AT-VQ-M2)
1. Serve a fixture catalog: `mkdir -p /tmp/vq10cat/catalog/v2 && cp fixtures/catalog/catalog-expired.json /tmp/vq10cat/catalog/v2/catalog.json && cp fixtures/catalog/catalog-expired.json.sig /tmp/vq10cat/catalog/v2/catalog.json.sig && python3 -I -m http.server 4399 -d /tmp/vq10cat`.
2. Launch with a fresh container: `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq10c -CatalogURL http://127.0.0.1:4399/catalog/v2/catalog.json`.
3. ⌘, → Capabilities. Capture: the warn banner `catalog.expired` with [Check now] above the Chat row (light + dark).
4. Quit; replace the served pair with `catalog-bad-sig.json` + its `.sig` (renamed to catalog.json[.sig]), relaunch on a
   fresh container, capture the `catalog.badSignature` row with [Retry]. Serve `catalog-valid` and press [Retry]: the
   row disappears.

## Capabilities › Advanced (M2.T07, AT-222 part 2; S-21 Capabilities bar ≥ 4.5 in AT-VQ-M2)
1. Launch `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq10a -FakeHardware t1-m2-16`.
2. ⌘, → Capabilities. Capture the Advanced disclosure collapsed (light + dark), then expanded.
3. Expanded: one "Model for {pack} ({mode})" row per pack × mode with the current model, quant · context and a FitPill;
   unavailable slots read "Not available on this Mac". Open the Chat (Normal) picker: chat-4b shows **Fits**,
   chat-35b-q4 **Too large** and is disabled. Pick chat-4b; "Reset to recommended" appears; capture.
4. Turn on "Allow loads above the memory budget": chat-35b-q4 becomes selectable. Turn it off again.
5. Keep models loaded reads 15 min by default (5 / 15 / 30 min / Never unload). FitPill states: compare with
   `Packages/UI/Tests/AntiChatUIModuleTests/__Snapshots__/FitPillSnapshotTests/` (Fits / Tight / Too large, light + dark).

## Updates: "Update models automatically" + Capabilities update offer (M2.T11, AT-294)
1. Settings › Updates: the "Update models automatically" switch is on by default; the app-updates row stays "arrives …".
2. Serve `fixtures/catalog/catalog-upgrade-big.json` (+ `.sig`) as `catalog.json` on 127.0.0.1:4399 (as above) and launch
   with a container whose starter is installed (`antichat-cli models install --id chat-0.8b --slot chat/normal/chat_fast`)
   and `-CatalogURL http://127.0.0.1:4399/catalog/v2/catalog.json`.
3. Settings › Capabilities: capture the offer row "A better Chat model is available (…). Update now?" [Later] [Update]
   (light + dark). [Later] hides it until the next catalog version.
4. After an applied update the notice "Chat got an upgrade" shows above the Chat row (dismiss ×); capture.

## Personalization › Memory (M8.T03, AT-060 / AT-246; S-21 Personalization ≥ 4.0, S-08 no regression)
1. Seed: `python3 -I tools/fixtures/gen-chats.py --chats 20 --long 0:0 --turns 0 --memories 12 --memory-topics 4 --out /tmp/vq10m/antichat.sqlite`;
   add 3 pending suggestions: `sqlite3 /tmp/vq10m/antichat.sqlite "INSERT INTO memory_suggestion (id,text,topic,created_at) VALUES ('s1','Plays jazz piano','Hobbies',1),('s2','Runs on Sundays','Hobbies',2),('s3','Has a cat','Home',3)"`.
2. Launch `build/AntiChat.app/Contents/MacOS/AntiChat -ANTICHAT_DEV_CONTAINER /tmp/vq10m`. Sidebar footer: pill
   "3 new things to review" → `memory-review-pill`; click it → Settings › Personalization (`personalization-light`/`-dark`).
3. Suggestions section with 3 cards → `memory-suggestions`. Manage memories: Family (3), Food (3), Hobbies (3), Work (3)
   → `memory-browser`; Edit one → `memory-edit`; Reset with "RES" typed (disabled) → `memory-reset-disabled`.
4. In a chat run the scripted remember turn (`-UseScriptedEngine fixtures/scripts/memory-remember.jsonl`) →
   `memory-inline-collapsed`, expand → `memory-inline-expanded`; a later chat's first reply shows "Used memory ▸".
5. Component states (proposed · saved · undone · Used memory · pill, light/dark/Evil):
   `Packages/UI/Tests/AntiChatUIModuleTests/__Snapshots__/MemoryNoticeSnapshotTests/`.
