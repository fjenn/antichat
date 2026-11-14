# vq-05-image — Photo (journey 5, AT-VQ-M4)

Visual QA runbook for M4 (M4.T16; test-strategy §5, screens S-11 / S-13). The full checkpoint list is M4.md
§M4.T16 "vq-05-image runbook"; this file is the part that runs on this Mac today and how.

## Automated capture (in-process probe, scripted)
`tools/visual/vq-05-image.sh` (Debug build, `make build`) → `build/visual/<version>/vq-05-image/<variant>/`,
1440×900, system Light and Dark for every shot. The app runs with:
- `-UseScriptedEngine <turn.jsonl>`: turn 1 calls `create_image`; turn 2 calls `edit_image` with `{{image}}` = the
  picture the turn's context line names (what a model copies);
- `-UseScriptedImageEngine <{"steps":4,"delayMs":200}>`: the helper's ScriptedImageEngine (gradients, no weights)
  through the real queue → runner → **real gate with the dev cache's detectors** (no forced verdict);
- `-ChatModel chat-9b-q4` (a tool-capable slot: the starter is offered no tools, D-023 a), `-FakeHardware T1`
  (templated caption, no live previews), `-FakePackState photo=ready|absent`,
  `ANTICHAT_ERASE_MODEL=<dev cache>/img-erase/LaMa.mlpackage` (Erase runs LaMa for real);
- `-VisualQAProbe <dir> -VisualQAImageLeg <variant>` (App/AntiChat/VisualQAProbe.swift `imageLeg`): the probe drives
  the chat and asks the shell for window shots (want/got protocol, Screen Recording grant on the shell).

| Variant | Shots | Checkpoint |
|---|---|---|
| main | `image-done` | S-11 done card: the picture, `img.done.caption` (M4.md step 5) |
| main | `image-viewer` | S-13 viewer: zoom/save/copy/reveal, bottom toolbar Erase · Remove background, Describe the change focused, Best quality |
| main | `image-edit-done` | edit by text from the viewer → a turn with `edit_image` → second card (step 6) |
| main | `image-viewer-versions` | version rail newest first with `viewer.op.*` labels (step 18) |
| main | `image-erase` | Erase (brush mask → LaMa + feathered composite) → version 3 `Erased` (step 26) |
| main | `image-remove-background` | Remove background; on the scripted gradient Vision finds no subject (`noSubject`, honest) |
| main | `image-viewer-closed` | Esc → the transcript as it was (step 18) |
| missing | `image-safety-missing` | `ANTICHAT_NO_DETECTORS=1`: `safety.missing` card with the repair size (step 15) |
| install | `image-install-card` | `-FakePackState photo=absent`: Photo install card (step 13) |

Not capturable from a Debug build: the blocked tile (steps 14) needs `-ScriptedSafetyVerdict block`, which compiles
only in the UI-testing configuration (A-M4-T03a b, r241 rule 2b) — the tile is covered by the snapshot tests
(`imageJobCard.blocked-*`) and the forced-verdict suite (`tools/at/at-285-runner.sh`).

## Release leg at the Mac's real tier (vq-05-release.sh)
The probe and every launch argument are DEBUG-only, so a Release build is driven from outside:
`APP=build/tryout/AntiChat.app tools/visual/vq-05-release.sh <out>` (under `gpu-run.sh shared --` after the memory
check). It copies the try-out build (`make build-tryout`: Photo on through the try-out preview flag, never a change to
`ModelPack.shipped`) to a probe host with `app.antichat.AntiChat.relprobe-adhoc` ids (sign.sh --mode adhoc), runs it
with a scratch `CFFIXED_USER_HOME` whose Models links the dev models (the tier's photo set installed there with
`antichat-cli models import` / `models install`), `onboarding.completed`, and a Normal chat override (`CHAT_MODEL`,
default chat-35b-q4: a real model makes the `create_image` call), launched with `open -g -n` (never takes focus).
`tools/visual/axdrive.swift` drives it through the Accessibility API only (AXValue / AXPress; no activation, no
synthetic input, so the Erase brush is not painted here — the Debug REAL=1 leg covers brush + LaMa): prompt → done
card → viewer → Describe the change → version 2 → Erase mode → Remove background → version 3, one 1440×900 window shot per step in the System, Light
and Dark colour modes (`colorMode`). Note: preferences of the relprobe id live in the real home (cfprefsd ignores
CFFIXED_USER_HOME); the domain is the probe's own, never the shipped app's.

## Manual / pending checkpoints
Steps needing XCUITest or computer use (menus, drag to Finder/Mail, Get Info, QuickTime, ⌘Q prompt, force-quit,
memory pressure, 120 fps recordings) stay with the XCUITest legs (Q-015) and M9.T08 blind scoring. Steps 23–25 and
28 (variants, upscale, Markup, Sketch) moved to M11 (D-026).

## Findings format
Each checkpoint in `findings.md`: expected, observed, IS rule (IS-8), copy key match, grid, contrast.
