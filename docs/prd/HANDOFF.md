# AntiChat build handoff (updated 2026-11-09, main `fdbe54e1f`)

This is for whoever continues the build: another agent or another tool. Everything needed is in git; nothing lives only in a chat.

## Read first
1. `docs/prd/BUILD-BRIEF.md`: the working rules.
2. `docs/prd/BUILD-ORDER.md`: the chunk order and dependency notes.
3. The milestone card for the task you're on: `docs/prd/M{2..10}-card.md`.
4. What is left and who does it: `docs/prd/OWNER-STEPS.md` (owner-only items, ordered) and the README §1 status table.
5. `docs/prd/M11.md`: work moved out of v1. Don't build it.
6. `docs/research/DECISIONS.md` (D-0xx) and `docs/PRD-AMENDMENTS.md` (A-xx), searched by ID.

## How the work is organised
- **Tracks and the merge queue (2026-11-07):** one git worktree per track, under `.claude/worktrees/`. A track merges main only at the start of its run (or for a real conflict). It finishes when its own gates are green once on its branch: full `make test-unit`, `make test-integration-stub`, `BINARIES_SRC=$HOME/AntiChat/Binaries make audit` (EXIT=0). It then reports `READY: <branch> @<sha>` and stops. The lead's integration step merges all READY branches together, runs the full suite **once** on the combined result, and fast-forwards main. Tracks no longer run the merge → re-test → ff loop themselves; that loop multiplied full test runs.
- **One agent per worktree.** Two agents in one worktree overwrite each other's work; this happened twice.
- **Fixtures:** every worktree tests against its own `fixtures` submodule at the pinned commit (`git submodule update --init fixtures && git -C fixtures lfs pull`, `ANTICHAT_FIXTURES=$PWD/fixtures`).
  - Never commit inside another checkout's fixtures.
  - Push fixture or migration-lock commits to the bare repo `~/AntiChat-fixtures.git` main only **after** the code that needs them is on main.
- **Migrations:** the numbers are global, and v1–v27 are taken; check main before you pick one.
- **Never `git stash`.** The stash stack is shared across worktrees and carried files into the wrong tracks. Use WIP commits.
- **GPU and model runs:** run them through `~/AntiChat-tools/gpu-run.sh`.
  - Use `shared --` for accuracy runs; up to 2 run at once.
  - Use `timing --` for latency, throughput or memory numbers. It's exclusive and only starts when load avg < 40. After 45 min of waiting it exits 75 (`DEFERRED`); then record the number as deferred to M9.T05.
  - CPU-only benches don't go through it.
  - Before loading any model, check that free memory is at least model size + 20 GB.
  - Never edit `gpu-run.sh` in place while runs are live; write a new file and `mv` it over.
- **Load:** with 5 tracks, load runs at 50–250 on 18 cores. Don't run more than about 5 tracks. Note the load average next to every timing number, and never relax a bar because of load.
- **Background tests:** tests never take focus from the owner (`BackgroundRun`; the `no-focus-steal` audit). Visual-QA capture is the only exception.
- **Leftover processes:** every spawned server is guarded by a watchdog. `tools/ci/test-leftovers.sh` fails a test run that leaves its own servers behind.

## Standing owner rulings
- Full product: **no scope cuts beyond M11 and no accepted trade-offs** on bars. Items move to M11 only with the owner's OK.
- **D-005:** no harness safety filters in either mode.
- **D-006:** the only filter is the local ChildSafetyCheck on photo and video **outputs**. It blocks only sexual content involving minors, is called from exactly one place, and sends nothing.
  - Never create, collect or download sexual imagery of minors. Use lawful proxies only (Q-012).
  - A-M4-T02b is accepted: body-only recall comes first; a better body-age model is a re-check item in M9.T05.
- **Voice (A-M3-06):** English plus the western languages is enough. Arabic and Chinese stay on WhisperKit with the miss accepted (ar 11.4% WER, zh 10.6% CER); no new STT model.
  - Hallucination control in decoding (VAD trim, thresholds, temperature fallback, no previous-text conditioning, suppressing non-speech tokens) is **not** a content filter under R-241/D-005.
- **Citations (A-M7-T03c):** R-250 AC2 is gated on **independent labels** at ≥0.90; the chat-122b judge rate is reported too but doesn't gate. Scoring rule pre-registered in A-M7-T03d (first + strict pass, fresh adjudicator on disagreements); labellers must each work in a private temp dir.
- **Search:** A-M7-01 is accepted (native keyless engines, no bundled SearXNG). Engines that answer with a bot check are never retried or worked around.
- **Signing:** the Developer ID `Finn Jennen (446XT9839S)` is in the keychain. The notary profile is `AntiChat-notary`. Secrets never go in the repo.
- **Composio:** the key never ships in the app; the Vercel relay holds it. `Endpoints.plist` placeholders (repo URL, support email) come from the owner in M10.
- **The previous product:** never open the owner's earlier product, its folder or its repo.

## State at 2026-11-09 (main `fdbe54e1f`, after merge-queue rounds 13–17)
Rounds 13–17 (2026-11-09) merged: M3 close (`.voice` ships, round 13), M4 photo legs (13, 17), M3 review fixes (14), M4 and M5 review fixes (15), M7 search (16), T4 video on `vid-5b` (17, catalog v12). `m9/polish`, `m10/release`, `m3/voice`, `m4/photo`, `m5/video`, `integration/m0` (M8) and the `fix/*` review branches are fully merged.

| Milestone | State on main | Track in flight | Next |
|---|---|---|---|
| M0 | done, exit conditional (AT-VQ-M0, Q-021) | — | AT-VQ-M0 in M9.T08 |
| M1 | done; T26b / T27 folded into M9.T05 / M9.T08 (D-025) | — | XCUITest catch-up after Q-015 |
| M2 | done 2026-11-04 | — | — |
| M3 | done, exit conditional | — | AT-280 AC3 off-leg re-run [agent]; AT-280 AC1 [owner] |
| M4 | done (`fix/closeout` adds `.photo` to `ModelPack.shipped`) | `fix/closeout` | — |
| M5 | done with pending legs | — | VideoQueueXPCTests, offline + video job, AT-290 T3, A-M5-10 [agent]; VID2 and A-M5-13 [owner] |
| M6 | T01–T20 on main; **T21 close in progress** | `m6/sandbox` (11 ahead, 159 behind main) | merge main → gates → Release probe → M6-report → READY |
| M7 | T01–T16 on main; exit conditional | **`m7/bars` in progress** (AT-250 c2, T1 search latency, AT-266 c2 0.860 on the branch) | READY → lead merge; R-235 owner decision |
| M8 | done, exit conditional (owner grants) | — | owner passes (M8-owner-steps.md) |
| M9 | T01, T02, T04 done; T03 partial | — | **T05, T06, T08, T09, T10 not started**; T05 needs a machine with no other tracks |
| M10 | T01–T08 done | — | **T09: only the VM release smoke ran; the AT-FA-01…14 suite (`final-acceptance.md`, `FinalAcceptanceTests`, `fa-*.sh`, `make test-final`) is not built.** T10 blocked on the owner. **T11 not started** |

Cross-cutting: XCUITest has never run on this Mac (Q-015), and computer-use visual QA (Q-021) is pending for M0, M5, M6, M8, M9 and M10. Expect a fix-up pass when Q-015 is granted. Every owner-only item, in order, with its command: `docs/prd/OWNER-STEPS.md`.

Critical path: land M6 and M7 → M9.T05 on a quiet machine → M9.T06 soak → (Q-015, Q-021) XCUITest catch-up, M9.T03 / T08 → M9.T09 → M9.T10 → M10.T09 AT-FA → M10.T11 → owner M10 steps → M10.T10 re-runs → release.

## Open items to carry
- **XCUITest legs:** written but never run (Q-015); M10 `LegalUITests` / `HelpUITests` were written on `m10/missing-checks` (compile-checked by `tools/ci/uitests-build.sh`). AT-VQ-M0 (Q-021).
- **Office checks:** the Word/Excel/PowerPoint columns of the open-checks wait until Office is installed. Pages and Keynote licences are accepted.
- **Deferred to M9.T05:** everything recorded as `DEFERRED`, plus:
  - AT-248 c1 / AT-254 (measure the web-results prefill first)
  - NFR-M5 20-run + 10 Mbps
  - U3, PR1 tcpdump + journey loop
  - D3 real bytes
  - F7 full path
  - the body-age model re-check
- **Visual QA:** M7.T16 has the citation pill line-break check.
- **Leftovers:** pre-fix orphans (range-server.py, llama-server with ppid 1) may still be running. They're safe to stop with `pkill -P 1 -f 'worktrees/.*/(tools/fixtures/range-server.py|build/binaries/(llama|sd)-server)'`.

## Per-milestone close (D-025)
Each milestone closes with:
- all ATs and the full suite
- an **independent code review** (a separate agent; fix every confirmed finding)
- a running-app check
- 1440×900 light/dark captures
- the headline speed numbers

Then rebuild the owner try-out at `~/Desktop/AntiChat-tryout/` (Release, `make build-release`, arm64) with a short TRY-ME.md.

M6 pre-close review (2026-11-05): `docs/prd/reviews/M6-review.md` — 1 P0, 6 P1, 14 P2; fixed (21/21 re-checked in `M6-close-review.md` on `m6/sandbox`), #17 / #19 left for M9 polish.
